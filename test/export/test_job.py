# Copyright (C) 2026 seijiro and contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Job regression tests; renderer tests live beside these."""
import argparse
import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'export'))
from tategaki_export.config import load_profile, sha256, validate_document
from tategaki_export.job import Cancelled, Runner, run_job
from tategaki_export.txt import export_txt


def model(text):
    return {'schema_version': 1, 'source': {'sha256': sha256(text.encode())},
            'metadata': {'title': '試験', 'author': '', 'language': 'ja', 'identifier': 'urn:test:1'},
            'blocks': [{'id': 'p1', 'type': 'paragraph', 'start': 0, 'end': len(text),
                        'runs': [{'kind': 'text', 'text': text, 'start': 0, 'end': len(text), 'emphasis': []}]}],
            'expectations': {'body_text': text, 'ruby_readings': [], 'chapters': [], 'annotation_counts': {}},
            'diagnostics': []}


class JobTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.source = self.directory / '日本語 原稿.txt'
        self.source.write_text('本文「そのまま」。', encoding='utf-8')
        self.doc = model(self.source.read_text())
        self.model_file = self.directory / 'document.json'
        self.model_file.write_text(json.dumps(self.doc, ensure_ascii=False))
        self.args = argparse.Namespace(out=str(self.directory / 'output'), formats='txt,html',
                                       source=str(self.source), model=str(self.model_file),
                                       metadata=None, source_name=self.source.name,
                                       profile='preview', job_id='test-job', timeout=10)

    def run(self, result=None):
        # unittest calls run; keep environment writes scoped to its temporary HOME.
        return super().run(result)

    def execute(self):
        with patch('tategaki_export.job.versions', return_value={'test': True}), \
                patch.dict(os.environ, {'HOME': str(self.directory / 'home')}):
            code = run_job(self.args)
        report = json.loads((Path(self.args.out) / 'report.json').read_text())
        return code, report

    def test_success_atomic_artifacts_and_snapshot(self):
        original = self.source.read_bytes()
        code, report = self.execute()
        self.assertEqual(code, 0)
        self.assertEqual(report['formats']['pdf']['status'], 'not_requested')
        self.assertEqual((Path(self.args.out) / 'txt/source.txt').read_bytes(), original)
        self.assertEqual(self.source.read_bytes(), original)
        self.assertFalse((Path(self.args.out) / '.work/txt').exists())
        self.assertTrue((Path(self.args.out) / report['formats']['html']['artifact']).is_file())

    def test_failure_isolated_and_no_failed_promotion(self):
        with patch('tategaki_export.html.export_html', side_effect=ValueError('deliberate format error')):
            code, report = self.execute()
        self.assertEqual(code, 1)
        self.assertEqual(report['formats']['txt']['status'], 'succeeded')
        self.assertEqual(report['formats']['html']['status'], 'failed')
        self.assertFalse((Path(self.args.out) / 'html').exists())

    def test_cancel_does_not_run_remaining_formats(self):
        with patch('tategaki_export.txt.export_txt', side_effect=Cancelled()):
            code, report = self.execute()
        self.assertEqual(code, 130)
        self.assertEqual(report['status'], 'cancelled')
        self.assertEqual(report['formats']['html']['status'], 'cancelled')

    def test_hash_mismatch_blocks_all_formats(self):
        self.source.write_text('変更された原稿')
        code, report = self.execute()
        self.assertEqual(code, 1)
        self.assertIn('SHA-256', report['error'])
        self.assertEqual(report['formats']['txt']['status'], 'blocked')

    def test_profile_typo_rejected(self):
        value = load_profile('preview')
        value['pdf']['page_hight_mm'] = 100
        path = self.directory / 'bad.json'
        path.write_text(json.dumps(value))
        with self.assertRaises(Exception):
            load_profile(str(path))

    def test_impossible_page_rejected(self):
        value = load_profile('preview')
        value['pdf']['margin_mm']['top'] = 200
        path = self.directory / 'bad.json'
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, 'margins'):
            load_profile(str(path))

    def test_strict_annotation_failure_preserves_snapshot(self):
        self.doc['diagnostics'] = [{'code': 'unknown', 'severity': 'warning', 'message': 'unknown annotation', 'start': 0, 'end': 1}]
        self.model_file.write_text(json.dumps(self.doc))
        self.args.profile = 'submission'
        code, report = self.execute()
        self.assertEqual(code, 1)
        self.assertEqual(report['formats']['txt']['status'], 'failed')
        self.assertEqual((Path(self.args.out) / 'source.txt').read_bytes(), self.source.read_bytes())

    def test_duplicate_output_rejected(self):
        self.execute()
        with self.assertRaisesRegex(ValueError, 'already'):
            self.execute()

    def test_bad_source_ranges_rejected(self):
        self.doc['blocks'][0]['runs'][0]['end'] = 1000
        with self.assertRaisesRegex(ValueError, 'range'):
            validate_document(self.doc, self.source.read_text())

    def test_tampered_expectations_rejected(self):
        self.doc['expectations']['body_text'] = '欠落'
        with self.assertRaisesRegex(ValueError, 'expectation'):
            validate_document(self.doc, self.source.read_text())

    def test_txt_encoding_error_is_not_replacement(self):
        profile = load_profile('preview')
        profile['_source_path'] = str(self.source)
        profile['txt']['encoding'] = 'cp932'
        doc = model('原稿😀')
        with self.assertRaisesRegex(ValueError, 'source run offsets'):
            export_txt(doc, profile, self.directory, None)
        self.assertFalse((self.directory / 'body.txt').exists())

    def test_txt_original_crlf_is_exact(self):
        payload = '原稿\r\n次行\n'.encode()
        self.source.write_bytes(payload)
        profile = load_profile('preview')
        profile['_source_path'] = str(self.source)
        profile['txt']['newline'] = 'crlf'
        export_txt(model(payload.decode()), profile, self.directory, None)
        self.assertEqual((self.directory / 'source.txt').read_bytes(), payload)
        self.assertEqual((self.directory / 'body.txt').read_bytes(), '原稿\r\n次行\r\n'.encode())

    def test_runner_timeout_kills_process(self):
        run = Runner(self.directory, 1)
        with self.assertRaises(subprocess.TimeoutExpired):
            run([sys.executable, '-c', 'import time; time.sleep(30)'], timeout=1)
        self.assertIsNone(run.child)


if __name__ == '__main__':
    unittest.main()
