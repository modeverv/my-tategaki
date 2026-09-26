;;; tategaki-export-model-test.el --- Export snapshot tests -*- lexical-binding: t; -*-

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
(require 'tategaki-export-model)

(defconst tategaki-export-test--fixtures
  (expand-file-name "fixtures" (file-name-directory (or load-file-name buffer-file-name))))

(defun tategaki-export-test--body (model)
  (alist-get 'body_text (alist-get 'expectations model)))

(ert-deftest tategaki-export-model-shared-annotations ()
  (let* ((source "｜長い親文字《ながいおやもじ》と漢字《かんじ》。\n［＃傍点］強調［＃傍点終わり］、傍線［＃「傍線」に傍線］。\n［＃縦中横］12［＃縦中横終わり］\n")
         (model (tategaki-export-model-create source))
         (expect (alist-get 'expectations model)))
    (should (equal (tategaki-export-test--body model)
                   "長い親文字と漢字。\n強調、傍線。\n12\n"))
    (should (equal (tategaki-export-test--body model) (tategaki-typeset-plain-text source)))
    (should (equal (alist-get 'ruby_readings expect) ["ながいおやもじ" "かんじ"]))
    (should (equal (alist-get 'annotation_counts expect) '((ruby . 2) (tcy . 1) (dot . 1) (line . 1))))
    (should (= (length (alist-get 'diagnostics model)) 0))))

(ert-deftest tategaki-export-model-graphemes-and-punctuation-unchanged ()
  (let* ((source "が葛󠄀👩‍💻、。ーー……\r\n\n末尾\n")
         (model (tategaki-export-model-create source)))
    (should (equal source (tategaki-export-test--body model)))
    (should (= (length (alist-get 'blocks model)) 4))
    (should (equal (alist-get 'sha256 (alist-get 'source model))
                   (secure-hash 'sha256 (encode-coding-string source 'utf-8-unix t))))))

(ert-deftest tategaki-export-model-preserves-unknown-and-incomplete ()
  (dolist (source '("［＃未対応］本文" "｜親文字《よみ" "［＃傍点］未完" "文字《》"))
    (let ((model (tategaki-export-model-create source)))
      (should (equal source (tategaki-export-test--body model)))
      (should (> (length (alist-get 'diagnostics model)) 0))
      (should (equal (alist-get 'severity (aref (alist-get 'diagnostics model) 0)) "error")))))

(ert-deftest tategaki-export-model-heading-interpretation-is-explicit ()
  (let* ((source "# 一章 $x$ <html>\n本文\n## 二章\n")
         (plain (tategaki-export-model-create source))
         (structured (tategaki-export-model-create source nil '((input . ((headings . "markdown")))))))
    (should (equal source (tategaki-export-test--body plain)))
    (should (= 0 (length (alist-get 'chapters (alist-get 'expectations plain)))))
    (should (equal "一章 $x$ <html>\n本文\n二章\n" (tategaki-export-test--body structured)))
    (should (equal (mapcar (lambda (chapter) (alist-get 'title chapter))
                          (append (alist-get 'chapters (alist-get 'expectations structured)) nil))
                   '("一章 $x$ <html>" "二章")))))

(ert-deftest tategaki-export-model-annotation-display-settings-ignored ()
  (let ((tategaki-typeset-annotation-display 'raw)
        (tategaki-layout-use-vertical-forms t))
    (should (equal (tategaki-export-test--body (tategaki-export-model-create "｜母《はは》ー。")) "母ー。"))))

(ert-deftest tategaki-export-model-snapshot-preserves-editor-state ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "冒頭\n｜漢字《かんじ》\n末尾\n")
    (put-text-property 1 3 'display "表示差し替え")
    (let ((overlay (make-overlay 4 4)))
      (overlay-put overlay 'before-string "IME未確定")
      (overlay-put overlay 'after-string "CopilotGhost"))
    (goto-char 5) (set-mark 10) (setq mark-active t)
    (narrow-to-region 4 13)
    (let ((point-before (point)) (mark-before (mark)) (min-before (point-min))
          (max-before (point-max)) (undo-before buffer-undo-list)
          (modified-before (buffer-modified-p))
          (snapshot (tategaki-export-model-snapshot)))
      (should (equal (plist-get snapshot :text) "冒頭\n｜漢字《かんじ》\n末尾\n"))
      (should (equal (tategaki-export-test--body (plist-get snapshot :model)) "冒頭\n漢字\n末尾\n"))
      (should (= point-before (point))) (should (= mark-before (mark)))
      (should (= min-before (point-min))) (should (= max-before (point-max)))
      (should (eq undo-before buffer-undo-list))
      (should (eq modified-before (buffer-modified-p))))))

(ert-deftest tategaki-export-model-explicit-narrowed-range ()
  (with-temp-buffer
    (insert "前\n｜漢字《かんじ》\n後")
    (narrow-to-region 3 12)
    (let* ((snapshot (tategaki-export-model-snapshot 'narrowed))
           (model (plist-get snapshot :model)))
      (should (equal (plist-get snapshot :text) "｜漢字《かんじ》\n"))
      (should (equal (tategaki-export-test--body model) "漢字\n"))
      (should (= 2 (alist-get 'range_start (alist-get 'source model))))
      (should (= 0 (alist-get 'start (aref (alist-get 'blocks model) 0)))))))

(ert-deftest tategaki-export-model-cut-ruby-remains-literal ()
  (with-temp-buffer
    (insert "｜親漢字《よみ》")
    (narrow-to-region 3 (point-max))
    (let ((model (plist-get (tategaki-export-model-snapshot 'narrowed) :model)))
      (should (equal (tategaki-export-test--body model) "漢字《よみ》"))
      (should (equal (alist-get 'ruby_readings (alist-get 'expectations model)) []))
      (should (= (alist-get 'ruby (alist-get 'annotation_counts (alist-get 'expectations model))) 0))
      (should (equal (alist-get 'code (aref (alist-get 'diagnostics model) 0)) "cut_annotation")))))

(ert-deftest tategaki-export-model-cut-inside-reading-is-diagnosed ()
  (with-temp-buffer
    (insert "｜漢字《かんじ》")
    (narrow-to-region 5 7)
    (let* ((snapshot (tategaki-export-model-snapshot 'narrowed)) (model (plist-get snapshot :model)))
      (should (equal "かん" (tategaki-export-test--body model)))
      (should (equal "cut_annotation" (alist-get 'code (aref (alist-get 'diagnostics model) 0)))))))

(ert-deftest tategaki-export-model-cut-outer-emphasis-keeps-inner-ruby-literal ()
  (with-temp-buffer
    (insert "［＃傍点］｜漢字《かんじ》［＃傍点終わり］")
    (narrow-to-region 6 14)
    (let* ((snapshot (tategaki-export-model-snapshot 'narrowed)) (model (plist-get snapshot :model)))
      (should (equal (plist-get snapshot :text) (tategaki-export-test--body model)))
      (should (equal [] (alist-get 'ruby_readings (alist-get 'expectations model))))
      (should (equal "cut_annotation" (alist-get 'code (aref (alist-get 'diagnostics model) 0)))))))

(ert-deftest tategaki-export-model-diagnostic-offset-inside-emphasis ()
  (let* ((source "［＃傍点］本文［＃未対応］［＃傍点終わり］")
         (model (tategaki-export-model-create source))
         (diagnostic (aref (alist-get 'diagnostics model) 0)))
    (should (equal "［＃未対応］" (substring source (alist-get 'start diagnostic) (alist-get 'end diagnostic))))))

(ert-deftest tategaki-export-model-json-roundtrip-and-invalid-heading ()
  (let* ((model (tategaki-export-model-create "\f\n"))
         (json-object-type 'alist) (json-key-type 'symbol)
         (decoded (json-read-from-string (json-encode model))))
    (should (equal "page_break" (alist-get 'type (aref (alist-get 'blocks decoded) 0)))))
  (should-error (tategaki-export-model-create "本文" nil '((input . ((headings . "automatic")))))))

(ert-deftest tategaki-export-model-independent-representative-expectations ()
  (let* ((json-object-type 'alist) (json-key-type 'symbol)
         (expected (json-read-file (expand-file-name "representative-expected.json" tategaki-export-test--fixtures)))
         (text (with-temp-buffer
                 (insert-file-contents (expand-file-name "representative.txt" tategaki-export-test--fixtures))
                 (buffer-string)))
         (model (tategaki-export-model-create text nil `((input . ,(alist-get 'input expected)))))
         (actual (alist-get 'expectations model)))
    (should (equal (alist-get 'body_text actual) (alist-get 'body_text expected)))
    (should (equal (alist-get 'ruby_readings actual) (alist-get 'ruby_readings expected)))
    (should (equal (mapcar (lambda (chapter) (list (alist-get 'title chapter) (alist-get 'level chapter)))
                          (append (alist-get 'chapters actual) nil))
                   (mapcar (lambda (chapter) (list (alist-get 'title chapter) (alist-get 'level chapter)))
                           (append (alist-get 'chapters expected) nil))))
    (should (equal (alist-get 'annotation_counts actual) (alist-get 'semantic_annotation_counts expected)))
    (should (equal [] (alist-get 'diagnostics model)))))

(ert-deftest tategaki-export-model-batch-preserves-bom-crlf-and-source-hash ()
  (let* ((dir (make-temp-file "tategaki-export-batch-" t))
         (source (expand-file-name "source.txt" dir))
         (output (expand-file-name "document.json" dir))
         (text "﻿｜本文《ほんぶん》\r\n\r\n末尾\r\n")
         (bytes (encode-coding-string text 'utf-8-unix))
         (json-object-type 'alist) (json-key-type 'symbol))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion)) (write-region bytes nil source nil 'silent))
          (let ((command-line-args-left (list source output))) (tategaki-export-model-batch))
          (let ((model (json-read-file output)))
            (should (equal (alist-get 'sha256 (alist-get 'source model)) (secure-hash 'sha256 bytes)))
            (should (equal (tategaki-export-test--body model) "﻿本文\r\n\r\n末尾\r\n"))))
      (delete-directory dir t))))

(ert-deftest tategaki-export-model-batch-rejects-invalid-utf8 ()
  (let* ((dir (make-temp-file "tategaki-export-invalid-" t))
         (source (expand-file-name "source.txt" dir))
         (output (expand-file-name "document.json" dir)))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (write-region (unibyte-string 255 254 200) nil source nil 'silent))
          (let ((command-line-args-left (list source output)))
            (should-error (tategaki-export-model-batch))))
      (delete-directory dir t))))

(provide 'tategaki-export-model-test)
