# org-tategaki-preview 実装 Handoff

## 1. 目的

GNU Emacs 内だけで完結する、Org-mode 向けの縦書きプレビュー機能を実装する。

WebKit、ブラウザ、外部GUI、Electron 等は使用しない。

左側で通常どおり Org 文書を横書き編集し、右側の Emacs window に同じ文章を「疑似縦書き」で表示する。

想定UI:

```text
┌──────────────────────┬──────────────────────┐
│ article.org          │ *Tategaki Preview*   │
│                      │                      │
│ * 第一章             │    名 吾 第          │
│                      │    前 輩 一          │
│ 吾輩は猫である。     │    は は 章          │
│ 名前はまだ無い。     │    ま 猫             │
│                      │    だ で             │
│                      │    無 あ             │
│                      │    い る             │
│                      │    ︒ ︒             │
└──────────────────────┴──────────────────────┘
```

用途は本格的なDTPではなく、文章・小説・長文を「縦書きで読んだときの見え方」を執筆中に確認すること。

---

# 2. 基本方針

完全に Elisp のみで実装する。

構造:

```text
Org source buffer
      │
      │ buffer text
      ▼
tategaki transform
      │
      │ 横書き文字列 → 縦書き表示文字列
      ▼
*Tategaki Preview*
      │
      └─ special-mode/read-only
```

縦書きは Emacs の描画方向を変更するのではなく、文字列そのものを行列変換して生成する。

例えば:

```text
これは縦書きです。
吾輩は猫である。
```

を概念的に:

```text
る　き　こ
。　で　れ
　　す　は
　　。　縦
　　　　書
　　　　き
```

のような文字列に変換する。

列方向は、日本語縦書きと同様に

```text
右 → 左
```

とする。

1列内の文字方向は

```text
上 → 下
```

。

---

# 3. 最初の実装範囲

まず MVP を完成させる。

必須要件:

1. `M-x org-tategaki-preview`
2. 現在の Org buffer の右側を split
3. `*Tategaki Preview*` buffer を表示
4. source buffer の文章を縦書き変換
5. source buffer 編集時に自動再描画
6. preview buffer は read-only
7. source buffer は通常どおり編集可能
8. preview window の大きさに応じて列高さを変更
9. 日本語約物を最低限縦書き用 Unicode へ変換
10. preview 終了コマンドを用意

WebKit、HTML、CSS、ブラウザは一切不要。

---

# 4. 想定ファイル構成

まずは単一ファイルでよい。

```text
org-tategaki-preview.el
```

成熟後は必要なら分割する。

例:

```text
org-tategaki-preview.el
README.md
test/
  org-tategaki-preview-test.el
```

---

# 5. コマンド仕様

## `org-tategaki-preview`

interactive command。

実行すると:

```text
現在のwindow
      ↓
split-window-right
      ↓
右windowに *Tategaki Preview*
```

を表示。

source buffer を記録する。

既に preview が存在する場合は新しい window を無制限に作らず、既存 preview を再利用する。

---

## `org-tategaki-preview-close`

preview window を閉じる。

可能なら preview buffer も kill。

source buffer に設定した hook/timer も解除する。

---

## `org-tategaki-preview-refresh`

手動再描画。

debug 用としても利用する。

---

## 将来候補

```text
org-tategaki-preview-toggle
org-tategaki-preview-next-page
org-tategaki-preview-previous-page
org-tategaki-preview-toggle-org-markup
```

MVPでは不要。

---

# 6. Minor mode

可能なら

```elisp
org-tategaki-preview-mode
```

という buffer-local minor mode にする。

source buffer 側で有効化する。

有効時:

```text
after-change-functions
window-size-change-functions
kill-buffer-hook
```

等を必要に応じて設定する。

無効化時にはすべて解除する。

global hook を汚さないこと。

---

# 7. Preview buffer

preview は例えば:

```text
*Tategaki Preview: article.org*
```

とする。

複数 source buffer を同時に使える設計が望ましい。

例えば:

```text
*Tategaki Preview: novel.org*
*Tategaki Preview: memo.org*
```

。

preview buffer は:

```elisp
special-mode
```

ベースでよい。

設定候補:

```elisp
(setq-local cursor-type nil)
(setq-local truncate-lines t)
(setq-local buffer-read-only t)
```

不要な mode-line を簡略化してもよいが MVP では必須でない。

---

# 8. 入力対象

最初の MVP は source buffer 全体を対象にしてよい。

ただし設計上は後から:

```text
現在の subtree
narrowing
region
current heading
```

へ切り替えられる構造にする。

理想的には内部関数:

```elisp
(org-tategaki-preview--source-text)
```

で入力文字列取得処理を隔離する。

---

# 9. Org markup の扱い

MVPでは「文章確認用途」が主目的。

Org記法を完全にレンダリングする必要はない。

ただし最低限:

```text
* 第一章
** 第二節
```

程度は読みやすく表示したい。

方法は二案。

### 案A

buffer text をそのまま縦書き。

最も単純。

### 案B

軽い前処理を行う。

例:

```text
* 第一章
```

を:

```text
第一章
```

として表示。

MVPでは案Bを推奨するが、複雑な `org-export` は使わない。

Org parser 全体を通す必要もない。

将来:

```elisp
org-element-parse-buffer
```

で本文・見出し・引用などを抽出してもよい。

---

# 10. 縦書き変換アルゴリズム

重要部分。

関数イメージ:

```elisp
(org-tategaki-preview--render TEXT HEIGHT WIDTH)
```

HEIGHT:

1列あたりの最大文字数。

WIDTH:

表示可能な列数。

概念として文章を固定高さで分割する。

例:

```text
abcdefghijklmnop
```

height=4 の場合:

```text
abcd
efgh
ijkl
mnop
```

これを右から左へ配置:

```text
m i e a
n j f b
o k g c
p l h d
```

日本語でも同じ。

つまり内部的には:

1. 文字列を grapheme / character 単位で分割
2. HEIGHT ごとに chunk
3. chunk を列として扱う
4. 列配列を reverse
5. 各rowごとに文字を取得
6. horizontal string として join
7. newline で join

---

# 11. 改行

ここが重要。

文章中の改行を単純な1文字として処理すると表示が崩れる。

MVPでは以下のルールを推奨。

通常の段落:

```text
今日は晴れです。
散歩へ行きます。
```

は、

```text
今日は晴れです。
散歩へ行きます。
```

という論理行を維持せず、一旦文章フローとして扱ってよい。

ただし空行は段落区切りとして残す。

つまり:

```text
line1
line2

line3
```

を内部的に:

```text
line1line2

line3
```

程度に正規化する。

将来的には段落ごとに新しい列を開始するモードを追加可能。

---

# 12. 約物変換

最低限、以下を preview 用に置換する。

source buffer は絶対に変更しない。

候補:

```text
、 → ︑ または ︐
。 → ︒

「 → ﹁
」 → ﹂

『 → ﹃
』 → ﹄

（ → ︵
） → ︶

［ → ﹇
］ → ﹈

｛ → ︷
｝ → ︸

〈 → ︿
〉 → ﹀

《 → ︽
》 → ︾
```

Unicode Vertical Forms を利用する。

ただし使用中フォントによって見え方が違うため、

```elisp
(defcustom org-tategaki-preview-use-vertical-forms t ...)
```

のように無効化可能にしておくとよい。

---

# 13. ASCII / 英数字

MVPでは横倒しにしなくてよい。

例えば:

```text
Emacs 31
```

なら:

```text
E
m
a
c
s

3
1
```

程度で構わない。

本格的な

```text
縦中横
欧文回転
```

は将来機能。

---

# 14. 全角・半角幅

ここは注意。

Emacsの画面では CJK 文字と ASCII 文字の表示幅が違う。

単純に:

```elisp
(string-join chars " ")
```

では列がずれる可能性がある。

可能なら:

```elisp
string-width
char-width
truncate-string-to-width
```

を利用してセル幅を揃える。

最初は各縦列の間隔を:

```text
" "
```

または

```text
"　"
```

で確保する。

ユーザー設定:

```elisp
org-tategaki-preview-column-spacing
```

を持たせてもよい。

---

# 15. Window height

固定で30文字などにしない。

preview window の高さから計算する。

例:

```elisp
(window-body-height preview-window)
```

を利用。

mode-line 等を除いた行数を取得し、

```text
height = window-body-height - margin
```

程度にする。

つまり Emacs frame をリサイズすると:

```text
縦書きの1列あたり文字数
```

も変わる。

---

# 16. Window width

preview window の:

```elisp
(window-body-width)
```

から最大列数を求める。

CJK 1文字の横幅を2セル程度と考える。

例えば1列:

```text
2セル + 列間1セル
```

なら、

```text
columns = width / 3
```

程度。

厳密でなくてよい。

最初は visible columns を計算し、それを超えた文章はページングする設計にしてもよい。

ただし MVP の第一版では buffer が横方向に非常に長くなっても構わない。

その後ページングを追加する。

---

# 17. 自動更新

source buffer に:

```elisp
after-change-functions
```

を設定。

ただし1キー入力ごとに即再描画しない。

idle timer / debounce を入れる。

例えば:

```text
0.15〜0.30秒
```

程度。

実装イメージ:

```elisp
(run-with-idle-timer
 0.2 nil
 #'org-tategaki-preview--refresh
 source-buffer)
```

前回のtimerが存在すれば cancel。

つまり:

```text
typing
typing
typing
typing
    ↓
200ms停止
    ↓
refresh
```

とする。

---

# 18. Window resize 対応

window size が変わったら再描画。

例えば:

```elisp
window-size-change-functions
```

を使用。

global hook を使う場合でも、対象 preview/source が存在する時だけ動かす。

過剰再描画を避ける。

---

# 19. カーソル同期

MVP完成後の優先度高め機能。

source buffer の point がある文字に対応する preview 位置を highlight。

source offset:

```text
source point
```

から、変換後の:

```text
row
column
```

を算出。

preview buffer 側では overlay を使用。

例えば:

```elisp
make-overlay
overlay-put 'face 'highlight
```

。

これにより:

```text
左:
吾輩は[猫]である

右:
猫 ← highlight
は
輩
吾
```

のようにできる。

ただし MVP 第一版では不要。

---

# 20. Page概念

将来的には page を持つ。

例:

```text
height: 35 chars
columns: 16
```

なら1ページ:

```text
35 × 16 = 560文字
```

。

次の560文字を next page。

コマンド候補:

```text
n / p
SPC / DEL
C-v / M-v
```

preview buffer 上で操作可能にする。

---

# 21. Preview mode keymap

例えば:

```text
q    close
g    refresh
n    next page
p    previous page
SPC  next page
DEL  previous page
```

MVPでは:

```text
q
g
```

だけでもよい。

---

# 22. Text properties

source text の text properties は基本的に除去する。

処理時に:

```elisp
substring-no-properties
```

を使う。

preview buffer に source buffer の face 等を持ち込まない。

---

# 23. Performance

一般的な小説ファイル:

```text
数万〜数十万文字
```

程度で実用速度を目指す。

毎回 buffer 全体を組み直す MVP でも最初はよい。

ただし、

```text
1MB級 Org file
```

でも編集不能になるほど重くしないこと。

まず profile して問題が出てから incremental rendering を考える。

---

# 24. Coding style

Emacs Lisp の一般的な package style に従う。

prefix:

```text
org-tategaki-preview-
```

private:

```text
org-tategaki-preview--
```

例:

```elisp
org-tategaki-preview-mode
org-tategaki-preview
org-tategaki-preview-close

org-tategaki-preview--render
org-tategaki-preview--refresh
org-tategaki-preview--schedule-refresh
org-tategaki-preview--normalize-text
org-tategaki-preview--vertical-form
```

lexical-binding を使用。

ファイル先頭:

```elisp
;;; org-tategaki-preview.el --- Vertical writing preview for Org -*- lexical-binding: t; -*-
```

---

# 25. Custom variables

最低限候補:

```elisp
(defgroup org-tategaki-preview nil ...)

(defcustom org-tategaki-preview-refresh-delay 0.2 ...)
(defcustom org-tategaki-preview-use-vertical-forms t ...)
(defcustom org-tategaki-preview-column-spacing 1 ...)
```

将来:

```elisp
org-tategaki-preview-source-scope
org-tategaki-preview-page-mode
org-tategaki-preview-show-headings
org-tategaki-preview-font
```

---

# 26. Font

preview buffer 用 font を指定可能にしてもよい。

ただし初期値は `nil` とし Emacs default font を使う。

ユーザーが:

```elisp
(set-face-attribute ...)
```

で明朝体等を使える設計にする。

例えば専用 face:

```elisp
(defface org-tategaki-preview-face
  '((t (:inherit default)))
  ...)
```

。

---

# 27. Org heading 表示

見出し:

```text
* 第一章
```

は最低限:

```text
第一章
```

として本文中に残す。

見出し前後に適度な空白を入れてよい。

例えば:

```text
第一章

吾輩は猫である。
```

。

Org markup:

```text
* 
** 
***
```

は表示用には削除。

---

# 28. 非表示候補

MVPでは以下を preview から除外してもよい。

```text
:PROPERTIES:
...
:END:
```

Org property drawer。

また:

```text
#+TITLE:
#+AUTHOR:
#+OPTIONS:
```

など metadata も本文表示から除外可能。

ただし implementation complexity が増えるなら第一版ではそのままでもよい。

優先順位は:

```text
動く縦書き
>
Org構文の綺麗な解釈
```

。

---

# 29. 文字変換テスト

ERT test を書く。

例:

入力:

```text
あいうえお
```

height=2

論理列:

```text
あい
うえ
お
```

出力:

```text
おうあ
　えい
```

※実際には spacing policy に応じて空白を入れる。

ASCIIでもテスト。

約物:

```text
「こんにちは。」
```

が vertical forms 有効時に:

```text
﹁
こ
ん
に
ち
は
︒
﹂
```

相当のセルデータになることを確認。

---

# 30. UI acceptance test

以下が成立すれば MVP 完了。

## Test 1

Org buffer:

```text
* 第一章

吾輩は猫である。
名前はまだ無い。
```

から:

```text
M-x org-tategaki-preview
```

。

右側に preview window が出る。

---

## Test 2

左側で:

```text
猫
```

を

```text
犬
```

へ編集。

0.2秒程度後に preview が自動更新される。

---

## Test 3

Emacs frame の高さを変更。

縦書きの1列あたり文字数が自動で変わる。

---

## Test 4

```text
「こんにちは。」
```

の括弧・句点が縦書き向け glyph に置換される。

---

## Test 5

preview buffer を `q` で閉じられる。

timer/hook が残らない。

---

# 31. 重要な非目標

このプロジェクトでは最初から以下を実装しない。

```text
本格DTP
TeXレベルの禁則処理
OpenType vertical substitution
CSS writing-mode 相当
EPUB renderer
WebKit
ブラウザ
PDF出力
ルビの完全な組版
欧文の90度回転
縦中横
```

目的はあくまで:

```text
Emacs 内で文章を縦書きとして読む
```

こと。

---

# 32. 将来的な発展

MVP後は以下を検討。

### Phase 2

カーソル同期。

```text
source point
↕
preview highlight
```

### Phase 3

現在の Org subtree のみ表示。

```text
* 第一章
```

にカーソルがあるなら第一章だけ表示。

### Phase 4

ページング。

```text
n
p
SPC
DEL
```

。

### Phase 5

ルビ。

Org上で例えば:

```text
漢字{かんじ}
```

など独自記法を定義し、previewでは横に小さく表示する。

Emacsの `display` property / overlay 等で工夫する。

### Phase 6

原稿用紙風表示。

```text
20文字 × 20行
```

等。

### Phase 7

小説執筆向けモード。

```text
執筆文字数
現在ページ
現在章
章内文字数
```

などを mode-line に表示。

---

# 33. 実装上の重要判断

「Emacs本体を縦書きにする」のではない。

あくまで:

```text
縦書きになるように並び替えた文字列
```

を通常の Emacs buffer に表示する。

このため:

```text
redisplay hack
Emacs C code modification
native module
WebKit
外部プロセス
```

は不要。

pure Emacs Lisp で完結させる。

---

# 34. 最終的に目指す操作感

ユーザーは普通に Org を編集する。

```text
┌────────────────────┬─────────────────────┐
│ novel.org          │ Tategaki Preview    │
│                    │                     │
│ * 第一章           │    名 吾 第         │
│                    │    前 輩 一         │
│ 吾輩は猫である。   │    は は 章         │
│ 名前はまだ無い。   │    ま 猫            │
│                    │    だ で            │
│                    │    無 あ            │
│                    │    い る            │
│                    │    ︒ ︒            │
└────────────────────┴─────────────────────┘
```

左側については普段の Org-mode を一切壊さない。

保存形式も普通の `.org`。

縦書きは表示専用。

これを最優先する。

---

# 35. 最初に作るべき実装順

以下の順番で進める。

```text
1. pure function の縦書き変換
2. preview buffer 作成
3. split-window-right
4. refresh command
5. after-change 自動更新
6. debounce timer
7. window resize 対応
8. vertical forms
9. Org heading 軽処理
10. ERT tests
```

最初から機能を増やしすぎない。

特にまず、

```elisp
(org-tategaki-preview--render "吾輩は猫である。" 10)
```

が正しい文字列を返す pure function を完成させること。

UI実装はその後。

---

# 36. 完成条件

第一版完成時には少なくとも以下が可能であること。

```text
Emacs 起動

↓

Org file を開く

↓

M-x org-tategaki-preview

↓

右半分に縦書き

↓

左で文章を書く

↓

ほぼリアルタイムで右が更新

↓

外部ブラウザ不要
外部プログラム不要
```

この状態を MVP とする。