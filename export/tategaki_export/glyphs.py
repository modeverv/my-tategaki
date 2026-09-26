# Copyright (C) 2026 seijiro and contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Detect absent Unicode glyphs before making a publication look successful."""
from functools import lru_cache
import unicodedata


@lru_cache(maxsize=16)
def font_codepoints(path):
    from fontTools.ttLib import TTFont, TTCollection
    if path.lower().endswith('.ttc'):
        collection = TTCollection(path, lazy=True)
        try:
            return frozenset(cp for font in collection.fonts for cp in (font.getBestCmap() or {}))
        finally:
            collection.close()
    font = TTFont(path, lazy=True)
    try:
        return frozenset((font.getBestCmap() or {}).keys())
    finally:
        font.close()


def check_glyphs(document, fonts):
    supported = frozenset().union(*(font_codepoints(item['file']) for item in fonts))
    missing = []
    variations = False
    for block in document['blocks']:
        for run in block['runs']:
            for text in (run['text'], run.get('reading', '')):
                for char in text:
                    cp = ord(char)
                    if 0xFE00 <= cp <= 0xFE0F or 0xE0100 <= cp <= 0xE01EF:
                        variations = True
                        continue
                    if unicodedata.category(char) in ('Cc', 'Cf') or char.isspace():
                        continue
                    if cp not in supported:
                        missing.append({'character': char, 'codepoint': f'U+{cp:04X}',
                                        'source_run_start': run['start']})
    if missing:
        raise ValueError(f'No bundled/configured font glyph for: {missing[:20]}')
    return {'codepoint_coverage': True,
            'variation_selectors': 'Requires visual review of selected glyph shapes' if variations else 'none',
            'shaping': 'Coverage does not certify ZWJ/combining glyph shaping; review rendered pages.'}
