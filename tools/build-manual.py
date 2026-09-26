#!/usr/bin/env python3
# Copyright (C) 2026 seijiro and contributors.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the dependency-free GitHub Pages manual from HTML content fragments."""
from html import escape
from html.parser import HTMLParser
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
PAGES = [
    ("index", "使い方マニュアル", "縦書きで書き、整え、原稿を渡す。my-tategakiの使い方を目的別に案内します。"),
    ("getting-started", "導入と最初の原稿", "Emacsへの導入、3つの表示方法、最初の保存まで。"),
    ("editing", "縦書きで編集する", "移動・選択・検索・日本語入力と、読みやすい余白の設定。"),
    ("typesetting", "組版と原稿用紙", "ルビ・縦中横・禁則から、見開き・文字数・執筆目標まで。"),
    ("writing", "執筆支援・アウトライン・脚本", "段落の字下げ、章への移動、人物名と台詞の入力。"),
    ("export", "原稿を出力する", "同じ原稿からTXT・DOCX・PDF・EPUB・HTMLを作る。"),
    ("reference", "コマンド・設定一覧", "目的からコマンドを探し、setqで自分の書き方に合わせる。"),
    ("troubleshooting", "困ったとき", "表示・入力・出力の切り分けと、現在の対応範囲。"),
]
REPO = "https://github.com/modeverv/my-tategaki"

class Contents(HTMLParser):
    def __init__(self):
        super().__init__()
        self.headings = []
        self.text = []
        self.heading = None
        self.rows = []
        self.row = None
    def handle_starttag(self, tag, attrs):
        if tag in ("h2", "h3"):
            self.heading = {"level": tag, "id": dict(attrs).get("id", ""), "text": ""}
        if tag == "tr" and dict(attrs).get("id"):
            self.row = {"id": dict(attrs)["id"], "text": ""}
    def handle_endtag(self, tag):
        if self.heading and tag == self.heading["level"]:
            self.headings.append(self.heading)
            self.heading = None
        if tag == "tr" and self.row is not None:
            self.rows.append(self.row)
            self.row = None
    def handle_data(self, data):
        self.text.append(data)
        if self.heading is not None:
            self.heading["text"] += data
        if self.row is not None:
            self.row["text"] += data + " "

def target(slug, root):
    return root + ("index.html" if slug == "index" else "manual/" + slug + ".html")

def build():
    search = []
    for number, (slug, title, description) in enumerate(PAGES):
        root = "./" if slug == "index" else "../"
        body = (DOCS / "manual/content" / (slug + ".html")).read_text(encoding="utf-8")
        parsed = Contents()
        parsed.feed(body)
        if any(not h["id"] for h in parsed.headings):
            raise ValueError(f"Every h2/h3 needs an id: {slug}")
        nav_links = []
        for i, (s, t, _) in enumerate(PAGES):
            current = ' aria-current="page"' if s == slug else ''
            nav_links.append(f'<a href="{target(s, root)}"{current}><span>{i:02}</span>{escape(t)}</a>')
        links = "".join(nav_links)
        toc = "".join(f'<li class="{h["level"]}"><a href="#{escape(h["id"])}">{escape(h["text"])}</a></li>' for h in parsed.headings)
        siblings = []
        for direction, index in (("前の章", number - 1), ("次の章", number + 1)):
            if 0 <= index < len(PAGES):
                s, t, _ = PAGES[index]
                siblings.append(f'<a href="{target(s, root)}"><small>{direction}</small>{escape(t)} <span aria-hidden="true">→</span></a>')
        page = f'''<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="{escape(description)}">
<meta name="theme-color" content="#f7f6f0">
<title>{escape(title)} | my-tategaki</title>
<link rel="icon" href="{root}assets/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="{root}assets/manual.css">
<script src="{root}assets/search-index.js" defer></script>
<script src="{root}assets/manual.js" defer></script>
</head>
<body data-root="{root}" class="page-{slug}">
<a class="skip-link" href="#main">本文へ移動</a>
<aside class="sidebar">
<a class="brand" href="{root}index.html"><span class="brand-mark" aria-hidden="true">縦</span><span>my-tategaki<small>Emacs 縦書きマニュアル</small></span></a>
<p class="nav-label">CONTENTS</p><nav aria-label="章一覧">{links}</nav>
<div class="sidebar-bottom"><a href="{REPO}">GitHub リポジトリ ↗</a><p>プレーンテキストから<br>あなたの一冊へ。</p></div>
</aside>
<div class="site-body">
<header class="site-header"><a class="mobile-brand" href="{root}index.html">my-tategaki</a><span class="header-context">USER MANUAL <span aria-hidden="true">/</span> {number:02}</span>
<div class="search"><label class="sr-only" for="manual-search">マニュアルを検索</label><input id="manual-search" type="search" placeholder="用語・コマンドを検索" autocomplete="off" aria-controls="search-results"><div id="search-results" class="search-results" hidden></div><span id="search-status" class="sr-only" aria-live="polite"></span></div></header>
<details class="mobile-menu"><summary>目次を開く</summary><nav aria-label="モバイル章一覧">{links}</nav></details>
<main id="main" tabindex="-1">
<div class="page-heading"><p class="eyebrow">{'MY-TATEGAKI / GUIDE' if slug == 'index' else f'CHAPTER {number:02}'}</p><h1>{escape(title)}</h1><p class="lead">{escape(description)}</p></div>
<div class="document-grid"><article>{body}<nav class="chapter-pager" aria-label="前後の章">{''.join(siblings)}</nav></article>
<aside class="page-toc"><p>このページ</p><ol>{toc}</ol><a class="back-top" href="#main">ページの先頭へ ↑</a></aside></div>
</main>
<footer><span>my-tategaki · Emacsで縦書き。</span><a href="{REPO}/blob/main/LICENSE" rel="license">GPL-3.0-or-later</a><a href="{REPO}/blob/main/docs/manual/content/{slug}.html">このページの原稿</a><a href="{root}manual/troubleshooting.html#support">確認環境と制限</a></footer>
</div>
</body></html>'''
        path = DOCS / ("index.html" if slug == "index" else "manual/" + slug + ".html")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(page, encoding="utf-8")
        url = "index.html" if slug == "index" else f"manual/{slug}.html"
        search.append({"title": title, "url": url, "text": re.sub(r"\s+", " ", " ".join(parsed.text))})
        for h in parsed.headings:
            search.append({"title": f'{title} / {h["text"]}', "url": f'{url}#{h["id"]}', "text": h["text"]})
        for row in parsed.rows:
            search.append({"title": row["id"], "url": f'{url}#{row["id"]}', "text": row["text"]})
    notice = "// Copyright (C) 2026 seijiro and contributors.\n// SPDX-License-Identifier: GPL-3.0-or-later\n"
    (DOCS / "assets/search-index.js").write_text(notice + "window.TATEGAKI_SEARCH = " + json.dumps(search, ensure_ascii=False).replace("</", "<\\/") + ";\n", encoding="utf-8")
    (DOCS / ".nojekyll").write_text("", encoding="utf-8")
    print(f"Built {len(PAGES)} manual pages and {len(search)} search entries.")

if __name__ == "__main__":
    build()
