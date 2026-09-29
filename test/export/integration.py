#!/usr/bin/env python3
# Copyright (C) 2026 seijiro and contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Explicit Docker integration checks (not run by unittest discovery).

Run from the repository: python3 test/export/integration.py
Only this development test driver requires host Python; the product launcher does not.
"""
import concurrent.futures
import json
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / 'bin/tategaki-export'
FIXTURES = ROOT / 'test/export/fixtures'


def main():
    suite = ROOT / 'dist' / ('integration-' + uuid.uuid4().hex[:8])
    suite.mkdir(parents=True)
    results = []

    def job(name, source, profile='preview', formats='txt,html', expected=0, timeout=600):
        started = time.monotonic()
        process = subprocess.run([str(BIN), 'export', str(source), '--profile', str(profile),
                                  '--formats', formats, '--out', str(suite), '--job-id', name,
                                  '--timeout', str(timeout)], capture_output=True, text=True, timeout=timeout + 60)
        assert process.returncode == expected, (name, process.returncode, process.stdout, process.stderr)
        report = json.loads((suite / name / 'report.json').read_text())
        results.append({'case': name, 'duration_seconds': round(time.monotonic() - started, 3),
                        'report': f'{name}/report.json', 'status': report['status']})
        return report

    report = job('representative', FIXTURES / 'representative.txt', FIXTURES / 'representative-profile.json',
                 formats='txt,docx,pdf,epub,html')
    assert all(v['status'] == 'succeeded' for v in report['formats'].values())
    # Docker uses the host UID, which usually has no passwd entry in the image.
    # Java's default user.home becomes "?" and XMLResolver mistakes its cache
    # path for a URI query.  Keep that cache out of artifacts and logs clean.
    assert '[Fatal Error]' not in report['formats']['epub']['validation']['epubcheck']['output']
    assert not (suite / 'representative' / 'epub' / '?').exists()
    expected = json.loads((FIXTURES / 'representative-expected.json').read_text())
    model = json.loads((suite / 'representative/document.json').read_text())
    assert model['expectations']['body_text'] == expected['body_text']
    assert model['expectations']['ruby_readings'] == expected['ruby_readings']
    assert [{k: c[k] for k in ('title', 'level')} for c in model['expectations']['chapters']] == expected['chapters']
    assert (suite / 'representative/txt/source.txt').read_bytes() == (FIXTURES / 'representative.txt').read_bytes()
    job('unsupported-preview', FIXTURES / 'unsupported-annotations.txt')
    report = job('unsupported-strict', FIXTURES / 'unsupported-annotations.txt', 'submission', expected=1)
    assert report['diagnostics'] and report['formats']['txt']['status'] == 'failed'
    job('script', FIXTURES / 'script.txt', formats='txt,docx,pdf,epub,html')
    profile = json.loads((ROOT / 'export/profiles/preview.json').read_text())
    profile['pdf']['font'] = 'Tategaki Deliberately Missing Font 12345'
    custom = suite / 'missing-font.json'
    custom.write_text(json.dumps(profile))
    report = job('partial-failure', FIXTURES / 'script.txt', custom, formats='txt,pdf,html', expected=1)
    assert report['formats']['txt']['status'] == report['formats']['html']['status'] == 'succeeded'
    assert report['formats']['pdf']['status'] == 'failed'
    path = suite / '日本語と 空白 $(literal).txt'
    path.write_text('空白のあるパス。\r\n未保存に相当する本文。', encoding='utf-8', newline='')
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(lambda name: job(name, path), ['concurrent-a', 'concurrent-b']))
    for name in ('concurrent-a', 'concurrent-b'):
        assert (suite / name / 'txt/source.txt').read_bytes() == path.read_bytes()
    timeout_report = job('timeout', FIXTURES / 'representative.txt', formats='txt,pdf,html', expected=1, timeout=1)
    assert timeout_report['formats']['html']['status'] == 'succeeded'
    assert timeout_report['formats']['pdf']['status'] == 'failed'
    (suite / 'integration-results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
    print(suite)


if __name__ == '__main__':
    main()
