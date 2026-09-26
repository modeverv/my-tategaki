# Copyright (C) 2026 seijiro and contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Vivliostyle PDF adapter with independent Poppler checks."""

from __future__ import annotations

import os
from pathlib import Path
import re
import unicodedata
import xml.etree.ElementTree as ET

from .html import block_text, prepare_publication


def _comparison_text(text: str) -> str:
    # These two source spacing characters are checked separately through painted
    # text geometry. Do not use isspace(), NFC/NFKC, sorting or punctuation maps.
    return text.translate(str.maketrans("", "", " \u3000\r\n\f"))


def verify_pdf_words(bbox_path: Path, document: dict, profile: dict, first_page: int) -> dict:
    """Separate half-size ruby/emphasis from body without reordering glyphs."""
    root = ET.parse(bbox_path).getroot()
    size = float(profile.get("pdf", {}).get("font_size_pt", 12))
    margin = float(profile.get("pdf", {}).get("margin_mm", {}).get("bottom", 20)) * 72 / 25.4
    base, readings, dots = [], [], []
    for page_number, page in enumerate(root.iter("{http://www.w3.org/1999/xhtml}page"), 1):
        if page_number < first_page:
            continue
        height = float(page.attrib["height"])
        for word in page.iter("{http://www.w3.org/1999/xhtml}word"):
            text = "".join(word.itertext())
            width = float(word.attrib["xMax"]) - float(word.attrib["xMin"])
            word_height = float(word.attrib["yMax"]) - float(word.attrib["yMin"])
            if text == str(page_number) and float(word.attrib["yMin"]) >= height - margin:
                continue
            # Chromium's vertical glyph boxes are one em wide; sideways Latin
            # boxes use the font's 2.6 em vertical metrics with this pinned font.
            em_size = width if word_height >= width else width / 2.6
            if word_height >= 2 * size and width < 1.5 * size:
                em_size = max(em_size, word_height / 2.6)
            invisible = all(unicodedata.category(char) in {"Cf", "Mn", "Me"} for char in text)
            if 0 < em_size <= size * .8 and not invisible:
                (dots if all(char == "\ufe45" for char in text) else readings).append(text)
            else:
                base.append(text)
    actual = _comparison_text("".join(base))
    expected = _comparison_text("".join(block_text(block) for block in document["blocks"]))
    if document["metadata"].get("colophon"):
        expected += "奥付" + _comparison_text(document["metadata"]["colophon"])
    if actual != expected:
        mismatch = next((index for index, (left, right) in enumerate(zip(expected, actual)) if left != right), min(len(expected), len(actual)))
        raise ValueError(f"PDF ordered body differs at character {mismatch}: expected {expected[mismatch:mismatch+35]!r}, extracted {actual[mismatch:mismatch+35]!r}")
    expected_readings = _comparison_text("".join(document["expectations"].get("ruby_readings", [])))
    if _comparison_text("".join(readings)) != expected_readings:
        raise ValueError("PDF ruby readings differ after separating half-size text by geometry")
    expected_dots = sum(sum(unicodedata.category(char) not in {"Cf", "Mn", "Me"} for char in run["text"])
                        for block in document["blocks"] for run in block.get("runs", []) if "dot" in run.get("emphasis", []))
    if len("".join(dots)) != expected_dots:
        raise ValueError("PDF emphasis dot count differs from the source")
    return {"ordered_text": True, "ordered_body_blocks": len(document["blocks"]),
            "ruby_exact": True, "emphasis_dots": expected_dots,
            "text_comparison_rule": "Painting order, geometry-separated half-size ruby and sesame dots, footer outside body area. Only U+0020/U+3000 and CR/LF/formfeed excluded from glyph comparison; spaces checked separately. No normalization, punctuation replacement or sorting."}


def validate_pdf(path: Path, document: dict, profile: dict, run_command) -> dict:
    if not path.exists() or not path.read_bytes().startswith(b"%PDF-"):
        raise ValueError("Vivliostyle did not produce a PDF")
    info_result = run_command(["pdfinfo", str(path)], cwd=path.parent, timeout=60)
    info = info_result.stdout
    pages_match = re.search(r"^Pages:\s*(\d+)", info, re.M)
    size_match = re.search(r"^Page size:\s*([\d.]+) x ([\d.]+) pts", info, re.M)
    if not pages_match or not size_match:
        raise ValueError("PDF page count or size could not be read")
    pages = int(pages_match.group(1))
    dimensions = [float(size_match.group(i)) for i in (1, 2)]
    settings = profile.get("pdf", {})
    requested = [float(settings.get("page_width_mm", 148)) * 72 / 25.4,
                 float(settings.get("page_height_mm", 210)) * 72 / 25.4]
    if any(abs(actual - expected) > 1 for actual, expected in zip(dimensions, requested)):
        raise ValueError(f"PDF page size differs: {dimensions}, expected {requested} points")
    font_result = run_command(["pdffonts", str(path)], cwd=path.parent, timeout=60)
    font_lines = font_result.stdout.splitlines()
    fonts = []
    for line in font_lines[2:]:
        if not line.strip():
            continue
        # Last columns are emb/sub/uni/object/ID regardless of the font type's spaces.
        parts = line.split()
        if len(parts) < 8:
            raise ValueError(f"Unexpected pdffonts row: {line}")
        embedded, subset, unicode_map = parts[-5:-2]
        fonts.append({"name": parts[0], "embedded": embedded == "yes", "subset": subset == "yes", "unicode": unicode_map == "yes"})
    if not fonts or any(not font["embedded"] for font in fonts):
        raise ValueError("PDF contains unembedded fonts or has no text fonts")
    if any(not font["unicode"] for font in fonts):
        raise ValueError("PDF contains a font without a Unicode mapping")
    text_path = path.with_suffix(".extracted.txt")
    run_command(["pdftotext", "-raw", "-enc", "UTF-8", str(path), str(text_path)], cwd=path.parent, timeout=120)
    extracted = text_path.read_text(encoding="utf-8")
    if "\ufffd" in extracted and "\ufffd" not in document["expectations"].get("body_text", ""):
        raise ValueError("PDF extraction contains replacement characters absent from the source")
    destinations = run_command(["pdfinfo", "-dests", str(path)], cwd=path.parent, timeout=60).stdout
    first_id = document["blocks"][0]["id"] if document["blocks"] else ""
    destination_pages = [int(match.group(1)) for match in re.finditer(r'^\s*(\d+) .*:0023' + re.escape(first_id) + r'"$', destinations, re.M)]
    if not destination_pages:
        raise ValueError("PDF source-start destination is missing; cannot separate navigation from body")
    first_page = min(destination_pages)
    bbox_path = path.with_suffix(".bbox.html")
    run_command(["pdftotext", "-raw", "-bbox", str(path), str(bbox_path)], cwd=path.parent, timeout=120)
    text_validation = verify_pdf_words(bbox_path, document, profile, first_page)
    geometry_prefix = path.parent / "pdf-geometry"
    run_command(["pdftohtml", "-xml", "-i", str(path), str(geometry_prefix)], cwd=path.parent, timeout=120)
    geometry = ET.parse(geometry_prefix.with_suffix(".xml")).getroot()
    painted = "".join("".join(node.itertext()) for page in geometry.findall("page")
                      if int(page.attrib["number"]) >= first_page for node in page.findall("text"))
    source = "".join(block_text(block) for block in document["blocks"])
    # Poppler's geometry export maps the font's ideographic-space glyph to U+2003.
    # This is a glyph mapping check, not normalization of manuscript content.
    fullwidth_spaces = painted.count("\u2003") + painted.count("\u3000")
    if fullwidth_spaces < source.count("\u3000") or painted.count(" ") < source.count(" "):
        raise ValueError("PDF painted spacing glyph count is lower than the source")
    headings = [block_text(block) for block in document["blocks"] if block["type"] == "heading"]
    if headings and document["blocks"][0]["type"] != "heading":
        headings.insert(0, "本文")
    outline = geometry.find("outline")
    outline_titles = ["".join(item.itertext()) for item in outline.iter("item")] if outline is not None else []
    if headings and outline_titles != headings:
        raise ValueError("PDF bookmark titles/order differ from the source chapters")
    text_validation["bookmarks"] = True
    text_validation["source_spacing"] = {"ascii_spaces": source.count(" "), "ideographic_spaces": source.count("\u3000"),
                                         "painted_ascii_spaces": painted.count(" "), "painted_ideographic_spaces": fullwidth_spaces,
                                         "glyph_counts_present": True, "positions": "Inspect page images; no full positional equality is claimed."}
    renders = path.parent / "pdf-pages"
    renders.mkdir(exist_ok=True)
    run_command(["pdftoppm", "-png", "-r", "96", str(path), str(renders / "page")], cwd=path.parent,
                timeout=max(120, pages * 10))
    rendered = sorted(renders.glob("page-*.png"))
    if len(rendered) != pages or any(p.stat().st_size < 100 for p in rendered):
        raise ValueError("Not all PDF pages were successfully rasterized")
    return {"pages": pages, "size_points": dimensions, "page_size": True,
            "fonts": fonts, "embedded_fonts": True, "unicode_maps": True,
            **text_validation,
            "rendered_pages": len(rendered), "page_images": [str(p.relative_to(path.parent)) for p in rendered],
            "extracted_text": str(text_path.relative_to(path.parent)),
            "visual_review": "not performed by automated validator",
            "glyph_shape_review": "Font embedding and text mapping do not prove every glyph shape; inspect page images."}


def export_pdf(document: dict, profile: dict, workdir: Path, run_command) -> dict:
    if profile.get("pdf", {}).get("font", "Noto Serif CJK JP") != "Noto Serif CJK JP":
        raise ValueError("PDF geometry validation is currently verified only for Noto Serif CJK JP; select this font for PDF")
    config = prepare_publication(document, profile, workdir, "pdf")
    timeout = int(profile.get("timeout_seconds", 300))
    run_command(["vivliostyle", "build", "-c", str(config.resolve()),
                 "--executable-browser", os.environ.get("CHROME_BIN", "/usr/bin/chromium"),
                 "--no-vite-config-file", "--timeout", str(timeout)], cwd=workdir, timeout=timeout + 30)
    path = workdir / "manuscript.pdf"
    validation = validate_pdf(path, document, profile, run_command)
    return {"path": str(path.resolve()), "validation": validation,
            "warnings": ["提出・校正用PDFです。印刷所指定のPDF/X・塗り足し・色の検査は行っていません。",
                         "全ページの画像を生成しました。字形やルビの衝突は画像での確認が必要です。",
                         "PDF抽出が省略する半角・全角空白は描画字形数を照合しています。空白の位置・幅の完全一致は自動判定していません。"]}
