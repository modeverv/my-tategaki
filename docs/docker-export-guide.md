# 原稿をTXT・DOCX・PDF・EPUB・HTMLへ出力する

my-tategakiは、原稿の同じスナップショットから5形式を生成します。Emacsから出力すると、未保存の確定済み本文とStudioの作品名・著者名を使えます。処理は別プロセスで進み、その間も原稿の編集を続けられます。

最初に試す場合は次の「準備」と「Emacsからの出力」へ進んでください。画面付きの説明は[出力マニュアル](manual/export.html)、試験の実施条件は[出力検証記録](docker-export-validation.md)と[Studio検証記録](novel-studio-validation.md)にあります。

## 準備：Dockerを起動してイメージを作る

必要なのはDockerとComposeです。macOSではDocker Desktopを起動し、ターミナルで `docker info` が成功することを確認します。ホストへPython・Node・Java・Pandocを個別に導入する必要はありません。

リポジトリのフォルダーで実行します。

```sh
cd /path/to/my-tategaki
./bin/tategaki-export build
./bin/tategaki-export doctor
```

`build` は初回と出力コードの更新後に行います。ツール・フォントの取得にネット接続が必要で、依存レイヤーはキャッシュされます。`doctor` はDockerとコンテナ内の出力ツールを確認します。通常の原稿変換はネット接続なしのコンテナで行います。

縦書き編集、Studio、ローカル校正などを使うだけならDockerは不要です。

## Emacsからの出力

1. 原稿を開きます。Studioの設定でタイトル・著者・言語・識別子を入力し、継続して使う値は「この作品」へ保存します。
2. Studioの「原稿 → 出力」または `M-x tategaki-export` を実行します。
3. 形式を選びます。例えば `epub,html`。5形式すべてを出す場合は `M-x tategaki-export-all` でも実行できます。
4. まずは `preview` を選びます。電子目次へ章を入れる場合は「章見出しの設定」も確認してください。
5. `M-x tategaki-export-status` でジョブを選び、レポートと出力フォルダーを開きます。

出力先の既定値はリポジトリ内の `dist/` です。変更する例です。

```elisp
(require 'tategaki-export)
(setq tategaki-export-output-directory "~/Documents/tategaki-output"
      tategaki-export-profile "preview")
(setq-local tategaki-export-input-options '((headings . "markdown")))
```

`tategaki-export-formats` は形式選択の既定値です。`tategaki-export-all` はこの変数にかかわらず5形式を出力します。

### 未保存の本文と範囲

出力するのは開始時点のバッファ本文です。未保存の確定済み編集も含みますが、開始後の追記はそのジョブへ入りません。元ファイルの保存・本文の置換・Undoの追加を行わず、カーソルと選択範囲を保持します。IMEの未確定表示や未採用の補完候補は出力本文に含みません。

既定はnarrowing中でも全文です。部分出力は選択・narrowingを先に行い、`C-u M-x tategaki-export` または `C-u M-x tategaki-export-all` で範囲を選びます。

| 範囲 | 対象 |
|---|---|
| `full` | 元バッファの全文 |
| `region` | 現在の選択範囲 |
| `narrowed` | narrowingによる編集可能な範囲 |

UTF-8以外の原稿も、Emacsで正しく開けばバッファから出力できます。CLIへ直接渡すファイルはUTF-8にしてください。

### 作品名・著者名の共有

Emacsからの通常出力は、次の優先順位で書誌情報を使います。

1. Studioのセッション・作品・全作品の既定metadata（この中ではセッションが最優先）
2. バッファの `tategaki-export-metadata`
3. 出力プロファイルの `metadata`
4. タイトルが空の場合はファイル／バッファ名、言語が空の場合は `ja`

Studioで共有する項目は `title`、`author`、`language`、`identifier` です。本文にタイトルや著者を自動挿入する操作ではありません。既存の作品metadataがあると、`setq-local tategaki-export-metadata` だけではその値を上書きできません。設定画面の保存先も確認してください。

CLIは作品の `.tategaki/project.json` を自動で読みません。CLIではプロファイルまたは `--metadata` で渡すJSONへ書誌情報を指定します。

## ターミナルからの出力

```sh
./bin/tategaki-export export "小説 原稿.txt" \
  --profile preview \
  --formats txt,docx,pdf,epub,html \
  --out ./dist
```

形式指定を省略すると5形式を生成します。空白を含むパスは引用符で囲みます。開始時に表示されたジョブIDを使い、状態確認・取消を行えます。

```sh
./bin/tategaki-export status ./dist/JOB-ID
./bin/tategaki-export cancel JOB-ID
```

`status` にはジョブのフォルダー、`cancel` にはIDだけを渡します。`JOB-ID` は実際の値へ置き換えてください。取消はジョブ名・ラベルが一致するコンテナだけを対象にします。

| オプション | 用途 |
|---|---|
| `--profile preview` / `submission` / JSONパス | 出力の用紙・見出し・書誌情報など |
| `--formats txt,docx,pdf,epub,html` | 必要な形式をカンマ区切りで指定 |
| `--out DIR` | ジョブ別フォルダーを置く親ディレクトリ |
| `--metadata JSON` | プロファイルの書誌情報を上書き |
| `--font-dir DIR` | 追加するOTF・TTF・TTCのあるフォルダー |
| `--timeout 600` | 外部コマンド一回あたりの秒数上限。ジョブ全体の時間ではない |

## プロファイルと章見出し

| 標準プロファイル | 既定内容 |
|---|---|
| `preview` | A5、余白20mm、12pt。見出しは本文のまま。未解決の注記は原文を残して警告 |
| `submission` | A4、余白25mm、12pt。和文の章を認識。DOCX・PDFに文字表紙。未解決の注記診断があれば失敗 |

`submission` は汎用の提出・校正用設定です。出版社・賞・年度ごとの応募規定を保証しません。

変更する場合は標準JSONをコピーします。

```sh
cp export/profiles/preview.json my-profile.json
./bin/tategaki-export export manuscript.txt \
  --profile ./my-profile.json --out ./dist
```

Emacsでは `tategaki-export-profile` に独自JSONの絶対パスを設定します。型、未知のキー、用紙と余白の矛盾は検査されます。

| 設定 | 意味 |
|---|---|
| `input.headings` | `literal` / `markdown` / `org` / `japanese`。見出しの認識だけを選ぶ |
| `strict_diagnostics` | `true` は未解決の原文注記診断を出力失敗にする |
| `metadata` | `title`, `author`, `language`, `identifier`。任意で `subtitle`, `colophon` |
| `txt.encoding` | `utf-8`, `utf-8-sig`, `cp932`, `shift_jis` |
| `txt.newline` | `lf`, `crlf`, `preserve`。`source.txt` は変更しない |
| `docx` / `pdf` | 用紙寸法・余白はmm、`font_size_pt` はpt、`line_height` は行送り倍率。`font`, `page_numbers`, `cover`, `auto_tcy` も形式ごとに指定 |
| `epub` | `font`, `cover`, `auto_tcy`, `embed_fonts`。現在の `embed_fonts` は `false` のみ |

編集画面の目次認識と出力の見出し解釈は別です。`preview` のままでは章を解釈しません。Markdownの `# 第一章` を電子目次にするなら `input.headings` を `markdown` にします。本文のリンク・数式・HTML・強調記法までMarkdown/Orgとして解釈するものではありません。

対応する青空文庫注記はルビ・傍点・傍線・縦中横です。未対応・未完成の注記は原文と位置を残して診断します。フォームフィードは明示改ページとして扱います。

### CLI用のmetadata例

`metadata.json` を用意します。

```json
{
  "title": "雨上がりの町",
  "author": "筆名",
  "language": "ja",
  "identifier": "urn:novel:ameagari"
}
```

```sh
./bin/tategaki-export export manuscript.txt \
  --profile ./my-profile.json --metadata ./metadata.json --out ./dist
```

識別子は作品固有の値へ変更するか、省略します。CLIで省略した場合は原文SHA-256由来のURNになります。住所・電話番号などの応募用別紙や、投稿先固有の表紙は自動生成しません。

## 生成物・レポート・ログ

出力は `出力先/ジョブID/` にまとまります。

| ファイル | 内容 |
|---|---|
| `txt/source.txt` | 注記付きの原文スナップショット |
| `txt/body.txt` | 対応注記を除いた本文。ルビの親文字を保持 |
| `docx/manuscript.docx` | 編集可能な縦書き段落、注記、見出し、ページ番号 |
| `pdf/manuscript.pdf` | Vivliostyleによる組版PDF。検査用ページ画像も生成 |
| `epub/manuscript.epub` | 縦書き・右開き・電子目次を持つリフローEPUB 3 |
| `html/manuscript.html` | ブラウザ用の縦書きHTML |
| `report.md` / `report.json` | 形式別の結果・警告・使用ツール・入力と設定のhash |
| `logs/` / `.work/` | 実行ログ・途中生成物。失敗した形式は完成品へ公開しない |

レポートの状態は `pending`、`running`、`succeeded`、`failed`、`blocked`、`cancelled`、`not_requested` です。一つの形式が失敗しても、独立して処理できる形式は続行します。CLIは全指定形式の成功で0、形式失敗で1、取消で130を返します。起動・引数のエラーも非0です。

入力・設定・共通モデルのSHA-256、時刻、ツール・Dockerイメージ・フォントの情報、検査結果と処理時間を残します。別の実行でバイナリ全体が完全一致する保証ではありません。同じジョブIDの出力先は再利用せず、再実行は新しいジョブになります。

### Emacsで取消する

`M-x tategaki-export-cancel` で実行中のジョブを選びます。このEmacsで開始したジョブだけが対象です。コンテナ起動中の場合は一定時間再試行します。

状態・ログ・出力フォルダーの「閉じる」は表示を閉じるだけです。出力処理は続きます。終了と取消が重なる場合もあるため、最終状態はレポートで確認してください。

## フォントと表示確認

コンテナにはNoto Serif CJK JP、Noto Sans CJK JP、Noto Color Emojiを同梱します。要求フォントがなければ該当形式をエラーにし、黙って別書体へ置換しません。フォントの情報とライセンスも出力へ記録します。

追加フォントは `--font-dir ./fonts` で渡します。指定フォルダー直下のOTF・TTF・TTCだけをコピーし、ホストのフォントを自動収集・導入しません。プロファイルには実際のfamily名を指定してください。

**PDFの本文照合は現在Noto Serif CJK JP限定です。** 別書体をPDFへ指定すると未検証としてエラーになります。DOCX・HTML・EPUBにはこのPDF固有の制限はありません。DOCXのフォントは埋め込まないため、同じ書体で編集するには閲覧・編集側にもフォントが必要です。EPUBへのフォント埋め込みは未対応です。

PDFの埋め込みと本文照合、EPUBCheck、DOCX構造検査などに加え、完成物を使うアプリで開いて確認してください。確認用画像の生成だけで、任意の字形・改ページ・印刷品質を保証することはできません。

## 現在の対応範囲

- **編集画面と出力の版面**：別設定です。画面の20字×20列や見開きがそのまま出力に適用されるわけではありません。DOCX・PDF・EPUB間の同じ改ページも保証しません。
- **PDF**：固定字数・列数指定は未実装で明示エラーです。用紙・余白・文字サイズ・行送りは変更できます。PDF/X、塗り足し、印刷所別の色変換は未対応です。
- **DOCX**：`chars_per_column` / `columns_per_page` はOOXMLグリッドの試験設定です。実際の字数・列数・改ページとの一致は未保証です。
- **表紙・EPUB**：文字表紙は利用できます。画像表紙、固定レイアウトEPUB、EPUBフォント埋め込みは未対応です。
- **確認環境**：実Docker出力はApple Silicon / linux aarch64で検証しています。amd64は未確認です。

### 閲覧アプリで確認した範囲

macOSのLibreOfficeDev 26.8.0.0.alpha0で、代表DOCXの描画と再保存後の本文・注記を確認しました。プログラムで用意した追記を含む試料であり、GUI手入力の試験ではありません。ZWJ絵文字の一部は複数の絵に分かれて見えます。Wordでの実表示・再編集は未確認です。

2026年9月29日の合成EPUBでは、Studioの作品metadataを含めて生成し、EPUBCheckのエラー・警告0件、本文・ルビ・章順・右から左のページ進行を確認しました。Apple Books 9.0で日本語の書名・著者、縦書き、ルビ、縦中横、英語の横倒し、2章の電子目次と第二章への移動を実確認しています。

別の代表試料では、`& <灯>` のような記号を含む章名でBooksの目次に `xmlParseEntityRef: no name` が出る問題が残っています。元EPUBのXMLと本文は検査に通り、本文表示は正常ですが、この条件の目次は未解決です。章名を自動で変えず警告を出します。Kindle Previewerは未検証です。

これらの詳細と過去の実測値は[出力検証記録](docker-export-validation.md)、Studioからのmetadata連携とEPUB確認は[Studio検証記録](novel-studio-validation.md)を参照してください。

## 問題を切り分ける

| 症状 | 確認すること |
|---|---|
| Dockerが見つからない・起動していない | Docker Desktopを起動。Emacsだけで失敗する場合は `exec-path` とPATHを確認 |
| ソース更新が出力へ反映されない | `./bin/tategaki-export build` を再実行 |
| 一部形式だけ失敗 | `report.md` の形式別結果と `logs/`。要求フォント、注記診断、時間上限を確認 |
| 章が電子目次に入らない | `input.headings` を原稿に合わせる。previewの既定はliteral |
| 出力の著者・タイトルが違う | EmacsではStudioの上位scopeが優先。CLIではmetadataを明示しているか確認 |
| CP932本文が生成できない | 表せない文字の診断位置を確認。UTF-8を選べば出力できるか試す |
| 処理が長い | PDFは全ページの検査画像も作る。ログで進行と時間上限を確認 |

## 開発時の再検証

通常利用では不要です。実施内容や結果の履歴は検証記録へ残し、現在の手順と区別してください。

```sh
docker run --rm --network none --entrypoint python3 tategaki-export:1 \
  -m unittest discover -s test/export -p 'test_*.py'
docker run --rm --network none --entrypoint emacs tategaki-export:1 \
  -Q --batch -L /app -l test/export/tategaki-export-model-test.el \
  -l test/export/tategaki-export-test.el -f ert-run-tests-batch-and-exit
python3 test/export/integration.py
```

最後の統合runnerだけはホストPython 3を使います。通常の出力には不要です。共通モデルはEmacs側の注記解析から作り、CLIもコンテナ内のEmacsで同じ解析を行います。DOCXはPandocとOOXML処理、PDF・EPUBは共通HTMLとVivliostyleを使用し、Docker内でさらにDockerを動かす構成ではありません。
