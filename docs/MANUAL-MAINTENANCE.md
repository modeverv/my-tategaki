# マニュアルの更新とGitHub Pages公開

サイトは静的HTML・CSS・JavaScriptです。公開時にNode・Jekyll・Dockerのビルドは不要です。`docs/.nojekyll` により、そのまま配信します。

## 更新する場所

- `docs/manual/content/*.html`: 各章の本文。HTML断片で、`html` / `head` / `body` は書きません。
- `tools/build-manual.py`: 共通レイアウト、章の順番、タイトルと説明。
- `docs/assets/manual.css`, `manual.js`: 表示、検索、コードのコピー。
- `docs/images/manual-*.jpg`: 実画面の画像。来歴は `docs/images/README.md`。
- `docs/examples/`: ダウンロードして試す原稿。

本文の `h2` / `h3` にはページ内で一意な `id` を付けます。リンクの基準は生成後の `docs/manual/` です。ホーム用の `content/index.html` だけは `docs/` が基準です。

Python 3.9以降の標準ライブラリだけで生成できます。

```sh
python3 tools/build-manual.py
python3 -m http.server 8769 --directory docs --bind 127.0.0.1
```

ブラウザで `http://127.0.0.1:8769/` を開きます。本文を更新したら再生成し、生成された `docs/index.html`、`docs/manual/*.html`、`docs/assets/search-index.js` も一緒にコミットします。生成物を手で直すと次の生成で上書きされます。

検索は同梱インデックスをブラウザ内で検索し、入力した語をサーバーへ送信しません。JavaScriptを無効にしても本文・章リンク・目次を読めます。JavaScript使用時は検索・コピー・表のスクロール補助が加わります。印刷用スタイルも含みます。

## GitHub Pagesで公開する

設定はリポジトリ所有者が行います。

1. GitHubリポジトリの **Settings → Pages** を開く。
2. **Build and deployment → Source** を **Deploy from a branch** にする。
3. **Branch** は `main`、フォルダーは `/docs` を選んで **Save**。
4. GitHubが表示する公開URLとデプロイ完了を確認する。

通常の公開先は `https://modeverv.github.io/my-tategaki/` です。既存の独自ドメインや公開設定は、この変更では操作していません。

GitHub側の設定については[公式ドキュメント](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)を参照してください。
