;;; tategaki-typeset-integration-test.el --- Rich editor model integration -*- lexical-binding: t; -*-

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

;; Batch model integration: the real editor, parser and preview adapters run;
;; only graphical availability/geometry and the final painter are substituted.
;; Pixel placement belongs to tategaki-typeset-graphical-tests.el.

(require 'ert)
(require 'cl-lib)
(require 'tategaki)

(defmacro tategaki-rich-test--with-text (text &rest body)
  "Run BODY through the actual rich editor with final GUI painting suppressed."
  (declare (indent 1) (debug t))
  `(save-window-excursion
     (let ((source (generate-new-buffer " *tategaki rich model test*")))
       (unwind-protect
           (cl-letf (((symbol-function 'tategaki-typeset-view-available-p) #'always)
                     ((symbol-function 'tategaki--geometry)
                      (lambda (_window _metrics)
                        (list :rows (or (car tategaki-manuscript-size) tategaki-column-height 6)
                              :capacity (or (cdr tategaki-manuscript-size) 10))))
                     ((symbol-function 'tategaki--paint) #'ignore))
             (switch-to-buffer source)
             (delete-other-windows)
             (text-mode)
             (insert ,text)
             (goto-char (point-min))
             (setq-local tategaki-typesetting t tategaki-column-height 6)
             (buffer-enable-undo)
             (setq buffer-undo-list nil)
             (set-buffer-modified-p nil)
             (tategaki-mode 1)
             ,@body)
         (when (buffer-live-p source)
           (with-current-buffer source
             (tategaki-mode -1)
             (set-buffer-modified-p nil))
           (kill-buffer source))))))

(ert-deftest tategaki-rich-model-toggle-refresh-retains-source-properties-and-undo ()
  (tategaki-rich-test--with-text "前｜漢字《かんじ》12👩‍👩‍👧‍👧後"
    (should (plist-get tategaki--layout :typeset))
    (put-text-property 1 2 'face 'warning)
    (setq buffer-undo-list nil)
    (set-buffer-modified-p nil)
    (let ((original (buffer-string)) (tick (buffer-chars-modified-tick)))
      (dotimes (_ 3) (tategaki-refresh))
      (tategaki-mode -1)
      (should (equal-including-properties original (buffer-string)))
      (should (= tick (buffer-chars-modified-tick)))
      (should-not buffer-undo-list)
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-rich-model-native-edit-undo-and-save-retain-markup ()
  (let ((file (make-temp-file "tategaki-rich-save-" nil ".txt")))
    (unwind-protect
        (tategaki-rich-test--with-text "｜漢字《かんじ》12が"
          (let ((original (buffer-string)))
            (goto-char (point-max))
            (let ((last-command-event ?追)) (self-insert-command 1))
            (undo-boundary)
            (tategaki-refresh)
            (should (equal (buffer-string) (concat original "追")))
            (undo-only 1)
            (tategaki-refresh)
            (should (equal (buffer-string) original))
            (setq buffer-file-name file)
            (setq-local make-backup-files nil require-final-newline nil)
            (set-buffer-modified-p t)
            (save-buffer)
            (with-temp-buffer
              (insert-file-contents file)
              (should (equal (buffer-string) original)))))
      (delete-file file))))

(ert-deftest tategaki-rich-model-tcy-cluster-and-ruby-preserve-every-source-position ()
  (tategaki-rich-test--with-text "前12が｜漢字《かんじ》後"
    (cl-loop for position from (point-min) to (point-max)
             for entry = (tategaki--entry position)
             do (should (= (aref entry 0) position)))
    (dolist (pair '((2 . 3) (4 . 5) (6 . 7) (8 . 13)))
      (let ((first (tategaki--entry (car pair)))
            (second (tategaki--entry (cdr pair))))
        (should (= (aref first 2) (aref second 2)))
        (should (= (aref first 3) (aref second 3)))))
    (should (eq (plist-get (aref (tategaki--entry 3) 4) :kind) 'tcy))
    (should (equal (plist-get (aref (tategaki--entry 5) 4) :text) "が"))
    (should (eq (plist-get (aref (tategaki--entry 12) 4) :kind) 'ruby))
    (goto-char 12)
    (tategaki-refresh)
    (should (= (point) 12))
    (should (= tategaki--caret-position 12))))

(ert-deftest tategaki-rich-model-selection-search-and-cursor-face-priority ()
  (tategaki-rich-test--with-text "前12後"
    (let ((search (make-overlay 3 4)) (transient-mark-mode t))
      (overlay-put search 'face 'isearch)
      (overlay-put search 'priority 1001)
      (goto-char 2)
      (tategaki-refresh)
      (let* ((unit (aref (tategaki--entry) 4))
             (faces (tategaki-typeset-view--face unit (selected-window))))
        (should (< (cl-position 'isearch faces) (cl-position 'tategaki-cursor-face faces))))
      (push-mark 4 t t)
      (let ((faces (tategaki-typeset-view--face (aref (tategaki--entry) 4) (selected-window))))
        (should (eq (car faces) 'region)))
      (should (equal (buffer-string) "前12後"))
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-rich-model-physical-navigation-respects-cluster-source-start ()
  (tategaki-rich-test--with-text "前12👩‍👩‍👧‍👧後"
    (goto-char 2)
    (tategaki-next-character 2)
    (should (= (point) 11))
    (tategaki-previous-character 2)
    (should (= (point) 2))
    (goto-char 8)
    (tategaki-previous-character)
    (should (= (point) 4))
    (forward-char)
    (should (= (point) 5))
    (tategaki-next-character)
    (should (= (point) 11))
    (should-not buffer-undo-list)
    (should-not (buffer-modified-p))))

(ert-deftest tategaki-rich-model-completion-and-ime-preview-never-edit-source ()
  (tategaki-rich-test--with-text "前古い後"
    (goto-char 2)
    (tategaki-completion-set 'copilot 2 4 "12漢字" 0)
    (should (eq tategaki--preview-kind 'copilot))
    (should (equal (tategaki--virtual-text) "前12漢字後"))
    (should (= (tategaki--source-position 6) 4))
    (should (eq (plist-get (aref (tategaki--entry 2) 4) :kind) 'tcy))
    (tategaki-completion-set 'corfu 2 4 "日本語" 1)
    (should (eq tategaki--preview-kind 'corfu))
    (should (= tategaki--caret-position 3))
    (setq tategaki-ime--text (propertize "にほん" 'face 'underline)
          tategaki-ime--position 2 tategaki-ime--selection '(1 . 1))
    (tategaki--ime-updated)
    (should (eq tategaki--preview-kind 'ime))
    (should (equal (tategaki--virtual-text) "前にほん古い後"))
    (should (= tategaki--caret-position 3))
    (setq tategaki-ime--text nil tategaki-ime--position nil)
    (tategaki--ime-updated)
    (should (eq tategaki--preview-kind 'corfu))
    (tategaki-completion-clear 'corfu)
    (should (eq tategaki--preview-kind 'copilot))
    (tategaki-completion-clear 'copilot)
    (should (equal (buffer-string) "前古い後"))
    (should-not buffer-undo-list)
    (should-not (buffer-modified-p))))

(ert-deftest tategaki-rich-model-fixed-manuscript-page-navigation ()
  (tategaki-rich-test--with-text (make-string 1300 ?字)
    (tategaki-manuscript-set-preset "20x20")
    (should (= (plist-get tategaki--layout :height) 20))
    (should (= (plist-get (tategaki-manuscript-page-info tategaki--layout (point)) :total) 4))
    (tategaki-goto-page 2)
    (should (= (point) 401))
    (should (= (plist-get (tategaki-manuscript-page-info tategaki--layout (point)) :current) 2))
    (tategaki-manuscript-toggle-spread)
    (tategaki-manuscript-toggle-grid)
    (should tategaki-manuscript-spread)
    (should tategaki-manuscript-grid)
    (tategaki-manuscript-set-preset "40x30")
    (should (= (plist-get tategaki--layout :height) 40))
    (should (= (plist-get (tategaki-manuscript-page-info tategaki--layout (point)) :total) 2))
    (tategaki-goto-page 2)
    (should (= (point) 1201))
    (should-error (tategaki-goto-page 3) :type 'user-error)
    (should-not (buffer-modified-p))))

(ert-deftest tategaki-rich-model-narrowing-and-option-change-preserve-source ()
  (tategaki-rich-test--with-text "外側前\n前｜漢字《かんじ》12後\n外側後"
    (narrow-to-region 5 18)
    (goto-char (point-min))
    (tategaki-refresh)
    (let ((original (buffer-string)) (begin (point-min)) (end (point-max)))
      (setq-local tategaki-typeset-annotation-display 'raw)
      (tategaki-refresh)
      (setq-local tategaki-typeset-annotation-display 'rendered)
      (tategaki-refresh)
      (should (= (point-min) begin))
      (should (= (point-max) end))
      (should (equal (buffer-string) original))
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-rich-model-fixed-page-geometry-fits-without-repagination ()
  (tategaki-rich-test--with-text "原稿"
    (setq-local tategaki-manuscript-fit-window t)
    (dolist (size '((20 . 20) (40 . 30)))
      (setq-local tategaki-manuscript-size size tategaki-manuscript-spread nil)
      (let ((geometry (tategaki-typeset-view-geometry (selected-window) '(nil 24 30 24))))
        (should (= (plist-get geometry :rows) (car size)))
        (should (= (plist-get geometry :capacity) (cdr size)))
        (should (> (plist-get geometry :scale) 0)))
      (setq-local tategaki-manuscript-spread t)
      (let ((geometry (tategaki-typeset-view-geometry (selected-window) '(nil 24 30 24))))
        (should (= (plist-get geometry :rows) (car size)))
        (should (= (plist-get geometry :capacity) (* 2 (cdr size))))))))

(ert-deftest tategaki-rich-model-fixed-pages-prioritize-readable-text ()
  (let ((tategaki-manuscript-size '(20 . 20))
        (tategaki-manuscript-spread t)
        (tategaki-manuscript-fit-window nil)
        (tategaki-line-spacing 14) (tategaki-character-spacing 0)
        (tategaki-padding-left 40) (tategaki-padding-right 40)
        (tategaki-padding-top 40) (tategaki-padding-bottom 40))
    (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 1386))
              ((symbol-function 'window-body-height) (lambda (&rest _) 768))
              ((symbol-function 'frame-char-width) (lambda (&rest _) 13))
              ((symbol-function 'tategaki-scrollbar-height) (lambda (&rest _) 24))
              ((symbol-function 'tategaki-scrollbar-line-spacing) (lambda (&rest _) 0)))
      (let* ((small (tategaki-typeset-view-geometry (selected-window) '(nil 15 19 15)))
             (large (tategaki-typeset-view-geometry (selected-window) '(nil 26 33 26)))
             (tategaki-manuscript-fit-window t)
             (fitted (tategaki-typeset-view-geometry (selected-window) '(nil 26 33 26))))
        (should (> (plist-get large :body) (plist-get small :body)))
        (should (> (plist-get large :body) (plist-get fitted :body)))
        (should (< (plist-get large :capacity) (plist-get small :capacity)))
        (should (= (plist-get fitted :capacity) 40))
        (dolist (geometry (list small large fitted))
          (should (= (plist-get geometry :rows) 20))
          (should (= (plist-get geometry :paper-columns) 20))
          ;; Every partial view remains on screen, including views crossing
          ;; one or two paper boundaries at arbitrary scrollbar positions.
          (dotimes (first 40)
            (let ((capacity (plist-get geometry :capacity)))
              (should (>= (tategaki-typeset-view--column-x geometry first 0) 0))
              (should (<= (+ (tategaki-typeset-view--column-x geometry first (1- capacity))
                             (plist-get geometry :cell)) 1386)))))))))

(ert-deftest tategaki-rich-model-partial-viewport-gaps-follow-paper-boundaries ()
  (let* ((geometry '(:capacity 8 :paper-columns 20 :paper-gap 24 :pitch 40
                    :right 500 :cell 30))
         (xs (cl-loop for visual downfrom 7 to 0
                      collect (tategaki-typeset-view--column-x geometry 17 visual))))
    ;; Logical columns 17,18,19,20,21,... go right to left.  Only the
    ;; 19->20 sheet boundary gains the extra paper gap.
    (should (equal (cl-mapcar #'- (butlast xs) (cdr xs)) '(40 40 64 40 40 40 40)))))

(provide 'tategaki-typeset-integration-test)
;;; tategaki-typeset-integration-test.el ends here
