# Docker出力ガイド

## 構成

`tategaki-export-model.el` が既存の注記解析を呼び、原文を変更せず `document.json` を作ります。CLIでもDocker内の `emacs -Q --batch` が同じ処理を呼びます。Python側で青空文庫記法を再解析しません。

PandocがDOCXの段落・見出しを生成し、OOXML処理で縦書き・注記・用紙設定を加えます。PDFとEPUBは共通のHTMLからVivliostyleを通常のCLIとして実行します。DockerソケットのマウントやDockerの入れ子は使いません。

## 導入と実行

```sh
./bin/tategaki-export build
./bin/tategaki-export doctor
./bin/tategaki-export export manuscript.txt --out ./dist
```

Docker Desktopを起動してください。`build` はリポジトリ全体をビルドコンテキストにしたComposeサービスを使います。ソースを更新した場合も再度 `build` してください。依存レイヤーはキャッシュされます。

ホストのPython・Node・Java・Pandocは不要です。CLIの入力はUTF-8です。UTF-8以外のファイルはEmacsで適切な文字コードとして開き、バッファから出力できます。

出力中に編集を続けても、開始時のスナップショットから全形式が生成されます。共通モデル内の `start` / `end` は、そのスナップショット内の0始まりUnicodeコードポイント位置です。終端は範囲に含めません。部分出力では `source.range_start` / `range_end` に元バッファ内の範囲を記録します。

## JSONプロファイル

`export/profiles/preview.json` または `submission.json` をコピーして変更し、`--profile 自分の設定.json` と指定します。Emacsの `tategaki-export-profile` に絶対パスを設定しても使えます。JSON Schemaで型・未知の設定名・用紙と余白の矛盾を検出します。

| 設定 | 値・意味 |
|---|---|
| `input.headings` | `literal` / `markdown` / `org` / `japanese`。見出し判定だけを切替 |
| `strict_diagnostics` | `true` なら未解決の原文診断がある出力を失敗にする |
| `metadata` | `title`, `author`, `language`, `identifier`。任意で `subtitle`, `colophon` |
| `txt.encoding` | `utf-8`, `utf-8-sig`, `cp932`, `shift_jis` |
| `txt.newline` | `lf`, `crlf`, `preserve`。`source.txt` には適用しない |
| `docx` / `pdf` | `page_width_mm`, `page_height_mm`, `margin_mm` の上下左右、`font`, `font_size_pt`, `line_height`, `page_numbers`, `cover`, `auto_tcy` |
| `epub` | `font`, `cover`, `auto_tcy`, `embed_fonts`。現段階の `embed_fonts` は `false` のみ |

青空文庫の対応注記はルビ、傍点、傍線、縦中横です。その他の注記、途中で切れた注記は原文として残し、原文位置とともにレポートします。Markdownを指定してもリンク・数式・HTML・強調記号等を解釈しません。原稿中のフォームフィードは明示改ページとして扱います。

`metadata.json` は例えば次のように書きます。

```json
{"title":"作品名","author":"筆名","language":"ja","identifier":"urn:uuid:作品固有のID"}
```

```sh
./bin/tategaki-export export manuscript.txt \
  --profile ./my-profile.json --metadata ./metadata.json --out ./dist
```

識別子を省略したCLI出力は原文SHA-256由来のURNになります。個人の住所・電話番号等の専用項目は実装していません。書誌情報へ自動転記する仕組みもありません。

## フォント

Noto Serif CJK JP、Noto Sans CJK JP、Noto Color Emojiをコンテナに同梱します。ファイルのSHA-256、選択フォントとフォールバック候補、ライセンスを出力フォルダーへ記録します。要求したフォントがなければ該当形式を失敗にし、別の書体への黙った置換はしません。

追加フォントは `--font-dir ./fonts` と指定し、プロファイルの `font` に実際のファミリー名を書きます。指定ディレクトリ直下のOTF/TTF/TTCだけをスナップショットへコピーします。ホストのフォントを自動収集したり、インストールしたりしません。DOCXをOffice互換ソフトで同じ書体にするには、その環境にもフォントが必要です。現在のPDF本文照合は **Noto Serif CJK JP限定**です。他の書体をPDFへ指定すると未検証として明示エラーになります。DOCX・HTML・EPUBにはこのPDF固有の制限はありません。

PDFではフォントのUnicode収録範囲、埋め込み、Unicode対応表を検査し、確認用に全ページ画像を生成します。今回、結合文字・異体字・絵文字の具体的な字形を目視確認した範囲は代表原稿等の短い試料です。画像生成だけで任意の原稿の字形を保証するものではありません。原文を正規化して別の文字へ置換しません。

## 成功・失敗・取消

`report.json` / `report.md` は処理中も更新されます。形式別の状態は `pending`, `running`, `succeeded`, `failed`, `blocked`, `cancelled`, `not_requested` です。失敗した形式の途中ファイルは `.work/` と `logs/` に残し、完成したファイルとして公開しません。

成功時0、形式の失敗時1、起動・引数のエラー時非0、取消時130を返します。元原稿・プロファイル・共通モデルのSHA-256、開始・終了時刻、ツールの版、DockerイメージID、フォント、検査結果、処理時間と最大RSSを記録します。バイナリ全体の完全一致は保証しません。

`--timeout 600` は外部コマンド一回あたりの秒数上限です。PDF変換器にも独自の上限があります。取り消す場合は `./bin/tategaki-export cancel JOB-ID` を使います。ジョブ名とラベルを確認して、そのコンテナだけを停止します。Emacsからは現在のセッションで開始したジョブだけを取り消せます。

出力先の同じジョブIDを再利用できません。もう一度コマンドを実行すると新しいIDで開始します。日本語・空白を含むパスに対応し、シェルへ原稿やファイル名をコードとして展開しません。

## 対応範囲

`submission` は汎用のA4提出・校正設定です。出版社名・年度の規定を保証するものではありません。本文文字数と400字詰換算、Wordの試験的グリッド、実際のPDFページ数は別の指標です。

DOCXの `chars_per_column` と `columns_per_page` はOOXMLグリッドの試験設定です。使用するOffice互換ソフトでの行送りと実改ページの確認が必要です。PDFの固定字数・行数設定は誤解を避けるためエラーにします。通常の用紙・余白・文字サイズ・行送りの指定は使えます。

表紙は書名・著者を置く文字表紙です。表紙画像の指定、EPUBフォント埋め込み、ページ画像だけの固定レイアウトEPUB、印刷所別のPDF/X・塗り足し・色変換は未対応です。PDF/Xは印刷所の具体的な仕様を決めた後の実装段階です。

Office互換ソフト、Apple Books、Kindle Previewerの表示確認と構造検査は別に扱います。今回のDOCX実表示・再保存の確認には、ユーザー指定に従いmacOS版LibreOfficeを使っています。Word互換性の保証には置き換えません。[検証記録](docker-export-validation.md) に実施環境と未確認事項を記録します。

## 開発時の検証

```sh
docker run --rm --network none --entrypoint python3 tategaki-export:1 \
  -m unittest discover -s test/export -p 'test_*.py'
docker run --rm --network none --entrypoint emacs tategaki-export:1 \
  -Q --batch -L /app -l test/export/tategaki-export-model-test.el \
  -l test/export/tategaki-export-test.el -f ert-run-tests-batch-and-exit
python3 test/export/integration.py
```

最後のコマンドは開発専用の実Docker統合テストで、ホストPythonを使います。通常の出力には不要です。スナップショットと生成物を独立した期待値で照合し、未対応注記、形式の部分失敗、同時実行、日本語と空白を含むパス、タイムアウトを確認します。
