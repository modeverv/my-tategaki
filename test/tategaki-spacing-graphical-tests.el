;;; tategaki-spacing-graphical-tests.el --- Spacing GUI checks -*- lexical-binding: t; -*-

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

;; Run in a dedicated GUI: emacs -Q -l /absolute/path/to/this-file.el
(require 'ert)
(require 'cl-lib)
(let ((root (file-name-directory (directory-file-name
                                 (file-name-directory (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path root)
  (load (expand-file-name "tategaki.el" root) nil nil t))

(defmacro tategaki-spacing-gui--with-text (text &rest body)
  "Show TEXT in an isolated buffer while running BODY."
  (declare (indent 1))
  `(save-window-excursion
     (let ((buffer (generate-new-buffer " *spacing test*"))
           (tategaki-writing-assistance nil)
           (tategaki-column-height 4)
           (tategaki-padding-top 0) (tategaki-padding-bottom 0)
           (tategaki-padding-left 0) (tategaki-padding-right 0)
           (tategaki-line-spacing nil) (tategaki-character-spacing 0))
       (unwind-protect
           (progn (switch-to-buffer buffer) (delete-other-windows)
                  (text-mode) (insert ,text) (goto-char 1)
                  (buffer-enable-undo) (setq buffer-undo-list nil)
                  (tategaki-mode 1) ,@body)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (tategaki-mode -1) (set-buffer-modified-p nil))
           (kill-buffer buffer))))))

(defun tategaki-spacing-gui--cursor ()
  "Return point's real glyph origin, also checking the native cursor."
  (let ((pixel (tategaki-position-pixel (point)))
        (cursor (window-cursor-info)))
    (should pixel)
    (should cursor)
    (should (= (plist-get pixel :x) (aref cursor 1)))
    (should (= (plist-get pixel :y) (aref cursor 2)))
    (should (<= (+ (plist-get pixel :y) (plist-get pixel :height))
                (window-body-height nil t)))
    pixel))

(ert-deftest tategaki-spacing-gui-exact-pixels ()
  (tategaki-spacing-gui--with-text (make-string 80 ?文)
    (let* ((first (tategaki-spacing-gui--cursor))
           (second (tategaki-position-pixel 2))
           (original (buffer-string)))
      ;; One-pixel padding must not become a full font-height blank line.
      (setq tategaki-padding-top 1 tategaki-padding-right 17)
      (let ((padded (tategaki-spacing-gui--cursor)))
        (should (= (plist-get padded :y) (1+ (plist-get first :y))))
        (should (= (plist-get padded :x) (- (plist-get first :x) 17)))
        ;; Column gaps change only inter-column distance, not right padding.
        (dolist (gap '(0 1 19 50))
          (setq tategaki-line-spacing gap)
          (should (= (plist-get (tategaki-spacing-gui--cursor) :x)
                     (plist-get padded :x)))))
      (setq tategaki-padding-top 23 tategaki-padding-left 37
            tategaki-padding-bottom 29 tategaki-character-spacing 7
            tategaki-line-spacing 19)
      (let ((padded (tategaki-spacing-gui--cursor))
            (next (tategaki-position-pixel 2))
            (column (tategaki-position-pixel 5)))
        (should (= (plist-get padded :y) (+ (plist-get first :y) 23)))
        (should (= (- (plist-get next :y) (plist-get padded :y))
                   (+ 7 (- (plist-get second :y) (plist-get first :y)))))
        (should (= (- (plist-get padded :x) (plist-get column :x))
                   (+ (nth 1 tategaki--metrics) 19)))
        (goto-char (1+ (* 4 (1- tategaki--page-size))))
        (should (>= (plist-get (tategaki-spacing-gui--cursor) :x) 37)))
      (should (equal (buffer-string) original))
      (should-not buffer-undo-list))))

(ert-deftest tategaki-spacing-gui-cursor-stable-and-empty ()
  (tategaki-spacing-gui--with-text "天地AB玄黄。「宇宙」\n洪荒"
    (setq tategaki-padding-top 7 tategaki-padding-right 21
          tategaki-character-spacing 1 tategaki-line-spacing 5)
    (let ((origins (cl-loop for position from 1 to (point-max)
                            collect (tategaki-position-pixel position))))
      (dotimes (index (length origins))
        (goto-char (1+ index))
        (should (equal (nth index origins) (tategaki-spacing-gui--cursor))))))
  (tategaki-spacing-gui--with-text ""
    (setq tategaki-padding-top 7 tategaki-character-spacing 1)
    (tategaki-spacing-gui--cursor)
    (execute-kbd-macro "a")
    (tategaki-spacing-gui--cursor)
    (execute-kbd-macro (kbd "DEL"))
    (should (equal (buffer-string) ""))
    (tategaki-spacing-gui--cursor)))

(ert-deftest tategaki-spacing-gui-auto-fit-and-extreme-padding ()
  (let ((width (frame-width)) (height (frame-height)))
    (unwind-protect
        (tategaki-spacing-gui--with-text (make-string 800 ?文)
          (setq tategaki-column-height nil tategaki-padding-top 17
                tategaki-padding-bottom 31 tategaki-character-spacing 9)
          (set-frame-size (selected-frame) 48 22)
          (sit-for 0.1)
          (tategaki-refresh)
          (goto-char (plist-get tategaki--layout :height))
          (let ((pixel (tategaki-spacing-gui--cursor)))
            (should (<= (+ (plist-get pixel :y) (plist-get pixel :height))
                        (- (window-body-height nil t) 31))))
          (setq tategaki-padding-top 10000 tategaki-padding-bottom 10000
                tategaki-padding-left 10000 tategaki-padding-right 10000
                tategaki-line-spacing 10000 tategaki-character-spacing 10000)
          (goto-char (point-max))
          (tategaki-spacing-gui--cursor)
          (should (= (plist-get tategaki--layout :height) 1)))
      (set-frame-size (selected-frame) width height))))

(ert-deftest tategaki-spacing-gui-physical-keys ()
  (tategaki-spacing-gui--with-text (make-string 40 ?文)
    (let ((tategaki-physical-navigation t))
      (setq tategaki-padding-top 13 tategaki-line-spacing 11
            tategaki-character-spacing 5)
      (goto-char 6)
      (let ((start (tategaki-spacing-gui--cursor)))
        (execute-kbd-macro (kbd "C-f"))
        (should (= (point) 2))
        (should (> (plist-get (tategaki-spacing-gui--cursor) :x) (plist-get start :x)))
        (execute-kbd-macro (kbd "C-b C-n"))
        (should (= (point) 7))
        (should (> (plist-get (tategaki-spacing-gui--cursor) :y) (plist-get start :y)))
        (execute-kbd-macro (kbd "C-p"))
        (should (equal start (tategaki-spacing-gui--cursor))))
      (setq tategaki-physical-navigation nil)
      (execute-kbd-macro (kbd "C-f"))
      (should (= (point) 7)))))

(run-at-time 60 nil (lambda () (kill-emacs 2)))
(run-at-time
 1 nil
 (lambda ()
   (let ((status 2))
     (condition-case err
         (progn
           (unless (and (display-graphic-p) (fboundp 'window-cursor-info))
             (error "A graphical Emacs with window-cursor-info is required"))
           (set-frame-size (selected-frame) 72 28)
           (let ((stats (ert-run-tests-batch "^tategaki-spacing-gui-")))
             (setq status (if (= (ert-stats-completed-expected stats) 4) 0 1))))
       (error (message "Spacing GUI setup failed: %S" err)))
     (with-current-buffer "*Messages*"
       (write-region (point-min) (point-max)
                     (expand-file-name "tategaki-spacing-gui-tests.log" temporary-file-directory)))
     (kill-emacs status))))

;;; tategaki-spacing-graphical-tests.el ends here
