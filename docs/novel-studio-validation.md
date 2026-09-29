# Novel Studio 実装・検証記録

2026-09-29 / macOS / GNU Emacs 31.1（Emacs-takaxp）

## 執筆中の目次・アウトライン（11時台）

Write／Reviewの上部と原稿メニューに「目次」を追加し、`C-c s o` でも開閉できるようにしました。開く操作は本文にフォーカスを残し、Writeへ戻っても同じ原稿の目次は維持します。セッション復元では表示／非表示の両方を反映し、Readerとの往復でも状態を保持します。

`#第一章` / `##第一節` の空白なし見出しを認識し、通常のハッシュタグとは区別します。三角クリックで折りたたみ、タイトルクリック・RETで本文へ移動できます。入力中は全文の再走査をidleまでまとめ、折りたたみや目次の選択位置を保持します。見出し記号を編集した直後でもクリックが正しい本文位置を参照するよう、markerの扱いを修正しました。

- 通常ERT全体：565件中561成功、失敗0、既存GUI専用4件skip。
- アウトラインERT：30/30成功。遅延更新、接頭辞編集直後の移動・開閉、現在章追従、本文保全を含む。
- アウトライン専用GUI：6/6成功。実event loopでのidle更新、描画位置からの三角・タイトルクリックを確認。
- Studio目次GUI：8/8成功。上部ボタン、狭いReview、Write、キー操作、他ペインの保持を確認。
- 既存Studio GUI：6/6成功。設定・Reader・履歴比較などを回帰確認。
- 変更した本体3ファイルの厳格byte compileと `git diff --check` 成功。

実行中の主Emacsへ再起動なしで反映し、その前後で本文・point・mark・Undo・modified・編集tickの不変を確認しました。Computer Useで「目次」をクリックして現在の `#第一章` が「第一章」と表示されること、Writeへ戻っても目次が残ることを確認しています。操作後も本文のSHA-256は変更前と同じで、本文にフォーカスがあり、未保存状態も維持されています。

ログは `dist/novel-studio-qa/evidence/outline/` に保存しています。

## LM StudioのProvider表示・保存の修正（11時20分）

実際の作品JSONにLM StudioのEndpoint・モデルは保存されていましたが、`ai-provider` 自体が欠落しており、初期値のOllamaが表示されていました。通常のProvider選択→保存→再表示ではLM Studioが維持されることを隔離環境で確認しました。

Providerの現在値を `[LM Studio ▼]` のような直接クリックできるボタンにしました。Providerを保存していない旧設定は、既知の標準ローカルEndpointから補完します。明示された保存値やLispのローカル設定を優先し、独自URLは推定せず、補完だけでJSONを書き換えることもありません。

今回の作品には、指定された `ai-provider: "lm-studio"` だけを明示保存しました。他のJSON項目、Endpoint、会話用・埋め込み用モデル、本文・point・mark・Undo・modified・編集tickが不変であることを確認しました。主Emacsへ再起動なしで反映し、設定ウィジェットの値がLM Studio、実サーバーから3モデル取得済み、未保存の設定変更なしであることを確認しました。最後のComputer Useによる主画面の目視確認はMacのロックにより未実施です。

- 通常ERT: 546件中542成功、失敗0、既存GUI専用4件skip。
- 専用GUI: Providerの実キー選択、保存・閉じる・再表示、モデル選択を含む1/1成功。
- 旧設定復元: 7/7成功。Endpoint変更・消失、明示値、設定破棄、別バッファ、JSONと原稿の保全を検査。
- 変更した本体3ファイルの厳格byte compile成功。

ログは `dist/novel-studio-qa/evidence/provider-fix/` に保存しています。

## 原稿用紙の自由指定・各ペインの閉じるUI（11時台）

設定の原稿用紙に「フリー（文字サイズ優先）」と、縦字数・列数の入力欄を追加しました。各1〜200の整数を入力し「寸法を適用」でまとめてプレビューします。入力途中や不正な値は原稿へ反映せず、他の設定変更による再描画でも入力を保持します。未適用の入力は保存・終了時に通知し、明示した適用・保存・破棄を通します。大きなフォントの狭いペインでも操作できるよう、入力欄と適用ボタンを別行にしました。

セッションで保存した項目を同じ設定画面で作品・既定値へ保存し直す際、変更なしとして永続化されない問題も修正しました。その画面で編集・適用した項目だけを移し、無関係な作品タイトルなどはコピーしません。同じ寸法の明示適用やフリーの再選択も保存できます。既存の「セッション > 作品 > 既定値」の優先順位は維持します。

Studioの補助ペインに、スクロールしても見える上部の「閉じる」を統合しました。対象は開始画面・原稿メニュー・設定・目次・校正・レビュー・履歴・比較・復元コピー・別案・世界設定・日時・伏線・話者・人物知識・資料登録・検索結果・参照資料・出力状態・ログ・出力フォルダー・Lookupです。Readerには「閉じる・執筆に戻る」があります。AIペインには前回追加した専用の閉じる操作があります。

通常のペインは押した画面だけを閉じ、原稿と他のペインを残します。未保存のコピーはバッファに保持し、比較は比較前の配置へ戻し、設定は保存・破棄を確認します。出力ログを閉じても出力処理は継続します。検索はその要求だけを取り消し、遅延応答が閉じたペインを再表示することを防ぎます。

LookupではStudio専用のバッファとウィンドウ状態を使い、通常のLookupから分離しました。実際のローカル辞書で「猫」「犬」を検索し、見出し・本文・辞書一覧・ヘルプ・項目情報の5種を個別に閉じる操作、再検索、履歴移動、一覧を閉じた後の復帰を確認しました。

| 検証 | 結果 |
|---|---|
| 通常ERT全体 | 538件中534成功、失敗0、既存GUI専用4件skip（11:06:38） |
| 共通ペインGUI | 13/13。実描画ヘッダーのマウスイベント、非選択ペイン、スクロール、各種cleanup、原稿・Undo保持 |
| 原稿用紙GUI | 1/1。実キーで27字×43列を入力・適用し、フリーへ切替 |
| Lookup GUI | 1/1。実辞書と5種のペイン、通常Lookup・他ペイン・原稿の保持 |
| Studio既存GUI | 6/6。設定・Write/Review・Reader・履歴比較などの回帰確認 |
| 厳格byte compile | `tategaki*.el` 全ファイル成功。再起動時に使う `.elc` も更新 |
| `git diff --check` | 成功 |

主Emacsへ再起動なしで読み込み、本文・point・mark・Undoオブジェクト・modified・編集tick・用紙寸法が更新前後で不変であることを検査しました。Computer Useで上部「閉じる」をクリックして原稿へ戻り、設定を開き直して数値欄と「フリー」の実メニューも確認しました。操作前後の本文・point・mark・Undo・modified・編集tickはすべて不変でした。

検証ログは [全ERT](../dist/novel-studio-qa/evidence/paper-panes/full-ert.log)、[ペインGUI](../dist/novel-studio-qa/evidence/paper-panes/panes-gui.log)、[原稿用紙GUI](../dist/novel-studio-qa/evidence/paper-panes/paper-gui.log)、[Lookup GUI](../dist/novel-studio-qa/evidence/paper-panes/lookup-gui.log)、[主Emacs反映記録](../dist/novel-studio-qa/evidence/paper-panes/live-update.el) に保存しています。

## 文字サイズ・AIペイン・接続設定の追加修正（10時台）

固定原稿用紙の見開き40列を必ず横幅に収める処理が、文字サイズの変更を相殺していました。既定では文字サイズを優先して可視列数を減らし、残りを既存の横スクロールで表示します。論理的な字数・列数・ページ数を保ち、途中表示でも用紙の境界に余白を置きます。縦の字数は画面高に収まる範囲に制限します。設定の「用紙全体を画面に収める」で従来の全体縮小を選べます。

AIペインにはスクロール位置によらず見える `[閉じる]` を追加しました。実行中の相談を取り消し、他ペインを残して原稿へ戻り、再表示時は会話・下書きを維持します。設定にはOllama／LM Studioの標準URL切替、モデル一覧取得、会話用／埋め込み用の別選択を追加しました。

Reader中のセッション保存と終了時保存では、一時的な縮小設定を保存せず、元の執筆設定・位置・アウトライン表示を記録します。

| 追加修正後の検証 | 結果 |
|---|---|
| 通常ERT全体 | 502件中498成功、失敗0、既存GUI専用4件skip（10:40:25） |
| 組版・入力連携GUI | 12/12。実SVG文字の拡大、可視列数の減少、途中表示の境界、クリック・caret・原稿不変を追加確認 |
| AIペイン専用GUI | 1/1。長文をスクロール後のheaderボタンとq、別ペイン保持、遅延応答破棄、再表示 |
| AI設定専用GUI | 1/1。Endpointの実キー入力、モデル選択のminibuffer入力 |
| localhost HTTP | 11/11。モデルID取得、不正応答、既存のchat・embedding・取消検証を含む |
| Reader・保存復元 | 30/30。実JSONへの保存・復元、元のnil設定、未保存本文・Undo・表示状態の保持 |
| 厳格byte compile | `tategaki*.el` 全ファイル成功 |

実LM Studioの `/v1/models` から `gemma-4-12b-it-mlx`、`tategaki-embedding`、`google/embedding-gemma-300m` の3件を取得し、設定画面の会話用・埋め込み用選択まで確認しました。Ollamaの接続先切替はHTTP fixtureで検証しましたが、実機の127.0.0.1:11434は未接続です。

実行中の主Emacsへ再起動なしで反映し、本文の標準倍率と文字サイズ優先表示を適用しました。適用直前・直後の本文、point、Undo、modified、編集tickの不変を検査しました。Computer Useでも、本文が拡大され、右側ペインを開いた状態でも読みやすい大きさを保つことを確認しました。検証ログは `dist/novel-studio-qa/evidence/ui-fixes/` に保存しています。

## 実装範囲

ハンドオフのMilestone A〜Eを実装し、人物の知識境界、登録原稿・資料の横断索引、全文の候補抽出まで拡張しました。既存の原稿バッファを正本とし、Studioを終了すると通常の縦書き編集へ戻ります。

| 範囲 | 提供する機能 |
|---|---|
| A | Studio開始画面、Write/Review、クリック操作、設定と即時プレビュー、作品metadataと出力共有、セッション、履歴、Lookup |
| B | 共通diagnosticsとsource overlay、12系統のローカル校正 |
| C | AI provider、非同期HTTP、embedding索引、語句検索へのフォールバック、RAG、Assistantと引用ジャンプ、登録ファイルの横断索引 |
| D | 世界設定・日時・伏線の全文候補抽出と作者採用、同一contextのFact比較、別名・初出・Scene、人物の知識範囲と読者との差、未知の頻出表現・話者候補 |
| E | 縦書きの行単位diff、別案コピー、macOS音読、Reader、プレーンテキスト資料コレクション、Review画面 |

使用方法、保存場所、対応範囲は[操作マニュアル](novel-studio.md)を参照してください。

## 自動検証の結果

| 検証 | 結果 |
|---|---|
| 通常ERT全体 | 486件中482成功、失敗0、既存GUI専用4件skip（03:33:08） |
| Studio専用GUI | 追加機能統合後に再実行し6/6成功 |
| 組版・入力連携の専用NS GUI | 11/11成功。Studio、NS未確定文字、Corfu、Copilotの同時表示・優先順位・確定/Undo、header/tab付き最終行のcaret |
| コレクション専用NS GUI | 1/1成功。対象選択、検索、引用ジャンプ |
| 再起動・セッション専用GUI | 1/1成功。主Emacsの実再起動も別途確認 |
| localhost実HTTP | コレクション連携を含め9/9成功（03:33:01）。日本語、embedding→検索、chat→引用、エラー、timeout、取消、redirect拒否 |
| 話者候補・反復表現の追加ERT | 7/7成功。既存world系との併用25/25成功 |
| Docker統合 | 8ケースすべて期待通り。通常出力、未対応注記、部分失敗、同時実行、特殊文字パス、timeout |
| 作品metadataを使うEPUB実生成 | EPUBCheck 5.4.0：0 fatals / 0 errors / 0 warnings。独立ZIP/XML照合も成功 |
| `tategaki*.el` のbyte compile | 最終統合後の全体をwarningをerror扱いにして成功（03:32:58、exit 0） |
| `git diff --check` | 成功 |

通常ERTで省略されたのは既存の `org-tategaki-preview-frame-lifecycle`、`org-tategaki-preview-frame-move-and-cleanup`、`org-tategaki-preview-graphical-alignment`、`org-tategaki-preview-graphical-padding-and-row-height` です。Studio用GUI6件と組版・入力連携GUI11件は、それぞれの専用runnerで別途実行しました。

通常ERTでは、設定の本文・Undo・modified不変、scopeの分離、不正入力と壊れたJSONの保護、fresh bufferでの保存値復元、export優先順位、履歴のコピー復元、古いAI応答や出典の拒否、未来の本文/Fact/日時の除外、取消処理などを確認しました。

人物の許可範囲だけを切り出した本文から、元段落の人物・POV・日時タグも除外します。見出し途中の位置制限で見出し末尾が引用ラベルへ漏れるケースと、現在の相対日時が古い出典の基準日時を参照するケースも再現し、修正後の回帰テストで除外を確認しました。

専用GUIでは、実描画のheader位置からmouse handlerを解決し、設定プレビューと取消、Write/Review、Assistantの下部表示と引用移動、diagnosticsの縦書き投影、Readerの非表示/復帰、履歴diff、metadata再読込、TTSハイライトを確認しました。固定原稿・ズーム・見開きでcaretとscrollbar画像の描画境界も検査しています。

組版・入力連携GUIでは、ヘッダー・タブを含む `posn-at-x-y` の入力座標と、それらを除く戻り座標の違いを確認しました。高いheader/tab付き原稿用紙の最下行で、修正前は位置取得がnilになることを再現し、本文領域全体へ走査範囲を補正した後に全11件が成功しました。Copilotの通信はこのrunnerでは停止し、実パッケージのoverlay・受入・Undoと、Corfuの実child frame、NS未確定文字APIを検査しています。

実行ログは [Studio GUI](../dist/novel-studio-qa/evidence/studio-gui.log)、[組版・入力連携GUI](../dist/novel-studio-qa/evidence/rich-gui.log)、[コレクションGUI](../dist/novel-studio-qa/evidence/corpus-gui.log) に保存しています。

## 実機確認

- Computer UseのマウスでStudioの設定ボタン、倍率、grid/spread、元に戻す、閉じるを操作し、表示を確認しました。操作後の本文・Undo履歴・modified状態はすべて不変でした。
- タイトル欄へのASCII/日本語入力は実Emacsのキーイベントでも確認しました。別途、主Emacsの専用QA原稿でmacOS日本語IMEのローマ字入力 → 未確定の「日本語日本語」 → Space変換 → Return確定を実操作し、未確定中の本文不変と確定時の挿入を確認しました。この時CorfuとCopilotのmodeはいずれも有効でした。
- 実CorfuのCAPF候補「青い傘」「赤い傘」が縦書きの挿入位置へ表示され、Computer UseのDown → Returnで「青い傘」を確定できました。
- 合成原稿で実Copilotサービスへ2回補完を要求し、HTTP 200の応答を確認しましたが、いずれも候補は0件でした。クラウドが生成した候補の採用成功とは扱いません。候補表示・採用・Undoは、前述のGUI runnerで与えた候補を実Copilot overlay/APIへ渡す試験で確認しています。
- インストール済みLookupで「猫」を検索し、20件の見出しと本文を右側の2ペインに表示しました。原稿本文とpointは不変でした。
- TTSのhighlight/pause/resume/stopは実子プロセスを使う無音fixtureで確認しました。別途 `/usr/bin/say -v Kyoko` で合成した日本語から91,104 bytesのAIFFを生成し、exit 0を確認しました。スピーカーによる聴感評価は行っていません。
- 主Emacsを実際に再起動し、プロセスIDが68617から2117へ変わったことを確認しました。QA原稿のpoint 35、mark 43、Review、10字×8列、scale 1を復元しました。既存の `index.org` は再起動前後のハッシュが一致しました。

再起動・入力・後片付けの状態は [再起動記録](../dist/novel-studio-qa/evidence/primary-restart.el)、[OS IME記録](../dist/novel-studio-qa/evidence/native-ime.el)、[後片付け記録](../dist/novel-studio-qa/evidence/primary-cleanup.el) に残しています。専用QA画面を閉じた後も元の `index.org` のハッシュ・point・未変更状態を確認しました。最終修正を主Emacsへ読み込み、元の原稿で継続使用できる状態に戻しています。

## ローカル実モデルの確認

LM Studioの `http://localhost:1234/v1` に接続し、chatモデル `gemma-4-12b-it-mlx`、embeddingモデル `tategaki-embedding` を使用しました。合成原稿だけで日本語chatの応答と768次元embeddingを確認しました。人物に許可された知識がない質問では「不明です」と回答しました。

登録した別原稿・資料でも、実embedding索引2チャンク→意味検索→実Gemma回答→引用ボタンから別原稿の位置1への移動を確認しました（03:33:51、exit 0）。本文・point・Undo・modified状態は不変です。この例では現在稿は語句検索、登録コレクションは意味検索を使います。[設定済みデモの使い方](../dist/novel-studio-qa/ai/README.md)、[実行結果](../dist/novel-studio-qa/ai/live-result.json)、[回答](../dist/novel-studio-qa/ai/answer.txt)を保存しています。

同じ実モデルで全文候補抽出を実行し、世界設定14件（知識4件・別名1件を含む）、日時5件、伏線4件を得ました。世界設定と日時はすべて `inferred`、伏線は `candidate` として入り、全件の引用が合成原稿と正確に一致することを検査しました。その後、作者によるFact採用、基準日時 `2026-09-29 08:00` と翌日08:00の相対日時の採用、青い鍵の配置と回収の対応付けを実行しました。本文・point・Undo・modified状態は不変でした。候補件数や内容はモデルに依存します。

[実RAG結果](../dist/novel-studio-qa/evidence/gemma-rag.json)、[抽出・採用結果](../dist/novel-studio-qa/evidence/gemma-extraction.json)、[抽出ログ](../dist/novel-studio-qa/evidence/gemma-extraction.log) を保存しています。

これは実際のHTTP・モデル実行を通した疎通と、特定の知識境界試料の確認です。モデルの回答精度・抽出再現率・他作品での誤推測率を測る網羅的な品質評価ではありません。未採用の抽出候補を事実として扱わず、出典変更・未来の範囲・人物の未許可本文はコード側でも除外します。

## EPUBと各形式の実出力

Docker Desktopを起動し、`tategaki-export:1` を再構築しました。環境はDocker 29.4.1 / linux aarch64、Vivliostyle CLI 11.3.3、Chromium 154、EPUBCheck 5.4.0です。

合成原稿「夏の終わり ― 縦書き検証」は、日本語著者名、2章、3か所のルビ、英語と数字を含みます。作品の `.tategaki/project.json` からEmacsのexport開始処理へmetadataを渡し、Docker内でEPUBとHTMLを実生成しました。生成前後で本文・Undo履歴・modified状態は不変でした。

- [生成EPUB](../dist/novel-studio-qa/exports/emacs-dd06780f18-7cb05dacc75d/epub/manuscript.epub)（6,282 bytes）
- [出力レポート](../dist/novel-studio-qa/exports/emacs-dd06780f18-7cb05dacc75d/report.json) / [独立検証結果](../dist/novel-studio-qa/verification.json)
- SHA-256: `93991e5066ad3ec82784ebfb3567b85f6b2b8a49345926abeae2fad11de4554a`

EPUBCheckはEPUB 3.4規則でエラー・警告0件です。別のZIP/XML検査でも書名・著者・言語・識別子、章順、ルビ「なつき」「るり」「みさき」、`vertical-rl`、右から左へのページ進行、本文を確認しました。Docker内の未登録UIDでJavaのホームが `?` になる問題も実行時に発見し、EPUBCheckへホームを明示して余計なキャッシュと `control.xml` エラーログを解消しました。

この生成EPUBをApple Booksへ読み込み、日本語の書名・著者、右から左へ進む縦書き見開き、夏樹/瑠璃/美咲のルビ、`12` の縦中横、`Summer` の横倒しを実画面で確認しました。電子目次に2章が認識され、第二章をクリックして4ページ目の第二章へ移動できました。

[Docker統合8ケースの結果](../dist/integration-ed89c9aa/integration-results.json)では、代表原稿と脚本のTXT/DOCX/PDF/EPUB/HTMLがすべて生成・構造検査に成功しました。strict注記拒否、要求フォント不足による部分失敗、timeoutは想定した失敗を検出しています。各成果物はローカルの `dist/` にあり、Git管理対象外です。

## 再実行

リポジトリのルートで実行します。実機で使用した実行ファイルは `/Applications/Emacs-takaxp/Emacs.app/Contents/MacOS/Emacs` です。以下の `emacs` を必要に応じて置き換えてください。

```sh
emacs --batch -Q -L . --eval '(setq load-prefer-newer t)' \
  --eval '(dolist (file (directory-files "test" t "-test\\.el$")) (unless (featurep (intern (file-name-base file))) (load file nil t)))' \
  -f ert-run-tests-batch-and-exit

emacs --batch -Q -L . --eval '(setq load-prefer-newer t)' \
  -l test/tategaki-corpus-http-tests.el -f ert-run-tests-batch-and-exit

emacs -Q -l "$PWD/test/tategaki-studio-graphical-tests.el"
emacs -Q -l "$PWD/test/tategaki-typeset-graphical-tests.el"

./bin/tategaki-export build
./bin/tategaki-export doctor
python3 test/export/integration.py

emacs --batch -Q -L . \
  --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
  -f batch-byte-compile tategaki*.el
```

HTTP fixtureと開発用Docker統合runnerにはPATH上のPython 3が必要です。fixtureは127.0.0.1の一時ポートを使い、テスト終了時に停止します。GUI runnerは**専用のEmacsプロセス**で、絶対パスを指定して実行してください。終了時にそのEmacsを閉じ、`temporary-file-directory` 内の `tategaki-studio-gui-tests.log` / `tategaki-typeset-gui-tests.log` に結果を保存します。組版・入力runnerには既存のCorfu/Copilotパッケージが必要です。通常のDocker出力にホストPythonは不要です。

実モデル抽出は任意の追加確認です。ローカルサーバーへモデルを読み込んだ後、導入済みの名前を明示して実行します。スクリプトは合成原稿だけを使い、結果を指定ディレクトリへ保存します。

```sh
TATEGAKI_LIVE_MODEL=gemma-4-12b-it-mlx \
TATEGAKI_LIVE_ENDPOINT=http://127.0.0.1:1234/v1 \
TATEGAKI_LIVE_OUTPUT="$PWD/dist/novel-studio-qa/live-extraction" \
  emacs --batch -Q -l "$PWD/test/support/tategaki_live_extraction.el"
```

## 検証していない範囲

- すべてのモデル/provider、長編作品での回答・embedding・抽出品質や性能の網羅的評価。
- すべてのOS入力方式、およびCopilotクラウドが実生成した非空候補の採用までの一連の操作。実通信はHTTP 200/候補0件、表示・採用・Undoは制御した候補によるGUI試験です。
- 今回生成したファイルのMicrosoft Word・Kindle Previewerでの表示。PDFの構造検査と任意の文字の字形・印刷品質の目視検査は別です。
- 全macOS音声の聴感・固有名詞の読み。音読のプロセス制御とAIFF生成成功は発音品質を保証しません。
- Docker amd64での実行。今回の実生成はApple Silicon / linux aarch64です。

世界設定・視点・時系列・知識は根拠付き候補と作者の採用を分けます。人物の本文参照は明示したFact/Scene範囲に限定し、登場・POVだけから知識を推定しません。横断索引は個別登録したテキストが対象で、フォルダの自動走査やPDF/Word/OCR取り込みは行いません。
