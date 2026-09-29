# マニュアルの画面写真

`manual-editing.jpg`、`manual-typesetting.jpg`、`manual-outline.jpg`、`manual-script.jpg` は2026-09-27にmacOS版Emacs 31.1の撮影用フレームを実際に表示し、Computer Useのウィンドウキャプチャで保存した画像です。合成したUIではありません。キャプチャが返したJPEGをそのまま保存しています。

本文は `../examples/novel.txt` と `../examples/script.txt` の公開用サンプルです。ユーザーの編集中の文書は撮影に使っていません。配色、フォント、モードライン、上部の操作案内は説明用に調整しました。本文用書体はHiragino Mincho ProN、背景は `#fcfbf6`、文字色は `#253c38`。画像は894×622ピクセルです。右上・左上などのOSの表示は撮影時のものです。

撮影用サンプルを別プロセスで開き直す補助コードは `../../tools/manual-screenshots.el` です。必ず新規のGUI Emacsを `-Q` で起動し、絶対パスで読み込んでください。普段の編集用Emacsへロードするコードではありません。撮影環境の違いによりフォントやウィンドウ装飾は変わります。

既存の `tategaki-edit.png`、`tategaki-preview.png`、`tategaki-typesetting.png` は以前の操作例として残しています。このうちプレビュー画像は導入マニュアルでも使っています。

2026-09-29の追加画像は、別プロセスのNS版GUI Emacs 31.1を `-Q -l tools/manual-screenshots.el` で起動し、公開サンプル `docs/examples/novel.txt` の一時コピーを使ってウィンドウ単位で撮影しました。`manual-welcome.png`、`manual-studio-write.png`、`manual-studio-settings.png`、`manual-studio-outline.png`、`manual-studio-review.png`、`manual-assistant.png`、`manual-history.png`、`manual-world.png` が該当します。画像はRetina解像度のPNGです。設定した履歴保存先と作品データは一時ディレクトリに分離しました。履歴の2件目には公開サンプルの続きを撮影用に1文追加し、作品世界にはサンプル本文の引用を根拠にした人物とFactを登録しています。AI相談画像ではモデルへ質問を送信していません。

`manual-export-pdf.png` は `./bin/tategaki-export export docs/examples/novel.txt --profile preview --formats pdf` で生成したPDFの本文2ページ目をPopplerで144dpiのPNGに描画したものです。Emacsの画面写真ではなく、実際の出力ページの例です。
