# Copyright (C) 2026 seijiro and contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Boundary tests independent of the external typesetting engines."""

from copy import deepcopy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "export"))
from tategaki_export.html import (export_html, html_document, prepare_publication,
                                 render_block, render_run, stylesheet, validate_html)
from tategaki_export.epub import set_epub_metadata, validate_epub
from tategaki_export.pdf import verify_pdf_words


def fixture():
    return {
        "schema_version": 1,
        "metadata": {"title": "本 & 題", "author": "筆名", "language": "ja", "identifier": "urn:test:source"},
        "blocks": [
            {"id": "chapter-1", "type": "heading", "level": 1, "start": 0, "end": 3,
             "runs": [{"kind": "text", "text": "一 & <", "emphasis": []}]},
            {"id": "p-1", "type": "paragraph", "start": 4, "end": 20, "runs": [
                {"kind": "ruby", "text": "東京", "reading": "とうきょう", "emphasis": []},
                {"kind": "text", "text": " の", "emphasis": ["dot"]},
                {"kind": "tcy", "text": "12", "emphasis": ["line"]},
                {"kind": "text", "text": "か\u3099葛\U000e0100🙂。<script>", "emphasis": []}]},
            {"id": "p-empty", "type": "paragraph", "start": 21, "end": 21, "runs": []},
            {"id": "chapter-2", "type": "heading", "level": 1, "start": 22, "end": 23,
             "runs": [{"kind": "text", "text": "二", "emphasis": []}]},
            {"id": "p-2", "type": "paragraph", "start": 24, "end": 25,
             "runs": [{"kind": "text", "text": "終", "emphasis": []}]}],
        "expectations": {"body_text": "一 & <\n東京 の12か\u3099葛\U000e0100🙂。<script>\n\n二\n終",
                         "ruby_readings": ["とうきょう"], "chapters": [], "annotation_counts": {}}}


def make_epub(path, document):
    """Small fixed EPUB container; deliberately independent of Vivliostyle."""
    root = '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
    opf = '''<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0" unique-identifier="book-id"><metadata><dc:identifier id="book-id">urn:test:source</dc:identifier><dc:title>本 &amp; 題</dc:title><dc:creator>筆名</dc:creator><dc:language>ja</dc:language></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="body" href="body.xhtml" media-type="application/xhtml+xml"/></manifest><spine page-progression-direction="rtl"><itemref idref="body"/></spine></package>'''
    nav = '<nav epub:type="toc"><ol><li><a href="body.xhtml#chapter-1">一 &amp; &lt;</a></li><li><a href="body.xhtml#chapter-2">二</a></li></ol></nav>'
    content = "<main>" + "".join(render_block(b) for b in document["blocks"]) + "</main>"
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", root)
        archive.writestr("EPUB/package.opf", opf)
        archive.writestr("EPUB/nav.xhtml", html_document(document["metadata"], nav, ""))
        archive.writestr("EPUB/body.xhtml", html_document(document["metadata"], content, stylesheet({}, "epub")))


def mutate_zip(path, name, replacement):
    with zipfile.ZipFile(path) as archive:
        entries = [(info, archive.read(info.filename)) for info in archive.infolist()]
    with zipfile.ZipFile(path, "w") as archive:
        for info, data in entries:
            archive.writestr(info, replacement(data) if info.filename == name else data)


class HtmlTests(unittest.TestCase):
    def test_crlf_snapshot_text_is_not_normalized_by_xml(self):
        document = fixture()
        document["blocks"][1]["runs"].append({"kind": "text", "text": "\r", "emphasis": []})
        with tempfile.TemporaryDirectory() as directory:
            result = export_html(document, {}, Path(directory))
            self.assertTrue(result["validation"]["body_exact"])
            self.assertIn("&#13;", Path(result["path"]).read_text())

    def test_auto_tcy_does_not_break_escaped_apostrophe(self):
        html = render_run({"kind": "text", "text": "'12' & <34>", "emphasis": []}, True)
        root = ET.fromstring("<p>" + html + "</p>")
        self.assertEqual("".join(root.itertext()), "'12' & <34>")
        self.assertEqual(len(root.findall("span")), 2)

    def test_page_break_control_char_is_semantic(self):
        document = fixture()
        document["blocks"].insert(3, {"id": "break", "type": "page_break", "runs": [{"kind": "text", "text": "\f"}]})
        with tempfile.TemporaryDirectory() as directory:
            result = export_html(document, {}, Path(directory))
            self.assertNotIn("\f", Path(result["path"]).read_text())
            self.assertEqual(result["validation"]["body_blocks"], 6)

    def test_literal_html_and_complex_unicode_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            result = export_html(fixture(), {}, Path(directory))
            text = Path(result["path"]).read_text()
            self.assertIn("&lt;script&gt;", text)
            self.assertNotIn("<script>", text)
            self.assertIn("か\u3099葛\U000e0100", text)
            self.assertIn('<span class="emoji">🙂</span>', text)
            self.assertTrue(result["validation"]["ruby_exact"])
            self.assertIn('class="empty"', text)

    def test_zwj_emoji_kept_in_one_horizontal_shaping_span(self):
        html = render_run({"kind": "text", "text": "👩‍💻、☕️", "emphasis": []})
        self.assertIn('<span class="emoji">👩‍💻</span>', html)
        self.assertIn('<span class="emoji">☕️</span>', html)

    def test_missing_empty_paragraph_is_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            result = export_html(fixture(), {}, Path(directory))
            path = Path(result["path"])
            path.write_text(path.read_text().replace('<p id="p-empty" data-source-block="true" class="empty"></p>', ""))
            with self.assertRaisesRegex(ValueError, "block order"):
                validate_html(path, fixture())

    def test_epub_css_has_no_print_settings(self):
        css = stylesheet({"pdf": {"font_size_pt": 9, "page_width_mm": 123}}, "epub")
        self.assertNotIn("@page", css)
        self.assertNotIn("counter(page)", css)
        self.assertIn("font-size: 100%", css)

    def test_publication_local_entries_and_cover_privacy(self):
        with tempfile.TemporaryDirectory() as directory:
            document = fixture()
            document["metadata"]["contact"] = "private@example.com"
            config = prepare_publication(document, {"epub": {"cover": True}}, Path(directory), "epub")
            data = json.loads(config.read_text())
            self.assertEqual(data["readingProgression"], "rtl")
            self.assertEqual(len(data["entry"]), 4)
            cover = (Path(directory) / "epub-source/cover.html").read_text()
            self.assertNotIn("private@example.com", cover)

    def test_without_headings_navigation_still_points_to_body(self):
        with tempfile.TemporaryDirectory() as directory:
            document = fixture()
            document["blocks"] = [block for block in document["blocks"] if block["type"] != "heading"]
            config = prepare_publication(document, {}, Path(directory), "epub")
            data = json.loads(config.read_text())
            self.assertEqual(len(data["entry"]), 2)
            toc = ET.fromstring((Path(directory) / "epub-source/toc.html").read_text())
            links = list(toc.iter("{http://www.w3.org/1999/xhtml}a"))
            self.assertEqual([link.attrib["href"] for link in links], ["chapter-0001.html#p-1"])


class EpubTests(unittest.TestCase):
    def test_converter_cr_normalization_is_repaired_without_losing_text(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.epub"
            document = fixture()
            document["blocks"][1]["runs"].append({"kind": "text", "text": "\r", "emphasis": []})
            make_epub(path, document)
            mutate_zip(path, "EPUB/body.xhtml", lambda data: data.replace(b"&#13;", b"\n"))
            set_epub_metadata(path, document)
            self.assertTrue(validate_epub(path, document)["body_exact"])

    def test_cr_repair_does_not_hide_other_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.epub"
            document = fixture()
            document["blocks"][1]["runs"].append({"kind": "text", "text": "\r", "emphasis": []})
            make_epub(path, document)
            mutate_zip(path, "EPUB/body.xhtml", lambda data: data.replace(b"&#13;", b"CORRUPTED\n"))
            with self.assertRaisesRegex(ValueError, "beyond XML"):
                set_epub_metadata(path, document)

    def test_structure_body_ruby_links_and_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.epub"
            make_epub(path, fixture())
            result = validate_epub(path, fixture())
            self.assertTrue(result["body_exact"])
            self.assertEqual(result["body_blocks"], 5)
            self.assertFalse(result["epubcheck"]["passed"])

    def test_lost_chapter_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.epub"
            document = fixture()
            document["blocks"] = document["blocks"][:3]
            make_epub(path, document)
            with self.assertRaisesRegex(ValueError, "block/chapter order"):
                validate_epub(path, fixture())

    def test_ruby_tampering_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.epub"
            make_epub(path, fixture())
            mutate_zip(path, "EPUB/body.xhtml", lambda data: data.replace("とうきょう".encode(), "おおさか".encode()))
            with self.assertRaisesRegex(ValueError, "ruby readings"):
                validate_epub(path, fixture())

    def test_identifier_rewrite_preserves_zip_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.epub"
            make_epub(path, fixture())
            document = fixture()
            document["metadata"]["identifier"] = "urn:new:identifier"
            set_epub_metadata(path, document)
            self.assertTrue(validate_epub(path, document)["metadata_exact"])

    def test_broken_navigation_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.epub"
            make_epub(path, fixture())
            mutate_zip(path, "EPUB/nav.xhtml", lambda data: data.replace(b"#chapter-2", b"#missing"))
            with self.assertRaisesRegex(ValueError, "Broken EPUB link"):
                validate_epub(path, fixture())


class PdfTests(unittest.TestCase):
    def bbox(self, path, document, *, reordered=False, extra=False):
        from html import escape
        blocks = document["blocks"][:]
        if reordered:
            blocks[-1], blocks[-2] = blocks[-2], blocks[-1]
        words = []
        def word(text, size):
            words.append(f'<word xMin="100" yMin="100" xMax="{100+size}" yMax="{100+size*2.6}">{escape(text)}</word>')
        for block in blocks:
            for run in block["runs"]:
                for char in run["text"]:
                    if char not in " \u3000":
                        word(char, 12)
                if "dot" in run.get("emphasis", []):
                    for char in run["text"]:
                        word("\ufe45", 6)
            for run in block["runs"]:
                if run["kind"] == "ruby":
                    for char in run["reading"]:
                        word(char, 6)
        if extra:
            word("余", 12)
        path.write_text('<html xmlns="http://www.w3.org/1999/xhtml"><page height="595">' + ''.join(words) + '</page></html>')

    def test_geometric_ruby_and_body_order(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bbox.html"
            self.bbox(path, fixture())
            result = verify_pdf_words(path, fixture(), {}, 1)
            self.assertTrue(result["ordered_text"])
            self.assertTrue(result["ruby_exact"])

    def test_out_of_order_text_fails_without_sorting(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bbox.html"
            self.bbox(path, fixture(), reordered=True)
            with self.assertRaisesRegex(ValueError, "ordered body"):
                verify_pdf_words(path, fixture(), {}, 1)

    def test_extra_text_is_not_accepted_as_subsequence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bbox.html"
            self.bbox(path, fixture(), extra=True)
            with self.assertRaisesRegex(ValueError, "ordered body"):
                verify_pdf_words(path, fixture(), {}, 1)


if __name__ == "__main__":
    unittest.main()
