;;; tategaki-manuscript-test.el --- Paper and writing statistics tests -*- lexical-binding: t; -*-

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
(require 'tategaki-layout)
(require 'tategaki-manuscript)
(require 'outline)

;; Standalone tests do not require the core renderer, but its state variables
;; still need dynamic bindings when exercising the public navigation API.
(defvar tategaki-mode nil)
(defvar tategaki--page-size 1)
(defvar tategaki--layout nil)

(defmacro tategaki-manuscript-test--with-text (text &rest body)
  "Run BODY in a plain-text buffer containing TEXT."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (text-mode)
     (insert ,text)
     (goto-char (point-min))
     (set-buffer-modified-p nil)
     (unwind-protect (progn ,@body)
       (tategaki-manuscript-disable))))

(ert-deftest tategaki-manuscript-presets-are-buffer-local-and-display-only ()
  (let ((default (default-value 'tategaki-manuscript-size)))
    (tategaki-manuscript-test--with-text "原稿の本文"
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (let ((original (buffer-string))
            (tick (buffer-chars-modified-tick)))
        (tategaki-manuscript-set-preset "20x20")
        (should (equal (tategaki-manuscript-config)
                       '(:rows 20 :columns 20 :spread nil :grid nil)))
        (tategaki-manuscript-set-preset "40x30")
        (should (equal tategaki-manuscript-size '(40 . 30)))
        (tategaki-manuscript-set-preset "adaptive")
        (should-not tategaki-manuscript-size)
        (should (equal (buffer-string) original))
        (should (= tick (buffer-chars-modified-tick)))
        (should-not buffer-undo-list)
        (should-not (buffer-modified-p))))
    (should (equal (default-value 'tategaki-manuscript-size) default))))

(ert-deftest tategaki-manuscript-invalid-settings-fail-before-rendering ()
  (tategaki-manuscript-test--with-text "本文"
    (dolist (bad '(0 (0 . 20) (20 . 0) (20 . -1) (20 . "20") (20 20)))
      (let ((tategaki-manuscript-size bad))
        (should-error (tategaki-manuscript-config) :type 'user-error)))
    (should-error (tategaki-manuscript-set-preset "not-a-preset") :type 'user-error)
    (should-error (tategaki-manuscript-set-target -1) :type 'user-error)))

(ert-deftest tategaki-manuscript-spread-and-grid-preserve-paper-dimensions ()
  (tategaki-manuscript-test--with-text "本文"
    (tategaki-manuscript-set-preset '20x20)
    (tategaki-manuscript-toggle-spread)
    (tategaki-manuscript-toggle-grid)
    (should (equal (tategaki-manuscript-config)
                   '(:rows 20 :columns 20 :spread t :grid t)))
    (tategaki-manuscript-toggle-spread -1)
    (tategaki-manuscript-toggle-grid -1)
    (should-not tategaki-manuscript-spread)
    (should-not tategaki-manuscript-grid)
    (should (equal tategaki-manuscript-size '(20 . 20)))))

(ert-deftest tategaki-manuscript-navigation-pages-include-eof-but-content-sheets-do-not ()
  (tategaki-manuscript-test--with-text (make-string 400 ?字)
    (let* ((tategaki-manuscript-size '(20 . 20))
           (layout (tategaki-typeset-layout (buffer-string) 20 1))
           (last (tategaki-manuscript-page-info layout 401)))
      (should (= (plist-get last :current) 2))
      (should (= (plist-get last :total) 2))
      (should (= (plist-get last :content-pages) 1))
      (should (= (plist-get last :columns-per-page) 20))
      (let ((tategaki-manuscript-spread t))
        (should (equal (tategaki-manuscript-page-info layout 401) last))))))

(ert-deftest tategaki-manuscript-empty-source-has-one-editing-page-and-no-filled-sheets ()
  (tategaki-manuscript-test--with-text ""
    (let* ((tategaki-manuscript-size '(20 . 20))
           (layout (tategaki-layout-render "" 20))
           (info (tategaki-manuscript-page-info layout 1))
           (stats (tategaki-manuscript-statistics layout)))
      (should (= (plist-get info :current) 1))
      (should (= (plist-get info :total) 1))
      (should (= (plist-get info :content-pages) 0))
      (should (= (plist-get stats :characters) 0))
      (should (= (plist-get stats :manuscript-pages) 0))
      (should (= (plist-get stats :layout-pages) 0)))))

(ert-deftest tategaki-manuscript-typeset-content-pages-ignore-an-eof-only-page ()
  (tategaki-manuscript-test--with-text (make-string 400 ?字)
    (let* ((tategaki-manuscript-size '(20 . 20))
           (layout (tategaki-typeset-layout (buffer-string) 20 1))
           (info (tategaki-manuscript-page-info layout (point-max))))
      (should (= (plist-get info :total) 2))
      (should (= (plist-get info :current) 2))
      (should (= (plist-get info :content-pages) 1)))))

(ert-deftest tategaki-manuscript-adaptive-page-count-uses-window-capacity ()
  (tategaki-manuscript-test--with-text (make-string 40 ?字)
    (let* ((tategaki-manuscript-size nil)
           (tategaki--page-size 5)
           (layout (tategaki-layout-render (buffer-string) 4)))
      (should (= (plist-get (tategaki-manuscript-page-info layout 22) :current) 2))
      (should (= (plist-get (tategaki-manuscript-page-info layout 22) :total) 3))
      (should (= (plist-get (tategaki-manuscript-page-info layout 22 10) :total) 2)))))

(ert-deftest tategaki-manuscript-literal-fallback-keeps-settings-but-uses-screen-pages ()
  (tategaki-manuscript-test--with-text (make-string 40 ?字)
    (let* ((tategaki-manuscript-size '(20 . 20))
           (tategaki--page-size 5)
           (layout (tategaki-layout-render (buffer-string) 4))
           (info (tategaki-manuscript-page-info layout 22)))
      (should (= (plist-get info :columns-per-page) 5))
      (should (= (plist-get info :current) 2))
      (should (= (plist-get info :total) 3))
      (should (equal tategaki-manuscript-size '(20 . 20))))))

(ert-deftest tategaki-manuscript-page-navigation-uses-source-mapping ()
  (tategaki-manuscript-test--with-text (make-string 25 ?字)
    (let ((tategaki-mode t)
          (tategaki-manuscript-size '(3 . 2))
          (tategaki--page-size 2)
          (tategaki--layout (tategaki-layout-render (buffer-string) 3))
          (refreshes 0))
      (cl-letf (((symbol-function 'tategaki-refresh)
                 (lambda () (cl-incf refreshes)))
                ((symbol-function 'tategaki--source-position) #'identity))
        (tategaki-goto-page 3)
        (should (= (point) 13))
        (should (= refreshes 2))
        (should-error (tategaki-goto-page 0) :type 'user-error)
        (should-error (tategaki-goto-page 6) :type 'user-error)
        (should (= (point) 13))
        ;; Layout position 13 maps back to source 10 after virtual preedit.
        (cl-letf (((symbol-function 'tategaki--source-position)
                   (lambda (position) (- position 3))))
          (tategaki-goto-page 3)
          (should (= (point) 10)))))))

(ert-deftest tategaki-manuscript-typeset-page-navigation-skips-ruby-notation ()
  (tategaki-manuscript-test--with-text "甲乙｜青空《あおぞら》丙丁戊己庚辛"
    (let ((tategaki-mode t)
          (tategaki-manuscript-size '(2 . 2))
          (tategaki--layout (tategaki-typeset-layout (buffer-string) 2 1)))
      (cl-letf (((symbol-function 'tategaki-refresh) #'ignore)
                ((symbol-function 'tategaki--source-position) #'identity))
        (tategaki-goto-page 2)
        (should (eq (char-after) ?丙))
        (should (= (point) 12))))))

(ert-deftest tategaki-manuscript-whitespace-and-newlines-have-separate-counting-rules ()
  (tategaki-manuscript-test--with-text ""
    (let ((text "甲 乙\t丙　丁\n"))
      (should (= (tategaki-manuscript-count-text text) 7))
      (let ((tategaki-manuscript-count-whitespace nil))
        (should (= (tategaki-manuscript-count-text text) 4))
        (let ((tategaki-manuscript-count-newlines t))
          (should (= (tategaki-manuscript-count-text text) 5))))
      (let ((tategaki-manuscript-count-newlines t))
        (should (= (tategaki-manuscript-count-text text) 8))))))

(ert-deftest tategaki-manuscript-counts-typeset-body-and-optionally-raw-markup ()
  (tategaki-manuscript-test--with-text ""
    (dolist (text '("｜青空《あおぞら》へ" "|青空《あおぞら》へ" "青空《あおぞら》へ"
                    "［＃傍点］青空［＃傍点終わり］へ"
                    "青空［＃「青空」に傍点］へ"
                    "［＃傍線］青空［＃傍線終わり］へ"))
      (should (= (tategaki-manuscript-count-text text) 3))
      (let ((tategaki-manuscript-count-markup t))
        (should (= (tategaki-manuscript-count-text text) (length text)))))
    (should (= (tategaki-manuscript-count-text
                "［＃縦中横］12［＃縦中横終わり］年") 3))
    (let ((text "｜青空《未完成"))
      (should (= (tategaki-manuscript-count-text text) (length text))))))

(ert-deftest tategaki-manuscript-malformed-and-unsupported-annotations-stay-in-counts ()
  (tategaki-manuscript-test--with-text ""
    (dolist (text '("｜青空《未完成" "｜《よみ》" "｜青空《》"
                    "［＃傍点］未完成" "［＃斜体］本文［＃斜体終わり］"
                    "別文［＃「本文」に傍点］"
                    "［＃縦中横］123456789［＃縦中横終わり］"))
      (should (= (tategaki-manuscript-count-text text) (length text))))))

(ert-deftest tategaki-manuscript-markdown-and-japanese-chapters-follow-point ()
  (tategaki-manuscript-test--with-text "前文\n# 一章\n甲乙\n第2章 続き\n丙\n"
    (let ((preamble (tategaki-manuscript-statistics)))
      (should (equal (plist-get preamble :chapter-title) "前文"))
      (should (= (plist-get preamble :chapter) 2)))
    (search-forward "甲")
    (let ((chapter (tategaki-manuscript-statistics)))
      (should (equal (plist-get chapter :chapter-title) "# 一章"))
      (should (= (plist-get chapter :chapter) 6)))
    (goto-char (point-max))
    (let ((chapter (tategaki-manuscript-statistics)))
      (should (equal (plist-get chapter :chapter-title) "第2章 続き"))
      (should (= (plist-get chapter :chapter) 7)))))

(ert-deftest tategaki-manuscript-org-outline-and-explicit-chapter-detection ()
  (tategaki-manuscript-test--with-text "* 第一章\n甲\n** 第二節\n乙丙\n"
    (setq major-mode 'org-mode)
    (search-forward "甲")
    (should (equal (plist-get (tategaki-manuscript-statistics) :chapter-title)
                   "* 第一章"))
    (goto-char (point-max))
    (should (equal (plist-get (tategaki-manuscript-statistics) :chapter-title)
                   "** 第二節"))
    (let ((tategaki-manuscript-chapter-regexp 'outline)
          (outline-regexp "^\\* "))
      (should (equal (plist-get (tategaki-manuscript-statistics) :chapter-title)
                     "* 第一章")))
    (let ((tategaki-manuscript-chapter-regexp "^\\*\\* "))
      (should (equal (plist-get (tategaki-manuscript-statistics) :chapter-title)
                     "** 第二節")))
    (let ((tategaki-manuscript-chapter-regexp nil))
      (should-not (plist-get (tategaki-manuscript-statistics) :chapter)))))

(ert-deftest tategaki-manuscript-statistics-cache-avoids-full-scans-during-motion ()
  (tategaki-manuscript-test--with-text "# 一章\n甲乙\n# 二章\n丙丁\n"
    (let ((count-function (symbol-function 'tategaki-manuscript-count-text))
          (calls 0))
      (cl-letf (((symbol-function 'tategaki-manuscript-count-text)
                 (lambda (text) (cl-incf calls) (funcall count-function text))))
        (tategaki-manuscript-enable)
        (tategaki-manuscript-statistics)
        (let ((initial calls))
          (dotimes (offset (buffer-size))
            (goto-char (1+ offset))
            (tategaki-manuscript-statistics))
          (should (= calls initial))
          (setq tategaki-manuscript-target-characters 100)
          (let ((stats (tategaki-manuscript-statistics)))
            (should (= (plist-get stats :remaining)
                       (- 100 (plist-get stats :characters)))))
          (should (= calls initial))
          (goto-char (point-max))
          (insert "追")
          (tategaki-manuscript-statistics)
          (should (> calls initial)))))))

(ert-deftest tategaki-manuscript-selection-is-counted-only-while-active-and-cached ()
  (tategaki-manuscript-test--with-text "甲乙丙丁"
    (let ((transient-mark-mode t)
          (count-function (symbol-function 'tategaki-manuscript-count-text))
          (calls 0))
      (cl-letf (((symbol-function 'tategaki-manuscript-count-text)
                 (lambda (text) (cl-incf calls) (funcall count-function text))))
        (tategaki-manuscript-statistics)
        (should (= calls 1))
        (set-mark 1)
        (goto-char 3)
        (setq mark-active t)
        (should (= (plist-get (tategaki-manuscript-statistics) :selection) 2))
        (dotimes (_ 5) (tategaki-manuscript-statistics))
        (should (= calls 2))
        (goto-char 4)
        (should (= (plist-get (tategaki-manuscript-statistics) :selection) 3))
        (should (= calls 3))
        (setq mark-active nil)
        (should-not (plist-get (tategaki-manuscript-statistics) :selection))
        (should (= calls 3))))))

(ert-deftest tategaki-manuscript-selection-strips-only-completely-selected-annotations ()
  (tategaki-manuscript-test--with-text "前｜青空《あおぞら》後"
    (let ((transient-mark-mode t))
      ;; Whole annotation: count the two base characters.
      (set-mark 2)
      (goto-char 11)
      (setq mark-active t)
      (should (= (plist-get (tategaki-manuscript-statistics) :selection) 2))
      ;; This suffix resembles standalone implicit ruby, but it cuts a larger
      ;; explicit annotation.  Keep its seven original characters in the count.
      (set-mark 4)
      (should (= (plist-get (tategaki-manuscript-statistics) :selection) 7))
      (set-mark 2)
      (goto-char 7)
      (should (= (plist-get (tategaki-manuscript-statistics) :selection) 5))
      (set-mark 6)
      (goto-char 10)
      (should (= (plist-get (tategaki-manuscript-statistics) :selection) 4))
      (should (= (plist-get (tategaki-manuscript-statistics) :characters) 4)))))

(ert-deftest tategaki-manuscript-partial-selection-finds-context-outside-narrowing ()
  (tategaki-manuscript-test--with-text "前｜青空《あおぞら》後"
    (let ((transient-mark-mode t))
      (narrow-to-region 4 11)
      (set-mark (point-min))
      (goto-char (point-max))
      (setq mark-active t)
      (should (= (plist-get (tategaki-manuscript-statistics) :selection) 7))
      (should (= (point-min) 4))
      (should (= (point-max) 11))
      (should (= (point) 11)))))

(ert-deftest tategaki-manuscript-count-options-invalidate-cache-without-source-edits ()
  (tategaki-manuscript-test--with-text "｜青空《あおぞら》 へ\n"
    (let ((tick (buffer-chars-modified-tick)))
      (should (= (plist-get (tategaki-manuscript-statistics) :characters) 4))
      (setq tategaki-manuscript-count-whitespace nil)
      (should (= (plist-get (tategaki-manuscript-statistics) :characters) 3))
      (setq tategaki-manuscript-count-newlines t)
      (should (= (plist-get (tategaki-manuscript-statistics) :characters) 4))
      (setq tategaki-manuscript-count-markup t)
      (should (= (plist-get (tategaki-manuscript-statistics) :characters)
                 (1- (buffer-size))))
      (should (= tick (buffer-chars-modified-tick))))))

(ert-deftest tategaki-manuscript-statistics-preserve-active-search-match-data ()
  (tategaki-manuscript-test--with-text "# 章\n｜青空《あおぞら》\n"
    (string-match "a\\(b\\)" "ab")
    (let ((search-match (match-data)))
      (tategaki-manuscript-enable)
      (tategaki-manuscript-mode-line)
      (should (equal (match-data) search-match))
      (tategaki-manuscript-count-text "｜青空《あおぞら》")
      (should (equal (match-data) search-match)))))

(ert-deftest tategaki-manuscript-full-count-respects-source-and-preserves-narrowing ()
  (tategaki-manuscript-test--with-text "前文\n# 章\n本文\n後文"
    (put-text-property 1 3 'face 'bold)
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (set-buffer-modified-p nil)
    (let ((original (buffer-string))
          (tick (buffer-chars-modified-tick)))
      (narrow-to-region 8 10)
      (goto-char 9)
      (tategaki-manuscript-enable)
      (let ((stats (tategaki-manuscript-statistics)))
        (should (= (plist-get stats :characters) 9)))
      (should (= (point-min) 8))
      (should (= (point-max) 10))
      (should (= (point) 9))
      (tategaki-manuscript-disable)
      (widen)
      (should (equal-including-properties (buffer-string) original))
      (should (= (buffer-chars-modified-tick) tick))
      (should-not buffer-undo-list)
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-manuscript-400-character-equivalents-differ-from-layout-pages ()
  (tategaki-manuscript-test--with-text (concat (make-string 399 ?字) "\n字")
    (let* ((tategaki-manuscript-size '(40 . 30))
           (layout (tategaki-typeset-layout (buffer-string) 40 1))
           (stats (tategaki-manuscript-statistics layout)))
      (should (= (plist-get stats :characters) 400))
      (should (= (plist-get stats :manuscript-pages) 1))
      (should (= (plist-get stats :layout-pages) 1))
      (insert "字")
      (setq stats (tategaki-manuscript-statistics layout))
      (should (= (plist-get stats :manuscript-pages) 2))
      (should (= (plist-get stats :layout-pages) 1)))))

(ert-deftest tategaki-manuscript-goal-updates-immediately-and-clamps-at-zero ()
  (tategaki-manuscript-test--with-text "五文字本文"
    (tategaki-manuscript-set-target 10)
    (should (= (plist-get (tategaki-manuscript-statistics) :remaining) 5))
    (setq tategaki-manuscript-target-characters 3)
    (should (= (plist-get (tategaki-manuscript-statistics) :remaining) 0))
    (tategaki-manuscript-set-target 0)
    (should-not (plist-get (tategaki-manuscript-statistics) :remaining))))

(ert-deftest tategaki-manuscript-mode-line-restores-inherited-and-local-values ()
  (dolist (local '(nil t))
    (tategaki-manuscript-test--with-text "本文"
      (if local (setq-local mode-line-format '("MY MODE LINE"))
        (kill-local-variable 'mode-line-format))
      (let ((original mode-line-format)
            (binding (local-variable-p 'mode-line-format))
            (default (default-value 'mode-line-format)))
        (tategaki-manuscript-enable)
        (tategaki-manuscript-enable)
        (should (local-variable-p 'mode-line-format))
        (should (string-match-p "2字" (tategaki-manuscript-mode-line)))
        (should (equal default (default-value 'mode-line-format)))
        (setq tategaki-manuscript-status nil)
        (should-not (tategaki-manuscript-mode-line))
        (tategaki-manuscript-disable)
        (should (eq (local-variable-p 'mode-line-format) binding))
        (should (equal mode-line-format original))
        (should-not (memq #'tategaki-manuscript--invalidate after-change-functions))))))

(ert-deftest tategaki-manuscript-hidden-mode-line-stays-hidden ()
  (tategaki-manuscript-test--with-text "本文"
    (setq-local mode-line-format nil)
    (tategaki-manuscript-enable)
    (should-not mode-line-format)
    (tategaki-manuscript-disable)
    (should-not mode-line-format)
    (should (local-variable-p 'mode-line-format))))

(ert-deftest tategaki-manuscript-mode-line-prioritizes-stats-after-buffer-name ()
  (tategaki-manuscript-test--with-text "本文"
    (let* ((original '("%e" mode-line-front-space mode-line-client
                       mode-line-buffer-identification "   " mode-line-position
                       mode-line-modes mode-line-misc-info mode-line-end-spaces))
           (snapshot (copy-tree original))
           (status '(:eval (tategaki-manuscript-mode-line))))
      (setq-local mode-line-format original)
      (tategaki-manuscript-enable)
      (let ((after-name (cdr (memq 'mode-line-buffer-identification mode-line-format))))
        (should (equal (car after-name) status))
        (should (equal (cdr after-name)
                       (cdr (memq 'mode-line-buffer-identification original)))))
      (should (equal original snapshot))
      (should (= (cl-count status mode-line-format :test #'equal) 1))
      (tategaki-manuscript-disable)
      (should (eq mode-line-format original)))))

(ert-deftest tategaki-manuscript-custom-mode-line-is-preserved-behind-priority-stats ()
  (dolist (original '("Custom mode line %b" (:eval "custom generated mode line")
                     ("Legacy name " "%b" " many modes")))
    (tategaki-manuscript-test--with-text "本文"
      (setq-local mode-line-format original)
      (let ((snapshot (copy-tree original)))
        (tategaki-manuscript-enable)
        (should (equal (car mode-line-format)
                       '(:eval (tategaki-manuscript-mode-line))))
        (should (eq (nth 2 mode-line-format) original))
        (should (equal original snapshot))
        (tategaki-manuscript-disable)
        (should (eq mode-line-format original))))))

(ert-deftest tategaki-manuscript-optional-counts-do-not-push-page-and-goal-fields-back ()
  (tategaki-manuscript-test--with-text "本文"
    (tategaki-manuscript-enable)
    (cl-letf (((symbol-function 'tategaki-manuscript-statistics)
               (lambda (&optional _)
                 '(:current-page 1 :total-pages 8 :characters 2500
                   :manuscript-pages 7 :layout-pages 8 :remaining 1500
                   :selection 1200 :chapter 1800))))
      (should (equal (substring-no-properties (tategaki-manuscript-mode-line))
                     " 1/8頁 2500字 400字7枚 配8枚 残1500 選1200 章1800")))))

(defun tategaki-manuscript-benchmark (&optional size annotated)
  "Measure statistics alone for SIZE characters, optionally ANNOTATED.
ANNOTATED inserts one explicit ruby per 1000 source characters.  Return
first count, count after inserting one body character, and 1000 cached
mode-line evaluations in seconds.  This does not measure GUI redisplay."
  (let* ((size (or size 100000))
         (block (concat (make-string 991 ?文) "｜青空《あおぞら》"))
         (text (if annotated
                   (substring (apply #'concat (make-list (ceiling size 1000) block))
                              0 size)
                 (make-string size ?文))))
    (with-temp-buffer
      (text-mode)
      (insert text)
      (tategaki-manuscript-enable)
      (unwind-protect
          (let ((begin (float-time)) first edit)
            (tategaki-manuscript-statistics)
            (setq first (- (float-time) begin))
            ;; Beginning of a block is ordinary body text, not a ruby reading.
            (goto-char (1+ (* 1000 (/ size 2000))))
            (insert "追")
            (setq begin (float-time))
            (tategaki-manuscript-statistics)
            (setq edit (- (float-time) begin) begin (float-time))
            (dotimes (_ 1000) (tategaki-manuscript-mode-line))
            (list :source-characters size :annotated (and annotated t)
                  :first-seconds first :edit-seconds edit
                  :cached-mode-line-1000-seconds (- (float-time) begin)
                  :body-count-after-edit
                  (plist-get (tategaki-manuscript-statistics) :characters)))
        (tategaki-manuscript-disable)))))

(provide 'tategaki-manuscript-test)
;;; tategaki-manuscript-test.el ends here
