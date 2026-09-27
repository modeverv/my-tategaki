;;; tategaki-zoom-graphical-tests.el --- Vertical text zoom GUI checks -*- lexical-binding: t; -*-

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
(let ((root (file-name-directory
             (directory-file-name (file-name-directory load-file-name)))))
  (add-to-list 'load-path root))
(setq load-prefer-newer t)
(require 'tategaki)

(defmacro tategaki-zoom-gui--with-text (rich &rest body)
  "Run BODY in an isolated vertical editor using the RICH backend."
  (declare (indent 1))
  `(save-window-excursion
     (let ((source (generate-new-buffer " *zoom GUI*"))
           (text-scale-mode-step 1.2))
       (unwind-protect
           (progn
             (switch-to-buffer source) (delete-other-windows) (text-mode)
             (insert (make-string 1200 ?文)) (goto-char 6)
             (setq-local tategaki-typesetting ,rich)
             (buffer-enable-undo) (setq buffer-undo-list nil)
             (set-buffer-modified-p nil) (tategaki-mode 1)
             ,@body)
         (when (buffer-live-p source) (kill-buffer source))))))

(defun tategaki-zoom-gui--check-display ()
  "Verify native caret, mouse hit testing and the bottom scrollbar."
  (tategaki-refresh)
  (redisplay t)
  (let* ((pixel (tategaki-position-pixel (point)))
         (cursor (window-cursor-info))
         (hit (posn-at-x-y (+ (plist-get pixel :x) 1)
                           (+ (plist-get pixel :y) 1)))
         (object (posn-string hit))
         (height (window-body-height nil t))
         (width (window-body-width nil t)))
    (should (= (aref cursor 1) (plist-get pixel :x)))
    (should (= (aref cursor 2) (plist-get pixel :y)))
    (should (<= (+ (plist-get pixel :y) (plist-get pixel :height)) height))
    (should (= (get-text-property (cdr object) 'tategaki-position (car object))
               (point)))
    (should
     (cl-loop for y from (max 0 (- height 50)) below height
              for pos = (posn-at-x-y (/ width 2) y)
              for obj = (and pos (posn-string pos))
              thereis (and obj (get-text-property (cdr obj) 'tategaki-scrollbar (car obj)))))
    pixel))

(ert-deftest tategaki-zoom-gui-keys-reflow-and-preserve-source ()
  (dolist (rich '(nil t))
    (tategaki-zoom-gui--with-text rich
      (push-mark 3 t t)
      (let ((original (buffer-string))
            (tick (buffer-chars-modified-tick))
            (undo buffer-undo-list)
            (metrics (cdr tategaki--metrics))
            (rows (plist-get tategaki--layout :height))
            (frame-font (face-all-attributes 'default)))
        (tategaki-zoom-gui--check-display)
        (execute-kbd-macro (kbd "M-+"))
        (should (> (nth 1 tategaki--metrics) (car metrics)))
        (should (< (plist-get tategaki--layout :height) rows))
        (tategaki-zoom-gui--check-display)
        (execute-kbd-macro (kbd "M--"))
        (should (equal (cdr tategaki--metrics) metrics))
        (execute-kbd-macro (kbd "M-="))
        (should (> (nth 1 tategaki--metrics) (car metrics)))
        (execute-kbd-macro (kbd "M-0"))
        (should (equal (cdr tategaki--metrics) metrics))
        (execute-kbd-macro (kbd "M--"))
        (should (< (nth 1 tategaki--metrics) (car metrics)))
        (tategaki-zoom-gui--check-display)
        (execute-kbd-macro (kbd "C-u 3 M-+"))
        (should (= tategaki--text-scale-amount 2))
        (tategaki-zoom-gui--check-display)
        (should (= (point) 6))
        (should (= (mark) 3))
        (should mark-active)
        (should (= tick (buffer-chars-modified-tick)))
        (should (equal (buffer-string) original))
        (should (eq undo buffer-undo-list))
        (should-not (buffer-modified-p))
        (should (equal frame-font (face-all-attributes 'default)))))))

(ert-deftest tategaki-zoom-gui-paper-and-existing-remaps ()
  (tategaki-zoom-gui--with-text t
    (setq-local tategaki-manuscript-size '(20 . 20)
                tategaki-manuscript-grid t line-spacing 2)
    (text-scale-set 3)
    (face-remap-add-relative 'tategaki-face :slant 'italic)
    (tategaki-refresh)
    (let ((remaps (copy-tree face-remapping-alist))
          (metrics (cdr tategaki--metrics))
          (columns (plist-get tategaki--layout :columns))
          (before (tategaki-zoom-gui--check-display)))
      (tategaki-text-scale-increase 2)
      (should (> (plist-get (tategaki-zoom-gui--check-display) :width)
                 (plist-get before :width)))
      ;; Even a larger requested font keeps the whole fixed paper visible.
      (tategaki-text-scale-increase 5)
      (goto-char 20)
      (tategaki-zoom-gui--check-display)
      (should (= columns (plist-get tategaki--layout :columns)))
      (should (= (plist-get tategaki--layout :height) 20))
      (should (equal tategaki-manuscript-size '(20 . 20)))
      (should (= text-scale-mode-amount 3))
      (tategaki-text-scale-reset)
      (should (equal (cdr tategaki--metrics) metrics))
      (should (equal face-remapping-alist remaps))
      (tategaki-zoom-gui--check-display)
      (tategaki-text-scale-increase 2)
      (tategaki-mode -1)
      (should-not tategaki--text-scale-cookie)
      (should (equal face-remapping-alist remaps))
      (should-not (eq (key-binding (kbd "M-+")) #'tategaki-text-scale-increase))
      (tategaki-mode 1)
      (should (= tategaki--text-scale-amount 2))
      (should (> (nth 1 tategaki--metrics) (car metrics)))
      (tategaki-zoom-gui--check-display))))

(ert-deftest tategaki-zoom-gui-other-buffer-and-invalid-prefix ()
  (tategaki-zoom-gui--with-text t
    (let ((other (generate-new-buffer " *other zoom GUI*")))
      (unwind-protect
          (progn
            (tategaki-text-scale-increase 2)
            (let ((remaps (copy-tree face-remapping-alist)))
              (should-error (tategaki-text-scale-increase 10000) :type 'user-error)
              (should (= tategaki--text-scale-amount 2))
              (should (equal face-remapping-alist remaps)))
            (switch-to-buffer other) (text-mode) (insert "別の原稿")
            (tategaki-mode 1)
            (should (= tategaki--text-scale-amount 0))
            (should-not tategaki--text-scale-cookie)
            (should-not face-remapping-alist)
            (switch-to-buffer source)
            (tategaki-zoom-gui--check-display))
        (when (buffer-live-p other) (kill-buffer other))))))

(run-at-time 90 nil (lambda () (kill-emacs 2)))
(run-at-time
 1 nil
 (lambda ()
   (let ((status 2))
     (condition-case err
         (progn
           (unless (and (display-graphic-p) (fboundp 'window-cursor-info)
                        (image-type-available-p 'svg))
             (error "A graphical Emacs with SVG and window-cursor-info is required"))
           (set-frame-size (selected-frame) 150 55)
           (let ((stats (ert-run-tests-batch "^tategaki-zoom-gui-")))
             (setq status (if (= (ert-stats-completed-expected stats) 3) 0 1))))
       (error (message "Zoom GUI setup failed: %S" err)))
     (with-current-buffer "*Messages*"
       (write-region (point-min) (point-max)
                     (expand-file-name "tategaki-zoom-gui-tests.log" temporary-file-directory)))
     (kill-emacs status))))

;;; tategaki-zoom-graphical-tests.el ends here
