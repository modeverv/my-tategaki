;;; tategaki-test.el --- Functional tests for vertical text editing -*- lexical-binding: t; -*-

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
(require 'tategaki)

(defmacro tategaki-test--with-source (text &rest body)
  "Run BODY in a visible text buffer initially containing TEXT."
  (declare (indent 1) (debug t))
  `(save-window-excursion
     (delete-other-windows)
     (let ((source (generate-new-buffer " tategaki-test.txt")))
       (unwind-protect
           (progn
             (switch-to-buffer source)
             (text-mode)
             (insert ,text)
             (goto-char (point-min))
             (set-buffer-modified-p nil)
             ,@body)
         (when (buffer-live-p source)
           (with-current-buffer source
             (set-buffer-modified-p nil))
           (kill-buffer source))))))

(defun tategaki-test--display ()
  "Return the current vertical rendering, including empty-buffer rendering."
  (or (and (boundp 'tategaki--display-string) tategaki--display-string)
      (overlay-get tategaki--overlay 'display)
      (overlay-get tategaki--overlay 'before-string)
      (overlay-get tategaki--overlay 'after-string)))

(defun tategaki-test--mapped-positions ()
  "Return distinct source positions represented by displayed glyphs."
  (let ((display (tategaki-test--display)) positions)
    (dotimes (index (length display))
      (let ((position (get-text-property index 'tategaki-position display)))
        (when position (cl-pushnew position positions))))
    (sort positions #'<)))

(defun tategaki-test--face-at-source (position)
  "Return the displayed face associated with source POSITION."
  (let* ((display (tategaki-test--display))
         (index (text-property-any 0 (length display)
                                   'tategaki-position position display)))
    (when index
      (let ((face (get-text-property index 'face display)))
        (if (listp face) face (list face))))))

(ert-deftest tategaki-edit-keeps-the-native-source-selected ()
  (tategaki-test--with-source "吾輩は猫である。\n名前はまだ無い。"
    (let ((window (selected-window))
          (original (buffer-string)))
      (tategaki-edit)
      (should tategaki-mode)
      (should (eq (current-buffer) source))
      (should (eq (window-buffer window) source))
      (should (= (length (window-list)) 1))
      (should (eq (overlay-buffer tategaki--overlay) source))
      (should (eq (overlay-get tategaki--overlay 'window) window))
      (should (stringp (tategaki-test--display)))
      (should (equal (buffer-string) original))
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-display-preserves-source-properties-and-undo ()
  (tategaki-test--with-source "日本語とABC。\n次の段落"
    (put-text-property 1 4 'face 'bold)
    (put-text-property 4 6 'example-property '(retained metadata))
    (buffer-enable-undo)
    (let ((original (buffer-string))
          (undo-list buffer-undo-list)
          (modified (buffer-modified-p)))
      (goto-char 5)
      (tategaki-mode 1)
      (dotimes (_ 3) (tategaki-refresh))
      (should (= (point) 5))
      (should (equal-including-properties (buffer-string) original))
      (should (equal buffer-undo-list undo-list))
      (should (eq (buffer-modified-p) modified))
      (tategaki-mode -1)
      (should (equal-including-properties (buffer-string) original))
      (should (equal buffer-undo-list undo-list)))))

(ert-deftest tategaki-native-self-insert-newline-and-delete-edit-source ()
  (tategaki-test--with-source "吾輩"
    (tategaki-mode 1)
    (goto-char (point-max))
    (let ((last-command-event ?猫)) (self-insert-command 1))
    (newline)
    (let ((last-command-event ?犬)) (self-insert-command 1))
    (should (equal (buffer-string) "吾輩猫\n犬"))
    (backward-delete-char 1)
    (should (equal (buffer-string) "吾輩猫\n"))
    (should (buffer-modified-p))
    (tategaki-refresh)
    (should (stringp (tategaki-test--display)))
    (should (eq (current-buffer) source))))

(ert-deftest tategaki-undo-reverts-native-edit-with-mode-still-active ()
  (tategaki-test--with-source "元の文"
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (tategaki-mode 1)
    (goto-char (point-max))
    (undo-boundary)
    (let ((last-command-event ?。)) (self-insert-command 1))
    (undo-boundary)
    (tategaki-refresh)
    (undo-only 1)
    (tategaki-refresh)
    (should (equal (buffer-string) "元の文"))
    (should tategaki-mode)
    (should (eq (overlay-buffer tategaki--overlay) source))))

(ert-deftest tategaki-save-writes-plain-source-not-the-display ()
  (let ((file (make-temp-file "tategaki-save-" nil ".txt")))
    (unwind-protect
        (tategaki-test--with-source "保存する文章。\n二行目。"
          (setq buffer-file-name file)
          (setq-local make-backup-files nil)
          (setq-local require-final-newline nil)
          (setq-local buffer-file-coding-system 'utf-8-unix)
          (tategaki-mode 1)
          (goto-char (point-max))
          (let ((last-command-event ?追)) (self-insert-command 1))
          (tategaki-refresh)
          (save-buffer)
          (should-not (buffer-modified-p))
          (let ((expected (buffer-string)))
            (with-temp-buffer
              (insert-file-contents file)
              (should (equal (buffer-string) expected)))))
      (delete-file file))))

(ert-deftest tategaki-normal-writing-keys-remain-native ()
  (tategaki-test--with-source ""
    (tategaki-mode 1)
    (dolist (key '("q" "j" "k" "a" "s" "f" "猫"))
      (should (eq (key-binding key) 'self-insert-command)))
    (should (eq (key-binding (kbd "C-x C-s")) 'save-buffer))
    (should (eq (key-binding (kbd "<down>")) 'tategaki-next-character))
    (should (eq (key-binding (kbd "<up>")) 'tategaki-previous-character))
    (should (eq (key-binding (kbd "<left>")) 'tategaki-forward-column))
    (should (eq (key-binding (kbd "<right>")) 'tategaki-backward-column))))

(ert-deftest tategaki-rejects-programming-buffers-cleanly ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(+ 1 2)")
    (let ((original (buffer-string)))
      (should-error (tategaki-mode 1) :type 'user-error)
      (should-not tategaki-mode)
      (should-not (and (overlayp tategaki--overlay)
                       (overlay-buffer tategaki--overlay)))
      (should (equal (buffer-string) original)))))

(ert-deftest tategaki-next-previous-character-follow-source-order ()
  (tategaki-test--with-source "あいう\nえお"
    (tategaki-mode 1)
    (tategaki-next-character 3)
    (should (= (point) 4))
    (tategaki-next-character 1)
    (should (= (point) 5))
    (tategaki-previous-character 2)
    (should (= (point) 3))
    (tategaki-next-character -1)
    (should (= (point) 2))))

(ert-deftest tategaki-column-movement-respects-vertical-rows ()
  (tategaki-test--with-source "あいうえおかきくけこさし"
    (let ((tategaki-column-height 4))
      (tategaki-mode 1)
      (goto-char 2)
      (tategaki-refresh)
      (tategaki-forward-column 1)
      (should (= (point) 6))
      (tategaki-forward-column 1)
      (should (= (point) 10))
      (tategaki-backward-column 2)
      (should (= (point) 2))
      (tategaki-forward-column -1)
      (should (= (point) 2)))))

(ert-deftest tategaki-short-paragraph-column-movement-clamps-row ()
  (tategaki-test--with-source "あいう\nえ\nかきく"
    (let ((tategaki-column-height 6))
      (tategaki-mode 1)
      (goto-char 3)
      (tategaki-refresh)
      (tategaki-forward-column 1)
      ;; The short following column still has a position for its newline.
      (should (memq (point) '(5 6)))
      (tategaki-forward-column 1)
      (should (<= 7 (point) 9)))))

(ert-deftest tategaki-empty-newline-and-eof-have-editable-mappings ()
  (dolist (text '("" "\n" "\n\n" "あ" "あ\n" "あ\n\nい"))
    (tategaki-test--with-source text
      (tategaki-mode 1)
      (goto-char (point-max))
      (tategaki-refresh)
      (should (stringp (tategaki-test--display)))
      (let ((positions (tategaki-test--mapped-positions)))
        (should (member (point-max) positions))
        (dotimes (offset (length text))
          (should (member (+ (point-min) offset) positions))))
      (let ((last-command-event ?追)) (self-insert-command 1))
      (tategaki-refresh)
      (should (equal (buffer-string) (concat text "追"))))))

(ert-deftest tategaki-refresh-preserves-active-narrowing ()
  (tategaki-test--with-source "非表示前\n対象本文\n非表示後"
    (let ((original (buffer-string)))
      (narrow-to-region 6 10)
      (goto-char 8)
      (tategaki-mode 1)
      (tategaki-refresh)
      (should (buffer-narrowed-p))
      (should (= (point-min) 6))
      (should (= (point-max) 10))
      (should (= (point) 8))
      (should (equal (buffer-string) "対象本文"))
      (tategaki-mode -1)
      (should (buffer-narrowed-p))
      (widen)
      (should (equal (buffer-string) original)))))

(ert-deftest tategaki-display-is-restricted-to-its-owner-window ()
  (tategaki-test--with-source "片方だけ縦書き\n他方は通常表示"
    (let* ((owner (selected-window))
           (other (split-window-right)))
      (set-window-buffer other source)
      (tategaki-mode 1)
      (tategaki-refresh)
      (should (eq (overlay-get tategaki--overlay 'window) owner))
      (should-not (eq (overlay-get tategaki--overlay 'window) other))
      (should (eq (window-buffer other) source))
      (should (equal (buffer-string) "片方だけ縦書き\n他方は通常表示")))))

(ert-deftest tategaki-leaves-other-window-display-options-unchanged ()
  (tategaki-test--with-source "両方のウィンドウで共有される本文"
    (setq-local truncate-lines nil)
    (setq-local word-wrap t)
    (setq-local line-spacing 0.3)
    (let ((other (split-window-right)))
      (set-window-buffer other source)
      (tategaki-mode 1)
      (tategaki-refresh)
      (with-current-buffer (window-buffer other)
        (should-not truncate-lines)
        (should word-wrap)
        (should (= line-spacing 0.3)))
      (should (eq (overlay-get tategaki--overlay 'window) (selected-window)))
      (when (boundp 'tategaki--tail-overlay)
        (should (eq (overlay-get tategaki--tail-overlay 'window)
                    (selected-window)))))))

(ert-deftest tategaki-buffers-have-independent-displays-and-lifecycle ()
  (tategaki-test--with-source "最初の文"
    (tategaki-mode 1)
    (let ((first-overlay tategaki--overlay)
          (second (generate-new-buffer " tategaki-second.txt")))
      (unwind-protect
          (progn
            (switch-to-buffer second)
            (text-mode)
            (insert "別の原稿")
            (tategaki-mode 1)
            (should-not (eq tategaki--overlay first-overlay))
            (should (eq (overlay-buffer first-overlay) source))
            (tategaki-mode -1)
            (with-current-buffer source
              (should tategaki-mode)
              (should (eq tategaki--overlay first-overlay))
              (should (eq (overlay-buffer first-overlay) source))))
        (with-current-buffer second (set-buffer-modified-p nil))
        (kill-buffer second)))))

(ert-deftest tategaki-disable-removes-overlay-and-restores-hooks ()
  (tategaki-test--with-source "解除しても本文は残る。"
    ;; Pre-existing local hooks must survive the mode's own hook lifecycle.
    (dolist (hook '(after-change-functions post-command-hook
                    kill-buffer-hook change-major-mode-hook))
      (add-hook hook #'ignore nil t))
    (let ((after-change (copy-sequence after-change-functions))
          (post-command (copy-sequence post-command-hook))
          (kill-hooks (copy-sequence kill-buffer-hook))
          (major-hooks (copy-sequence change-major-mode-hook)))
      (tategaki-mode 1)
      (let ((overlay tategaki--overlay))
        (tategaki-quit)
        (should-not tategaki-mode)
        (should-not (overlay-buffer overlay))
        (should (equal after-change-functions after-change))
        (should (equal post-command-hook post-command))
        (should (equal kill-buffer-hook kill-hooks))
        (should (equal change-major-mode-hook major-hooks))
        (should (equal (buffer-string) "解除しても本文は残る。"))))))

(ert-deftest tategaki-major-mode-change-cleans-up-display ()
  (tategaki-test--with-source "通常モードに戻す"
    (tategaki-mode 1)
    (let ((overlay tategaki--overlay))
      (fundamental-mode)
      (should-not tategaki-mode)
      (should-not (overlay-buffer overlay))
      (should (equal (buffer-string) "通常モードに戻す")))))

(ert-deftest tategaki-killing-source-cleans-up-overlay ()
  (tategaki-test--with-source "終了する原稿"
    (tategaki-mode 1)
    (let ((overlay tategaki--overlay))
      (kill-buffer source)
      (should-not (overlay-buffer overlay)))))

(ert-deftest tategaki-active-region-is-visible-without-modifying-source ()
  (tategaki-test--with-source "あいうえおか"
    (let ((transient-mark-mode t))
      (tategaki-mode 1)
      (goto-char 2)
      (push-mark 5 t t)
      (tategaki-refresh)
      (should (use-region-p))
      (dolist (position '(2 3 4))
        (should (memq 'region (tategaki-test--face-at-source position))))
      (dolist (position '(1 5 6 7))
        (should-not (memq 'region (tategaki-test--face-at-source position))))
      (should (= (point) 2))
      (should (= (mark) 5))
      (should-not (buffer-modified-p))
      (kill-region (region-beginning) (region-end))
      (tategaki-refresh)
      (should (equal (buffer-string) "あおか"))
      (should (buffer-modified-p)))))

(ert-deftest tategaki-native-region-overlay-is-suppressed-only-in-owner-window ()
  (tategaki-test--with-source "範囲選択が表示全体に広がらない"
    (let* ((owner (selected-window))
           (other (split-window-right))
           delegated-windows
           (original (lambda (start end window overlay)
                       (push window delegated-windows)
                       (redisplay--highlight-overlay-function
                        start end window overlay))))
      (setq-local redisplay-highlight-region-function original)
      (set-window-buffer other source)
      (tategaki-mode 1)
      (let ((old-region (make-overlay 2 5)))
        (overlay-put old-region 'face 'region)
        (should-not (funcall redisplay-highlight-region-function
                             2 5 owner old-region))
        (should-not (overlay-buffer old-region))
        (should-not delegated-windows))
      (let ((normal-region (funcall redisplay-highlight-region-function
                                   2 5 other nil)))
        (should (overlayp normal-region))
        (should (eq (overlay-get normal-region 'face) 'region))
        (should (eq (overlay-get normal-region 'window) other))
        (should (equal delegated-windows (list other)))
        (delete-overlay normal-region))
      (tategaki-mode -1)
      (should (eq redisplay-highlight-region-function original)))))

(ert-deftest tategaki-cursor-face-follows-native-point ()
  (tategaki-test--with-source "カーソル位置"
    (tategaki-mode 1)
    (goto-char 3)
    (tategaki-refresh)
    (should (memq 'tategaki-cursor-face (tategaki-test--face-at-source 3)))
    (should-not (memq 'tategaki-cursor-face (tategaki-test--face-at-source 1)))
    (goto-char (point-max))
    (tategaki-refresh)
    (should (memq 'tategaki-cursor-face
                  (tategaki-test--face-at-source (point-max))))))

(ert-deftest tategaki-toggle-restores-local-display-options ()
  (tategaki-test--with-source "設定を戻す"
    (setq-local line-spacing 0.3)
    (setq-local truncate-lines nil)
    (setq-local word-wrap t)
    (let ((variables '(line-spacing truncate-lines word-wrap
                      global-disable-point-adjustment))
          before)
      (dolist (variable variables)
        (push (list variable (local-variable-p variable) (symbol-value variable)) before))
      (tategaki-mode 1)
      (tategaki-mode -1)
      (dolist (item before)
        (should (eq (local-variable-p (car item)) (nth 1 item)))
        (should (equal (symbol-value (car item)) (nth 2 item)))))))

(ert-deftest tategaki-toggle-retains-input-method-state ()
  (tategaki-test--with-source "入力方式を保全する"
    (activate-input-method "japanese")
    (unwind-protect
        (let ((method current-input-method)
              (function input-method-function))
          (tategaki-mode 1)
          (tategaki-refresh)
          (should (equal current-input-method method))
          (should (eq input-method-function function))
          (tategaki-mode -1)
          (should (equal current-input-method method))
          (should (eq input-method-function function)))
      (deactivate-input-method))))

(provide 'tategaki-test)
;;; tategaki-test.el ends here
