# Copyright (C) 2026 seijiro and contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Lossless semantic HTML shared by the print and reflowable exports."""

from __future__ import annotations

from html import escape
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

TEMPLATES = Path(__file__).resolve().parent.parent / "templates"
XHTML = "http://www.w3.org/1999/xhtml"
EMOJI = re.compile(r"[\U0001f000-\U0001faff\u2600-\u27bf](?:[\ufe0e\ufe0f\U0001f3fb-\U0001f3ff]|\u200d[\U0001f000-\U0001faff\u2600-\u27bf])*")


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def body_text(element: ET.Element) -> str:
    """Read base text, excluding ruby readings and fallback parentheses."""
    if local_name(element.tag) in {"rt", "rp"}:
        return ""
    return (element.text or "") + "".join(
        body_text(child) + (child.tail or "") for child in element
    )


def block_text(block: dict) -> str:
    return "".join(run["text"] for run in block.get("runs", []))


def source_block_text(node: ET.Element) -> str:
    """Reconstruct an XML-forbidden form feed from its semantic page break."""
    if "page-break" in node.attrib.get("class", "").split():
        if body_text(node):
            raise ValueError("A page break unexpectedly contains body text")
        return "\f"
    return body_text(node)


def render_plain(text: str, auto_tcy: bool = False) -> str:
    parts = []
    cursor = 0
    for match in EMOJI.finditer(text):
        parts.append(render_plain(text[cursor:match.start()], auto_tcy))
        parts.append('<span class="emoji">' + escape(match.group()) + '</span>')
        cursor = match.end()
    if cursor:
        parts.append(render_plain(text[cursor:], auto_tcy))
        return "".join(parts)
    if auto_tcy:
        pattern = r"((?<![0-9])[0-9]{2}(?![0-9])|(?<![!?])[!?]{2}(?![!?]))"
        pieces = re.split(pattern, text)
        return "".join(f'<span class="tcy">{escape(piece)}</span>' if index % 2 else escape(piece).replace("\r", "&#13;")
                       for index, piece in enumerate(pieces))
    return escape(text).replace("\r", "&#13;")


def render_run(run: dict, auto_tcy: bool = False) -> str:
    text = render_plain(run["text"], auto_tcy and run["kind"] == "text")
    if run["kind"] == "ruby":
        text = f'<ruby><rb>{text}</rb><rt>{escape(run["reading"]).replace(chr(13), "&#13;")}</rt></ruby>'
    elif run["kind"] == "tcy":
        text = f'<span class="tcy">{text}</span>'
    classes = [f"emphasis-{kind}" for kind in run.get("emphasis", [])]
    if classes:
        text = f'<span class="{" ".join(classes)}">{text}</span>'
    return text


def render_block(block: dict, auto_tcy: bool = False) -> str:
    identifier = escape(block["id"], quote=True)
    if block["type"] == "page_break":
        return f'<div id="{identifier}" class="page-break" data-source-block="true"></div>'
    tag = f'h{min(6, max(1, block.get("level", 1)))}' if block["type"] == "heading" else "p"
    empty = ' class="empty"' if not block_text(block) else ""
    content = "".join(render_run(run, auto_tcy) for run in block.get("runs", []))
    return f'<{tag} id="{identifier}" data-source-block="true"{empty}>{content}</{tag}>'


def _css_string(text: str) -> str:
    # JSON strings are valid CSS strings after escaping CSS's line separators.
    return json.dumps(text, ensure_ascii=False).replace("<", "\\3c ").replace(">", "\\3e ").replace("&", "\\26 ")


def stylesheet(profile: dict, target: str) -> str:
    settings = profile.get(target, profile.get("pdf", {}))
    if target != "epub" and any(key in settings for key in ("chars_per_column", "columns_per_page")):
        raise ValueError("PDF fixed characters/columns grid is not verified; remove chars_per_column and columns_per_page and use page/font/margin dimensions")
    css = (TEMPLATES / "common.css").read_text(encoding="utf-8")
    css += (TEMPLATES / ("epub.css" if target == "epub" else "print.css")).read_text(encoding="utf-8")
    family = _css_string(settings.get("font", "Noto Serif CJK JP"))
    css += f"\nbody {{ font-family: {family}, serif; }}\n"
    if target != "epub":
        width = float(settings.get("page_width_mm", 148))
        height = float(settings.get("page_height_mm", 210))
        margins = settings.get("margin_mm", {})
        values = [float(margins.get(edge, 20)) for edge in ("top", "right", "bottom", "left")]
        font_size = float(settings.get("font_size_pt", 12))
        line_height = float(settings.get("line_height", 1.8))
        css += f'body {{ font-size: {font_size:g}pt; line-height: {line_height:g}; }}\n'
        css += f'@page {{ size: {width:g}mm {height:g}mm; margin: {" ".join(f"{v:g}mm" for v in values)};'
        if settings.get("page_numbers", True):
            css += ' @bottom-center { content: counter(page); writing-mode: horizontal-tb; font-size: 9pt; }'
        css += " }\n"
    return css


def html_document(metadata: dict, content: str, css: str, *, title: str | None = None) -> str:
    title = title if title is not None else metadata.get("title", "無題")
    language = escape(metadata.get("language", "ja"), quote=True)
    author = escape(metadata.get("author", ""), quote=True)
    # XML-compatible HTML lets both our validator and EPUB's XHTML path inspect it.
    return ('<!DOCTYPE html>\n'
            f'<html xmlns="{XHTML}" xmlns:epub="http://www.idpf.org/2007/ops" lang="{language}" xml:lang="{language}">'
            f'<head><meta charset="utf-8"/><title>{escape(title)}</title>'
            f'<meta name="author" content="{author}"/><style>{css}</style></head>'
            f'<body>{content}</body></html>')


def render_cover(metadata: dict) -> str:
    content = '<section class="cover" epub:type="cover"><h1>' + escape(metadata.get("title", "無題")) + '</h1>'
    if metadata.get("subtitle"):
        content += '<p class="subtitle">' + escape(metadata["subtitle"]) + '</p>'
    return content + '<p>' + escape(metadata.get("author", "")) + '</p></section>'


def render_colophon(metadata: dict) -> str:
    if not metadata.get("colophon"):
        return ""
    return '<section class="colophon"><h1>奥付</h1><p data-colophon="true">' + escape(metadata["colophon"]) + '</p></section>'


def validate_html(path: Path, document: dict) -> dict:
    root = ET.fromstring(path.read_text(encoding="utf-8"))
    found = [node for node in root.iter() if node.attrib.get("data-source-block") == "true"]
    expected = document["blocks"]
    if [node.attrib.get("id") for node in found] != [block["id"] for block in expected]:
        raise ValueError("HTML source block order differs from the snapshot")
    for node, block in zip(found, expected):
        if source_block_text(node) != block_text(block):
            raise ValueError(f'HTML body differs at block {block["id"]}')
    readings = ["".join(node.itertext()) for node in root.iter() if local_name(node.tag) == "rt"]
    if readings != document["expectations"].get("ruby_readings", []):
        raise ValueError("HTML ruby readings differ from the snapshot")
    return {"xml": True, "body_blocks": len(found), "body_exact": True,
            "ruby_exact": True, "chapter_order": True}


def export_html(document: dict, profile: dict, workdir: Path, run_command=None) -> dict:
    workdir.mkdir(parents=True, exist_ok=True)
    content = render_cover(document["metadata"]) if profile.get("pdf", {}).get("cover") else ""
    content += "<main>" + "".join(render_block(block, bool(profile.get("pdf", {}).get("auto_tcy", False)))
                                for block in document["blocks"]) + "</main>"
    content += render_colophon(document["metadata"])
    path = workdir / "manuscript.html"
    path.write_text(html_document(document["metadata"], content, stylesheet(profile, "pdf")), encoding="utf-8")
    return {"path": str(path.resolve()), "validation": validate_html(path, document), "warnings": []}


def prepare_publication(document: dict, profile: dict, workdir: Path, target: str) -> Path:
    """Create explicit local chapter HTML and a Vivliostyle JSON config."""
    workdir.mkdir(parents=True, exist_ok=True)
    source_dir = workdir / f"{target}-source"
    source_dir.mkdir(exist_ok=True)
    metadata = document["metadata"]
    settings = profile.get(target, {})
    if target == "epub" and settings.get("embed_fonts"):
        raise ValueError("EPUB embedded user fonts are not supported by this profile; set embed_fonts=false")
    css = stylesheet(profile, target)
    groups: list[list[dict]] = []
    for block in document["blocks"]:
        if not groups or (block["type"] == "heading" and block.get("level", 1) == 1):
            groups.append([])
        groups[-1].append(block)
    if not groups:
        groups = [[]]
    entries = []
    links = []
    if settings.get("cover"):
        cover = render_cover(metadata)
        (source_dir / "cover.html").write_text(html_document(metadata, cover, css), encoding="utf-8")
        # A typographic title page is an article entry. Vivliostyle's special
        # cover entry requires an image asset and replaces supplied markup.
        entries.append({"path": "cover.html", "title": metadata.get("title", "無題")})
    for index, blocks in enumerate(groups):
        name = f"chapter-{index + 1:04d}.html"
        title = next((block_text(block) for block in blocks if block["type"] == "heading"), metadata.get("title", "本文"))
        content = "<main>" + "".join(render_block(block, bool(settings.get("auto_tcy", False))) for block in blocks) + "</main>"
        (source_dir / name).write_text(html_document(metadata, content, css, title=title), encoding="utf-8")
        entries.append({"path": name, "title": title})
        for block in blocks:
            if block["type"] == "heading":
                links.append((name + "#" + block["id"], block_text(block), block.get("level", 1)))
    if links and document["blocks"] and document["blocks"][0]["type"] != "heading":
        links.insert(0, ("chapter-0001.html#" + document["blocks"][0]["id"], "本文", 1))
    if not links:
        fragment = "#" + document["blocks"][0]["id"] if document["blocks"] else ""
        links = [("chapter-0001.html" + fragment, metadata.get("title", "本文"), 1)]
    if metadata.get("colophon"):
        (source_dir / "colophon.html").write_text(html_document(metadata, render_colophon(metadata), css, title="奥付"), encoding="utf-8")
        entries.append({"path": "colophon.html", "title": "奥付"})
    # Explicit navigation prevents Markdown interpretation and makes bookmark order deterministic.
    nav = '<nav role="doc-toc" epub:type="toc" id="toc"><h1>目次</h1><ol>'
    nav += "".join(f'<li class="level-{level}"><a href="{escape(href, quote=True)}">{escape(title).replace(chr(13), "&#13;")}</a></li>'
                   for href, title, level in links)
    nav += "</ol></nav>"
    (source_dir / "toc.html").write_text(html_document(metadata, nav, css, title="目次"), encoding="utf-8")
    entries.insert(1 if settings.get("cover") else 0, {"path": "toc.html", "rel": "contents", "title": "目次"})
    config = {"title": metadata.get("title") or "無題",
              "language": metadata.get("language", "ja"), "readingProgression": "rtl",
              "entryContext": str(source_dir.resolve()), "entry": entries,
              "workspaceDir": str((workdir / f"{target}-webpub").resolve()),
              "output": {"path": str((workdir / f"manuscript.{target}").resolve()), "format": target},
              "timeout": int(profile.get("timeout_seconds", 300)) * 1000,
              "viteConfigFile": False}
    if metadata.get("author"):
        config["author"] = metadata["author"]
    if target == "pdf":
        config["size"] = f'{settings.get("page_width_mm", 148)}mm,{settings.get("page_height_mm", 210)}mm'
    path = workdir / f"vivliostyle-{target}.config.json"
    path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return path
