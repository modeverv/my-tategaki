"""Isolated job lifecycle, provenance, atomic publication and cancellation."""
import argparse
import importlib
import json
import os
import platform
import resource
import shutil
import signal
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from .config import ROOT, load_profile, read_json, sha256, validate_document, validate_schema

FORMATS = ('txt', 'docx', 'pdf', 'epub', 'html')


class Cancelled(Exception):
    pass


def now():
    return datetime.now(timezone.utc).isoformat()


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


class Runner:
    def __init__(self, directory, timeout):
        self.directory = directory
        self.timeout = timeout
        self.sequence = 0
        self.child = None

    def __call__(self, argv, cwd=None, timeout=None):
        self.sequence += 1
        self.child = subprocess.Popen([str(x) for x in argv], cwd=cwd, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            stdout, stderr = self.child.communicate(timeout=min(timeout or self.timeout, self.timeout))
        except (subprocess.TimeoutExpired, Cancelled):
            os.killpg(self.child.pid, signal.SIGKILL)
            self.child.communicate()
            raise
        finally:
            # A signal handler may raise Cancelled while communicate is active.
            if self.child.poll() is not None:
                returncode = self.child.returncode
                self.child = None
        log = self.directory / f'{self.sequence:03d}-{Path(argv[0]).name}.log'
        log.write_text(stdout + '\n' + stderr, encoding='utf-8')
        if returncode:
            raise RuntimeError(f"{Path(argv[0]).name} exited {returncode}: {(stderr or stdout)[-2000:]}")
        return subprocess.CompletedProcess(argv, returncode, stdout, stderr)


def versions():
    result = {'architecture': platform.machine(), 'python': platform.python_version(),
              'runtime': os.environ.get('TATEGAKI_EXPORT_IMAGE', 'tategaki-export:1'),
              'image_id': os.environ.get('TATEGAKI_EXPORT_IMAGE_ID', 'unrecorded direct container invocation'),
              'network': 'disabled by launcher'}
    commands = {'pandoc': ['pandoc', '--version'], 'node': ['node', '--version'],
                'vivliostyle': ['vivliostyle', '--version'], 'chromium': ['chromium', '--version'],
                'emacs': ['emacs', '--version'], 'epubcheck': ['epubcheck', '--version'],
                'poppler': ['pdftotext', '-v'], 'java': ['java', '-version']}
    for name, argv in commands.items():
        try:
            output = subprocess.run(argv, capture_output=True, text=True, timeout=30)
            result[name] = (output.stdout or output.stderr).splitlines()[0]
        except (OSError, subprocess.SubprocessError, IndexError) as error:
            result[name] = {'unavailable': str(error)}
    return result


def fonts(profile, requested, run):
    result = []
    for name in sorted({profile[k]['font'] for k in requested if k in ('docx', 'pdf', 'epub')}):
        output = run(['fc-match', '-f', '%{family}\n%{file}\n', name]).stdout.splitlines()
        if len(output) < 2 or name not in output[0].split(','):
            raise ValueError(f'Required font is unavailable: {name}; match was {output[:1]}')
        path = Path(output[1])
        result.append({'requested': name, 'family': output[0], 'file': str(path),
                       'sha256': sha256(path.read_bytes())})
    # Fallback faces are part of provenance, never an undeclared host dependency.
    for name in ('Noto Sans CJK JP', 'Noto Color Emoji'):
        output = run(['fc-match', '-f', '%{family}\n%{file}\n', name]).stdout.splitlines()
        path = Path(output[1])
        result.append({'fallback': True, 'family': output[0], 'file': str(path),
                       'sha256': sha256(path.read_bytes())})
    return result


def report_markdown(report):
    lines = [f"# Export {report['job_id']}", '', f"Status: **{report['status']}**", '',
             f"Input SHA-256: `{report.get('input_sha256', 'unavailable')}`", '',
             f"Profile SHA-256: `{report.get('profile_sha256', 'unavailable')}`", '',
             '| Format | Status | Artifact |', '|---|---|---|']
    for name, item in report['formats'].items():
        artifact = item.get('artifact', '')
        lines.append(f"| {name} | {item['status']} | {artifact} |")
    for name, item in report['formats'].items():
        if item.get('error'):
            lines.extend(['', f"## {name} error", '', item['error']])
        for warning in item.get('warnings', []):
            lines.extend(['', f'- {name}: {warning}'])
    lines.extend(['', '## Diagnostics', ''])
    for item in report.get('diagnostics', []):
        lines.append(f"- {item['severity']} {item['code']} [{item['start']}:{item['end']}]: {item['message']}")
    if report.get('error'):
        lines.extend(['', report['error']])
    lines.extend(['', '## Validation limits', ''])
    lines.extend(f'- {item}' for item in report['unverified'])
    return '\n'.join(lines) + '\n'


def save_report(directory, report):
    write_json(directory / 'report.json', report)
    path = directory / 'report.md.tmp'
    path.write_text(report_markdown(report), encoding='utf-8')
    path.replace(directory / 'report.md')


def run_job(args):
    output = Path(args.out)
    output.mkdir(parents=True, exist_ok=True)
    if (output / 'report.json').exists():
        raise ValueError('Job directory already contains a report; use a new job ID')
    requested = list(dict.fromkeys(args.formats.split(',')))
    report = {'schema_version': 1, 'job_id': args.job_id, 'status': 'running', 'started_at': now(),
              'formats': {name: {'status': 'pending' if name in requested else 'not_requested'} for name in FORMATS},
              'unverified': ['Microsoft Word rendering and re-editing require testing in the target Word version.',
                             'Apple Books / Kindle Previewer rendering and font resizing require reader tests.',
                             'PDF visual review is separate from structural validation; see validation evidence.',
                             'No printer-specific PDF/X compliance is claimed. This is a proof/submission PDF.',
                             'Character/400 conversion, fixed-grid page estimates and actual PDF pages differ.']}
    started = time.monotonic()
    logs = output / 'logs'
    logs.mkdir()
    runner = Runner(logs, args.timeout)
    previous_handlers = {}
    for sig in (signal.SIGTERM, signal.SIGINT):
        previous_handlers[sig] = signal.signal(sig, lambda *_: (_ for _ in ()).throw(Cancelled()))
    save_report(output, report)
    try:
        Path(os.environ.get('HOME', '/tmp/home')).mkdir(parents=True, exist_ok=True)
        if Path('/input/fonts').is_dir():
            font_config = Path('/tmp/tategaki-fonts.conf')
            font_config.write_text('<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">'
                                   '<fontconfig><include>/etc/fonts/fonts.conf</include>'
                                   '<dir>/input/fonts</dir><cachedir>/tmp/font-cache</cachedir></fontconfig>')
            os.environ['FONTCONFIG_FILE'] = str(font_config)
        if not requested or set(requested) - set(FORMATS):
            raise ValueError(f'Unknown formats: {requested}')
        if args.timeout <= 0:
            raise ValueError('timeout must be positive')
        source_bytes = Path(args.source).read_bytes()
        source = source_bytes.decode('utf-8', errors='strict')
        report['input_sha256'] = sha256(source_bytes)
        (output / 'source.txt').write_bytes(source_bytes)
        profile = load_profile(args.profile)
        if args.metadata:
            metadata = read_json(args.metadata)
            validate_schema({**profile, 'metadata': metadata}, 'profile')
            profile['metadata'].update(metadata)
        profile['metadata'].setdefault('identifier', 'urn:sha256:' + report['input_sha256'])
        report['profile_sha256'] = sha256(json.dumps(profile, ensure_ascii=False, sort_keys=True).encode('utf-8'))
        report['profile'] = profile['name']
        write_json(output / 'profile.json', profile)
        model_path = output / 'document.json'
        if args.model:
            document = read_json(args.model)
            # Snapshot metadata wins over built-in placeholder defaults.
            document['metadata'] = {**profile['metadata'], **document['metadata']}
            if args.metadata:
                document['metadata'].update(read_json(args.metadata))
            write_json(model_path, document)
        else:
            options = {'metadata': profile['metadata'], 'input': profile['input'],
                       'source_name': args.source_name, 'timestamp': report['started_at']}
            write_json(output / 'model-options.json', options)
            runner(['emacs', '-Q', '--batch', '-L', '/app', '-l', 'tategaki-export-model.el',
                    '-f', 'tategaki-export-model-batch', str(output / 'source.txt'), str(model_path),
                    str(output / 'model-options.json')])
            document = read_json(model_path)
        validate_document(document, source)
        report['model_sha256'] = sha256(model_path.read_bytes())
        report['job_fingerprint'] = sha256((report['input_sha256'] + report['profile_sha256'] + report['model_sha256']).encode())
        report['diagnostics'] = document['diagnostics']
        report['source'] = document['source']
        report['counts'] = {'source_codepoints': len(source),
                            'body_codepoints': len(document['expectations']['body_text']),
                            'manuscript_400_equivalent': len(document['expectations']['body_text']) / 400,
                            'chapters': len(document['expectations']['chapters']),
                            'annotations': document['expectations']['annotation_counts']}
        report['tools'] = versions()
        report['fonts'] = []
        package_lock = Path('/opt/tategaki/debian-packages.lock')
        if package_lock.exists():
            shutil.copyfile(package_lock, output / 'debian-packages.lock')
        license_path = Path('/opt/tategaki/licenses')
        if license_path.exists():
            shutil.copytree(license_path, output / 'licenses')
        profile['_source_path'] = str(output / 'source.txt')
        for name in requested:
            item = report['formats'][name]
            item['status'] = 'running'
            save_report(output, report)
            format_started = time.monotonic()
            work = output / '.work' / name
            work.mkdir(parents=True)
            try:
                if profile['strict_diagnostics'] and any(d['severity'] in ('warning', 'error') for d in document['diagnostics']):
                    raise ValueError('Strict profile rejected unresolved source diagnostics; source.txt is preserved.')
                if name in ('docx', 'pdf', 'epub'):
                    selected_fonts = fonts(profile, [name], runner)
                    for font in selected_fonts:
                        if font not in report['fonts']:
                            report['fonts'].append(font)
                    if name == 'pdf':
                        from .glyphs import check_glyphs
                        item['glyph_coverage'] = check_glyphs(document, selected_fonts)
                adapter = getattr(importlib.import_module(f'.{name}', __package__), f'export_{name}')
                result = adapter(document, profile, work, runner)
                artifact = Path(result['path']).resolve()
                relative = artifact.relative_to(work.resolve())
                if not artifact.is_file() or not artifact.stat().st_size:
                    # Empty TXT is a valid empty manuscript.
                    if name != 'txt' or not artifact.is_file():
                        raise ValueError('Exporter did not produce a non-empty artifact')
                destination = output / name
                work.rename(destination)
                item.update(status='succeeded', artifact=str(Path(name) / relative),
                            sha256=sha256((destination / relative).read_bytes()),
                            validation=result.get('validation', {}), warnings=result.get('warnings', []))
            except Cancelled:
                item.update(status='cancelled', error='Cancelled by user')
                raise
            except Exception as error:
                item.update(status='failed', error=str(error))
            finally:
                item['duration_seconds'] = round(time.monotonic() - format_started, 3)
                save_report(output, report)
        report['status'] = 'succeeded' if all(report['formats'][n]['status'] == 'succeeded' for n in requested) else 'failed'
    except Cancelled:
        report['status'] = 'cancelled'
    except Exception as error:
        report.update(status='failed', error=str(error))
    finally:
        for item in report['formats'].values():
            if item['status'] in ('pending', 'running'):
                item['status'] = 'cancelled' if report['status'] == 'cancelled' else 'blocked'
        report['finished_at'] = now()
        report['duration_seconds'] = round(time.monotonic() - started, 3)
        report['peak_child_rss_kib'] = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        report['peak_runner_rss_kib'] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        save_report(output, report)
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)
    print(f"{report['status']}: {output / 'report.md'}", flush=True)
    return 0 if report['status'] == 'succeeded' else 130 if report['status'] == 'cancelled' else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('doctor')
    export = commands.add_parser('export')
    export.add_argument('--source', required=True)
    export.add_argument('--source-name', default='source.txt')
    export.add_argument('--profile', default='preview')
    export.add_argument('--formats', default=','.join(FORMATS))
    export.add_argument('--out', default='/output')
    export.add_argument('--job-id', required=True)
    export.add_argument('--model')
    export.add_argument('--metadata')
    export.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args(argv)
    if args.command == 'doctor':
        data = versions()
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return int(any(isinstance(v, dict) and 'unavailable' in v for v in data.values()))
    return run_job(args)
