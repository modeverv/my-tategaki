;;; tategaki-diagnostics.el --- Source-backed writing diagnostics -*- lexical-binding: t; -*-

;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Diagnostics belong to source buffers.  Their overlay faces are projected by
;; tategaki-highlight without modifying the manuscript or its undo history.

;;; Code:
(require 'tategaki-pane)
(require 'cl-lib)
(require 'button)
(require 'tategaki-highlight)

(defgroup tategaki-diagnostics nil "Writing diagnostics." :group 'tategaki)
(defface tategaki-diagnostics-error
  '((t (:inherit error :underline t))) "Diagnostic error face."
  :group 'tategaki-diagnostics)
(defface tategaki-diagnostics-warning
  '((t (:inherit warning :underline t))) "Diagnostic warning face."
  :group 'tategaki-diagnostics)
(defface tategaki-diagnostics-info
  '((t (:inherit font-lock-doc-face :underline t))) "Diagnostic suggestion face."
  :group 'tategaki-diagnostics)

(defvar-local tategaki-diagnostics--overlays nil)
(defvar-local tategaki-diagnostics--source nil)
(defvar-local tategaki-diagnostics--filter nil)
(defvar-local tategaki-diagnostics-visible t
  "Whether source diagnostic faces are currently visible.")
(declare-function tategaki-studio-source-buffer "tategaki-studio" (&optional buffer))
(declare-function tategaki-proofread-run "tategaki-proofread" (&optional lightweight))
(defvar tategaki-proofread-truncated)

(defun tategaki-diagnostics-source-buffer ()
  "Return the manuscript associated with the current buffer."
  (cond ((buffer-live-p tategaki-diagnostics--source)
         tategaki-diagnostics--source)
        ((fboundp 'tategaki-studio-source-buffer)
         (tategaki-studio-source-buffer))
        (t (current-buffer))))

(defun tategaki-diagnostics--face (diagnostic)
  "Return the face for DIAGNOSTIC."
  (pcase (plist-get diagnostic :severity)
    ('error 'tategaki-diagnostics-error)
    ('warning 'tategaki-diagnostics-warning)
    (_ 'tategaki-diagnostics-info)))

(defun tategaki-diagnostics-get (&optional source buffer)
  "Return current diagnostics for SOURCE in BUFFER, or all sources.
Positions reflect edits made since publication.  Returned plists are copies."
  (with-current-buffer (or buffer (tategaki-diagnostics-source-buffer))
    (let (results)
      (dolist (overlay tategaki-diagnostics--overlays)
        (let ((item (overlay-get overlay 'tategaki-diagnostic)))
          (when (and (overlay-buffer overlay)
                     (or (null source) (equal source (plist-get item :source))))
            (setq item (copy-sequence item))
            (setq item (plist-put item :start (overlay-start overlay)))
            (setq item (plist-put item :end (overlay-end overlay)))
            (push item results))))
      (sort results (lambda (a b) (< (plist-get a :start) (plist-get b :start)))))))

(defun tategaki-diagnostics-clear (&optional source buffer)
  "Remove SOURCE diagnostics in BUFFER; nil SOURCE means all sources."
  (interactive)
  (with-current-buffer (or buffer (tategaki-diagnostics-source-buffer))
    (setq tategaki-diagnostics--overlays
          (cl-delete-if
           (lambda (overlay)
             (when (or (null source)
                       (equal source (plist-get (overlay-get overlay 'tategaki-diagnostic)
                                                :source)))
               (delete-overlay overlay)
               t))
           tategaki-diagnostics--overlays))))

(defun tategaki-diagnostics-set (source diagnostics &optional buffer)
  "Replace SOURCE diagnostics with DIAGNOSTICS in BUFFER.
Each plist has :start, :end, :severity, :code and :message.  Invalid ranges
are rejected before replacing existing diagnostics.  SOURCE is authoritative."
  (with-current-buffer (or buffer (tategaki-diagnostics-source-buffer))
    (save-restriction
      (widen)
      (dolist (item diagnostics)
        (unless (and (integer-or-marker-p (plist-get item :start))
                     (integer-or-marker-p (plist-get item :end))
                     (<= (point-min) (plist-get item :start)
                         (plist-get item :end) (point-max))
                     (stringp (plist-get item :message)))
          (error "Invalid diagnostic: %S" item)))
      (tategaki-diagnostics-clear source (current-buffer))
      (dolist (item diagnostics)
        (let* ((data (plist-put (copy-sequence item) :source source))
               (overlay (make-overlay (plist-get data :start)
                                      (plist-get data :end) nil nil nil)))
          (overlay-put overlay 'tategaki-diagnostic data)
          (overlay-put overlay 'evaporate t)
          (overlay-put overlay 'priority 80)
          (overlay-put overlay 'help-echo (plist-get data :message))
          (overlay-put overlay 'face (and tategaki-diagnostics-visible
                                          (tategaki-diagnostics--face data)))
          (push overlay tategaki-diagnostics--overlays)))))
  diagnostics)

(defun tategaki-diagnostics-set-visible (visible &optional buffer)
  "Show diagnostic faces when VISIBLE is non-nil in BUFFER."
  (with-current-buffer (or buffer (tategaki-diagnostics-source-buffer))
    (setq tategaki-diagnostics-visible visible)
    (dolist (overlay tategaki-diagnostics--overlays)
      (overlay-put overlay 'face
                   (and visible (tategaki-diagnostics--face
                                 (overlay-get overlay 'tategaki-diagnostic)))))))

(defun tategaki-diagnostics--visit (button)
  "Visit the manuscript position recorded on BUTTON."
  (let ((marker (button-get button 'tategaki-marker)))
    (unless (and (markerp marker) (buffer-live-p (marker-buffer marker)))
      (user-error "この原稿は閉じられています"))
    (pop-to-buffer (marker-buffer marker))
    (widen)
    (goto-char marker)))

(defun tategaki-diagnostics--release-markers ()
  "Release source markers owned by this diagnostics list."
  (let ((position (point-min)))
    (while (< position (point-max))
      (let ((marker (get-text-property position 'tategaki-marker)))
        (when (markerp marker) (set-marker marker nil)))
      (setq position (next-single-property-change
                      position 'tategaki-marker nil (point-max))))))

(defvar tategaki-diagnostics-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'tategaki-diagnostics-list)
    map))
(define-derived-mode tategaki-diagnostics-list-mode special-mode "校正"
  "List source diagnostics; RET or a click visits the source."
  (add-hook 'kill-buffer-hook #'tategaki-diagnostics--release-markers nil t))

;;;###autoload
(defun tategaki-diagnostics-list (&optional source)
  "Run full proofreading and show diagnostics, optionally filtering SOURCE."
  (interactive)
  (let* ((manuscript (tategaki-diagnostics-source-buffer))
         (filter (or source tategaki-diagnostics--filter))
         (items (with-current-buffer manuscript
                  (require 'tategaki-proofread)
                  (tategaki-proofread-run)
                  (tategaki-diagnostics-get filter manuscript)))
         (truncated (buffer-local-value 'tategaki-proofread-truncated manuscript))
         (output (get-buffer-create (format "*Tategaki 校正: %s*"
                                            (buffer-name manuscript)))))
    (with-current-buffer output
      (let ((inhibit-read-only t))
        (tategaki-diagnostics--release-markers)
        (erase-buffer)
        (tategaki-diagnostics-list-mode)
        (tategaki-pane-install manuscript nil "校正")
        (setq tategaki-diagnostics--source manuscript
              tategaki-diagnostics--filter filter)
        (insert (format "%s — %d 件\n\n" (buffer-name manuscript) (length items)))
        (when truncated
          (insert "指摘数の上限に達しました。上限を増やすと残りも確認できます。\n\n"))
        (dolist (item items)
          (let* ((position (plist-get item :start))
                 (marker (with-current-buffer manuscript (copy-marker position)))
                 (line (with-current-buffer manuscript
                         (save-restriction (widen) (line-number-at-pos position)))))
            (insert-text-button
             (format "%5d  %-7s %s" line (or (plist-get item :severity) 'info)
                     (plist-get item :message))
             'tategaki-marker marker 'follow-link t
             'help-echo (format "%s [%s]" (plist-get item :source)
                                (or (plist-get item :code) ""))
             'action #'tategaki-diagnostics--visit)
            (insert "\n")))
        (when (null items) (insert "指摘はありません。\n"))
        (goto-char (point-min))))
    (pop-to-buffer output)
    output))

(provide 'tategaki-diagnostics)
;;; tategaki-diagnostics.el ends here
