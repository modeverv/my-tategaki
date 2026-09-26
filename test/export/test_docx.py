# Copyright (C) 2026 seijiro and contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
"""DOCX contract tests.  Actual Pandoc/Word rendering is an integration concern."""

from pathlib import Path
import sys
import tempfile
import unittest
from xml.etree import ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "export"))
from tategaki_export import docx


def manuscript():
    blocks = [
        {"id": "chapter-1", "type": "heading", "level": 1, "runs": [{"kind": "text", "text": "第一章 <>&$"}]},
        {"id": "p2", "type": "paragraph", "runs": [
            {"kind": "text", "text": "　 か\u3099 葛\U000e0100 👩‍💻\t"},
            {"kind": "ruby", "text": "漢字", "reading": "かんじ", "emphasis": ["dot"]},
            {"kind": "tcy", "text": "12", "emphasis": ["line"]},
            {"kind": "text", "text": "\n［＃未知の注記］"}]},
        {"id": "p3", "type": "paragraph", "runs": []},
        {"id": "p4", "type": "page_break", "runs": [{"kind": "text", "text": "\f"}]},
        {"id": "p5", "type": "paragraph", "runs": [{"kind": "ruby", "text": "空", "reading": "そら"}, {"kind": "ruby", "text": "海", "reading": "うみ"}]},
        {"id": "p6", "type": "paragraph", "runs": []},
    ]
    return {"schema_version": 1, "metadata": {"title": "題名", "subtitle": "副題", "author": "著者", "language": "ja", "identifier": "urn:test:1"},
            "blocks": blocks, "expectations": {"body_text": "第一章 <>&$\n　 か\u3099 葛\U000e0100 👩‍💻\t漢字12\n［＃未知の注記］\n\n\f\n空海\n", "ruby_readings": ["かんじ", "そら", "うみ"], "chapters": [{"id": "chapter-1", "title": "第一章 <>&$", "level": 1}]}}


def scaffold(path, document, options):
    root = docx._element("document")
    body = ET.SubElement(root, docx._w("body"))
    blocks = docx._cover_blocks(document, options) + document["blocks"]
    for index, block in enumerate(blocks):
        paragraph = ET.SubElement(body, docx._w("p"))
        if block["type"] == "heading":
            properties = ET.SubElement(paragraph, docx._w("pPr"))
            properties.append(docx._element("pStyle", val="Heading" + str(block["level"])))
        run = ET.SubElement(paragraph, docx._w("r"))
        ET.SubElement(run, docx._w("t")).text = f"TATEGAKIBLOCK{index:08d}"
    ET.SubElement(body, docx._w("sectPr"))
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("word/document.xml", ET.tostring(root))
        archive.writestr("word/styles.xml", f'<w:styles xmlns:w="{docx.W}"><w:style w:type="paragraph" w:styleId="Normal"><w:rPr><w:b/></w:rPr></w:style></w:styles>')
        archive.writestr("word/_rels/document.xml.rels", f'<Relationships xmlns="{docx.PR}"/>')
        archive.writestr("[Content_Types].xml", f'<Types xmlns="{docx.CT}"/>')
        archive.writestr("docProps/core.xml", '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"/>')


class DocxContractTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "日本語 原稿.docx"
        self.document = manuscript()
        self.profile = {"docx": {"font": "Noto Serif CJK JP", "font_size_pt": 12, "page_width_mm": 148, "page_height_mm": 210, "margin_mm": {"top": 10, "bottom": 15, "left": 20, "right": 25}}}

    def build(self):
        scaffold(self.path, self.document, self.profile["docx"])
        docx._reference(self.path, self.profile["docx"])
        docx._postprocess(self.path, self.document, self.profile["docx"])
        return docx.validate_docx(self.path, self.document, self.profile)

    def mutate_document(self, function):
        parts = docx._package(self.path)
        root = ET.fromstring(parts["word/document.xml"])
        function(root)
        parts["word/document.xml"] = docx._xml_bytes(root)
        docx._save_package(self.path, parts)

    def test_unicode_spacing_empty_paragraphs_annotations_and_page_break(self):
        validation = self.build()
        self.assertEqual(validation["paragraphs"], 6)
        self.assertEqual(validation["ruby"], 3)
        self.assertEqual(validation["tcy"], 1)
        self.assertEqual(validation["emphasis_dot_runs"], 1)
        self.assertEqual(validation["emphasis_line_runs"], 1)
        self.assertEqual(validation["word_visual_check"], "unverified")

    def test_cover_metadata_is_separate_from_manuscript(self):
        self.profile["docx"]["cover"] = True
        result = self.build()
        self.assertEqual(result["paragraphs"], 6)
        parts = docx._package(self.path)
        root = ET.fromstring(parts["docProps/core.xml"])
        self.assertEqual(root.find("dc:title", docx.NS).text, "題名")
        self.assertEqual(root.find("dc:creator", docx.NS).text, "著者")
        self.assertEqual(root.find("dc:identifier", docx.NS).text, "urn:test:1")

    def test_independent_expected_text_catches_shared_model_loss(self):
        self.document["blocks"][1]["runs"][0]["text"] = "欠落"
        with self.assertRaisesRegex(ValueError, "independent expected body"):
            self.build()

    def test_validator_detects_text_corruption(self):
        self.build()
        self.mutate_document(lambda root: setattr(root.find(".//w:t", docx.NS), "text", "壊れた"))
        with self.assertRaisesRegex(ValueError, "paragraph text/order"):
            docx.validate_docx(self.path, self.document, self.profile)

    def test_validator_detects_ruby_corruption_without_changing_base(self):
        self.build()
        self.mutate_document(lambda root: setattr(root.find(".//w:rt/w:r/w:t", docx.NS), "text", "誤読"))
        with self.assertRaisesRegex(ValueError, "ruby readings"):
            docx.validate_docx(self.path, self.document, self.profile)

    def test_validator_detects_lost_heading_style(self):
        self.build()
        self.mutate_document(lambda root: root.find(".//w:pStyle", docx.NS).set(docx._w("val"), "Normal"))
        with self.assertRaisesRegex(ValueError, "heading level/style"):
            docx.validate_docx(self.path, self.document, self.profile)

    def test_validator_detects_geometry_changes(self):
        self.build()
        self.mutate_document(lambda root: root.find(".//w:pgSz", docx.NS).set(docx._w("h"), "100"))
        with self.assertRaisesRegex(ValueError, "page dimensions"):
            docx.validate_docx(self.path, self.document, self.profile)

    def test_validator_detects_missing_explicit_font(self):
        self.build()
        self.mutate_document(lambda root: root.find(".//w:rPr", docx.NS).remove(root.find(".//w:rFonts", docx.NS)))
        with self.assertRaisesRegex(ValueError, "body font"):
            docx.validate_docx(self.path, self.document, self.profile)

    def test_validator_detects_disabled_tcy_with_text_intact(self):
        self.build()
        self.mutate_document(lambda root: root.find(".//w:eastAsianLayout", docx.NS).set(docx._w("vert"), "0"))
        with self.assertRaisesRegex(ValueError, "tate-chu-yoko"):
            docx.validate_docx(self.path, self.document, self.profile)

    def test_validator_detects_unlinked_page_number_field(self):
        self.build()
        self.mutate_document(lambda root: root.find(".//w:sectPr", docx.NS).remove(root.find(".//w:footerReference", docx.NS)))
        with self.assertRaisesRegex(ValueError, "not linked"):
            docx.validate_docx(self.path, self.document, self.profile)

    def test_page_number_option(self):
        self.profile["docx"]["page_numbers"] = False
        self.build()
        self.assertNotIn("word/tategaki-footer.xml", docx._package(self.path))

    def test_auto_tcy_preserves_long_numbers_and_full_body(self):
        runs = [{"kind": "text", "text": "12 123 !? !!!", "emphasis": ["dot"]}]
        result = docx._auto_tcy(runs, True)
        self.assertEqual("".join(run["text"] for run in result), runs[0]["text"])
        self.assertEqual([run["text"] for run in result if run["kind"] == "tcy"], ["12", "!?"])
        self.assertTrue(all(run["emphasis"] == ["dot"] for run in result))

    def test_scaffold_reordering_fails_before_promotion(self):
        scaffold(self.path, self.document, self.profile["docx"])
        self.mutate_document(lambda root: setattr(root.find(".//w:t", docx.NS), "text", "wrong sentinel"))
        with self.assertRaisesRegex(ValueError, "block order/content"):
            docx._postprocess(self.path, self.document, self.profile["docx"])

    def test_xml_ignorable_namespace_declaration_survives_rewrite(self):
        xml = f'<w:document xmlns:w="{docx.W}" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" mc:Ignorable="w14"><w:body/></w:document>'.encode()
        rewritten = docx._xml_bytes(ET.fromstring(xml), xml)
        self.assertIn(b'xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml"', rewritten)
        ET.fromstring(rewritten)

    def test_opc_parts_keep_interoperable_default_namespaces(self):
        # Bundled LibreOffice's OPC loader rejects prefixed package roots.
        self.build()
        parts = docx._package(self.path)
        self.assertIn(b'<Types xmlns="', parts["[Content_Types].xml"])
        self.assertIn(b'<Relationships xmlns="', parts["word/_rels/document.xml.rels"])

    def test_core_properties_keep_prefix_used_by_xsi_type_qname(self):
        original = b'<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dcterms:created xsi:type="dcterms:W3CDTF">2026-09-27T00:00:00Z</dcterms:created></cp:coreProperties>'
        parts = {"docProps/core.xml": original}
        docx._metadata(parts, {"title": "検証"})
        actual = parts["docProps/core.xml"]
        self.assertIn(b'<cp:coreProperties', actual)
        self.assertIn(b'<dcterms:created xsi:type="dcterms:W3CDTF"', actual)
        self.assertNotIn(b'xmlns:ns0=', actual)
        self.assertNotIn(b'xmlns:ns1=', actual)

    def test_unsupported_control_character_fails_explicitly(self):
        with self.assertRaisesRegex(ValueError, "control character"):
            docx._plain_run("本文\x00欠落させない", self.profile["docx"])


if __name__ == "__main__":
    unittest.main()
