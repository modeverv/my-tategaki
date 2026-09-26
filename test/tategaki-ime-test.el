;;; tategaki-ime-test.el --- Native IME preedit regression tests -*- lexical-binding: t; -*-

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

;; Batch Emacs does not load ns-win.el.  These small native mocks reproduce
;; its overlay protocol; the adapter's real advice and renderer run unchanged.

(require 'ert)
(require 'cl-lib)
(require 'tategaki)
(require 'tategaki-ime)

(defvar ns-working-text nil)
(defvar ns-working-overlay nil)
(defvar isearch-mode nil)
(defvar mac-ime-panel-offset-x 0)
(defvar mac-ime-panel-offset-y 2)

(defmacro tategaki-ime-test--with-panel-defaults (x y &rest body)
  "Run BODY with panel defaults X and Y, restoring global settings afterward."
  (declare (indent 2) (debug (form form body)))
  `(let ((saved-x (default-value 'mac-ime-panel-offset-x))
         (saved-y (default-value 'mac-ime-panel-offset-y)))
     (unwind-protect
         (progn
           (set-default 'mac-ime-panel-offset-x ,x)
           (set-default 'mac-ime-panel-offset-y ,y)
           ,@body)
       (set-default 'mac-ime-panel-offset-x saved-x)
       (set-default 'mac-ime-panel-offset-y saved-y))))

(defun tategaki-ime-test--native-delete ()
  "Reproduce the native deletion of a working-text overlay."
  (when (overlayp ns-working-overlay)
    (overlay-put ns-working-overlay 'after-string nil)
    (delete-overlay ns-working-overlay))
  (setq ns-working-overlay nil))

(defun tategaki-ime-test--native-working ()
  "Reproduce the ns-win working-text overlay."
  (ns-delete-working-text)
  (setq ns-working-overlay (make-overlay (point) (point)))
  (overlay-put ns-working-overlay 'after-string
               (propertize ns-working-text 'face 'ns-working-text-face)))

(defun tategaki-ime-test--native-marked (start length)
  "Reproduce the ns-win marked-text overlay for START and LENGTH."
  (ns-delete-working-text)
  (let ((end (+ start length)))
    (when (<= end (length ns-working-text))
      (setq ns-working-overlay (make-overlay (point) (point)))
      (overlay-put
       ns-working-overlay 'before-string
       (if (zerop length)
           (propertize ns-working-text 'face 'ns-working-text-face)
         (concat
          (propertize (substring ns-working-text 0 start)
                      'face 'ns-unmarked-text-face)
          (propertize (substring ns-working-text start end)
                      'face 'ns-marked-text-face)
          (propertize (substring ns-working-text end)
                      'face 'ns-unmarked-text-face)))))))

(defmacro tategaki-ime-test--with-native (&rest body)
  "Run BODY with the ns-win overlay protocol available in batch Emacs."
  (declare (indent 0) (debug t))
  `(let ((ns-working-text nil)
         (ns-working-overlay nil))
     (cl-letf (((symbol-function 'ns-insert-working-text)
                #'tategaki-ime-test--native-working)
               ((symbol-function 'ns-insert-marked-text)
                #'tategaki-ime-test--native-marked)
               ((symbol-function 'ns-delete-working-text)
                #'tategaki-ime-test--native-delete)
               ((symbol-function 'ns-in-echo-area)
                (lambda () t)))
       (unwind-protect (progn ,@body)
         (when (overlayp ns-working-overlay)
           (delete-overlay ns-working-overlay))))))

(defmacro tategaki-ime-test--with-source (text &rest body)
  "Run BODY in a displayed text buffer containing TEXT, then clean up."
  (declare (indent 1) (debug t))
  `(save-window-excursion
     (delete-other-windows)
     (let ((source (generate-new-buffer " tategaki-ime-test.txt")))
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
             (when tategaki-mode (tategaki-mode -1))
             (set-buffer-modified-p nil))
           (kill-buffer source))))))

(defun tategaki-ime-test--preedit-glyphs ()
  "Return (INDEX CHARACTER ROW COLUMN SOURCE FACE CURSOR) for each preedit glyph."
  (let ((display tategaki--display-string) glyphs)
    (dotimes (offset (length display))
      (let ((index (get-text-property offset 'tategaki-preedit-index display)))
        (when (integerp index)
          (push (list index (aref display offset)
                      (get-text-property offset 'tategaki-row display)
                      (get-text-property offset 'tategaki-column display)
                      (get-text-property offset 'tategaki-position display)
                      (get-text-property offset 'face display)
                      (get-text-property offset 'cursor display))
                glyphs))))
    (sort glyphs (lambda (left right) (< (car left) (car right))))))

(defun tategaki-ime-test--source-glyph (position)
  "Return (CHARACTER ROW COLUMN CURSOR) for actual source POSITION."
  (let ((display tategaki--display-string) found)
    (dotimes (offset (length display))
      (when (and (eq (get-text-property offset 'tategaki-position display) position)
                 (not (integerp (get-text-property
                                 offset 'tategaki-preedit-index display))))
        (setq found (list (aref display offset)
                          (get-text-property offset 'tategaki-row display)
                          (get-text-property offset 'tategaki-column display)
                          (get-text-property offset 'cursor display)))))
    found))

(ert-deftest tategaki-ime-preedit-preserves-source-properties-undo-and-modified ()
  (tategaki-ime-test--with-native
    (tategaki-ime-test--with-source "前後の文章"
      (put-text-property 1 3 'face 'bold)
      (put-text-property 3 5 'test-metadata '(keep these properties))
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (set-buffer-modified-p nil)
      (goto-char 2)
      (let ((original (buffer-string))
            (tick (buffer-chars-modified-tick))
            (undo-list buffer-undo-list))
        (tategaki-mode 1)
        (setq ns-working-text "にほんご")
        (ns-insert-working-text)
        (setq ns-working-text "日本語")
        (ns-insert-marked-text 0 3)
        (dotimes (_ 2) (tategaki-refresh))
        (should (equal-including-properties (buffer-string) original))
        (should (= (buffer-chars-modified-tick) tick))
        (should (equal buffer-undo-list undo-list))
        (should-not (buffer-modified-p))
        (should (= (point) 2))
        (should (= tategaki-ime--position 2))
        (should (equal tategaki-ime--selection '(0 . 3)))
        (should (equal (substring-no-properties tategaki-ime--text) "日本語"))
        (should-not (overlay-get ns-working-overlay 'before-string))
        (should-not (overlay-get ns-working-overlay 'after-string))))))

(ert-deftest tategaki-ime-preedit-wraps-left-and-preserves-following-source-mapping ()
  (tategaki-ime-test--with-native
    (tategaki-ime-test--with-source "甲乙丙丁"
      (let ((tategaki-column-height 3))
        (goto-char 3)
        (tategaki-mode 1)
        (setq ns-working-text "あいうえ")
        (ns-insert-working-text)
        (let ((glyphs (tategaki-ime-test--preedit-glyphs)))
          (should (equal (mapcar (lambda (glyph) (nth 1 glyph)) glyphs)
                         (string-to-list "あいうえ")))
          (should (equal (mapcar (lambda (glyph) (list (nth 2 glyph) (nth 3 glyph)))
                                glyphs)
                         '((2 0) (0 1) (1 1) (2 1))))
          (should (equal (mapcar (lambda (glyph) (nth 4 glyph)) glyphs) '(3 3 3 3))))
        (should (equal (cl-subseq (tategaki-ime-test--source-glyph 3) 0 3)
                       '(?丙 0 2)))
        (should (equal (cl-subseq (tategaki-ime-test--source-glyph 4) 0 3)
                       '(?丁 1 2)))
        (should (nth 3 (tategaki-ime-test--source-glyph 3)))
        (should (= (point) 3))))))

(ert-deftest tategaki-ime-marked-segment-preserves-native-faces-and-caret ()
  (tategaki-ime-test--with-native
    (tategaki-ime-test--with-source "前後"
      (goto-char 2)
      (tategaki-mode 1)
      (setq ns-working-text "日本語入力")
      (ns-insert-marked-text 2 2)
      (let ((glyphs (tategaki-ime-test--preedit-glyphs)))
        (should (= (length glyphs) 5))
        (dotimes (index 5)
          (should (memq (if (<= 2 index 3)
                            'ns-marked-text-face 'ns-unmarked-text-face)
                        (nth 5 (nth index glyphs))))
          (should (eq (not (null (nth 6 (nth index glyphs)))) (= index 2))))
      (should-not (nth 3 (tategaki-ime-test--source-glyph 2)))))))

(ert-deftest tategaki-ime-zero-length-selection-places-caret-inside-preedit ()
  (tategaki-ime-test--with-native
    (tategaki-ime-test--with-source "本文"
      (tategaki-mode 1)
      (setq ns-working-text "にほん")
      (ns-insert-marked-text 1 0)
      (let ((glyphs (tategaki-ime-test--preedit-glyphs)))
        (should (= (length glyphs) 3))
        (should-not (nth 6 (nth 0 glyphs)))
        (should (nth 6 (nth 1 glyphs)))
        (should-not (nth 6 (nth 2 glyphs)))
        (dolist (glyph glyphs)
          (should (memq 'ns-working-text-face (nth 5 glyph))))))))

(ert-deftest tategaki-ime-updating-shorter-preedit-removes-stale-cells ()
  (tategaki-ime-test--with-native
    (tategaki-ime-test--with-source "始終"
      (let ((tategaki-column-height 3))
        (goto-char 2)
        (tategaki-mode 1)
        (setq ns-working-text "にほんごにゅうりょく")
        (ns-insert-working-text)
        (setq ns-working-text "日本")
        (ns-insert-marked-text 0 2)
        (let ((glyphs (tategaki-ime-test--preedit-glyphs)))
          (should (= (length glyphs) 2))
          (should (equal (mapcar (lambda (glyph) (nth 1 glyph)) glyphs)
                         (string-to-list "日本"))))
        (should (equal (cl-subseq (tategaki-ime-test--source-glyph 2) 0 3)
                       '(?終 0 1)))))))

(ert-deftest tategaki-ime-same-text-new-segment-repaints-faces-and-caret ()
  (tategaki-ime-test--with-native
    (tategaki-ime-test--with-source "文章"
      (tategaki-mode 1)
      (setq ns-working-text "日本語入力")
      (ns-insert-marked-text 0 3)
      (ns-insert-marked-text 3 2)
      (let ((glyphs (tategaki-ime-test--preedit-glyphs)))
        (dotimes (index 5)
          (should (memq (if (< index 3)
                            'ns-unmarked-text-face 'ns-marked-text-face)
                        (nth 5 (nth index glyphs))))
          (should (eq (not (null (nth 6 (nth index glyphs)))) (= index 3))))))))

(ert-deftest tategaki-ime-other-window-retains-native-horizontal-preedit ()
  (tategaki-ime-test--with-native
    (tategaki-ime-test--with-source "同じ本文"
      (let ((owner (selected-window))
            (other (split-window-right)))
        (set-window-buffer other source)
        (tategaki-mode 1)
        (setq ns-working-text "未確定")
        (ns-insert-marked-text 1 2)
        (should (= (length tategaki-ime--mirrors) 1))
        (let ((mirror (car tategaki-ime--mirrors)))
          (should (eq (overlay-get mirror 'window) other))
          (should-not (eq (overlay-get mirror 'window) owner))
          (should (equal-including-properties
                   (overlay-get mirror 'before-string) tategaki-ime--text))
          (should-not (overlay-get ns-working-overlay 'before-string))
          (ns-delete-working-text)
          (should-not (overlay-buffer mirror))
          (should-not tategaki-ime--mirrors))))))

(ert-deftest tategaki-ime-owner-bypasses-display-triggered-echo-area-only ()
  (tategaki-ime-test--with-native
    (tategaki-ime-test--with-source "本文"
      (let ((other (split-window-right)))
        (set-window-buffer other source)
        (tategaki-mode 1)
        (should-not (ns-in-echo-area))
        (let ((isearch-mode t))
          (should (ns-in-echo-area)))
        (let ((cursor-in-echo-area t))
          (cl-letf (((symbol-function 'current-message) (lambda () "Input:")))
            (should (ns-in-echo-area))))
        (with-selected-window other
          (should (ns-in-echo-area)))
        (with-current-buffer (window-buffer (minibuffer-window))
          (should (ns-in-echo-area)))
        (tategaki-mode -1)
        (should (ns-in-echo-area))))))

(ert-deftest tategaki-ime-cancel-restores-original-render-and-source ()
  (tategaki-ime-test--with-native
    (tategaki-ime-test--with-source "取消前の文章"
      (goto-char 3)
      (tategaki-mode 1)
      (let ((original (buffer-string))
            (display tategaki--display-string))
        (setq ns-working-text "取り消す文字")
        (ns-insert-marked-text 2 3)
        (ns-delete-working-text)
        (should-not tategaki-ime--text)
        (should-not (tategaki-ime-test--preedit-glyphs))
        (should (equal-including-properties tategaki--display-string display))
        (should (equal-including-properties (buffer-string) original))
        (should-not (buffer-modified-p))))))

(ert-deftest tategaki-ime-empty-preedit-removes-virtual-text ()
  (tategaki-ime-test--with-native
    (tategaki-ime-test--with-source ""
      (tategaki-mode 1)
      (setq ns-working-text "入力")
      (ns-insert-working-text)
      (should (= (length (tategaki-ime-test--preedit-glyphs)) 2))
      (setq ns-working-text "")
      (ns-insert-marked-text 0 0)
      (should-not (tategaki-ime-test--preedit-glyphs))
      (should (tategaki-ime-test--source-glyph 1))
      (should (equal (buffer-string) ""))
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-ime-commit-is-one-native-insertion-and-undo ()
  (tategaki-ime-test--with-native
    (tategaki-ime-test--with-source "前後"
      (buffer-enable-undo)
      (setq buffer-undo-list nil)
      (goto-char 2)
      (tategaki-mode 1)
      (setq ns-working-text "にほんご")
      (ns-insert-working-text)
      (setq ns-working-text "日本語")
      (ns-insert-marked-text 0 3)
      (should-not buffer-undo-list)
      ;; ns deletes its presentation before normal input events commit text.
      (ns-delete-working-text)
      (undo-boundary)
      (insert "日本語")
      (undo-boundary)
      (tategaki-refresh)
      (should (equal (buffer-string) "前日本語後"))
      (should-not (tategaki-ime-test--preedit-glyphs))
      (undo-only 1)
      (tategaki-refresh)
      (should (equal (buffer-string) "前後"))
      (should tategaki-mode))))

(ert-deftest tategaki-ime-disabling-restores-native-preedit-presentation ()
  (tategaki-ime-test--with-native
    (tategaki-ime-test--with-source "本文"
      (tategaki-mode 1)
      (setq ns-working-text "未確定")
      (ns-insert-marked-text 1 2)
      (let ((overlay ns-working-overlay)
            (text tategaki-ime--text))
        (tategaki-mode -1)
        (should (eq (overlay-buffer overlay) source))
        (should (equal-including-properties
                 (overlay-get overlay 'before-string) text))
        (should-not (overlay-get overlay 'after-string))
        (should-not tategaki-ime--text)
        (should-not tategaki-ime--enabled)
        (should (equal (buffer-string) "本文"))))))

(ert-deftest tategaki-ime-other-buffers-keep-the-native-overlay ()
  (tategaki-ime-test--with-native
    (tategaki-ime-test--with-source "縦書き"
      (tategaki-mode 1)
      (let ((other (generate-new-buffer " tategaki-ime-ordinary.txt")))
        (unwind-protect
            (progn
              (switch-to-buffer other)
              (text-mode)
              (setq ns-working-text "通常入力")
              (ns-insert-marked-text 0 2)
              (should (stringp (overlay-get ns-working-overlay 'before-string)))
              (should-not tategaki-ime--text)
              (should-not tategaki-ime--enabled)
              (ns-delete-working-text)
              (should-not ns-working-overlay))
          (kill-buffer other))))))

(ert-deftest tategaki-ime-minibuffer-keeps-the-native-overlay ()
  (tategaki-ime-test--with-native
    (tategaki-ime-test--with-source "本文"
      (tategaki-mode 1)
      (with-current-buffer (window-buffer (minibuffer-window))
        (should (minibufferp))
        (setq ns-working-text "ミニバッファ")
        (ns-insert-working-text)
        (should (stringp (overlay-get ns-working-overlay 'after-string)))
        (should-not tategaki-ime--text)
        (ns-delete-working-text)))))

(ert-deftest tategaki-ime-advice-lives-until-last-mode-buffer-is-disabled ()
  (tategaki-ime-test--with-native
    (let ((native (symbol-function 'ns-insert-marked-text)))
      (tategaki-ime-test--with-source "最初"
        (tategaki-mode 1)
        (should-not (eq (symbol-function 'ns-insert-marked-text) native))
        (let ((first source))
          (tategaki-ime-test--with-source "次"
            (tategaki-mode 1)
            (with-current-buffer first (tategaki-mode -1))
            (should-not (eq (symbol-function 'ns-insert-marked-text) native))
            (setq ns-working-text "継続")
            (ns-insert-marked-text 0 2)
            (should (= (length (tategaki-ime-test--preedit-glyphs)) 2))
            (ns-delete-working-text)
            (tategaki-mode -1)
            (should (eq (symbol-function 'ns-insert-marked-text) native))))))))

(ert-deftest tategaki-ime-panel-preserves-global-offsets-without-accumulation ()
  (tategaki-ime-test--with-panel-defaults 7 -4
    (tategaki-ime-test--with-native
      (tategaki-ime-test--with-source "本文"
        (tategaki-ime-enable)
        (setq ns-working-text "未確定")
        (ns-insert-marked-text 0 3)
        (tategaki-ime-set-panel-offset 24 -18)
        (should (= mac-ime-panel-offset-x 31))
        (should (= mac-ime-panel-offset-y -22))
        (tategaki-ime-set-panel-offset 24 -18)
        (tategaki-ime-set-panel-offset 32 -20)
        (should (= mac-ime-panel-offset-x 39))
        (should (= mac-ime-panel-offset-y -24))
        (should (= (default-value 'mac-ime-panel-offset-x) 7))
        (should (= (default-value 'mac-ime-panel-offset-y) -4))
        ;; Native deletion is shared by both commit and cancellation.
        (ns-delete-working-text)
        (should (= mac-ime-panel-offset-x 7))
        (should (= mac-ime-panel-offset-y -4))
        (should-not (local-variable-p 'mac-ime-panel-offset-x))
        (should-not (local-variable-p 'mac-ime-panel-offset-y))
        (should-not tategaki-ime--panel-offset)))))

(ert-deftest tategaki-ime-panel-restores-existing-local-offsets-on-disable ()
  (tategaki-ime-test--with-panel-defaults 3 8
    (tategaki-ime-test--with-native
      (tategaki-ime-test--with-source "本文"
        (setq-local mac-ime-panel-offset-x -9 mac-ime-panel-offset-y 11)
        (tategaki-ime-enable)
        (setq ns-working-text "未確定")
        (ns-insert-marked-text 0 3)
        (tategaki-ime-set-panel-offset 20 -16)
        (should (= mac-ime-panel-offset-x 11))
        (should (= mac-ime-panel-offset-y -5))
        (tategaki-ime-disable)
        (should (local-variable-p 'mac-ime-panel-offset-x))
        (should (local-variable-p 'mac-ime-panel-offset-y))
        (should (= mac-ime-panel-offset-x -9))
        (should (= mac-ime-panel-offset-y 11))
        (should (= (default-value 'mac-ime-panel-offset-x) 3))
        (should (= (default-value 'mac-ime-panel-offset-y) 8))
        (should (overlay-buffer ns-working-overlay))))))

(ert-deftest tategaki-ime-panel-requires-supported-native-offsets ()
  (tategaki-ime-test--with-native
    (tategaki-ime-test--with-source "本文"
      (tategaki-ime-enable)
      (setq ns-working-text "未確定")
      (ns-insert-marked-text 0 3)
      (let ((native-boundp (symbol-function 'boundp))
            (x mac-ime-panel-offset-x)
            (y mac-ime-panel-offset-y))
        (cl-letf (((symbol-function 'boundp)
                   (lambda (symbol)
                     (and (not (memq symbol '(mac-ime-panel-offset-x
                                              mac-ime-panel-offset-y)))
                          (funcall native-boundp symbol)))))
          (tategaki-ime-set-panel-offset 24 -18))
        (should (= mac-ime-panel-offset-x x))
        (should (= mac-ime-panel-offset-y y))
        (should-not (local-variable-p 'mac-ime-panel-offset-x))
        (should-not (local-variable-p 'mac-ime-panel-offset-y))
        (should-not tategaki-ime--panel-original)))))

(ert-deftest tategaki-ime-panel-follows-selected-owner-and-restores-on-departure ()
  (tategaki-ime-test--with-panel-defaults 5 9
    (tategaki-ime-test--with-native
      (tategaki-ime-test--with-source "本文"
        (let ((owner (selected-window))
              (other (split-window-right)))
          (set-window-buffer other source)
          (tategaki-ime-enable nil owner)
          (setq ns-working-text "未確定")
          (ns-insert-marked-text 0 3)
          (tategaki-ime-set-panel-offset 24 -18)
          (select-window other)
          (run-hook-with-args 'window-selection-change-functions (selected-frame))
          (should (= mac-ime-panel-offset-x 5))
          (should (= mac-ime-panel-offset-y 9))
          (should-not (local-variable-p 'mac-ime-panel-offset-x))
          (tategaki-ime-set-panel-offset 32 -20)
          (should (= mac-ime-panel-offset-x 5))
          (select-window owner)
          (run-hook-with-args 'window-selection-change-functions (selected-frame))
          (should (= mac-ime-panel-offset-x 37))
          (should (= mac-ime-panel-offset-y -11))
          (ns-delete-working-text)
          (should (= mac-ime-panel-offset-x 5))
          (should (= mac-ime-panel-offset-y 9)))))))

(ert-deftest tategaki-ime-panel-does-not-leak-into-ordinary-buffers ()
  (tategaki-ime-test--with-panel-defaults 5 9
    (tategaki-ime-test--with-native
      (tategaki-ime-test--with-source "本文"
        (tategaki-ime-enable)
        (setq ns-working-text "未確定")
        (ns-insert-marked-text 0 3)
        (tategaki-ime-set-panel-offset 24 -18)
        (with-temp-buffer
          (should (= mac-ime-panel-offset-x 5))
          (should (= mac-ime-panel-offset-y 9))
          (tategaki-ime-set-panel-offset 24 -18)
          (should (= mac-ime-panel-offset-x 5))
          (should-not tategaki-ime--panel-offset)
          (should-not (local-variable-p 'mac-ime-panel-offset-x)))
        (should (= mac-ime-panel-offset-x 29))
        (should (= mac-ime-panel-offset-y -9))))))

(ert-deftest tategaki-ime-panel-restores-when-owner-shows-another-buffer ()
  (tategaki-ime-test--with-panel-defaults 5 9
    (tategaki-ime-test--with-native
      (tategaki-ime-test--with-source "本文"
        (setq-local mac-ime-panel-offset-y -7)
        (tategaki-ime-enable)
        (setq ns-working-text "未確定")
        (ns-insert-marked-text 0 3)
        (tategaki-ime-set-panel-offset 24 -18)
        (let ((owner (selected-window)))
          (with-temp-buffer
            (set-window-buffer owner (current-buffer))
            (run-hook-with-args 'window-buffer-change-functions owner)
            (should (= mac-ime-panel-offset-x 5))
            (should (= mac-ime-panel-offset-y 9))))
        (should-not (local-variable-p 'mac-ime-panel-offset-x))
        (should (local-variable-p 'mac-ime-panel-offset-y))
        (should (= mac-ime-panel-offset-x 5))
        (should (= mac-ime-panel-offset-y -7))
        (should-not tategaki-ime--panel-offset)
        (should (stringp (overlay-get ns-working-overlay 'before-string)))))))

(ert-deftest tategaki-ime-panel-restores-on-renderer-error ()
  (tategaki-ime-test--with-panel-defaults 5 9
    (tategaki-ime-test--with-native
      (tategaki-ime-test--with-source "本文"
        (tategaki-ime-enable)
        (setq ns-working-text "未確定")
        (ns-insert-marked-text 0 3)
        (tategaki-ime-set-panel-offset 24 -18)
        (setq tategaki-ime-update-function (lambda () (error "Renderer failed")))
        (tategaki-ime--notify)
        (should (= mac-ime-panel-offset-x 5))
        (should (= mac-ime-panel-offset-y 9))
        (should-not (local-variable-p 'mac-ime-panel-offset-x))
        (should-not tategaki-ime--panel-offset)
        (should (stringp (overlay-get ns-working-overlay 'before-string)))))))

(provide 'tategaki-ime-test)
;;; tategaki-ime-test.el ends here
