# my-tategaki Novel IDE 化 実装ハンドオフ

## 1. 目的

`my-tategaki` を高品質な縦書きエディタから、**小説・長編文章を書くための統合執筆環境 / Novel IDE** へ発展させる。

基本思想：

- **Write時**：ポメラのように単純で、原稿だけに集中できる。
- **Review時**：IDEのように辞書、校正、履歴、検索、設定資料、AI、音読、出力を統合する。
- Emacsを知らない利用者でもクリック主体で利用できる。
- Emacs利用者には従来通り command / key binding / Lisp を提供する。
- AIは本文生成を主目的とせず、作者の認知・検索・推敲能力を補助する。
- 本文を唯一の source of truth とする。
- 現在の「通常のEmacs buffer + 縦書きdisplay layer」という設計を維持する。

---

# 2. 守るべき既存設計

1. 本文は通常のEmacs buffer。
2. 縦書き表示のために本文を変更しない。
3. 保存・Undo・region・kill/yank・IME・検索等は可能な限りEmacs標準機構を使う。
4. diagnostics等はsource buffer上のoverlay等で表現する。
5. `tategaki-highlight.el` のface投影機構を活用する。
6. IME、Corfu、Copilot、カーソル、pixel geometryを壊さない。
7. AIなしでもすべての基本編集機能を使用可能にする。
8. 外部サービス障害で本文を失わない。
9. AIが本文を自動書換えしない。
10. Novel IDE機能を無効にすれば現在の軽量な`tategaki-mode`へ戻れる。

---

# 3. 全体構造

```text
                     ┌─────────────────────┐
                     │      原稿 buffer     │
                     │   source of truth    │
                     └──────────┬──────────┘
                                │
       ┌────────────────────────┼─────────────────────┐
       │                        │                     │
       ▼                        ▼                     ▼
 縦書きrenderer          document model        diagnostics
       │                        │                     │
       └──────────────┬─────────┴─────────┬───────────┘
                      │                   │
                      ▼                   ▼
                 Studio UI          Local Knowledge
                      │                   │
       ┌──────────────┼─────────┐         │
       ▼              ▼         ▼         ▼
      辞書           履歴       TTS     RAG / LLM
```

---

# 4. 新規モジュール

```text
tategaki-studio.el
tategaki-settings.el
tategaki-session.el
tategaki-history.el
tategaki-lookup.el

tategaki-diagnostics.el
tategaki-proofread.el

tategaki-project.el
tategaki-semantic.el
tategaki-rag.el
tategaki-ai.el
tategaki-assistant.el

tategaki-world.el
tategaki-timeline.el
tategaki-foreshadow.el
tategaki-voice.el

tategaki-diff.el
tategaki-reader.el
tategaki-tts.el

tategaki-review.el
```

AI用helperが必要なら独立：

```text
ai/
  tategaki_ai/
    server.py
    embedding.py
    index.py
    llm.py
    schema.py
```

AI未使用者にはPython等を要求しない。

---

# 5. Studio Mode

## `tategaki-studio.el`

初心者でも使える専用ワークスペース。

```text
M-x tategaki-studio
```

基本画面：

```text
┌──────────────────────────────────────────────────────────┐
│ 原稿  検索  辞書  校正  人物  履歴  AI  音読  出力  ⚙設定 │
├──────────────────────────────────────────────────────────┤
│                                                          │
│                    縦 書 き 原 稿                        │
│                                                          │
└──────────────────────────────────────────────────────────┘
  12,842字 / 30,000字                      第4章  12/38頁
```

toolbarは`header-line-format`等を使用。

全ボタンはcommandを呼ぶだけにする。

```text
[辞書] → tategaki-lookup-word
[校正] → tategaki-diagnostics-list
[履歴] → tategaki-history
[AI]   → tategaki-assistant
[設定] → tategaki-settings
```

---

# 6. Write / Review

## Write Mode

- 原稿最大化
- side windowを閉じる
- Assistantを閉じる
- diagnostics一覧を閉じる
- outlineを閉じる
- UI最小化
- 文字数・章・ページ程度のみ表示

## Review Mode

```text
┌────────────────────────┬───────────────────┐
│                        │ 人物 / 設定       │
│      縦書き本文        │ timeline          │
│                        │ diagnostics       │
├────────────────────────┴───────────────────┤
│ Assistant / Search / History               │
└────────────────────────────────────────────┘
```

commands：

```text
tategaki-studio-write
tategaki-studio-review
tategaki-studio-toggle-review
```

---

# 7. 設定画面

## `tategaki-settings.el`

**Milestone Aの必須機能とする。**

```text
M-x tategaki-settings
```

Studioの `[⚙設定]` から必ず開けること。

## 必須UI

```text
┌────────────── my-tategaki 設定 ──────────────┐
│                                               │
│ 作品                                          │
│  タイトル          [ 長編小説タイトル      ] │
│  著者名            [ 著者名                ] │
│  言語              [ ja ▼ ]                  │
│  識別子            [                       ] │
│                                               │
│ 表示                                          │
│  文字サイズ        [ − ]  18pt  [ ＋ ]       │
│  フォント          [ Noto Serif CJK JP ▼ ]   │
│  原稿用紙          [ 20×20 ▼ ]               │
│  [✓] 原稿用紙罫線                             │
│  [ ] 見開き                                   │
│                                               │
│  文字間            [ − ]   2   [ ＋ ]        │
│  行間              [ − ]  12   [ ＋ ]        │
│  上下左右余白      [ 詳細設定 ]               │
│                                               │
│ 執筆                                          │
│  [✓] 自動字下げ                               │
│  [✓] 括弧補完                                 │
│  [✓] 自動履歴                                 │
│      保存間隔        [ 5分 ▼ ]                │
│                                               │
│ 校正                                          │
│  [✓] ルールベース校正                         │
│  [ ] 入力中にリアルタイム校正                 │
│  一文の警告文字数   [ 100 ]                   │
│                                               │
│ AI                                            │
│  [✓] ローカルLLMを使用                        │
│  Provider          [ Ollama ▼ ]               │
│  Model             [ qwen... ▼ ]              │
│  [ 接続テスト ]                                │
│                                               │
│ 音読                                          │
│  Voice             [ Kyoko ▼ ]                │
│  速度              [ − ] 1.0 [ ＋ ]          │
│                                               │
│ 設定の保存先                                  │
│  ( ) このセッションだけ                       │
│  (●) この作品                                 │
│  ( ) 全作品の既定値                           │
│                                               │
│  [ 元に戻す ]   [ 保存 ]   [ 閉じる ]         │
└───────────────────────────────────────────────┘
```

マウスだけでも主要操作を完結できること。

キーボードでは：

```text
TAB       次
S-TAB     前
RET       決定
q         閉じる
```

---

# 8. 作品メタデータ

最低限：

```text
title
author
language
identifier
```

を設定可能にする。

タイトルと著者名は設定画面最上部へ置く。

本文には自動挿入しない。

`.tategaki/project.json` に作品metadataとして保存可能にする。

例：

```json
{
  "schema_version": 1,
  "title": "夏の終わり",
  "author": "山田花子",
  "language": "ja",
  "identifier": ""
}
```

---

# 9. Exportとのmetadata共有

既存：

```elisp
tategaki-export-metadata
```

と統合する。

設定画面で、

```text
タイトル = 夏の終わり
著者名   = 山田花子
```

を設定すれば、

- DOCX
- PDF
- EPUB
- HTML

で自動利用する。

優先順位：

```text
explicit export override
>
project metadata
>
buffer-local tategaki-export-metadata
>
filename/default
```

---

# 10. 表示設定binding

```text
文字サイズ
→ tategaki-text-scale-increase/decrease/reset

原稿用紙
→ tategaki-manuscript-size

原稿用紙罫線
→ tategaki-manuscript-grid

見開き
→ tategaki-manuscript-spread

文字間
→ tategaki-character-spacing

行間
→ tategaki-line-spacing

余白
→ tategaki-padding-top
   tategaki-padding-bottom
   tategaki-padding-left
   tategaki-padding-right
```

詳細余白：

```text
上余白      [ − ] 20 [ ＋ ]
下余白      [ − ] 20 [ ＋ ]
左余白      [ − ] 16 [ ＋ ]
右余白      [ − ] 16 [ ＋ ]
```

表示設定は即時preview。

本文・Undo・modified flagは変更しない。

---

# 11. 執筆設定

```text
自動字下げ
→ tategaki-writing-auto-indent

括弧補完
→ tategaki-writing-electric-pair

自動履歴
→ tategaki-history-enabled

保存間隔
→ tategaki-history-idle-interval
```

保存間隔候補：

```text
1分
3分
5分
10分
保存時のみ
```

---

# 12. 校正設定

```text
ルールベース校正
→ tategaki-proofread-enabled

リアルタイム校正
→ tategaki-proofread-live

一文警告文字数
→ tategaki-proofread-max-sentence-length
```

将来的に詳細画面：

```text
[✓] 表記揺れ
[✓] 括弧
[✓] 重複語
[✓] 語尾連続
[✓] 文長
[ ] 助詞連続
```

---

# 13. AI設定

```text
ローカルLLM
Provider
Model
接続テスト
```

最低限provider：

```text
OpenAI-compatible
Ollama
LM Studio
llama.cpp
```

可能なら内部的にはOpenAI-compatible endpointへ寄せる。

接続テスト：

```text
✓ 接続成功
Model: qwen...
```

または、

```text
✗ 接続できません
```

を設定画面内に表示。

---

# 14. TTS設定

```text
Voice
速度
```

macOSなら利用可能voice一覧を取得する。

例：

```text
Kyoko
Otoya
```

---

# 15. 設定scope

3階層：

```text
session
project
default
```

優先順位：

```text
session > project > default
```

### session

現在のbufferだけ。

### project

現在の小説だけ。

`.tategaki/project.json`

### default

全作品の既定。

---

# 16. 設定保存・取消

設定画面open時にsnapshotを保持。

`[元に戻す]`

→ 画面を開いた時点へ戻す。

`[保存]`

→ 選択scopeへ永続化。

`[閉じる]`

未保存変更があれば：

```text
変更を保存しますか？

[保存して閉じる]
[保存せず閉じる]
[戻る]
```

---

# 17. 初回起動UI

```text
┌────────────────────────────────────────┐
│              my-tategaki               │
│                                        │
│      [ 新しい小説を書く ]              │
│                                        │
│      [ 原稿を開く ]                    │
│                                        │
│      最近の原稿                        │
│      ・夏の終わり                      │
│      ・長編01                          │
│                                        │
│                          [ ⚙ 設定 ]     │
└────────────────────────────────────────┘
```

`C-x C-f`や`M-x`を知らなくても開始可能にする。

---

# 18. セッション復元

## `tategaki-session.el`

保存：

```text
file
point
mark
page
scroll-start
text scale
manuscript size
spread
typesetting
Studio Write/Review
open outline
active chapter
```

commands：

```text
tategaki-session-save
tategaki-session-restore
tategaki-session-open-last
```

目標：

**MacBookを開いたら前回の位置から書ける。**

---

# 19. 自動履歴 / Time Machine

## `tategaki-history.el`

- 保存時snapshot
- idle snapshot
- dirty buffer対応
- SHA-256重複排除
- 本文と別保存
- 原稿を勝手にrestoreしない

例：

```text
~/.local/share/my-tategaki/history/
  <document-id>/
    manifest.json
    snapshots/
      20260929T010501.txt
      20260929T011812.txt
```

UI：

```text
2026-09-29 01:18   68,814字   +601
2026-09-29 00:51   68,213字   +132
2026-09-28 22:10   68,081字
```

commands：

```text
tategaki-history
tategaki-history-open
tategaki-history-diff
tategaki-history-restore-as-copy
```

---

# 20. Lookup辞書

## `tategaki-lookup.el`

既存Emacs Lookupを利用。

取得順：

1. region
2. point上の語
3. 手入力

結果はside window。

原稿pointを維持する。

---

# 21. Diagnostics基盤

## `tategaki-diagnostics.el`

共通形式：

```elisp
(:id "..."
 :source rule
 :severity warning
 :start START
 :end END
 :code "repeated-ending"
 :message "同じ語尾が近接しています"
 :details ...)
```

source bufferへoverlay。

既存`tategaki-highlight`経由で縦書き表示へ反映。

---

# 22. ルールベース校正

## `tategaki-proofread.el`

対象：

- 括弧対応
- 約物連続
- 全半角
- 数字表記
- 表記揺れ
- 禁止語
- 文長
- 段落長
- 同一語近接
- 語尾連続
- 助詞連続
- 異常空白

軽量ルールはidle。

全文検査は明示command。

---

# 23. Project

## `tategaki-project.el`

```text
novel/
  manuscript.txt
  .tategaki/
    project.json
    world.json
    timeline.json
    index/
    resources/
```

作品固有設定・書誌情報・RAG情報等を保持。

---

# 24. Local AI

## `tategaki-ai.el`

provider abstraction：

```text
tategaki-ai-chat
tategaki-ai-embed
tategaki-ai-health
```

既定：

```text
AI disabled
```

またはlocalhost only。

本文を無断外部送信しない。

---

# 25. Semantic Search / RAG

## `tategaki-semantic.el`
## `tategaki-rag.el`

chunk：

```text
scene
paragraph
long paragraph fragments
```

metadata：

```text
document
chapter
scene
start/end
characters
POV
story-time
hash
```

検索例：

```text
主人公が母親について後悔している場面
```

RETで原稿へjump。

---

# 26. Tategaki Assistant

## `tategaki-assistant.el`

下部にREPLを開く。

```text
┌────────────────────────────────────────┐
│               縦書き原稿               │
├────────────────────────────────────────┤
│ *Tategaki Assistant*                   │
│ > このとき花子は何を考えていそう？    │
│                                        │
│ 原稿から確認できること                 │
│ ...                                    │
└────────────────────────────────────────┘
```

commands：

```text
tategaki-assistant
tategaki-ask
tategaki-ask-region
tategaki-ask-character
```

---

# 27. Assistant Context

質問時に収集：

```text
current paragraph
current scene
current chapter
surrounding text
semantic RAG
characters
world DB
timeline
selected region
```

回答は可能な限り：

```text
原稿から確認できること
推測
不明
参照箇所
```

に分ける。

---

# 28. clickable source citation

回答：

```text
[第4章:1321]
[第7章:8910]
```

をbutton化。

クリックで原稿へ移動。

LLM回答が原稿navigatorとして機能するようにする。

---

# 29. 人物がその時点で知っている情報

質問：

```text
この時点で花子は何を知っている？
```

では未来sceneをRAGから除外する。

将来的に：

```text
author knowledge
reader knowledge
character knowledge
```

を分離。

質問：

```text
読者は知っているが花子は知らないことは？
太郎はこの鍵の存在を知っている？
```

に対応。

---

# 30. 作品世界DB

## `tategaki-world.el`

抽出：

```text
Character
Place
Organization
Object
Event
Relationship
Fact
```

状態：

```text
observed
inferred
author-confirmed
rejected
```

LLMの推測を確定事実扱いしない。

人物カード：

```text
花子
────────────────
初出       第1章
年齢       32歳
一人称     私

関係
太郎       兄

登場箇所
第1章
第3章
第7章
```

---

# 31. 設定矛盾チェッカー

対象：

- 年齢
- 日時
- 曜日
- 場所
- 左右
- 色
- 所有物
- 人間関係
- 呼称
- 生死
- 人物が知っている情報

LLMはfact抽出に利用可能。

比較可能なものはコードで判定。

---

# 32. Timeline

## `tategaki-timeline.el`

```text
原稿順              作品時間
第1章 scene1   →    4/10 08:00
第2章 scene1   →    3/28
第3章 scene1   →    4/11 19:00
```

日時状態：

```text
exact
relative
inferred
unknown
```

---

# 33. 伏線管理

## `tategaki-foreshadow.el`

```text
未回収
赤い傘             第2章
父親からの手紙     第5章

回収済
時計               第3章 → 第12章
```

LLMは候補提示のみ。

登録は作者が確定する。

---

# 34. Character Voice

## `tategaki-voice.el`

人物別に：

- 一人称
- 二人称
- 語尾
- 文長
- 敬語
- 語彙
- 頻出表現

を分析。

新しい台詞との差をwarningとして提示。

---

# 35. 縦書きDiff

## `tategaki-diff.el`

```text
┌──────────────┬──────────────┐
│  旧稿 縦書き │  新稿 縦書き │
│              │              │
└──────────────┴──────────────┘
```

差分はsource overlayにして縦書きへ投影。

Scene A/B案も将来的に管理。

---

# 36. TTS音読

## `tategaki-tts.el`

```text
tategaki-tts-play
tategaki-tts-pause
tategaki-tts-stop
tategaki-tts-read-region
```

読み上げ箇所をoverlay highlight。

固有名詞読み辞書対応。

---

# 37. Reader Mode

## `tategaki-reader.el`

- diagnostics非表示
- Assistant非表示
- 編集UI非表示
- 文庫本風preset
- 見開き
- ページ送り中心

終了時にStudio状態を完全復元。

---

# 38. 資料RAG

```text
.tategaki/resources/
```

に作品資料を登録可能にする。

Assistantから：

```text
この章の資料に明治期の鉄道運賃について書いてあったはず
```

等を検索。

原稿RAGと資料RAGは回答上で区別する。

---

# 39. Unified Review

## `tategaki-review.el`

```text
M-x tategaki-review
```

Dashboard：

```text
校正                12 warnings
表記揺れ             3
設定整合性           1
時系列               2
人物Voice            4
AI review             未実行
音読                  未実行
出力確認              OK
```

クリックで該当箇所へ。

---

# 40. AIの役割

LLM：

- 指示語の曖昧さ
- 意味重複
- POV
- 主語
- 人物心理
- 人物描写比較
- 説明過多
- シーン分析

コード：

- 文字数
- 括弧
- 表記揺れ集計
- 登場回数
- exact search
- 日時計算
- deterministic矛盾

原則：

```text
Machine facts first.
LLM interpretation second.
```

---

# 41. Assistant質問プリセット

## 人物

```text
この人物はいま何を知っている？
この人物はいま何を考えていそう？
この人物はいま何を欲している？
この人物は何を恐れている？
過去の言動と矛盾していない？
この台詞はこの人物らしい？
```

## 場面

```text
この場面で新しく提示される情報は？
この場面の目的は？
緊張が変化する箇所は？
冗長な説明候補は？
前後の場面と重複している情報は？
```

## 構成

```text
未回収の要素は？
この章で初めて登場した情報は？
後の章で再登場する要素は？
読者は知っているがPOV人物は知らないことは？
```

---

# 42. UI原則

重要機能には、

```text
Clickable UI
Keyboard shortcut
M-x command
```

を用意する。

すべて同じcommand実装へ収束させる。

UIにロジックを重複実装しない。

---

# 43. 非同期処理

以下は編集をblockしない。

```text
embedding
LLM query
project indexing
world extraction
review
TTS preparation
```

AI処理開始時にsource hashを保持。

完了時に原稿が変更されていれば、古いpositionへ無条件に結果を貼らない。

---

# 44. Privacy

localhost以外へ原稿を送る場合：

```text
この設定では原稿本文が外部サービスへ送信されます
```

と明示する。

デフォルトでは外部送信しない。

---

# 45. GUIテスト

最低限：

- Studio toolbar mouse click
- Settings button
- タイトル・著者名入力
- Project metadata保存・復元
- +/-操作
- Font変更
- 原稿用紙preset変更
- grid/spread
- padding
- settings即時preview
- `[元に戻す]`
- Assistant bottom window
- side window
- diagnostics highlight
- zoom
- scrollbar
- fixed manuscript
- Reader
- TTS highlight

本文不変テスト：

```text
buffer-string unchanged
buffer-undo-list unchanged
modified flag unchanged
```

---

# 46. 設定画面Acceptance Criteria

最低限：

1. タイトル設定可能。
2. 著者名設定可能。
3. 言語設定可能。
4. identifier設定可能。
5. projectに保存可能。
6. 再起動後に復元可能。
7. export metadataに引き継がれる。
8. font変更を即時preview。
9. 文字サイズ変更を即時preview。
10. 原稿用紙変更を即時preview。
11. 字間・行間・余白変更を即時preview。
12. 自動履歴設定可能。
13. 校正設定可能。
14. AI provider/model設定可能。
15. AI接続テスト可能。
16. TTS voice/rate設定可能。
17. 設定変更で本文を変更しない。
18. Undo履歴を変更しない。
19. session/project/defaultが混線しない。
20. 壊れたproject設定でも本文は開ける。
21. UIを使わなくても`setq`等で従来通り設定可能。

---

# 47. 実装優先順位

## Milestone A — ポメラ以上の日常執筆

1. `tategaki-studio.el`
2. **`tategaki-settings.el`**
3. clickable toolbar
4. Write / Review
5. 初回起動画面
6. タイトル・著者名を含むProject metadata
7. session restore
8. history
9. Lookup

設定画面は後回しにしない。

## Milestone B — 文章IDE

10. diagnostics
11. rule proofreading

## Milestone C — 原稿と相談

12. project
13. AI provider
14. embeddings/index
15. semantic search
16. Assistant
17. clickable citations

## Milestone D — 長編理解

18. world DB
19. consistency
20. timeline
21. knowledge cutoff
22. foreshadowing
23. character voice

## Milestone E — 推敲環境

24. vertical diff
25. scene branches
26. TTS
27. Reader
28. resource RAG
29. unified review

---

# 48. 最初のVertical Slice

最初のNovel IDE版では以下を一気通貫で完成させる。

```text
tategaki-studio
      ↓
Zenな縦書き原稿
      ↓
[⚙設定]
      ↓
タイトル・著者名を設定
      ↓
文字サイズ・フォント・原稿用紙をクリック調整
      ↓
[辞書]
      ↓
Lookup
      ↓
[履歴]
      ↓
snapshot
      ↓
[校正]
      ↓
rule diagnostics
      ↓
[AI]
      ↓
Assistant
      ↓
「この場面について相談」
      ↓
RAG
      ↓
回答
      ↓
[第3章:1234]
      ↓
縦書き原稿へjump
      ↓
[出力]
      ↓
設定済みタイトル・著者名でPDF/EPUB/DOCX生成
```

---

# 49. 完成時のユーザー体験

MacBookを開く。

前回の原稿が表示される。

通常はほぼ本文しか見えない。

必要なら設定をクリックする。

```text
[⚙設定]
```

そこから、

```text
タイトル
著者名
フォント
文字サイズ
原稿用紙
字間
行間
自動履歴
校正
AI
音読
```

をすべて操作できる。

書く。

分からない語があれば辞書。

不自然な文章は校正。

昔の版は履歴。

人物について分からなくなればAssistant。

```text
> この時点で花子は太郎の嘘をどこまで知っている？
```

回答：

```text
原稿から確認できること

・第3章で太郎の説明と事実が食い違うことに気付いている。
・第5章ではその件を本人に問いただしていない。

推測

・嘘を確信しているというより、疑いを深めている段階と読める。

不明

・嘘の目的まで理解している描写はまだない。

参照
[第3章:1832]
[第5章:4910]
```

クリックすると原稿へ飛ぶ。

最後に出力を押せば、設定画面で登録した、

```text
タイトル
著者名
言語
identifier
```

を使用してPDF / EPUB / DOCX等を生成する。

---

# 50. プロジェクトの最終的位置付け

目標は、

**「Emacsで縦書きできる」**

ではない。

また、

**「AIが小説を書いてくれる」**

でもない。

目標は、

> **作者自身が小説を書くための認知・検索・推敲能力を拡張するNovel IDE**

である。

my-tategakiは最終的に、

```text
Editor
Writing UI
Project Metadata
Dictionary
Linter
Semantic Search
World Model
Timeline
History
Diff
Debugger
LLM REPL
TTS
Reader
Build System
```

を一つの原稿の周囲へ統合する。

**Write時にはポメラのように静か。  
Review時にはIDEのように強力。**

これを最優先の製品設計原則とする。