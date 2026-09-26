;;; tategaki-performance.el --- Reproducible GUI timing fixture -*- lexical-binding: t; -*-

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

;; Run: Emacs -Q -l /absolute/path/test/tategaki-performance.el
;; Writes tategaki-performance-results.el in temporary-file-directory;
;; no user document is touched.
(require 'cl-lib)
(setq load-prefer-newer t)
(let ((root (file-name-directory (directory-file-name (file-name-directory load-file-name)))))
  (add-to-list 'load-path root))
(require 'tategaki)
(defvar tategaki-performance-sizes '(1000 10000 100000 200000))
(defvar tategaki-performance-samples 20)

(defun tategaki-performance--text (length paragraphs)
  "Generate LENGTH source characters with distinct 100-character paragraphs."
  (let (parts)
    (dotimes (index (ceiling length 100))
      (push (concat (char-to-string (+ #x4e00 (mod index 2000)))
                    (make-string 98 ?文) (if paragraphs "\n" "字")) parts))
    (substring (apply #'concat (nreverse parts)) 0 length)))

(defun tategaki-performance--sample (function count)
  "Return timing summary for COUNT invocations of FUNCTION, in milliseconds."
  (let (samples)
    (dotimes (_ count)
      (let ((start (float-time)))
        (funcall function)
        (push (* 1000 (- (float-time) start)) samples)))
    (setq samples (sort samples #'<))
    (list :median-ms (nth (/ count 2) samples)
          :p95-ms (nth (1- (ceiling (* 0.95 count))) samples)
          :max-ms (car (last samples)) :samples count)))

(defun tategaki-performance-run ()
  "Measure initial display, native insertion, motion and page changes."
  (unless (display-graphic-p) (error "A dedicated graphical Emacs is required"))
  (set-frame-size (selected-frame) 100 40)
  (let ((tategaki-column-height 30)
        (tategaki-manuscript-size nil) (tategaki-manuscript-status t)
        results)
    (dolist (length tategaki-performance-sizes)
      (dolist (paragraphs '(nil t))
        (let ((buffer (generate-new-buffer " *typesetting benchmark*")))
          (unwind-protect
              (progn
                (switch-to-buffer buffer) (text-mode)
                (setq-local tategaki-typesetting t)
                (insert (tategaki-performance--text length paragraphs))
                (goto-char (/ length 2))
                (buffer-enable-undo) (setq buffer-undo-list nil)
                (garbage-collect)
                (let* ((gc-before gcs-done)
                       (initial (tategaki-performance--sample
                                 (lambda () (tategaki-mode 1)
                                   (unless (plist-get tategaki--layout :typeset)
                                     (error "Typesetting renderer was not selected"))
                                   (redisplay t)) 1))
                       (typing (tategaki-performance--sample
                                (lambda () (insert "猫") (tategaki-refresh) (redisplay t))
                                tategaki-performance-samples))
                       (motion (tategaki-performance--sample
                                (lambda () (forward-char 1) (tategaki-refresh) (redisplay t))
                                tategaki-performance-samples))
                       (direction 1)
                       (paging (tategaki-performance--sample
                                (lambda () (tategaki-forward-page direction)
                                  (setq direction (- direction)) (redisplay t))
                                tategaki-performance-samples)))
                  (push (list :characters length :paragraphs paragraphs
                              :initial initial :typing typing :motion motion :paging paging
                              :gc-count (- gcs-done gc-before)) results)
                  (message "Measured %s chars, paragraphs=%s" length paragraphs)))
            (with-current-buffer buffer (tategaki-mode -1) (set-buffer-modified-p nil))
            (kill-buffer buffer)))))
    (let ((print-length nil) (print-level nil))
      (with-temp-file (expand-file-name "tategaki-performance-results.el" temporary-file-directory)
        (prin1 (list :emacs emacs-version :system system-configuration
                     :frame '(100 . 40) :rows 30 :results (nreverse results)) (current-buffer))))))

(run-at-time 300 nil (lambda () (kill-emacs 2)))
(run-at-time 1 nil
             (lambda ()
               (condition-case err
                   (progn (tategaki-performance-run) (kill-emacs 0))
                 (error (message "Performance run failed: %S" err)
                        (with-current-buffer "*Messages*"
                          (write-region (point-min) (point-max)
                                        (expand-file-name "tategaki-performance-error.log"
                                                          temporary-file-directory)))
                        (kill-emacs 1)))))
;;; tategaki-performance.el ends here
