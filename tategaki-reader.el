;;; tategaki-reader.el --- Reversible book-style reading view -*- lexical-binding: t; -*-

;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; Temporarily replace the editing UI with a read-only spread.  Preserve the
;; exact source, diagnostic records, original display locals and window layout.

;;; Code:

(require 'cl-lib)
(require 'tategaki-manuscript)
(require 'tategaki-typeset)

(defgroup tategaki-reader nil "Book-style manuscript reading." :group 'text)
(defcustom tategaki-reader-manuscript-size '(40 . 17)
  "Rows and columns used by Reader's paperback-style spread."
  :type '(cons natnum natnum) :group 'tategaki-reader)
(defvar-local tategaki-reader--saved nil)
(defvar tategaki-studio-source)
(defvar tategaki-mode)
(defvar tategaki-reader-mode)
(defvar tategaki-diagnostics-visible)
(defvar tategaki-outline--buffer)
(declare-function tategaki-mode "tategaki" (&optional arg))
(declare-function tategaki-refresh "tategaki" ())
(declare-function tategaki-forward-page "tategaki" (&optional count))
(declare-function tategaki-backward-page "tategaki" (&optional count))
(declare-function tategaki-diagnostics-set-visible "tategaki-diagnostics" (visible &optional buffer))

(defconst tategaki-reader--variables
  '(header-line-format mode-line-format buffer-read-only
    tategaki-manuscript-size tategaki-manuscript-spread tategaki-manuscript-grid
    tategaki-manuscript-fit-window
    tategaki-typesetting tategaki-studio-state tategaki--page
    tategaki--scroll-start tategaki--goal-row tategaki--page-goal
    tategaki-diagnostics-visible)
  "Local state restored when Reader exits.")

(defun tategaki-reader--capture-locals ()
  "Capture each setting's value and whether it was buffer-local."
  (mapcar (lambda (symbol)
            (list symbol (local-variable-p symbol) (boundp symbol)
                  (and (boundp symbol) (symbol-value symbol))))
          tategaki-reader--variables))

(defun tategaki-reader--restore-locals (locals)
  "Restore LOCALS without leaking Reader settings into global defaults."
  (dolist (entry locals)
    (let ((symbol (nth 0 entry)))
      (if (nth 1 entry)
          (if (nth 2 entry)
              (set (make-local-variable symbol) (nth 3 entry))
            (makunbound (make-local-variable symbol)))
        (kill-local-variable symbol)))))

(defun tategaki-reader--button (label command)
  "Create clickable Reader header LABEL running COMMAND."
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1]
      (lambda (event)
        (interactive "e")
        (let ((window (posn-window (event-start event))))
          (when (windowp window) (select-window window)))
        (call-interactively command)))
    (propertize label 'local-map map 'mouse-face 'mode-line-highlight
                'help-echo label)))

(defun tategaki-reader-next-page ()
  "Advance one page in Reader."
  (interactive)
  (if (and (bound-and-true-p tategaki-mode) (fboundp 'tategaki-forward-page))
      (tategaki-forward-page)
    (scroll-up-command)))

(defun tategaki-reader-previous-page ()
  "Move back one page in Reader."
  (interactive)
  (if (and (bound-and-true-p tategaki-mode) (fboundp 'tategaki-backward-page))
      (tategaki-backward-page)
    (scroll-down-command)))

(defun tategaki-reader-quit ()
  "Leave Reader and restore its source's editing state."
  (interactive)
  (tategaki-reader-mode -1))

(defun tategaki-reader--leave ()
  "Restore saved Reader state once, including diagnostic visibility."
  (when tategaki-reader--saved
    (let ((saved tategaki-reader--saved))
      (setq tategaki-reader--saved nil)
      (remove-hook 'change-major-mode-hook #'tategaki-reader-quit t)
      (remove-hook 'kill-buffer-hook #'tategaki-reader-quit t)
      (when (and (not (plist-get saved :vertical)) (bound-and-true-p tategaki-mode))
        (tategaki-mode -1))
      (tategaki-reader--restore-locals (plist-get saved :locals))
      (save-restriction
        (widen)
        (goto-char (max (point-min) (min (point-max) (plist-get saved :point))))
        (set-marker (mark-marker) (plist-get saved :mark))
        (setq mark-active (plist-get saved :mark-active)))
      (when (fboundp 'tategaki-diagnostics-set-visible)
        (tategaki-diagnostics-set-visible
         (if (boundp 'tategaki-diagnostics-visible) tategaki-diagnostics-visible t)))
      (let ((windows (plist-get saved :windows)))
        (when (frame-live-p (window-configuration-frame windows))
          (set-window-configuration windows)))
      (when (and (bound-and-true-p tategaki-mode) (fboundp 'tategaki-refresh))
        (tategaki-refresh))
      (force-mode-line-update))))

(defun tategaki-reader--enter ()
  "Capture and apply Reader display state, rolling back a failed setup."
  (unless tategaki-reader--saved
    (setq tategaki-reader--saved
          (list :locals (tategaki-reader--capture-locals)
                :windows (current-window-configuration)
                :outline-visible (and (boundp 'tategaki-outline--buffer)
                                      (buffer-live-p tategaki-outline--buffer)
                                      (and (get-buffer-window tategaki-outline--buffer) t))
                :point (point) :mark (mark t) :mark-active mark-active
                :vertical (bound-and-true-p tategaki-mode)))
    (condition-case error-data
        (progn
          (unless (and (consp tategaki-reader-manuscript-size)
                       (integerp (car tategaki-reader-manuscript-size))
                       (> (car tategaki-reader-manuscript-size) 0)
                       (integerp (cdr tategaki-reader-manuscript-size))
                       (> (cdr tategaki-reader-manuscript-size) 0))
            (user-error "Reader manuscript size must be positive rows and columns"))
          (when (and (not (bound-and-true-p tategaki-mode))
                     (display-graphic-p) (require 'tategaki nil t))
            (tategaki-mode 1))
          (when (require 'tategaki-diagnostics nil t)
            (tategaki-diagnostics-set-visible nil))
          (setq-local tategaki-manuscript-size (copy-tree tategaki-reader-manuscript-size))
          (setq-local tategaki-manuscript-spread t)
          (setq-local tategaki-manuscript-fit-window t)
          (setq-local tategaki-manuscript-grid nil)
          (setq-local tategaki-typesetting t)
          (setq-local tategaki-studio-state 'write)
          (setq-local buffer-read-only t)
          (setq-local header-line-format
                      (list " 読書  "
                            (tategaki-reader--button "[前のページ]" #'tategaki-reader-previous-page)
                            "  "
                            (tategaki-reader--button "[次のページ]" #'tategaki-reader-next-page)
                            "  "
                            (tategaki-reader--button "[閉じる・執筆に戻る]" #'tategaki-reader-quit)))
          (setq-local mode-line-format nil)
          (let ((window (or (get-buffer-window (current-buffer))
                            (display-buffer (current-buffer)))))
            (select-window window)
            (dolist (side (window-list))
              (when (window-parameter side 'window-side) (delete-window side)))
            (delete-other-windows window))
          (add-hook 'change-major-mode-hook #'tategaki-reader-quit nil t)
          (add-hook 'kill-buffer-hook #'tategaki-reader-quit nil t)
          (tategaki-manuscript--refresh))
      (error
       (setq tategaki-reader-mode nil)
       (tategaki-reader--leave)
       (signal (car error-data) (cdr error-data))))))

(defvar tategaki-reader-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'tategaki-reader-quit)
    (define-key map (kbd "SPC") #'tategaki-reader-next-page)
    (define-key map (kbd "n") #'tategaki-reader-next-page)
    (define-key map (kbd "p") #'tategaki-reader-previous-page)
    (define-key map (kbd "DEL") #'tategaki-reader-previous-page)
    (define-key map (kbd "<next>") #'tategaki-reader-next-page)
    (define-key map (kbd "<prior>") #'tategaki-reader-previous-page)
    map))

;;;###autoload
(define-minor-mode tategaki-reader-mode
  "Read a book-style spread; exit to restore the complete Studio view."
  :lighter " 読書" :keymap tategaki-reader-mode-map
  (if tategaki-reader-mode (tategaki-reader--enter) (tategaki-reader--leave)))

;;;###autoload
(defun tategaki-reader ()
  "Enter Reader for this source manuscript."
  (interactive)
  (let ((source (or (and (boundp 'tategaki-studio-source)
                         (buffer-live-p tategaki-studio-source) tategaki-studio-source)
                    (current-buffer))))
    (pop-to-buffer source)
    (tategaki-reader-mode 1)))

(provide 'tategaki-reader)
;;; tategaki-reader.el ends here
