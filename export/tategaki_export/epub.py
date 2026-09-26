"""Vivliostyle EPUB generation and content-aware EPUB 3 validation."""

from __future__ import annotations

import os
from pathlib import Path
import posixpath
import re
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET
import zipfile

from .html import block_text, body_text, local_name, prepare_publication, source_block_text

OPF = "http://www.idpf.org/2007/opf"
DC = "http://purl.org/dc/elements/1.1/"
EPUB = "http://www.idpf.org/2007/ops"


def _resolve(base: str, href: str) -> tuple[str, str]:
    parsed = urlsplit(href)
    if parsed.scheme or parsed.netloc:
        raise ValueError(f"External EPUB resource is not allowed: {href}")
    path = posixpath.normpath(posixpath.join(posixpath.dirname(base), unquote(parsed.path))) if parsed.path else base
    if path.startswith("../") or path.startswith("/"):
        raise ValueError(f"EPUB resource leaves the publication: {href}")
    return path, unquote(parsed.fragment)


def set_epub_metadata(path: Path, document: dict) -> None:
    """Retain the snapshot identifier instead of the engine's generated UUID."""
    with zipfile.ZipFile(path) as archive:
        entries = [(info, archive.read(info.filename)) for info in archive.infolist()]
        container = ET.fromstring(archive.read("META-INF/container.xml"))
        package_path = next(node.attrib["full-path"] for node in container.iter() if local_name(node.tag) == "rootfile")
        package = ET.fromstring(archive.read(package_path))
    identifier = document["metadata"].get("identifier")
    if identifier:
        unique_id = package.attrib.get("unique-identifier")
        node = next((node for node in package.iter(f"{{{DC}}}identifier") if node.attrib.get("id") == unique_id), None)
        if node is None:
            raise ValueError("EPUB unique identifier is missing")
        node.text = identifier
    spine = package.find(f"{{{OPF}}}spine")
    if spine is None:
        raise ValueError("EPUB spine is missing")
    spine.set("page-progression-direction", "rtl")
    rewritten = ET.tostring(package, encoding="utf-8", xml_declaration=True)
    blocks = {block["id"]: block for block in document["blocks"]}
    # The HTML -> XHTML serializer normalizes literal CR to LF. Restore only
    # source-final CRs after verifying every other base character is unchanged.
    restored = {}
    for info, data in entries:
        if not info.filename.endswith(".xhtml"):
            continue
        root = ET.fromstring(data)
        changed = False
        for node in root.iter():
            block = blocks.get(node.attrib.get("id"))
            if not block or not block_text(block).endswith("\r"):
                continue
            expected = block_text(block)
            observed = body_text(node)
            if observed == expected:
                continue
            if observed != expected[:-1] + "\n":
                raise ValueError("EPUB differs beyond XML's final-CR normalization")
            # Find the last text/tail slot; the final CR is a literal text run.
            slots = []
            def collect_slots(parent):
                if parent.text:
                    slots.append((parent, "text"))
                for child in parent:
                    collect_slots(child)
                    if child.tail:
                        slots.append((child, "tail"))
            collect_slots(node)
            child, attr = slots[-1]
            value = getattr(child, attr)
            if not value.endswith("\n"):
                raise ValueError("EPUB final-CR text slot could not be identified")
            setattr(child, attr, value[:-1] + "\r")
            changed = True
        if changed:
            restored[info.filename] = ET.tostring(root, encoding="utf-8", xml_declaration=True).replace(b"\r", b"&#13;")
    temporary = path.with_suffix(".metadata.epub")
    with zipfile.ZipFile(temporary, "w") as archive:
        # Required EPUB ZIP convention even if the converter changes ordering.
        archive.writestr("mimetype", b"application/epub+zip", compress_type=zipfile.ZIP_STORED)
        for info, data in entries:
            if info.filename != "mimetype":
                archive.writestr(info, rewritten if info.filename == package_path else restored.get(info.filename, data))
    temporary.replace(path)


def validate_epub(path: Path, document: dict, run_command=None) -> dict:
    """Validate archive, reading order, block text, readings and navigation."""
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)):
            raise ValueError("Duplicate EPUB ZIP entries")
        if not infos or infos[0].filename != "mimetype" or infos[0].compress_type != zipfile.ZIP_STORED:
            raise ValueError("EPUB mimetype must be the first uncompressed ZIP entry")
        if archive.read("mimetype") != b"application/epub+zip":
            raise ValueError("Incorrect EPUB mimetype")
        if archive.testzip():
            raise ValueError("EPUB ZIP checksum failure")
        xmls = {}
        for name in names:
            if name.endswith((".xml", ".opf", ".xhtml", ".html", ".ncx", ".svg")):
                xmls[name] = ET.fromstring(archive.read(name))
        container = xmls["META-INF/container.xml"]
        package_path = next(node.attrib["full-path"] for node in container.iter() if local_name(node.tag) == "rootfile")
        package = xmls[package_path]
        if not package.attrib.get("version", "").startswith("3."):
            raise ValueError("Output is not EPUB 3")
        metadata = document["metadata"]
        for key, dcname in (("title", "title"), ("author", "creator"), ("language", "language"), ("identifier", "identifier")):
            expected = metadata.get(key)
            values = ["".join(node.itertext()) for node in package.iter(f"{{{DC}}}{dcname}")]
            if expected and expected not in values:
                raise ValueError(f"EPUB metadata differs: {key}")
        manifest = {}
        nav_files = []
        for item in package.iter(f"{{{OPF}}}item"):
            resource, _ = _resolve(package_path, item.attrib["href"])
            if resource not in names:
                raise ValueError(f"EPUB manifest resource is missing: {resource}")
            manifest[item.attrib["id"]] = resource
            if "nav" in item.attrib.get("properties", "").split():
                nav_files.append(resource)
        if len(nav_files) != 1:
            raise ValueError("EPUB must have exactly one navigation document")
        spine = package.find(f"{{{OPF}}}spine")
        if spine is None or spine.attrib.get("page-progression-direction") != "rtl":
            raise ValueError("EPUB page progression is not right-to-left")
        spine_files = [manifest[item.attrib["idref"]] for item in spine]
        if len(spine_files) != len(set(spine_files)):
            raise ValueError("EPUB repeats a document in the spine")
        block_nodes = []
        ruby_readings = []
        for filename in spine_files:
            root = xmls[filename]
            for node in root.iter():
                if node.attrib.get("data-source-block") == "true":
                    block_nodes.append(node)
                    ruby_readings += ["".join(child.itertext()) for child in node.iter() if local_name(child.tag) == "rt"]
        expected_blocks = document["blocks"]
        if [node.attrib.get("id") for node in block_nodes] != [block["id"] for block in expected_blocks]:
            raise ValueError("EPUB block/chapter order differs from the snapshot")
        for node, block in zip(block_nodes, expected_blocks):
            if source_block_text(node) != block_text(block):
                raise ValueError(f'EPUB body differs at block {block["id"]}')
        if ruby_readings != document["expectations"].get("ruby_readings", []):
            raise ValueError("EPUB ruby readings differ from the snapshot")
        colophons = [body_text(node) for filename in spine_files for node in xmls[filename].iter()
                     if node.attrib.get("data-colophon") == "true"]
        if colophons != ([metadata["colophon"]] if metadata.get("colophon") else []):
            raise ValueError("EPUB colophon differs from the requested metadata")
        all_ids = {name: {node.attrib["id"] for node in root.iter() if "id" in node.attrib}
                   for name, root in xmls.items()}
        for filename, root in xmls.items():
            if filename.endswith((".html", ".xhtml")):
                for node in root.iter():
                    for attr in ("href", "src"):
                        href = node.attrib.get(attr)
                        if href is None:
                            continue
                        parsed = urlsplit(href)
                        # Links may be external; resources cannot require network.
                        if parsed.scheme or parsed.netloc:
                            if local_name(node.tag) == "a" and attr == "href":
                                continue
                            raise ValueError(f"EPUB contains a remote resource: {href}")
                        dest, fragment = _resolve(filename, href)
                        if dest not in names or (fragment and fragment not in all_ids.get(dest, set())):
                            raise ValueError(f"Broken EPUB link: {filename} -> {href}")
        nav_root = xmls[nav_files[0]]
        toc = next((node for node in nav_root.iter() if local_name(node.tag) == "nav" and
                    "toc" in node.attrib.get(f"{{{EPUB}}}type", "").split()), None)
        if toc is None:
            raise ValueError("EPUB table of contents is missing")
        nav_links = [node for node in toc.iter() if local_name(node.tag) == "a"]
        headings = [block for block in expected_blocks if block["type"] == "heading"]
        actual = []
        for node in nav_links:
            _, fragment = _resolve(nav_files[0], node.attrib["href"])
            if fragment in {block["id"] for block in headings}:
                actual.append((fragment, body_text(node)))
        if actual != [(block["id"], block_text(block)) for block in headings]:
            raise ValueError("EPUB navigation chapter order/titles differ from the snapshot")
        styles = "\n".join(archive.read(name).decode("utf-8") for name in names if name.endswith(".css"))
        styles += "\n".join("".join(node.itertext()) for root in xmls.values() for node in root.iter() if local_name(node.tag) == "style")
        if not re.search(r"writing-mode\s*:\s*vertical-rl", styles):
            raise ValueError("EPUB vertical writing CSS is missing")
        if re.search(r"@page\s*[{: ]|counter\(page\)", styles):
            raise ValueError("Print-only page settings leaked into EPUB CSS")
    validation = {"zip": True, "xml": True, "epub_version": 3, "metadata_exact": True,
                  "rtl_progression": True, "vertical_css": True, "body_exact": True,
                  "body_blocks": len(block_nodes), "ruby_exact": True, "chapter_order": True,
                  "links": True, "reflowable_css": True, "spine_documents": len(spine_files)}
    if run_command is not None:
        checker = os.environ.get("EPUBCHECK", "epubcheck")
        result = run_command([checker, str(path)], cwd=path.parent, timeout=300)
        validation["epubcheck"] = {"passed": True, "output": (result.stdout + result.stderr)[-12000:]}
    else:
        validation["epubcheck"] = {"passed": False, "reason": "not run"}
    return validation


def export_epub(document: dict, profile: dict, workdir: Path, run_command) -> dict:
    config = prepare_publication(document, profile, workdir, "epub")
    timeout = int(profile.get("timeout_seconds", 300))
    run_command(["vivliostyle", "build", "-c", str(config.resolve()),
                 "--executable-browser", os.environ.get("CHROME_BIN", "/usr/bin/chromium"),
                 "--no-vite-config-file", "--timeout", str(timeout)], cwd=workdir, timeout=timeout + 30)
    path = workdir / "manuscript.epub"
    set_epub_metadata(path, document)
    validation = validate_epub(path, document, run_command)
    warnings = ["Apple Books / Kindle Previewer の実表示・文字サイズ変更は、この構造検査では確認していません。"]
    if any(any(char in block_text(block) for char in "&<>") for block in document["blocks"] if block["type"] == "heading"):
        warnings.append("Apple Books 9.0では、&・<・>を含む章名の検証原稿で目次ポップオーバーのXMLエラーを確認しました。EPUBCheckの仕様検査とは別の閲覧互換性の制限です。本文・章名・目次ラベルは原稿どおり保持しています。")
    return {"path": str(path.resolve()), "validation": validation,
            "warnings": warnings}
