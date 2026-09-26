;;; tategaki-script-test.el --- Dedicated script mode tests -*- lexical-binding: t; -*-

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
(require 'tategaki-script)

(defmacro tategaki-script-test--with-buffer (&rest body)
  "Run BODY in an isolated horizontal script buffer."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (let ((tategaki-script-start-vertical nil)
           (tategaki-writing-auto-indent t)
           (tategaki-writing-electric-pair t)
           (tategaki-script-speaker-indent 0)
           (tategaki-script-dialogue-indent 2)
           (tategaki-script-stage-direction-indent 1))
       (unwind-protect
           (progn (tategaki-script-mode) ,@body)
         (text-mode)))))

(defun tategaki-script-test--face-at (text)
  "Return the native source face on the first occurrence of TEXT."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (let ((position (- (point) (length text))))
      (or (get-text-property position 'face)
          (get-text-property position 'font-lock-face)))))

(ert-deftest tategaki-script-mode-is-local-and-can-start-horizontal ()
  (let ((style (default-value 'tategaki-writing-style))
        (pairs (copy-tree (default-value 'electric-pair-pairs)))
        (associations (copy-tree auto-mode-alist)))
    (tategaki-script-test--with-buffer
      (should (derived-mode-p 'tategaki-script-mode 'text-mode))
      (should-not (bound-and-true-p tategaki-mode))
      (should tategaki-writing-mode)
      (should electric-pair-mode)
      (should (eq tategaki-writing-style 'script))
      (should (local-variable-p 'tategaki-writing-style)))
    (should (equal style (default-value 'tategaki-writing-style)))
    (should (equal pairs (default-value 'electric-pair-pairs)))
    (should (equal associations auto-mode-alist))))

(ert-deftest tategaki-script-mode-entry-preserves-document-state ()
  (with-temp-buffer
    (insert "前書き\n○ 居間・朝\n太郎：\n　　「声」\n後書き")
    (buffer-enable-undo)
    (goto-char (point-max))
    (insert "。")
    (narrow-to-region 5 (- (point-max) 3))
    (goto-char 10)
    (set-buffer-modified-p nil)
    (let ((tategaki-script-start-vertical nil)
          (text (buffer-string))
          (position (point))
          (minimum (point-min))
          (maximum (point-max))
          (tick (buffer-chars-modified-tick))
          (undo buffer-undo-list))
      (tategaki-script-mode)
      (should (equal text (buffer-string)))
      (should (= position (point)))
      (should (= minimum (point-min)))
      (should (= maximum (point-max)))
      (should (= tick (buffer-chars-modified-tick)))
      (should (eq undo buffer-undo-list))
      (should-not (buffer-modified-p))
      (text-mode)
      (should (equal text (buffer-string)))
      (should (= position (point)))
      (should (eq undo buffer-undo-list))
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-script-mode-exit-cleans-up-writing-and-local-hooks ()
  (tategaki-script-test--with-buffer
    (text-mode)
    (should-not tategaki-writing-mode)
    (should-not (bound-and-true-p tategaki-mode))
    (should-not (memq #'tategaki-writing--after-change after-change-functions))
    (should-not (memq #'tategaki-writing--finish-input post-self-insert-hook))
    (should-not (memq #'tategaki-script-completion-at-point
                      completion-at-point-functions))
    (should-not (eq (key-binding (kbd "RET")) #'tategaki-script-newline))))

(ert-deftest tategaki-script-mode-effective-keys-use-script-commands ()
  (tategaki-script-test--with-buffer
    (dolist (entry '(("RET" . tategaki-script-newline)
                     ("TAB" . tategaki-script-indent-line)
                     ("C-c C-d" . tategaki-script-dialogue)
                     ("C-c C-t" . tategaki-script-stage-direction)
                     ("C-c C-s" . tategaki-script-scene)
                     ("C-c C-f" . tategaki-script-format)
                     ("C-c C-o" . tategaki-outline)
                     ("M-n" . tategaki-script-next-scene)
                     ("M-p" . tategaki-script-previous-scene)))
      (should (eq (key-binding (kbd (car entry))) (cdr entry))))))

(ert-deftest tategaki-script-speaker-ret-starts-paired-dialogue ()
  (tategaki-script-test--with-buffer
    (insert "太郎：")
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (tategaki-script-newline 1)
    (should (equal (buffer-string) "太郎：\n　　「」"))
    (should (eq (char-after) ?」))
    (undo-boundary)
    (undo-only 1)
    (should (equal (buffer-string) "太郎："))))

(ert-deftest tategaki-script-ret-in-middle-does-not-create-extra-dialogue ()
  (tategaki-script-test--with-buffer
    (insert "太郎：")
    (goto-char 2)
    (tategaki-script-newline 1)
    (should-not (string-match-p "「" (buffer-string)))
    (should (string-match-p "太\n" (buffer-string)))))

(ert-deftest tategaki-script-ordinary-ret-and-auto-indent-opt-out ()
  (tategaki-script-test--with-buffer
    (insert "　　「声」")
    (tategaki-script-newline 1)
    (should (equal (buffer-string) "　　「声」\n　　"))
    (setq-local tategaki-writing-auto-indent nil)
    (insert "次郎：")
    (tategaki-script-newline 1)
    (should (string-suffix-p "次郎：\n" (buffer-string)))))

(ert-deftest tategaki-script-indent-and-format-cover-scenes-and-role-lines ()
  (tategaki-script-test--with-buffer
    (insert "　○ 居間\n 太郎：\n「声」\n　　（退場）\n\n　◎ 廊下")
    (tategaki-script-format (point-min) (point-max))
    (should (equal (buffer-string)
                   "○ 居間\n太郎：\n　　「声」\n　（退場）\n\n◎ 廊下"))
    (let ((original (buffer-string)))
      (tategaki-script-format (point-min) (point-max))
      (should (equal original (buffer-string))))))

(ert-deftest tategaki-script-format-respects-configured-role-indents ()
  (tategaki-script-test--with-buffer
    (setq-local tategaki-script-speaker-indent 1
                tategaki-script-dialogue-indent 3
                tategaki-script-stage-direction-indent 2)
    (insert "○ 居間\n太郎：\n「声」\n（退場）")
    (tategaki-script-format)
    (should (equal (buffer-string)
                   "○ 居間\n　太郎：\n　　　「声」\n　　（退場）"))))

(ert-deftest tategaki-script-format-preserves-outside-selection-and-undo ()
  (tategaki-script-test--with-buffer
    (insert "冒頭\n 太郎：\n「声」\n末尾")
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (let ((original (buffer-string)))
      (tategaki-script-format 4 13)
      (should (string-prefix-p "冒頭\n太郎：\n　　「声」\n" (buffer-string)))
      (should (string-suffix-p "末尾" (buffer-string)))
      (undo-boundary)
      (undo-only 1)
      (should (equal original (buffer-string))))))

(ert-deftest tategaki-script-scene-insertion-is-editable-and-undoable ()
  (tategaki-script-test--with-buffer
    (insert "　　「声」")
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (tategaki-script-scene "居間・朝")
    (should (equal (buffer-string) "　　「声」\n○ 居間・朝\n"))
    (undo-boundary)
    (undo-only 1)
    (should (equal (buffer-string) "　　「声」"))))

(ert-deftest tategaki-script-scene-rejects-multiline-title-before-editing ()
  (tategaki-script-test--with-buffer
    (insert "本文")
    (should-error (tategaki-script-scene "居間\n次の場") :type 'user-error)
    (should (equal (buffer-string) "本文"))))

(ert-deftest tategaki-script-dialogue-wrapper-and-speaker-list-stay-in-sync ()
  (tategaki-script-test--with-buffer
    (tategaki-script-dialogue "太郎")
    (insert "声")
    (tategaki-script-dialogue "花子")
    (insert "返事")
    (tategaki-script-dialogue "太郎")
    (should (equal (tategaki-script-speakers) '("太郎" "花子")))
    (should (eq (char-after) ?」))
    (tategaki-script-stage-direction "退場")
    (should (string-suffix-p "\n　（退場）" (buffer-string)))))

(ert-deftest tategaki-script-speaker-list-observes-edits-and-buffer-scope ()
  (tategaki-script-test--with-buffer
    (insert "太郎：\n「声」\n花子:\n太郎：\n○ 朝：\n")
    (should (equal (tategaki-script-speakers) '("太郎" "花子")))
    (goto-char (point-min))
    (delete-region 1 3)
    (insert "次郎")
    (should (equal (tategaki-script-speakers) '("次郎" "花子" "太郎")))
    (with-temp-buffer
      (let ((tategaki-script-start-vertical nil))
        (tategaki-script-mode)
        (should-not (tategaki-script-speakers))
        (text-mode)))))

(ert-deftest tategaki-script-speaker-completion-targets-a-bare-name ()
  (tategaki-script-test--with-buffer
    (insert "太郎：\n　　「声」\n花子：\n　　「返事」\n太")
    (pcase-let ((`(,start ,end ,table . ,_) (tategaki-script-completion-at-point)))
      (should (= start (1- (point-max))))
      (should (= end (point-max)))
      (should (member "太郎：" (all-completions "太" table))))
    (goto-char (point-min))
    (search-forward "声")
    (should-not (tategaki-script-completion-at-point))))

(ert-deftest tategaki-script-scene-index-outline-and-imenu-agree ()
  (tategaki-script-test--with-buffer
    (insert "○ 居間\n太郎：\n　　「声」\n◎ 廊下\n# 第三場\n第一幕 開幕\n")
    (let* ((headings (tategaki-outline--headings))
           (index (funcall imenu-create-index-function)))
      (should (= (length headings) 4))
      (should (= (length index) 4))
      (cl-loop for heading across headings
               for entry in index
               do (should (equal (aref heading 2) (car entry)))
               do (should (= (marker-position (aref heading 0)) (cdr entry)))))))

(ert-deftest tategaki-script-scene-navigation-keeps-document-intact ()
  (tategaki-script-test--with-buffer
    (insert "○ 一\n太郎：\n「声」\n○ 二\n（退場）\n○ 三\n")
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (set-buffer-modified-p nil)
    (goto-char (point-min))
    (tategaki-script-next-scene)
    (should (looking-at "○ 二"))
    (tategaki-script-next-scene)
    (should (looking-at "○ 三"))
    (tategaki-script-previous-scene 2)
    (should (looking-at "○ 一"))
    (should-not buffer-undo-list)
    (should-not (buffer-modified-p))))

(ert-deftest tategaki-script-scene-navigation-respects-narrowing ()
  (tategaki-script-test--with-buffer
    (insert "○ 一\n本文\n○ 二\n本文\n○ 三\n本文\n")
    (goto-char (point-min))
    (search-forward "○ 二")
    (beginning-of-line)
    (narrow-to-region (point) (point-max))
    (should (= (length (tategaki-outline--headings)) 2))
    (tategaki-script-next-scene)
    (should (looking-at "○ 三"))
    (tategaki-script-previous-scene)
    (should (looking-at "○ 二"))
    (let ((position (point)))
      (condition-case nil (tategaki-script-previous-scene) (user-error nil))
      (should (= position (point))))))

(ert-deftest tategaki-script-font-lock-distinguishes-semantic-lines ()
  (tategaki-script-test--with-buffer
    (insert "○ 居間\n太郎：\n　　「声」\n　（退場）\n")
    (font-lock-ensure)
    (dolist (spec '(("○" . tategaki-script-scene-face)
                    ("太郎" . tategaki-script-speaker-face)
                    ("「" . tategaki-script-dialogue-face)
                    ("（" . tategaki-script-stage-direction-face)))
      (let ((face (tategaki-script-test--face-at (car spec))))
        (should (or (eq face (cdr spec)) (memq (cdr spec) face)))))))

(ert-deftest tategaki-script-fontification-keeps-edits-outside-new-narrowing ()
  (tategaki-script-test--with-buffer
    (insert "太郎\n　　「声」\n")
    (tategaki-script--fontify)
    (goto-char (point-min))
    (end-of-line)
    (insert "：")
    (forward-line 1)
    (narrow-to-region (point) (point-max))
    (let ((minimum (point-min))
          (maximum (point-max))
          (position (point))
          (tick (buffer-chars-modified-tick))
          (undo buffer-undo-list))
      (tategaki-script--fontify)
      (should (= minimum (point-min)))
      (should (= maximum (point-max)))
      (should (= position (point)))
      (should (= tick (buffer-chars-modified-tick)))
      (should (eq undo buffer-undo-list))
      (widen)
      ;; Do not request another font-lock pass after widening: the pending
      ;; edit on the formerly hidden paragraph must already be up to date.
      (let ((face (tategaki-script-test--face-at "太郎")))
        (should (or (eq face 'tategaki-script-speaker-face)
                    (memq 'tategaki-script-speaker-face face)))))))

(ert-deftest tategaki-script-runtime-scene-regexp-updates-faces-outline-and-tab ()
  (tategaki-script-test--with-buffer
    (insert "SCENE 居間\n太郎：\n　　「声」\n○ 旧形式\n")
    (tategaki-script--fontify)
    (should (= (length (tategaki-outline--headings)) 1))
    (setq-local tategaki-script-scene-regexp "^SCENE ")
    (tategaki-script--fontify)
    (goto-char (point-min))
    (should (eq (tategaki-script--line-role) 'scene))
    (let ((face (tategaki-script-test--face-at "SCENE"))
          (headings (tategaki-outline--headings)))
      (should (or (eq face 'tategaki-script-scene-face)
                  (memq 'tategaki-script-scene-face face)))
      (should (= (length headings) 1))
      (should (equal (aref (aref headings 0) 2) "SCENE 居間")))
    (insert "　　")
    (call-interactively (key-binding (kbd "TAB")))
    (should (string-prefix-p "SCENE 居間\n" (buffer-string)))
    (goto-char (point-min))
    (should (eq (tategaki-script--line-role) 'scene))
    (search-forward "○")
    (should (eq (tategaki-script--line-role) 'dialogue))))

(ert-deftest tategaki-script-mode-can-reenter-without-duplicate-pairing ()
  (tategaki-script-test--with-buffer
    (tategaki-script-mode)
    (let ((this-command 'self-insert-command) (last-command-event ?「))
      (self-insert-command 1))
    (should (equal (buffer-string) "　　「」"))
    (should (= (cl-count #'tategaki-script-completion-at-point
                         completion-at-point-functions) 1))))

(provide 'tategaki-script-test)
;;; tategaki-script-test.el ends here
