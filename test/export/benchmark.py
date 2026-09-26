#!/usr/bin/env python3
# Copyright (C) 2026 seijiro and contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Measure real Docker exports at 10k/100k/200k in three source shapes."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--formats', default='txt,docx,epub,html')
    parser.add_argument('--sizes', default='10000,100000,200000')
    parser.add_argument('--rounds', type=int, default=2)
    args = parser.parse_args()
    directory = ROOT / 'dist' / ('benchmark-' + uuid.uuid4().hex[:8])
    directory.mkdir(parents=True)
    results = []
    for size in map(int, args.sizes.split(',')):
        for name, unit in [('short', '　これは長文出力の検証原稿です。文章と句読点を保持します。\n'),
                           ('single', '日本語の本文を縦に組みます。'),
                           ('annotations', '｜東京《とうきょう》へ向かう。［＃傍点］重要［＃傍点終わり］な場面。\n')]:
            text = unit * (size // len(unit))
            # Do not accidentally introduce malformed annotations at the cutoff.
            text += '文' * (size - len(text))
            source = directory / f'{name}-{size}.txt'
            source.write_text(text, encoding='utf-8')
            for iteration in range(args.rounds):
                job_id = f'{name}-{size}-run{iteration + 1}'
                started = time.monotonic()
                proc = subprocess.run([str(ROOT / 'bin/tategaki-export'), 'export', str(source),
                                       '--formats', args.formats, '--out', str(directory),
                                       '--job-id', job_id], capture_output=True, text=True, timeout=1200)
                report = json.loads((directory / job_id / 'report.json').read_text())
                row = {'shape': name, 'source_codepoints': size, 'run': iteration + 1,
                       'wall_seconds': round(time.monotonic() - started, 3),
                       'duration_seconds': report['duration_seconds'], 'status': report['status'],
                       'peak_child_rss_kib': report['peak_child_rss_kib'],
                       'peak_runner_rss_kib': report['peak_runner_rss_kib'],
                       'formats': {kind: {'status': value['status'], 'seconds': value.get('duration_seconds')}
                                   for kind, value in report['formats'].items()}}
                results.append(row)
                (directory / 'timings.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
                print(json.dumps(row), flush=True)
                if proc.returncode:
                    raise RuntimeError(f'{job_id} failed: {proc.stderr}; see {directory / job_id}')
    print(directory)


if __name__ == '__main__':
    main()
