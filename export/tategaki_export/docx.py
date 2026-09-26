"""Editable vertical Word documents, with Pandoc scaffolding and OOXML annotations.

Only the shared document model is consumed here.  In particular this module must
not parse Aozora, Markdown, or Org syntax from the manuscript text.
"""

from __future__ import annotations

import io
import json
import re
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PR = "http://schemas.openxmlformats.org/package/2006/relationships"
CT = "http://schemas.openxmlformats.org/package/2006/content-types"
XML = "http://www.w3.org/XML/1998/namespace"
DC = "http://purl.org/dc/elements/1.1/"
NS = {"w": W, "r": R, "pr": PR, "ct": CT, "dc": DC,
      "cp": "http://schemas.openxmlformats.org/package/2006/metadata/core-properties",
      "dcterms": "http://purl.org/dc/terms/", "dcmitype": "http://purl.org/dc/dcmitype/",
      "xsi": "http://www.w3.org/2001/XMLSchema-instance"}
for _prefix, _uri in NS.items():
    ET.register_namespace(_prefix, _uri)


def _w(name):
    return "{" + W + "}" + name


def _element(name, **attrs):
    return ET.Element(_w(name), {_w(key): str(value) for key, value in attrs.items()})


def _put(parent, name, **attrs):
    """Replace a singleton property without leaving duplicate style settings."""
    for child in list(parent):
        if child.tag == _w(name):
            parent.remove(child)
    element = _element(name, **attrs)
    parent.append(element)
    return element


def _child(parent, name):
    child = parent.find(_w(name))
    if child is None:
        child = ET.SubElement(parent, _w(name))
    return child


def _xml_bytes(root, original=b""):
    """Retain declarations referenced only by mc:Ignorable (ElementTree drops them)."""
    namespaces = {}
    if original:
        for _, (prefix, uri) in ET.iterparse(io.BytesIO(original), events=("start-ns",)):
            namespaces.setdefault(prefix, uri)
    data = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    # The OPC loader in bundled LibreOffice rejects prefixed Types/Relationships
    # roots even though equivalent namespaced XML is well formed. Keep the
    # conventional default namespace for these package parts.
    for prefix, uri in (("ct", CT), ("pr", PR)):
        if root.tag.startswith("{" + uri + "}"):
            data = re.sub(rb"(<\/?)" + prefix.encode() + rb":", rb"\1", data)
            data = data.replace((f'xmlns:{prefix}="{uri}"').encode(), (f'xmlns="{uri}"').encode(), 1)
    # Namespace names and URIs originated in XML, not manuscript text.
    start = data.index(b"<", data.index(b"?>") + 2)
    end = data.index(b">", start)
    header = data[start:end]
    additions = b""
    for prefix, uri in namespaces.items():
        attribute = ("xmlns:" + prefix) if prefix else "xmlns"
        if not re.search(rb"\s" + re.escape(attribute.encode()) + rb"=", header):
            escaped = uri.replace("&", "&amp;").replace('"', "&quot;")
            additions += (f' {attribute}="{escaped}"').encode()
    return data[:end] + additions + data[end:]


def _package(path):
    with zipfile.ZipFile(path) as archive:
        bad = archive.testzip()
        if bad:
            raise ValueError(f"DOCX ZIP checksum failure: {bad}")
        return {item.filename: archive.read(item) for item in archive.infolist()}


def _save_package(path, parts):
    staging = path.with_suffix(".rewrite.docx")
    with zipfile.ZipFile(staging, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in parts.items():
            archive.writestr(name, data)
    staging.replace(path)


def _twips(mm):
    return round(float(mm) * 1440 / 25.4)


def _font_properties(properties, options, size=None):
    font = options.get("font", "Noto Serif CJK JP")
    _put(properties, "rFonts", ascii=font, hAnsi=font, eastAsia=font, cs=font)
    half_points = round(2 * float(size if size is not None else options.get("font_size_pt", 12)))
    _put(properties, "sz", val=half_points)
    _put(properties, "szCs", val=half_points)
    _put(properties, "color", val="000000")
    _put(properties, "lang", val="ja-JP", eastAsia="ja-JP")
    _sort_properties(properties, _RUN_ORDER)


_SECTION_ORDER = ["headerReference", "footerReference", "footnotePr", "endnotePr", "type",
                  "pgSz", "pgMar", "paperSrc", "pgBorders", "lnNumType", "pgNumType",
                  "cols", "formProt", "vAlign", "noEndnote", "titlePg", "textDirection",
                  "bidi", "rtlGutter", "docGrid", "printerSettings", "sectPrChange"]
_RUN_ORDER = ["rStyle", "rFonts", "b", "bCs", "i", "iCs", "caps", "smallCaps", "strike",
              "dstrike", "outline", "shadow", "emboss", "imprint", "noProof", "snapToGrid",
              "vanish", "webHidden", "color", "spacing", "w", "kern", "position", "sz", "szCs",
              "highlight", "u", "effect", "bdr", "shd", "fitText", "vertAlign", "rtl", "cs",
              "em", "lang", "eastAsianLayout", "specVanish", "oMath", "rPrChange"]
_PARAGRAPH_ORDER = ["pStyle", "keepNext", "keepLines", "pageBreakBefore", "framePr", "widowControl",
                    "numPr", "suppressLineNumbers", "pBdr", "shd", "tabs", "suppressAutoHyphens",
                    "kinsoku", "wordWrap", "overflowPunct", "topLinePunct", "autoSpaceDE", "autoSpaceDN",
                    "bidi", "adjustRightInd", "snapToGrid", "spacing", "ind", "contextualSpacing",
                    "mirrorIndents", "suppressOverlap", "jc", "textDirection", "textAlignment",
                    "textboxTightWrap", "outlineLvl", "divId", "cnfStyle", "rPr", "sectPr", "pPrChange"]
_STYLE_ORDER = ["name", "aliases", "basedOn", "next", "link", "autoRedefine", "hidden", "uiPriority",
                "semiHidden", "unhideWhenUsed", "qFormat", "locked", "personal", "personalCompose",
                "personalReply", "rsid", "pPr", "rPr", "tblPr", "trPr", "tcPr", "tblStylePr"]


def _sort_properties(parent, order):
    positions = {_w(name): index for index, name in enumerate(order)}
    parent[:] = sorted(parent, key=lambda element: positions.get(element.tag, len(order)))


def _section(section, options):
    _put(section, "pgSz", w=_twips(options.get("page_width_mm", 148)),
         h=_twips(options.get("page_height_mm", 210)))
    margins = options.get("margin_mm", {})
    _put(section, "pgMar", **{key: _twips(margins.get(key, 20)) for key in ("top", "bottom", "left", "right")},
         header=_twips(8), footer=_twips(8), gutter=0)
    _put(section, "textDirection", val="tbRl")
    _put(section, "cols", num=1, space=0)
    _put(section, "pgNumType", start=1)
    if options.get("chars_per_column") and options.get("columns_per_page"):
        chars, columns = int(options["chars_per_column"]), int(options["columns_per_page"])
        width_pt = (float(options.get("page_width_mm", 148)) - margins.get("left", 20) - margins.get("right", 20)) * 72 / 25.4
        height_pt = (float(options.get("page_height_mm", 210)) - margins.get("top", 20) - margins.get("bottom", 20)) * 72 / 25.4
        if chars < 1 or columns < 1 or width_pt <= 0 or height_pt <= 0:
            raise ValueError("Invalid DOCX manuscript grid dimensions")
        _put(section, "docGrid", type="linesAndChars", linePitch=round(width_pt * 20 / columns),
             charSpace=round((height_pt / chars - float(options.get("font_size_pt", 12))) * 4096))
    else:
        _put(section, "docGrid", type="default")
    _sort_properties(section, _SECTION_ORDER)


def _reference(path, options):
    parts = _package(path)
    styles = ET.fromstring(parts["word/styles.xml"])
    defaults = _child(_child(styles, "docDefaults"), "rPrDefault")
    _font_properties(_child(defaults, "rPr"), options)
    _sort_properties(styles.find("w:docDefaults", NS), ["rPrDefault", "pPrDefault"])
    for style in styles.findall("w:style", NS):
        identifier = style.get(_w("styleId"), "")
        if identifier in {"Normal", "BodyText", "FirstParagraph", "Compact", "Title", "Subtitle"} or identifier.startswith("Heading"):
            size = float(options.get("font_size_pt", 12))
            if identifier.startswith("Heading") or identifier == "Title":
                size *= 1.25
            _font_properties(_child(style, "rPr"), options, size)
            properties = _child(style, "pPr")
            _put(properties, "spacing", before=0, after=0,
                 line=round(float(options.get("line_height", 1.5)) * 240), lineRule="auto")
            _put(properties, "widowControl", val=0)
            if identifier in {"Normal", "BodyText", "FirstParagraph", "Compact"}:
                _put(properties, "ind", left=0, right=0, firstLine=0)
            _sort_properties(properties, _PARAGRAPH_ORDER)
            _sort_properties(style, _STYLE_ORDER)
    _sort_properties(styles, ["docDefaults", "latentStyles", "style"])
    parts["word/styles.xml"] = _xml_bytes(styles, parts["word/styles.xml"])
    root = ET.fromstring(parts["word/document.xml"])
    for section in root.findall(".//w:sectPr", NS):
        _section(section, options)
    parts["word/document.xml"] = _xml_bytes(root, parts["word/document.xml"])
    _save_package(path, parts)


def _text_content(run, text):
    """Use explicit OOXML characters for tabs/line/page breaks; never normalize."""
    for part in re.split(r"([\t\n\r\f])", text):
        if part == "\t":
            ET.SubElement(run, _w("tab"))
        elif part in ("\n", "\f"):
            run.append(_element("br", **({"type": "page"} if part == "\f" else {})))
        elif part == "\r":
            ET.SubElement(run, _w("cr"))
        elif part:
            if any(ord(char) < 32 for char in part):
                raise ValueError("Manuscript contains a control character unsupported by DOCX XML")
            node = ET.SubElement(run, _w("t"), {"{" + XML + "}space": "preserve"})
            node.text = part


def _plain_run(text, options, emphasis=(), tcy=False, identifier=1, size=None):
    run = _element("r")
    properties = ET.SubElement(run, _w("rPr"))
    _font_properties(properties, options, size)
    if "line" in emphasis:
        _put(properties, "u", val="single")
    if "dot" in emphasis:
        _put(properties, "em", val="dot")
    if tcy:
        # ECMA-376 horizontal-in-vertical text; combine means two-lines-in-one.
        _put(properties, "eastAsianLayout", id=identifier, vert="1", vertCompress="1")
    _sort_properties(properties, _RUN_ORDER)
    _text_content(run, text)
    return run


def _annotated_run(item, options, identifier=1, size=None):
    emphasis = item.get("emphasis") or []
    if item.get("kind") != "ruby":
        return _plain_run(item.get("text", ""), options, emphasis, item.get("kind") == "tcy", identifier, size)
    size = float(size if size is not None else options.get("font_size_pt", 12))
    wrapper = _element("r")
    ruby = ET.SubElement(wrapper, _w("ruby"))
    properties = ET.SubElement(ruby, _w("rubyPr"))
    for name, value in [("rubyAlign", "distributeSpace"), ("hps", round(size)),
                        ("hpsRaise", round(size * 2)), ("hpsBaseText", round(size * 2)), ("lid", "ja-JP")]:
        properties.append(_element(name, val=value))
    reading = ET.SubElement(ruby, _w("rt"))
    reading.append(_plain_run(item["reading"], options, size=size / 2))
    base = ET.SubElement(ruby, _w("rubyBase"))
    base.append(_plain_run(item.get("text", ""), options, emphasis, size=size))
    return wrapper


def _auto_tcy(runs, enabled):
    if not enabled:
        return runs
    result = []
    # Match short, isolated numeric/punctuation groups without rewriting their text.
    pattern = re.compile(r"(?<![0-9])[0-9]{2}(?![0-9])|(?<![!?])[!?]{2}(?![!?])")
    for item in runs:
        if item.get("kind") != "text":
            result.append(item)
            continue
        text, position = item.get("text", ""), 0
        for match in pattern.finditer(text):
            if match.start() > position:
                result.append({**item, "text": text[position:match.start()]})
            result.append({**item, "kind": "tcy", "text": match.group()})
            position = match.end()
        if position < len(text):
            result.append({**item, "text": text[position:]})
    return result


def _paragraph_text(node):
    """Read base text, omitting ruby readings and paragraph/field metadata."""
    if node.tag in {_w("rt"), _w("rPr"), _w("pPr"), _w("rubyPr"), _w("instrText")}:
        return ""
    if node.tag == _w("t"):
        return node.text or ""
    if node.tag == _w("tab"):
        return "\t"
    if node.tag == _w("br"):
        return "\f" if node.get(_w("type")) == "page" else "\n"
    if node.tag == _w("cr"):
        return "\r"
    return "".join(_paragraph_text(child) for child in node)


def _footer(parts, section, options):
    for old in list(section):
        if old.tag == _w("footerReference"):
            section.remove(old)
    if not options.get("page_numbers", True):
        return
    rel_path = "word/_rels/document.xml.rels"
    relationships = ET.fromstring(parts[rel_path])
    identifier = "rIdTategakiFooter"
    existing = {entry.get("Id") for entry in relationships}
    while identifier in existing:
        identifier += "X"
    ET.SubElement(relationships, "{" + PR + "}Relationship", {"Id": identifier, "Type": R + "/footer", "Target": "tategaki-footer.xml"})
    parts[rel_path] = _xml_bytes(relationships, parts[rel_path])
    types = ET.fromstring(parts["[Content_Types].xml"])
    ET.SubElement(types, "{" + CT + "}Override", {"PartName": "/word/tategaki-footer.xml", "ContentType": "application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"})
    parts["[Content_Types].xml"] = _xml_bytes(types, parts["[Content_Types].xml"])
    section.insert(0, ET.Element(_w("footerReference"), {_w("type"): "default", "{" + R + "}id": identifier}))
    root = _element("ftr")
    paragraph = ET.SubElement(root, _w("p"))
    properties = ET.SubElement(paragraph, _w("pPr"))
    properties.append(_element("jc", val="center"))
    properties.append(_element("textDirection", val="lrTb"))
    field = ET.SubElement(paragraph, _w("fldSimple"), {_w("instr"): " PAGE "})
    field.append(_plain_run("1", options, size=9))
    parts["word/tategaki-footer.xml"] = _xml_bytes(root)
    _sort_properties(section, _SECTION_ORDER)


def _metadata(parts, metadata):
    path = "docProps/core.xml"
    if path not in parts:
        return
    root = ET.fromstring(parts[path])
    for name, key in [("title", "title"), ("creator", "author"), ("language", "language"), ("identifier", "identifier")]:
        for old in root.findall("{" + DC + "}" + name):
            root.remove(old)
        node = ET.SubElement(root, "{" + DC + "}" + name)
        value = metadata.get(key, "")
        node.text = "; ".join(value) if isinstance(value, list) else str(value)
    parts[path] = _xml_bytes(root, parts[path])


def _cover_blocks(document, options):
    if not options.get("cover", False):
        return []
    metadata = document.get("metadata", {})
    result = []
    for field in ("title", "subtitle", "author"):
        if metadata.get(field):
            value = metadata[field]
            text = "; ".join(value) if isinstance(value, list) else str(value)
            result.append({"id": "cover-" + field, "type": "paragraph", "cover": True,
                           "runs": [{"kind": "text", "text": text}]})
    result.append({"id": "cover-break", "type": "page_break", "cover": True,
                   "runs": [{"kind": "text", "text": "\f"}]})
    return result


def _postprocess(path, document, options):
    parts = _package(path)
    root = ET.fromstring(parts["word/document.xml"])
    body = root.find("w:body", NS)
    paragraphs = body.findall("w:p", NS)
    blocks = _cover_blocks(document, options) + document["blocks"]
    if len(paragraphs) != len(blocks):
        raise ValueError(f"Pandoc paragraph count changed: expected {len(blocks)}, got {len(paragraphs)}")
    identifier = 1
    for index, (paragraph, block) in enumerate(zip(paragraphs, blocks)):
        marker = f"TATEGAKIBLOCK{index:08d}"
        if _paragraph_text(paragraph) != marker:
            raise ValueError(f"Pandoc block order/content changed at block {index}")
        for child in list(paragraph):
            # Keep heading styles and Pandoc bookmarks, replace only visible runs.
            if child.tag not in {_w("pPr"), _w("bookmarkStart"), _w("bookmarkEnd")}:
                paragraph.remove(child)
        size = float(options.get("font_size_pt", 12))
        if block.get("type") == "heading" or block.get("id") == "cover-title":
            size *= 1.25
        for item in _auto_tcy(block.get("runs", []), options.get("auto_tcy", False)):
            paragraph.append(_annotated_run(item, options, identifier, size))
            identifier += 1
    section = body.find("w:sectPr", NS)
    if section is None:
        section = ET.SubElement(body, _w("sectPr"))
    _section(section, options)
    _footer(parts, section, options)
    parts["word/document.xml"] = _xml_bytes(root, parts["word/document.xml"])
    _metadata(parts, document.get("metadata", {}))
    _save_package(path, parts)


def validate_docx(path, document, profile):
    """Fail on lost/changed text, readings, heading order, direction, or geometry."""
    options = profile.get("docx", {})
    parts = _package(Path(path))
    for name, data in parts.items():
        if name.endswith((".xml", ".rels")):
            ET.fromstring(data)
    root = ET.fromstring(parts["word/document.xml"])
    body = root.find("w:body", NS)
    if body is None or body.findall(".//w:tbl", NS) or body.findall(".//w:txbxContent", NS):
        raise ValueError("DOCX manuscript must consist of normal editable paragraphs")
    all_paragraphs = body.findall("w:p", NS)
    covers = _cover_blocks(document, options)
    expected_cover = ["".join(run.get("text", "") for run in block["runs"]) for block in covers]
    if [_paragraph_text(paragraph) for paragraph in all_paragraphs[:len(covers)]] != expected_cover:
        raise ValueError("DOCX cover differs from requested metadata")
    paragraphs = all_paragraphs[len(covers):]
    actual = [_paragraph_text(paragraph) for paragraph in paragraphs]
    expected = ["".join(run.get("text", "") for run in block.get("runs", [])) for block in document["blocks"]]
    if actual != expected:
        raise ValueError("DOCX paragraph text/order differs from document model")
    body_text = "\n".join(actual)
    if "body_text" in document.get("expectations", {}) and body_text != document["expectations"]["body_text"]:
        raise ValueError("DOCX body differs from independent expected body text")
    readings = ["".join(_paragraph_text(child) for child in node) for paragraph in paragraphs for node in paragraph.findall(".//w:rt", NS)]
    expected_readings = document.get("expectations", {}).get("ruby_readings", [run["reading"] for block in document["blocks"] for run in block.get("runs", []) if run.get("kind") == "ruby"])
    if readings != expected_readings:
        raise ValueError("DOCX ruby readings differ from expected readings")
    heading_titles = []
    for block, paragraph in zip(document["blocks"], paragraphs):
        style = paragraph.find("w:pPr/w:pStyle", NS)
        if block["type"] == "heading":
            if style is None or style.get(_w("val")) != f"Heading{block.get('level', 1)}":
                raise ValueError("DOCX heading level/style was lost")
            heading_titles.append(_paragraph_text(paragraph))
    chapters = document.get("expectations", {}).get("chapters")
    if chapters is not None and heading_titles != [chapter["title"] for chapter in chapters]:
        raise ValueError("DOCX chapter order differs from expected chapter order")
    section = body.find("w:sectPr", NS)
    direction = section.find("w:textDirection", NS) if section is not None else None
    if direction is None or direction.get(_w("val")) != "tbRl":
        raise ValueError("DOCX vertical writing direction is missing")
    size = section.find("w:pgSz", NS)
    if size is None or [size.get(_w(key)) for key in ("w", "h")] != [str(_twips(options.get("page_width_mm", 148))), str(_twips(options.get("page_height_mm", 210)))]:
        raise ValueError("DOCX page dimensions differ from profile")
    margins = section.find("w:pgMar", NS)
    if margins is None or any(margins.get(_w(key)) != str(_twips(options.get("margin_mm", {}).get(key, 20))) for key in ("top", "bottom", "left", "right")):
        raise ValueError("DOCX margins differ from profile")
    font = options.get("font", "Noto Serif CJK JP")
    for paragraph in paragraphs:
        for run in paragraph.findall(".//w:r", NS):
            if any(child.tag in {_w("t"), _w("br"), _w("cr"), _w("tab")} for child in run):
                declaration = run.find("w:rPr/w:rFonts", NS)
                if declaration is None or any(declaration.get(_w(key)) != font for key in ("ascii", "hAnsi", "eastAsia", "cs")):
                    raise ValueError("DOCX body font differs from profile")
    tcy_nodes = [node for paragraph in paragraphs for node in paragraph.findall(".//w:eastAsianLayout", NS)]
    tcy_count = len(tcy_nodes)
    expected_tcy = sum(1 for block in document["blocks"] for run in _auto_tcy(block.get("runs", []), options.get("auto_tcy", False)) if run.get("kind") == "tcy")
    if tcy_count != expected_tcy or any(node.get(_w("vert")) != "1" or node.get(_w("combine")) for node in tcy_nodes):
        raise ValueError("DOCX tate-chu-yoko annotation was lost")
    dots = sum(len(paragraph.findall(".//w:em", NS)) for paragraph in paragraphs)
    lines = sum(len(paragraph.findall(".//w:u", NS)) for paragraph in paragraphs)
    for kind, actual_count in (("dot", dots), ("line", lines)):
        expected_count = sum(1 for block in document["blocks"] for run in _auto_tcy(block.get("runs", []), options.get("auto_tcy", False)) if kind in (run.get("emphasis") or []))
        if actual_count != expected_count:
            raise ValueError(f"DOCX {kind} emphasis annotation was lost")
    if options.get("page_numbers", True):
        footer = ET.fromstring(parts.get("word/tategaki-footer.xml", b"<missing/>"))
        if not any("PAGE" in node.get(_w("instr"), "") for node in footer.findall(".//w:fldSimple", NS)):
            raise ValueError("DOCX page number field is missing")
        references = section.findall("w:footerReference", NS)
        relationships = ET.fromstring(parts["word/_rels/document.xml.rels"])
        matching = {node.get("Id") for node in relationships if node.get("Target") == "tategaki-footer.xml" and node.get("Type") == R + "/footer"}
        if not any(node.get("{" + R + "}id") in matching for node in references):
            raise ValueError("DOCX page number footer is not linked to the manuscript")
    elif section.findall("w:footerReference", NS):
        raise ValueError("DOCX has an unexpected active footer")
    metadata = ET.fromstring(parts["docProps/core.xml"])
    for name, key in (("title", "title"), ("creator", "author"), ("language", "language"), ("identifier", "identifier")):
        expected_value = document.get("metadata", {}).get(key, "")
        expected_value = "; ".join(expected_value) if isinstance(expected_value, list) else str(expected_value)
        node = metadata.find("{" + DC + "}" + name)
        if node is None or (node.text or "") != expected_value:
            raise ValueError("DOCX bibliographic metadata differs from document model")
    return {"checks": ["zip-crc", "xml", "editable-paragraphs", "body-text-exact", "ruby-readings", "chapter-order", "vertical-direction", "page-geometry", "font-declarations", "annotations", "page-number-field"],
            "paragraphs": len(paragraphs), "headings": len(heading_titles), "ruby": len(readings), "tcy": tcy_count,
            "emphasis_dot_runs": dots, "emphasis_line_runs": lines, "font": font, "font_embedding": "not_embedded",
            "word_visual_check": "unverified", "word_grid_check": "unverified"}


def export_docx(document, profile, workdir: Path, run_command):
    """Create and validate manuscript.docx; no success is inferred from exit code."""
    workdir = Path(workdir).resolve()
    workdir.mkdir(parents=True, exist_ok=True)
    options = profile.get("docx", {})
    reference = workdir / "reference.docx"
    empty = workdir / "pandoc-empty.txt"
    empty.write_text("", encoding="utf-8")
    # --print-default-data-file writes binary DOCX to stdout on some Pandoc
    # versions even with -o.  An empty conversion uses the same bundled styles
    # and keeps binary data away from the job runner's text-only log stream.
    run_command(["pandoc", "--from=markdown", "--to=docx", str(empty), "-o", str(reference)], cwd=workdir)
    _reference(reference, options)
    api = json.loads(run_command(["pandoc", "-f", "markdown", "-t", "json", str(empty)], cwd=workdir).stdout)["pandoc-api-version"]
    blocks = _cover_blocks(document, options) + document["blocks"]
    ast = {"pandoc-api-version": api, "meta": {}, "blocks": []}
    for index, block in enumerate(blocks):
        content = [{"t": "Str", "c": f"TATEGAKIBLOCK{index:08d}"}]
        if block["type"] == "heading":
            ast["blocks"].append({"t": "Header", "c": [int(block.get("level", 1)), [block["id"], [], []], content]})
        else:
            ast["blocks"].append({"t": "Para", "c": content})
    ast_path = workdir / "manuscript.pandoc.json"
    ast_path.write_text(json.dumps(ast, ensure_ascii=False), encoding="utf-8")
    output = workdir / "manuscript.docx"
    run_command(["pandoc", "--from=json", "--to=docx", "--reference-doc=" + str(reference), str(ast_path), "-o", str(output)], cwd=workdir)
    _postprocess(output, document, options)
    validation = validate_docx(output, document, profile)
    warnings = [{"code": "docx-word-rendering-unverified", "message": "OOXML structure and text were checked. Fonts are declared, not embedded; review layout in the submission application's installed profile font. Microsoft Word verification is not part of this run."}]
    if "\u200d" in document.get("expectations", {}).get("body_text", ""):
        warnings.append({"code": "docx-joined-emoji-rendering", "message": "Unicode code points are preserved, but LibreOffice 26.8 rendered the tested ZWJ emoji as separate glyphs. Check complex emoji appearance in the target application."})
    if options.get("chars_per_column") or options.get("columns_per_page"):
        warnings.append({"code": "docx-grid-unverified", "message": "Document grid properties are emitted; exact character/column counts have not been verified in Microsoft Word."})
    return {"path": str(output), "validation": validation, "warnings": warnings}
