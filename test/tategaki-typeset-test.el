;;; tategaki-typeset-test.el --- Typesetting model regression tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is part of my-tategaki.
;;
;; my-tategaki is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; my-tategaki is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with my-tategaki.  If not, see <https://www.gnu.org/licenses/>.

(require 'ert)
(require 'cl-lib)
(require 'tategaki-typeset)

(defun tategaki-typeset-test--entries (layout)
  "Return every unique entry in LAYOUT for assertions."
  (tategaki-typeset-visible layout 0 (plist-get layout :columns)))

(defun tategaki-typeset-test--check (text height &optional start cache)
  "Check all insertion positions and source coverage for TEXT's layout."
  (let* ((start (or start 1))
         (layout (tategaki-typeset-layout text height start cache))
         (entries (tategaki-typeset-test--entries layout))
         (end start))
    (dolist (entry entries)
      (let ((unit (aref entry 4)))
        (should (= (plist-get unit :start) end))
        (should (= (aref entry 0) end))
        (should (> (plist-get unit :advance) 0))
        (setq end (plist-get unit :end))))
    (should (= end (+ start (length text))))
    (should (eq (plist-get (aref (car (last entries)) 4) :kind) 'eof))
    (dotimes (index (1+ (length text)))
      (let* ((position (+ start index))
             (entry (tategaki-typeset-entry layout position))
             (unit (aref entry 4)))
        (should (= (aref entry 0) position))
        (should (<= (plist-get unit :start) position))
        (should (or (< position (plist-get unit :end))
                    (and (= position end) (eq (plist-get unit :kind) 'eof))))))
    (should-not (tategaki-typeset-entry layout (1- start)))
    (should-not (tategaki-typeset-entry layout (1+ end)))
    layout))

(ert-deftest tategaki-typeset-default-is-opt-in ()
  (should-not (default-value 'tategaki-typesetting)))

(ert-deftest tategaki-typeset-graphemes-retain-all-source-positions ()
  (dolist (text '("が" "葛󠄀" "☀️" "👍🏽" "👩‍👩‍👧‍👦" "🇯🇵" "é" "한" "1️⃣"))
    (let* ((layout (tategaki-typeset-test--check text 1))
           (entries (tategaki-typeset-test--entries layout))
           (unit (aref (car entries) 4)))
      (should (= (length entries) 2))
      (should (equal (plist-get unit :source-text) text))
      (dotimes (index (length text))
        (should (= (aref (tategaki-typeset-entry layout (1+ index)) 3) 0))))))

(ert-deftest tategaki-typeset-regional-indicators-pair-not-whole-run ()
  (let* ((layout (tategaki-typeset-test--check "🇯🇵🇺🇸🇦" 4))
         (entries (tategaki-typeset-test--entries layout)))
    (should (= (length entries) 4))
    (should (equal (mapcar (lambda (entry) (plist-get (aref entry 4) :source-text)) entries)
                   '("🇯🇵" "🇺🇸" "🇦" "")))))

(ert-deftest tategaki-typeset-preserves-source-and-whitespace ()
  (let* ((text (propertize " が\t\r\n\n* 本文　\0" 'face 'bold))
         (before (copy-sequence text)))
    (tategaki-typeset-test--check text 3 47)
    (should (equal-including-properties text before))
    (should (equal (tategaki-typeset-plain-text text) (substring-no-properties text)))))

(ert-deftest tategaki-typeset-empty-and-eof-content-columns ()
  (should (= (plist-get (tategaki-typeset-test--check "" 20) :content-columns) 0))
  (let ((layout (tategaki-typeset-test--check (make-string 400 ?文) 20)))
    (should (= (plist-get layout :content-columns) 20))
    (should (= (plist-get layout :columns) 21))))

(ert-deftest tategaki-typeset-kinsoku-pushes-open-bracket ()
  (let* ((tategaki-typeset-hanging-punctuation nil)
         (layout (tategaki-typeset-test--check "甲乙「丙丁" 3)))
    (should (= (aref (tategaki-typeset-entry layout 3) 2) 0))
    (should (= (aref (tategaki-typeset-entry layout 3) 3) 1))))

(ert-deftest tategaki-typeset-kinsoku-pushes-preceding-body-with-close ()
  (let* ((tategaki-typeset-hanging-punctuation nil)
         (layout (tategaki-typeset-test--check "甲乙丙」丁" 3)))
    (should (= (aref (tategaki-typeset-entry layout 3) 2) 0))
    (should (= (aref (tategaki-typeset-entry layout 4) 2) 1))))

(ert-deftest tategaki-typeset-hanging-has-half-cell-advance ()
  (let* ((layout (tategaki-typeset-test--check "甲乙丙。丁" 3))
         (entry (tategaki-typeset-entry layout 4)) (unit (aref entry 4)))
    (should (= (aref entry 3) 0))
    (should (= (aref entry 2) 3))
    (should (plist-get unit :hanging))
    (should (= (plist-get unit :advance) 0.5))))

(ert-deftest tategaki-typeset-compression-fits-prohibited-start ()
  (let* ((tategaki-typeset-hanging-punctuation nil)
         (tategaki-typeset-compression t)
         (layout (tategaki-typeset-test--check "甲乙丙」丁" 3))
         (entry (tategaki-typeset-entry layout 4)) (unit (aref entry 4)))
    (should (= (aref entry 3) 0))
    (should (= (+ (aref entry 2) (plist-get unit :advance)) 3.0))
    (should (= (plist-get unit :compression) 0.75))))

(ert-deftest tategaki-typeset-indivisible-punctuation-and-tiny-height ()
  (dolist (text '("甲乙……丙" "甲乙――丙" "「「「」」」、。"))
    (dolist (height '(1 2 3)) (tategaki-typeset-test--check text height)))
  (let ((layout (tategaki-typeset-test--check "……" 1)))
    (should (= (aref (tategaki-typeset-entry layout 1) 3)
               (aref (tategaki-typeset-entry layout 2) 3)))))

(ert-deftest tategaki-typeset-kinsoku-is-customizable ()
  (let* ((tategaki-typeset-kinsoku nil)
         (layout (tategaki-typeset-test--check "甲乙「丙" 3)))
    (should (= (aref (tategaki-typeset-entry layout 3) 2) 2)))
  (let* ((tategaki-typeset-line-start-prohibited "乙")
         (tategaki-typeset-hanging-punctuation nil)
         (layout (tategaki-typeset-test--check "丙甲乙丁" 2)))
    (should (= (aref (tategaki-typeset-entry layout 3) 2) 1))))

(ert-deftest tategaki-typeset-auto-tcy-requires-exact-run ()
  (let* ((layout (tategaki-typeset-test--check "12年123日!?！？A12Z" 20))
         (entries (tategaki-typeset-test--entries layout)))
    (should (= (cl-count 'tcy entries :key (lambda (entry) (plist-get (aref entry 4) :kind))) 1))
    (should (= (plist-get (aref (car entries) 4) :end) 3)))
  (dolist (text '("!?" "！？"))
    (should (eq (plist-get (aref (tategaki-typeset-entry (tategaki-typeset-test--check text 2) 1) 4) :kind) 'tcy)))
  (let ((tategaki-typeset-auto-tcy-digits nil))
    (should (= (length (tategaki-typeset-test--entries (tategaki-typeset-test--check "12" 3))) 3))))

(ert-deftest tategaki-typeset-explicit-tcy-keeps-hidden-syntax-addressable ()
  (let* ((text "［＃縦中横］2026［＃縦中横終わり］")
         (layout (tategaki-typeset-test--check text 2))
         (entries (tategaki-typeset-test--entries layout)))
    (should (= (length entries) 2))
    (should (eq (plist-get (aref (car entries) 4) :kind) 'tcy))
    (should (equal (tategaki-typeset-plain-text text) "2026"))))

(ert-deftest tategaki-typeset-latin-rotation-splits-long-runs ()
  (let* ((tategaki-typeset-latin-orientation 'rotate)
         (text "https://example.org/abcdef?year=2026")
         (layout (tategaki-typeset-test--check text 3))
         (entries (butlast (tategaki-typeset-test--entries layout))))
    (should (> (length entries) 1))
    (dolist (entry entries)
      (should (eq (plist-get (aref entry 4) :kind) 'latin))
      (should (<= (plist-get (aref entry 4) :span) 3)))
    (should (equal (mapconcat (lambda (entry) (plist-get (aref entry 4) :source-text)) entries "") text))))

(ert-deftest tategaki-typeset-ruby-splits-base-and-reading-together ()
  (dolist (text '("｜漢字《かんじ》" "|漢字《かんじ》" "漢字《かんじ》"))
    (let* ((layout (tategaki-typeset-test--check text 1 20))
           (entries (butlast (tategaki-typeset-test--entries layout))))
      (should (= (length entries) 2))
      (should (equal (mapconcat (lambda (entry) (plist-get (aref entry 4) :ruby)) entries "") "かんじ"))
      (should (equal (tategaki-typeset-plain-text text) "漢字"))
      (dolist (entry entries)
        (let ((unit (aref entry 4)))
          (should (eq (plist-get unit :kind) 'ruby))
          (should (= (plist-get unit :annotation-start) 20))
          (should (= (plist-get unit :annotation-end) (+ 20 (length text)))))))))

(ert-deftest tategaki-typeset-emphasis-paired-postfix-and-ruby ()
  (dolist (text '("［＃傍点］本文［＃傍点終わり］" "本文［＃「本文」に傍点］"
                  "［＃傍点］｜本文《ほんぶん》［＃傍点終わり］"))
    (let* ((layout (tategaki-typeset-test--check text 2))
           (entries (butlast (tategaki-typeset-test--entries layout))))
      (should (= (length entries) 2))
      (dolist (entry entries) (should (eq (plist-get (aref entry 4) :emphasis) 'dot)))
      (should (equal (tategaki-typeset-plain-text text) "本文"))))
  (let ((layout (tategaki-typeset-test--check "本文［＃「本文」に傍線］" 2)))
    (should (eq (plist-get (aref (tategaki-typeset-entry layout 1) 4) :emphasis) 'line))))

(ert-deftest tategaki-typeset-raw-and-malformed-notes-stay-visible ()
  (dolist (text '("｜漢字《" "｜漢字《》" "漢字《かんじ" "［＃傍点］本文"
                  "本文［＃「別の字」に傍点］" "｜《読み》"))
    (tategaki-typeset-test--check text 3)
    (should (equal (tategaki-typeset-plain-text text) text)))
  (let* ((tategaki-typeset-annotation-display 'raw)
         (text "｜漢字《かんじ》")
         (layout (tategaki-typeset-test--check text 3)))
    (should (= (length (tategaki-typeset-test--entries layout)) (1+ (length text))))))

(ert-deftest tategaki-typeset-nearest-uses-span-and-exact-boundaries ()
  (let ((layout (tategaki-typeset-test--check "甲乙丙" 4)))
    (should (= (aref (tategaki-typeset-nearest layout 0 1) 0) 2))
    (should-not (tategaki-typeset-nearest layout 100 0)))
  (let* ((tategaki-typeset-latin-orientation 'rotate)
         (layout (tategaki-typeset-test--check "ABCD日" 4)))
    (should (= (aref (tategaki-typeset-nearest layout 0 1) 0) 1))
    (should (= (aref (tategaki-typeset-nearest layout 0 2) 0) 5))))

(ert-deftest tategaki-typeset-visible-is-page-scoped-and-source-ordered ()
  (let* ((layout (tategaki-typeset-test--check (make-string 1000 ?文) 20))
         (visible (tategaki-typeset-visible layout 20 2)))
    (should (= (length visible) 40))
    (should (= (aref (car visible) 0) 401))
    (should (= (aref (car (last visible)) 0) 440))
    (should-not (plist-member layout :positions))
    (should-not (plist-member layout :text))))

(ert-deftest tategaki-typeset-reuses-paragraphs-after-source-shift ()
  (let* ((before "最初。\n次の段落。\n｜漢字《かんじ》")
         (after (concat "追加" before))
         (old (tategaki-typeset-layout before 4 1))
         (cached (tategaki-typeset-test--check after 4 10 old))
         (fresh (tategaki-typeset-layout after 4 10)))
    (should (equal (tategaki-typeset-test--entries cached) (tategaki-typeset-test--entries fresh)))
    (should (= (plist-get (plist-get cached :cache-stats) :reused) 2))
    (should (eq (plist-get (aref (plist-get old :blocks) 2) :data)
                (plist-get (aref (plist-get cached :blocks) 2) :data)))))

(ert-deftest tategaki-typeset-incremental-local-tokenization ()
  (let* ((tategaki-typeset--fast-path nil)
         (before (make-string 10000 ?文))
         (after (concat (substring before 0 5000) "追" (substring before 5000)))
         (old (tategaki-typeset-layout before 20 1))
         (cached (tategaki-typeset-layout after 20 1 old))
         (fresh (tategaki-typeset-layout after 20 1)))
    (should (< (plist-get (plist-get cached :cache-stats) :parsed-characters) 20))
    (should (> (plist-get (plist-get cached :cache-stats) :parsed-characters) 0))
    (should (equal (tategaki-typeset-test--entries cached) (tategaki-typeset-test--entries fresh)))))

(ert-deftest tategaki-typeset-general-cache-agrees-during-grapheme-edits ()
  (let ((text "本文が👩‍👩‍👧‍👦続き……12年\nが終わり") layout)
    (dotimes (iteration 36)
      (setq layout (tategaki-typeset-test--check text 4 7 layout))
      (should (equal (tategaki-typeset-test--entries layout)
                     (tategaki-typeset-test--entries (tategaki-typeset-layout text 4 7))))
      (let ((at (% (* iteration 7) (1+ (length text)))))
        (setq text (if (and (= (% iteration 3) 2) (< at (length text)))
                       (concat (substring text 0 at) (substring text (min (length text) (+ at 3))))
                     (concat (substring text 0 at)
                             (nth (% iteration 5) '("゙" "追" "\n" "12" "‍👧"))
                             (substring text at))))))))

(ert-deftest tategaki-typeset-options-and-height-invalidate-cache ()
  (let* ((text "12｜漢字《かんじ》") (old (tategaki-typeset-layout text 3 1)))
    (let ((tategaki-typeset-annotation-display 'raw))
      (should (= (plist-get (plist-get (tategaki-typeset-layout text 3 1 old) :cache-stats) :reused) 0)))
    (should (= (plist-get (plist-get (tategaki-typeset-layout text 4 1 old) :cache-stats) :reused) 0))))

(ert-deftest tategaki-typeset-compact-direct-index-matches-general-model ()
  (dolist (text '("今日は晴れ。「そうですか。」明日も、晴れ。\n次の段落。"
                  "「「「」」」、。本文" "本文\n\n終わり\n" "abc DEF 3 日 4 月" ""))
    (dotimes (rows 7)
      (dolist (adjustment '(push hanging compress))
        (let* ((tategaki-typeset-hanging-punctuation (eq adjustment 'hanging))
               (tategaki-typeset-compression (eq adjustment 'compress))
               (direct (tategaki-typeset-layout text (1+ rows) 10))
               (general (let ((tategaki-typeset--fast-path nil))
                          (tategaki-typeset-layout text (1+ rows) 10))))
          (should (equal (tategaki-typeset-test--entries direct)
                         (tategaki-typeset-test--entries general)))
          (should (= (plist-get direct :columns) (plist-get general :columns)))
          (should (= (plist-get direct :content-columns) (plist-get general :content-columns))))))))

(ert-deftest tategaki-typeset-forced-boundaries-separate-transient-input ()
  (dolist (text '("が" "👩‍👩‍👧‍👦" "12" "abcdefgh" "｜漢字《かんじ》"
                  "［＃傍点］本文［＃傍点終わり］" "本文［＃「本文」に傍点］"))
    (dotimes (offset (1- (length text)))
      (let* ((tategaki-typeset-latin-orientation 'rotate)
             (boundary (+ 11 offset))
             (layout (tategaki-typeset-layout text 4 10 nil (list boundary))))
        (dolist (entry (tategaki-typeset-test--entries layout))
          (let ((unit (aref entry 4)))
            (should-not (and (< (plist-get unit :start) boundary)
                             (< boundary (plist-get unit :end)))))))))
  (let* ((old (tategaki-typeset-layout "12" 3 1))
         (split (tategaki-typeset-layout "12" 3 1 old '(2))))
    (should (= (length (tategaki-typeset-test--entries split)) 3))
    (should (= (plist-get (plist-get split :cache-stats) :reused) 0))))

(ert-deftest tategaki-typeset-ruby-reading-keeps-graphemes ()
  (let* ((layout (tategaki-typeset-test--check "｜蚊《が》" 3))
         (unit (aref (tategaki-typeset-entry layout 1) 4)))
    (should (equal (plist-get unit :ruby-graphemes) '("が")))))

(ert-deftest tategaki-typeset-additional-vertical-forms-are-display-only ()
  (let* ((text "ー…—") (layout (tategaki-typeset-test--check text 4)))
    (should (equal (mapconcat (lambda (entry) (plist-get (aref entry 4) :text))
                             (butlast (tategaki-typeset-test--entries layout)) "") "｜︙︱"))
    (should (equal (tategaki-typeset-plain-text text) text)))
  (let ((tategaki-layout-use-vertical-forms nil))
    (should (equal (tategaki-typeset--display "ー") "ー"))))

(ert-deftest tategaki-typeset-plain-spans-match-parsed-body ()
  (let ((samples '("普通の文章。" "｜親字《おやじ》" "漢字《かんじ》"
                   "|abc《エービーシー》" "｜漢字《》" "漢字《未完" "\n"
                   "［＃傍点］本文［＃傍点終わり］" "本文［＃「本文」に傍点］"
                   "［＃傍線］｜青空《あおぞら》［＃傍線終わり］"
                   "｜青空《あおぞら》［＃「青空」に傍点］"
                   "［＃縦中横］12［＃縦中横終わり］" "［＃縦中横］123456789［＃縦中横終わり］")))
    (dolist (left samples)
      (dolist (right samples)
        (let* ((text (concat left "間" right))
               (expected (mapconcat (lambda (unit) (plist-get unit :source-text))
                                    (tategaki-typeset--parse text) "")))
          (should (equal (tategaki-typeset-plain-text text) expected)))))))

(ert-deftest tategaki-typeset-partial-annotation-selection-remains-literal ()
  (dolist (text '("｜青空《あおぞら》" "青空《あおぞら》"
                  "［＃傍点］青空［＃傍点終わり］" "青空［＃「青空」に傍点］"))
    (should (equal (tategaki-typeset-plain-text text) "青空"))
    (dotimes (start (length text))
      (cl-loop for end from start to (length text) do
               (unless (and (zerop start) (= end (length text)))
                 (should (equal (tategaki-typeset-plain-text text start end)
                                (substring text start end)))))))
  (let ((text "前｜青空《あおぞら》後"))
    (should (equal (tategaki-typeset-plain-text text 1 (1- (length text))) "青空"))))

(ert-deftest tategaki-typeset-public-analysis-preserves-search-match-data ()
  (save-match-data
    (string-match "a\\(b\\)" "ab")
    (let ((before (match-data)))
      (tategaki-typeset-layout "｜親字《おやじ》" 5 1)
      (should (equal (match-data) before))
      (tategaki-typeset-plain-text "｜親字《おやじ》")
      (should (equal (match-data) before)))))

(ert-deftest tategaki-typeset-cached-and-fresh-agree-across-edits ()
  (let ((text "甲乙。\nが12年👩‍👩‍👧‍👦……終わり") layout)
    (dotimes (iteration 24)
      (setq layout (tategaki-typeset-test--check text (1+ (% iteration 5)) 7 layout))
      (should (equal (tategaki-typeset-test--entries layout)
                     (tategaki-typeset-test--entries
                      (tategaki-typeset-layout text (1+ (% iteration 5)) 7))))
      (let ((at (% (* iteration 7) (1+ (length text)))))
        (setq text (concat (substring text 0 at)
                           (nth (% iteration 4) '("゙" "追" "\n" "12")) (substring text at)))))))

(defun tategaki-typeset-benchmark (&optional sizes)
  "Compare literal/full/cached layout for SIZES, without GUI painting.
Return records containing seconds and cache counters.  Call separately from
ERT so machine speed never becomes a correctness assertion."
  (let (results)
    (dolist (size (or sizes '(1000 10000 100000 200000)))
      (dolist (paragraphs '(nil t))
        (let* ((text (if paragraphs
                         (mapconcat (lambda (_) (concat (make-string 99 ?文) "\n"))
                                    (number-sequence 1 (/ size 100)) "")
                       (make-string size ?文)))
               (edited (concat (substring text 0 (/ size 2)) "追" (substring text (/ size 2))))
               (begin (float-time)) baseline initial cached elapsed)
          (tategaki-layout-render text 20)
          (setq baseline (- (float-time) begin) begin (float-time))
          (setq initial (tategaki-typeset-layout text 20 1)
                elapsed (- (float-time) begin) begin (float-time))
          (setq cached (tategaki-typeset-layout edited 20 1 initial))
          (push (list :characters size :paragraphs paragraphs :literal-seconds baseline
                      :typeset-initial-seconds elapsed :typeset-edit-seconds (- (float-time) begin)
                      :cache (plist-get cached :cache-stats)) results))))
    (nreverse results)))

(provide 'tategaki-typeset-test)
;;; tategaki-typeset-test.el ends here
