;;; tategaki-highlight.el --- Project source faces onto vertical cells -*- lexical-binding: t; -*-

;;; Commentary:
;; Copy only faces from text and overlays, never their replacement strings.
;; Native search and diagnostic overlays remain owned by their packages.

;;; Code:
(require 'cl-lib)

(defvar-local tategaki-highlight--callback nil)
(defvar-local tategaki-highlight--timer nil)
(defvar tategaki-highlight--buffers nil)

(defun tategaki-highlight--faces (value)
  "Normalize face VALUE to a list."
  (cond ((null value) nil)
        ((or (symbolp value) (keywordp (car-safe value))) (list value))
        (t value)))

(defun tategaki-highlight-faces (start end window)
  "Return source faces intersecting START..END in WINDOW, highest first.
Inside a composed grapheme or tate-chu-yoko cell, partial matches highlight
the containing cell; the underlying source selection remains unchanged."
  (let ((position (max (point-min) start)) overlays text-faces font-lock-faces)
    (while (< position (min end (point-max)))
      (dolist (overlay (overlays-at position t))
        (when (and (not (memq overlay overlays))
                   (not (overlay-get overlay 'tategaki-internal))
                   (or (not (overlay-get overlay 'window))
                       (eq (overlay-get overlay 'window) window)))
          (setq overlays (append overlays (list overlay)))))
      (setq text-faces
            (append text-faces (tategaki-highlight--faces
                                (get-text-property position 'face)))
            font-lock-faces
            (append font-lock-faces (tategaki-highlight--faces
                                     (get-text-property position 'font-lock-face))))
      (setq position (1+ position)))
    ;; A match can begin inside a composed cell, after a source text face.
    ;; Collect the whole cell before merging so that it still takes priority.
    ;; Mirror native overlay ordering: primary priority, strict nesting, then
    ;; secondary priority.  Equal/undefined ties retain native source order.
    (setq overlays
          (cl-stable-sort
           overlays
           (lambda (left right)
             (let* ((lp (overlay-get left 'priority))
                    (rp (overlay-get right 'priority))
                    (lprimary (if (numberp lp) lp (or (car-safe lp) 0)))
                    (rprimary (if (numberp rp) rp (or (car-safe rp) 0)))
                    (lsecondary (if (consp lp) (or (cdr lp) 0) 0))
                    (rsecondary (if (consp rp) (or (cdr rp) 0) 0))
                    (ls (overlay-start left)) (le (overlay-end left))
                    (rs (overlay-start right)) (re (overlay-end right)))
               (cond
                ((/= lprimary rprimary) (> lprimary rprimary))
                ((and (>= ls rs) (<= le re) (or (> ls rs) (< le re))) t)
                ((and (>= rs ls) (<= re le) (or (> rs ls) (< re le))) nil)
                (t (> lsecondary rsecondary)))))))
    (delete-dups
     (copy-sequence
      (append (cl-mapcan (lambda (overlay)
                           (copy-sequence (tategaki-highlight--faces
                                           (overlay-get overlay 'face))))
                         overlays)
              text-faces font-lock-faces)))))

(defun tategaki-highlight--flush (buffer)
  "Refresh BUFFER after a face-only change."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq tategaki-highlight--timer nil)
      (when tategaki-highlight--callback
        (funcall tategaki-highlight--callback)))))

(defun tategaki-highlight--schedule (buffer)
  "Schedule one visible refresh for participating BUFFER."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'tategaki-highlight--callback buffer))
    (with-current-buffer buffer
      (unless tategaki-highlight--timer
        (setq tategaki-highlight--timer
              (run-with-idle-timer 0.03 nil #'tategaki-highlight--flush buffer))))))

(defun tategaki-highlight--overlay-put (overlay property _value)
  "Notice a source OVERLAY's face PROPERTY change."
  (when (and (memq property '(face font-lock-face priority window))
             (not (overlay-get overlay 'tategaki-internal)))
    (tategaki-highlight--schedule (overlay-buffer overlay))))

(defun tategaki-highlight--delete (original overlay)
  "Call ORIGINAL to delete OVERLAY and notice the removed face."
  (let ((buffer (and (overlayp overlay) (overlay-buffer overlay)))
        (visible (and (overlayp overlay) (overlay-get overlay 'face)
                      (not (overlay-get overlay 'tategaki-internal)))))
    (prog1 (funcall original overlay)
      (when visible (tategaki-highlight--schedule buffer)))))

(defun tategaki-highlight--move (original overlay &rest arguments)
  "Call ORIGINAL to move OVERLAY using ARGUMENTS and update both owners."
  (let ((old (overlay-buffer overlay))
        (visible (and (overlay-get overlay 'face)
                      (not (overlay-get overlay 'tategaki-internal)))))
    (prog1 (apply original overlay arguments)
      (when visible
        (tategaki-highlight--schedule old)
        (tategaki-highlight--schedule (overlay-buffer overlay))))))

(defun tategaki-highlight--changed (&rest _)
  "Notice source text-property changes as well as normal text edits."
  (tategaki-highlight--schedule (current-buffer)))

(defun tategaki-highlight-consume ()
  "Cancel a pending face refresh when the renderer already paints it."
  (when (timerp tategaki-highlight--timer)
    (cancel-timer tategaki-highlight--timer))
  (setq tategaki-highlight--timer nil))

(defun tategaki-highlight-enable (callback)
  "Mirror source faces, calling CALLBACK on asynchronous overlay changes."
  (setq tategaki-highlight--callback callback)
  (cl-pushnew (current-buffer) tategaki-highlight--buffers)
  (add-hook 'after-change-functions #'tategaki-highlight--changed nil t)
  (add-hook 'kill-buffer-hook #'tategaki-highlight-disable nil t)
  (add-hook 'change-major-mode-hook #'tategaki-highlight-disable nil t)
  (dolist (entry '((overlay-put :after tategaki-highlight--overlay-put)
                   (delete-overlay :around tategaki-highlight--delete)
                   (move-overlay :around tategaki-highlight--move)))
    (unless (advice-member-p (nth 2 entry) (car entry))
      (advice-add (car entry) (cadr entry) (nth 2 entry)))))

(defun tategaki-highlight-disable ()
  "Remove face tracking without modifying the native overlays."
  (tategaki-highlight-consume)
  (setq tategaki-highlight--callback nil
        tategaki-highlight--buffers (delq (current-buffer) tategaki-highlight--buffers))
  (remove-hook 'after-change-functions #'tategaki-highlight--changed t)
  (remove-hook 'kill-buffer-hook #'tategaki-highlight-disable t)
  (remove-hook 'change-major-mode-hook #'tategaki-highlight-disable t)
  (unless tategaki-highlight--buffers
    (advice-remove 'overlay-put #'tategaki-highlight--overlay-put)
    (advice-remove 'delete-overlay #'tategaki-highlight--delete)
    (advice-remove 'move-overlay #'tategaki-highlight--move)))

(provide 'tategaki-highlight)
;;; tategaki-highlight.el ends here
