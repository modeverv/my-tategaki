;;; tategaki-completion.el --- Vertical completion previews -*- lexical-binding: t; -*-

;;; Commentary:
;; Display-only replacement snapshots.  Providers still own acceptance, Undo,
;; candidate selection, and their keymaps.  No completion package is required.

;;; Code:
(require 'cl-lib)

(defvar copilot--overlay)
(defvar-local tategaki-completion--enabled nil)
(defvar-local tategaki-completion--window nil)
(defvar-local tategaki-completion--update-function nil)
(defvar-local tategaki-completion--previews nil)
(defvar-local tategaki-completion--copilot-overlay nil)
(defvar-local tategaki-completion--copilot-properties nil)
(defvar-local tategaki-completion--mirrors nil)
(defvar tategaki-completion--buffers nil)

(defun tategaki-completion--notify ()
  "Update the selected buffer's display-only preview."
  (when (and tategaki-completion--enabled
             tategaki-completion--update-function)
    (funcall tategaki-completion--update-function)))

(defun tategaki-completion-set (owner beg end text &optional caret-offset)
  "Preview OWNER's TEXT replacing BEG to END, without editing source.
CARET-OFFSET is the insertion cursor's character offset within TEXT."
  (when tategaki-completion--enabled
    (when (and (integer-or-marker-p beg) (integer-or-marker-p end)
               (<= (point-min) beg end (point-max)) (stringp text))
      (setf (alist-get owner tategaki-completion--previews)
            (list :kind owner :start (+ beg 0) :end (+ end 0)
                  :text (copy-sequence text)
                  :caret-offset (min (length text)
                                     (max 0 (or caret-offset (- (point) beg)))))))
    (tategaki-completion--notify)))

(defun tategaki-completion-clear (owner)
  "Remove OWNER's display-only preview."
  (when (assq owner tategaki-completion--previews)
    (setq tategaki-completion--previews
          (assq-delete-all owner tategaki-completion--previews))
    (tategaki-completion--notify)))

(defun tategaki-completion-current ()
  "Return the active valid preview, preferring Corfu over Copilot."
  (cl-loop for owner in '(corfu copilot)
           for data = (alist-get owner tategaki-completion--previews)
           when (and tategaki-completion--enabled data
                     (<= (point-min) (plist-get data :start)
                         (plist-get data :end) (point-max)))
           return data))

(defun tategaki-completion--delete-mirrors ()
  "Delete horizontal Copilot displays in other windows."
  (mapc #'delete-overlay tategaki-completion--mirrors)
  (setq tategaki-completion--mirrors nil))

(defun tategaki-completion--restore-copilot ()
  "Restore native Copilot display properties without accepting it."
  (tategaki-completion--delete-mirrors)
  (when (and (overlayp tategaki-completion--copilot-overlay)
             (overlay-buffer tategaki-completion--copilot-overlay))
    (dolist (entry tategaki-completion--copilot-properties)
      (overlay-put tategaki-completion--copilot-overlay (car entry) (cdr entry)))))

(defun tategaki-completion-sync-window (&optional window)
  "Show the virtual preview only in WINDOW, retaining other windows."
  (when window (setq tategaki-completion--window window))
  (tategaki-completion--delete-mirrors)
  (let ((overlay tategaki-completion--copilot-overlay))
    (when (and tategaki-completion--enabled (overlayp overlay)
               (eq (overlay-buffer overlay) (current-buffer)))
      (if (and (window-live-p tategaki-completion--window)
               (eq (window-buffer tategaki-completion--window) (current-buffer)))
          (progn
            (dolist (entry tategaki-completion--copilot-properties)
              (overlay-put overlay (car entry) nil))
            (dolist (other (get-buffer-window-list (current-buffer) nil t))
              (when (and (not (eq other tategaki-completion--window))
                         (or (not (overlay-get overlay 'window))
                             (eq other (overlay-get overlay 'window))))
                (let ((mirror (copy-overlay overlay)))
                  (overlay-put mirror 'window other)
                  (dolist (entry tategaki-completion--copilot-properties)
                    (overlay-put mirror (car entry) (cdr entry)))
                  (push mirror tategaki-completion--mirrors)))))
        (tategaki-completion--restore-copilot)))))

(defun tategaki-completion--capture-copilot (&rest _)
  "Capture the existing Copilot overlay; leave its acceptance data intact."
  (when (and tategaki-completion--enabled (boundp 'copilot--overlay)
             (overlayp copilot--overlay)
             (eq (overlay-buffer copilot--overlay) (current-buffer)))
    (let* ((overlay copilot--overlay)
           (text (overlay-get overlay 'completion))
           (start (overlay-get overlay 'start))
           (tail (overlay-get overlay 'tail-length))
           (end (and (integerp tail) (- (overlay-end overlay) tail))))
      (when (and (stringp text) (integerp start) (integerp end)
                 (<= (point-min) start end (point-max)))
        (setq tategaki-completion--copilot-overlay overlay
              tategaki-completion--copilot-properties
              (mapcar (lambda (property) (cons property (overlay-get overlay property)))
                      '(display before-string after-string)))
        (tategaki-completion-sync-window)
        (tategaki-completion-set
         'copilot start end (propertize (copy-sequence text) 'face 'copilot-overlay-face) 0)))))

(defun tategaki-completion--copilot-cleared (&rest _)
  "Drop display state when Copilot dismisses or accepts its suggestion."
  (when tategaki-completion--enabled
    (tategaki-completion--delete-mirrors)
    (setq tategaki-completion--copilot-overlay nil
          tategaki-completion--copilot-properties nil)
    (tategaki-completion-clear 'copilot)))

(defun tategaki-completion--windows-changed (&optional _frame)
  "Maintain window-scoped horizontal copies of native previews."
  (dolist (buffer tategaki-completion--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (tategaki-completion-sync-window)))))

(defconst tategaki-completion--advice
  '((copilot--set-overlay-text . tategaki-completion--capture-copilot)
    (copilot-clear-overlay . tategaki-completion--copilot-cleared)))

(defun tategaki-completion--install ()
  "Install adapters only for loaded packages and participating buffers."
  (when tategaki-completion--buffers
    (dolist (entry tategaki-completion--advice)
      (when (and (fboundp (car entry))
                 (not (advice-member-p (cdr entry) (car entry))))
        (advice-add (car entry) :after (cdr entry))))))

(defun tategaki-completion-enable (&optional callback window)
  "Enable preview adaptation with CALLBACK in WINDOW."
  (setq tategaki-completion--enabled t
        tategaki-completion--update-function callback
        tategaki-completion--window (or window (selected-window)))
  (cl-pushnew (current-buffer) tategaki-completion--buffers)
  (add-hook 'kill-buffer-hook #'tategaki-completion-disable nil t)
  (add-hook 'change-major-mode-hook #'tategaki-completion-disable nil t)
  (add-hook 'window-configuration-change-hook #'tategaki-completion--windows-changed)
  (tategaki-completion--install)
  (if tategaki-completion--copilot-overlay
      (tategaki-completion-sync-window)
    (tategaki-completion--capture-copilot)))

(defun tategaki-completion-disable ()
  "Restore native completion display without accepting or dismissing it."
  (setq tategaki-completion--enabled nil)
  (tategaki-completion--restore-copilot)
  (setq tategaki-completion--previews nil
        tategaki-completion--copilot-overlay nil
        tategaki-completion--copilot-properties nil
        tategaki-completion--window nil
        tategaki-completion--update-function nil
        tategaki-completion--buffers (delq (current-buffer) tategaki-completion--buffers))
  (remove-hook 'kill-buffer-hook #'tategaki-completion-disable t)
  (remove-hook 'change-major-mode-hook #'tategaki-completion-disable t)
  (unless tategaki-completion--buffers
    (remove-hook 'window-configuration-change-hook #'tategaki-completion--windows-changed)
    (dolist (entry tategaki-completion--advice)
      (when (fboundp (car entry)) (advice-remove (car entry) (cdr entry))))))

(with-eval-after-load 'copilot (tategaki-completion--install))
(provide 'tategaki-completion)
;;; tategaki-completion.el ends here
