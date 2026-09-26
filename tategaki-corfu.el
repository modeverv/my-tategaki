;;; tategaki-corfu.el --- Corfu display in vertical text -*- lexical-binding: t; -*-

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

;; Corfu owns completion selection, insertion and undo.  This adapter only
;; substitutes its preview's presentation and the popup's pixel anchor.

;;; Code:

(require 'cl-lib)

(defvar tategaki--window)
(defvar tategaki-ime--text)
(defvar corfu--preview-ov)
(declare-function corfu--popup-hide "corfu" ())
(declare-function tategaki-position-pixel "tategaki" (position &optional window))
(declare-function tategaki-completion-set "tategaki-completion"
                  (owner beg end text &optional caret-offset))
(declare-function tategaki-completion-clear "tategaki-completion" (owner))

(defvar-local tategaki-corfu--enabled nil)
(defvar-local tategaki-corfu--preview nil)
(defvar tategaki-corfu--buffers nil)

(defun tategaki-corfu--active-p ()
  "Whether Corfu is displaying in the vertical owner window."
  (and tategaki-corfu--enabled
       (boundp 'tategaki--window)
       (window-live-p tategaki--window)
       (eq (selected-window) tategaki--window)
       (eq (window-buffer tategaki--window) (current-buffer))))

(defun tategaki-corfu--restore-preview ()
  "Restore Corfu's original overlay presentation."
  (when tategaki-corfu--preview
    (pcase-let ((`(,overlay ,display ,after) tategaki-corfu--preview))
      (when (overlay-buffer overlay)
        (overlay-put overlay 'display display)
        (overlay-put overlay 'after-string after)))
    (setq tategaki-corfu--preview nil)))

(defun tategaki-corfu--capture-preview ()
  "Render Corfu's native replacement overlay as vertical virtual text."
  (when (and (tategaki-corfu--active-p)
             (boundp 'corfu--preview-ov)
             (overlayp corfu--preview-ov)
             (eq (overlay-buffer corfu--preview-ov) (current-buffer))
             (memq (overlay-get corfu--preview-ov 'window)
                   (list nil tategaki--window)))
    (let* ((overlay corfu--preview-ov)
           (saved (and (eq overlay (car tategaki-corfu--preview))
                       tategaki-corfu--preview))
           (display (if saved (nth 1 saved) (overlay-get overlay 'display)))
           (after (if saved (nth 2 saved) (overlay-get overlay 'after-string)))
           (text (or display after)))
      (when (stringp text)
        (tategaki-corfu--restore-preview)
        (setq tategaki-corfu--preview (list overlay display after))
        (condition-case error-data
            (progn
              (overlay-put overlay 'display nil)
              (overlay-put overlay 'after-string nil)
              (tategaki-completion-set
               'corfu (overlay-start overlay) (overlay-end overlay) text))
          (error
           (tategaki-corfu--restore-preview)
           (signal (car error-data) (cdr error-data))))))))

(defun tategaki-corfu--preview-current (original &rest args)
  "Call ORIGINAL with ARGS, then capture its native preview."
  (prog1 (apply original args)
    (tategaki-corfu--capture-preview)))

(defun tategaki-corfu--preview-delete (original &rest args)
  "Call ORIGINAL with ARGS and clear the deleted preview in its owner."
  (let ((buffer (and (boundp 'corfu--preview-ov)
                     (overlayp corfu--preview-ov)
                     (overlay-buffer corfu--preview-ov))))
    (prog1 (apply original args)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when tategaki-corfu--preview
            (setq tategaki-corfu--preview nil)
            (tategaki-completion-clear 'corfu)))))))

(defun tategaki-corfu--popup-show (original pos off &rest args)
  "Anchor ORIGINAL's popup to vertical point, preserving its ARGS.
POS and OFF are Corfu's normal horizontal completion anchor."
  (cond
   ((not (tategaki-corfu--active-p)) (apply original pos off args))
   ;; Keep the native IME's conversion UI in charge during composition.
   ((and (boundp 'tategaki-ime--text) (stringp tategaki-ime--text)
         (> (length tategaki-ime--text) 0))
    (corfu--popup-hide))
   (t
    (let ((pixel (tategaki-position-pixel (point) tategaki--window)))
      (if (not pixel)
          ;; A hidden/off-page source position is not a valid pixel anchor.
          (corfu--popup-hide)
        ;; Keep the full posn structure for Corfu extensions.  The last slot
        ;; supplies cell height to Corfu's above/below placement calculation.
        (apply original
               (list tategaki--window (point)
                     (cons (plist-get pixel :x) (plist-get pixel :y))
                     0 nil nil nil nil nil
                     (cons (plist-get pixel :width) (plist-get pixel :height)))
               0 args))))))

(defconst tategaki-corfu--advice
  '((corfu--preview-current . tategaki-corfu--preview-current)
    (corfu--preview-delete . tategaki-corfu--preview-delete)
    (corfu--popup-show . tategaki-corfu--popup-show)))

(defun tategaki-corfu--install ()
  "Install optional Corfu integration while a vertical buffer needs it."
  (when tategaki-corfu--buffers
    (dolist (pair tategaki-corfu--advice)
      (when (and (fboundp (car pair))
                 (not (advice-member-p (cdr pair) (car pair))))
        (advice-add (car pair) :around (cdr pair))))))

(defun tategaki-corfu-enable ()
  "Enable Corfu presentation support in the current vertical buffer."
  (setq tategaki-corfu--enabled t)
  (cl-pushnew (current-buffer) tategaki-corfu--buffers)
  (add-hook 'kill-buffer-hook #'tategaki-corfu-disable nil t)
  (add-hook 'change-major-mode-hook #'tategaki-corfu-disable nil t)
  (tategaki-corfu--install)
  (tategaki-corfu--capture-preview))

(defun tategaki-corfu-disable ()
  "Restore native Corfu presentation in the current buffer."
  (setq tategaki-corfu--enabled nil)
  (tategaki-corfu--restore-preview)
  (tategaki-completion-clear 'corfu)
  (remove-hook 'kill-buffer-hook #'tategaki-corfu-disable t)
  (remove-hook 'change-major-mode-hook #'tategaki-corfu-disable t)
  (setq tategaki-corfu--buffers
        (delq (current-buffer) (cl-delete-if-not #'buffer-live-p
                                               tategaki-corfu--buffers)))
  (unless tategaki-corfu--buffers
    (dolist (pair tategaki-corfu--advice)
      (advice-remove (car pair) (cdr pair)))))

(with-eval-after-load 'corfu (tategaki-corfu--install))

(provide 'tategaki-corfu)
;;; tategaki-corfu.el ends here
