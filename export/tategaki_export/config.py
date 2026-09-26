# Copyright (C) 2026 seijiro and contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Profiles and model validation; no manuscript syntax lives in Python."""
import copy
import hashlib
import json
from pathlib import Path
import jsonschema

ROOT = Path(__file__).resolve().parents[1]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def validate_schema(value, name):
    jsonschema.Draft202012Validator(read_json(ROOT / 'schemas' / f'{name}.json')).validate(value)


def load_profile(name):
    path = ROOT / 'profiles' / f'{name}.json' if name in ('preview', 'submission') else Path(name)
    profile = read_json(path)
    validate_schema(profile, 'profile')
    for kind in ('docx', 'pdf'):
        config = profile[kind]
        margins = config['margin_mm']
        if margins['left'] + margins['right'] >= config['page_width_mm'] or \
                margins['top'] + margins['bottom'] >= config['page_height_mm']:
            raise ValueError(f'{kind}: margins consume the entire page')
    return copy.deepcopy(profile)


def validate_document(document, source):
    validate_schema(document, 'document')
    if sha256(source.encode('utf-8')) != document['source']['sha256']:
        raise ValueError('Model/source SHA-256 mismatch')
    blocks = document['blocks']
    ids = [b['id'] for b in blocks]
    if len(ids) != len(set(ids)):
        raise ValueError('Duplicate block IDs')
    previous = 0
    for block in blocks:
        if not previous <= block['start'] <= block['end'] <= len(source):
            raise ValueError('Invalid or out-of-order block source range')
        previous = block['end']
        for run in block['runs']:
            if not block['start'] <= run['start'] <= run['end'] <= block['end']:
                raise ValueError('Run outside block source range')
    body = '\n'.join(''.join(r['text'] for r in b['runs']) for b in blocks)
    if body != document['expectations']['body_text']:
        raise ValueError('Body expectation differs from model runs')
    readings = [r['reading'] for b in blocks for r in b['runs'] if r['kind'] == 'ruby']
    if readings != document['expectations']['ruby_readings']:
        raise ValueError('Ruby expectations differ from model runs')
    chapters = [{'id': b['id'], 'title': ''.join(r['text'] for r in b['runs']), 'level': b['level']}
                for b in blocks if b['type'] == 'heading']
    if chapters != document['expectations']['chapters']:
        raise ValueError('Chapter expectations differ from model order')
