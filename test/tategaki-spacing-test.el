;;; tategaki-spacing-test.el --- Padding and spacing output tests -*- lexical-binding: t; -*-

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

;; Batch Emacs renders terminal strings here.  Assertions inspect actual
;; displayed glyph coordinates and source state, not the geometry calculator.

(require 'ert)
(require 'cl-lib)
(require 'tategaki)

(defmacro tategaki-spacing-test--with-text (text &rest body)
  "Render TEXT in an isolated terminal window and run BODY."
  (declare (indent 1))
  `(progn
     (skip-unless (not (display-graphic-p)))
     (save-window-excursion
       (delete-other-windows)
       (let ((source (generate-new-buffer " *Tategaki spacing test*"))
             (tategaki-column-height 3)
             (tategaki-column-spacing 1)
             (tategaki-padding-top 0)
             (tategaki-padding-bottom 0)
             (tategaki-padding-left 0)
             (tategaki-padding-right 0)
             (tategaki-line-spacing nil)
             (tategaki-character-spacing 0))
         (unwind-protect
             (progn
               (switch-to-buffer source)
               (text-mode)
               (insert ,text)
               (goto-char (point-min))
               (buffer-enable-undo)
               (setq buffer-undo-list nil)
               (set-buffer-modified-p nil)
               ,@body)
           (when (buffer-live-p source)
             (with-current-buffer source
               (when tategaki-mode (tategaki-mode -1))
               (set-buffer-modified-p nil))
             (kill-buffer source)))))))

(defun tategaki-spacing-test--cells ()
  "Read source glyph positions from the actual displayed terminal string."
  (let ((display tategaki--display-string)
        (line-start 0) (row 0) cells)
    (dotimes (index (length display))
      (when-let* ((position (get-text-property index 'tategaki-position display)))
        (push (list :position position
                    :x (string-width (substring display line-start index))
                    :y row :char (aref display index)
                    :cursor (get-text-property index 'cursor display)) cells))
      (when (= (aref display index) ?\n)
        (setq row (1+ row) line-start (1+ index))))
    (nreverse cells)))

(defun tategaki-spacing-test--cell (position)
  "Return displayed glyph metadata for source POSITION."
  (cl-find position (tategaki-spacing-test--cells)
           :key (lambda (cell) (plist-get cell :position))))

(defun tategaki-spacing-test--first-column ()
  "Return displayed glyphs sharing the source's first visible column."
  (let* ((cells (tategaki-spacing-test--cells))
         (right (apply #'max (mapcar (lambda (cell) (plist-get cell :x)) cells))))
    (cl-remove-if-not (lambda (cell) (= (plist-get cell :x) right)) cells)))

(ert-deftest tategaki-spacing-terminal-top-character-and-column-gaps ()
  (tategaki-spacing-test--with-text "一二三四五六七八"
    (setq tategaki-padding-top 2
          tategaki-line-spacing 4
          tategaki-character-spacing 1)
    (tategaki-mode 1)
    (let ((first (tategaki-spacing-test--cell 1))
          (second (tategaki-spacing-test--cell 2))
          (third (tategaki-spacing-test--cell 3))
          (next-column (tategaki-spacing-test--cell 4)))
      (should (= (plist-get first :y) 2))
      (should (= (plist-get second :y) 4))
      (should (= (plist-get third :y) 6))
      (should (= (plist-get next-column :y) 2))
      (should (= (- (plist-get first :x) (plist-get next-column :x)) 6)))
    ;; Empty padding/gap rows must not become clickable source positions.
    (let ((rows (split-string tategaki--display-string "\n" nil)))
      (dolist (row '(0 1 3 5))
        (should (string-empty-p (nth row rows)))))))

(ert-deftest tategaki-spacing-terminal-horizontal-padding-stays-inside-window ()
  (tategaki-spacing-test--with-text (make-string 600 ?日)
    (tategaki-mode 1)
    (let ((original-x (plist-get (tategaki-spacing-test--cell 1) :x)))
      (setq tategaki-padding-left 9 tategaki-padding-right 5)
      (tategaki-refresh)
      (should (= (- original-x (plist-get (tategaki-spacing-test--cell 1) :x)) 5))
      (let ((cells (tategaki-spacing-test--cells)))
        (should (>= (apply #'min (mapcar (lambda (cell) (plist-get cell :x)) cells)) 9))
        (should (<= (+ 2 (apply #'max (mapcar (lambda (cell) (plist-get cell :x)) cells)))
                    (- (window-body-width) 5)))))))

(ert-deftest tategaki-spacing-auto-height-reserves-bottom-and-reflows-on-setq ()
  (tategaki-spacing-test--with-text (make-string 600 ?日)
    (setq tategaki-column-height nil)
    (tategaki-mode 1)
    (let ((original-rows (length (tategaki-spacing-test--first-column))))
      (setq tategaki-padding-top 2
            tategaki-padding-bottom 3
            tategaki-character-spacing 1)
      (tategaki-refresh)
      (let* ((column (tategaki-spacing-test--first-column))
             (ys (mapcar (lambda (cell) (plist-get cell :y)) column)))
        (should (< (length column) original-rows))
        (should (= (car ys) 2))
        (cl-loop for (a b) on ys while b do (should (= (- b a) 2)))
        (should (<= (1+ (car (last ys))) (- (window-body-height) 3))))
      (let ((rows-with-gap-one (length (tategaki-spacing-test--first-column))))
        (setq tategaki-character-spacing 2)
        (tategaki-refresh)
        (should (< (length (tategaki-spacing-test--first-column)) rows-with-gap-one)))
      (let ((rows-before-bottom-change (length (tategaki-spacing-test--first-column))))
        (setq tategaki-padding-bottom 8)
        (tategaki-refresh)
        (should (< (length (tategaki-spacing-test--first-column)) rows-before-bottom-change)))
      (setq tategaki-padding-top 4 tategaki-line-spacing 5)
      (tategaki-refresh)
      (should (= (plist-get (tategaki-spacing-test--cell 1) :y) 4))
      (let* ((cells (tategaki-spacing-test--cells))
             (columns (sort (delete-dups (mapcar (lambda (cell) (plist-get cell :x)) cells)) #'<)))
        (cl-loop for (a b) on columns while b do (should (= (- b a) 7)))))))

(ert-deftest tategaki-spacing-legacy-column-gap-and-explicit-zero ()
  (tategaki-spacing-test--with-text "一二三四五六"
    (setq tategaki-column-spacing 3)
    (tategaki-mode 1)
    (should (= (- (plist-get (tategaki-spacing-test--cell 1) :x)
                  (plist-get (tategaki-spacing-test--cell 4) :x)) 5))
    (setq tategaki-line-spacing 0)
    (tategaki-refresh)
    (should (= (- (plist-get (tategaki-spacing-test--cell 1) :x)
                  (plist-get (tategaki-spacing-test--cell 4) :x)) 2))
    (setq tategaki-line-spacing nil tategaki-column-spacing 1)
    (tategaki-refresh)
    (should (= (- (plist-get (tategaki-spacing-test--cell 1) :x)
                  (plist-get (tategaki-spacing-test--cell 4) :x)) 3))))

(ert-deftest tategaki-spacing-column-gap-keeps-right-padding-independent ()
  (tategaki-spacing-test--with-text "一二三四五六"
    (setq tategaki-padding-right 5 tategaki-line-spacing 0)
    (tategaki-mode 1)
    (let ((rightmost-x (plist-get (tategaki-spacing-test--cell 1) :x)))
      (dolist (gap '(1 4 20 0))
        (setq tategaki-line-spacing gap)
        (tategaki-refresh)
        ;; Only the next column moves; padding at the right stays fixed.
        (should (= (plist-get (tategaki-spacing-test--cell 1) :x) rightmost-x))
        (should (= (- rightmost-x (plist-get (tategaki-spacing-test--cell 4) :x))
                   (+ 2 gap)))))))

(ert-deftest tategaki-spacing-extreme-values-keep-eof-visible-and-bounded ()
  (dolist (text '("" "一二三四五六七八九十"))
    (tategaki-spacing-test--with-text text
      (setq tategaki-column-height nil
            tategaki-padding-top 100000000 tategaki-padding-bottom 100000000
            tategaki-padding-left 100000000 tategaki-padding-right 100000000
            tategaki-line-spacing 100000000 tategaki-character-spacing 100000000)
      (goto-char (point-max))
      (tategaki-mode 1)
      (let ((eof (tategaki-spacing-test--cell (point-max))))
        (should eof)
        (should (plist-get eof :cursor))
        (should (= (plist-get eof :char) (string-to-char tategaki-layout-eof-symbol)))
        (should (<= 0 (plist-get eof :x) (- (window-body-width) 2)))
        (should (<= 0 (plist-get eof :y) (1- (window-body-height))))
        (should (< (length tategaki--display-string)
                   (* (window-body-width) (window-body-height)))))
      (should (equal (buffer-string) text))
      (should-not buffer-undo-list))))

(ert-deftest tategaki-spacing-split-display-retains-padding-and-native-point ()
  (tategaki-spacing-test--with-text "一二三四五六"
    (setq tategaki-padding-top 3 tategaki-character-spacing 2)
    (tategaki-mode 1)
    (dolist (position '(1 2 4 7))
      (goto-char position)
      (tategaki-refresh)
      (let ((combined (concat (overlay-get tategaki--overlay 'after-string)
                              (overlay-get tategaki--tail-overlay 'before-string)))
            (cursor (cl-find-if (lambda (cell) (plist-get cell :cursor))
                                (tategaki-spacing-test--cells))))
        (should (equal-including-properties combined tategaki--display-string))
        (should (= (plist-get cursor :position) position))
        (should (= (point) position))))))

(ert-deftest tategaki-spacing-preserves-source-undo-and-other-window-settings ()
  (tategaki-spacing-test--with-text (propertize "一二三四五六" 'face 'bold)
    (setq-local line-spacing 7)
    (let* ((other (split-window-right))
           (owner (selected-window))
           (original (buffer-string))
           (tick (buffer-chars-modified-tick))
           (undo buffer-undo-list))
      (set-window-buffer other source)
      (set-window-hscroll other 4)
      (setq tategaki-padding-top 2 tategaki-padding-bottom 3
            tategaki-padding-left 4 tategaki-padding-right 5
            tategaki-line-spacing 3 tategaki-character-spacing 1)
      (tategaki-mode 1)
      (tategaki-refresh)
      (should (eq (overlay-get tategaki--overlay 'window) owner))
      (should (eq (overlay-get tategaki--tail-overlay 'window) owner))
      (should (= (window-hscroll other) 4))
      (should (= line-spacing 7))
      (should (equal-including-properties original (buffer-string)))
      (should (= tick (buffer-chars-modified-tick)))
      (should (eq undo buffer-undo-list))
      (should-not (buffer-modified-p))
      (tategaki-mode -1)
      (should (= line-spacing 7))
      (should (= (window-hscroll other) 4))
      (should (equal-including-properties original (buffer-string))))))

(provide 'tategaki-spacing-test)
;;; tategaki-spacing-test.el ends here
