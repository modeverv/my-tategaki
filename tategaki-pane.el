;;; tategaki-pane.el --- Visible close controls for Studio panes -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:

(defvar-local tategaki-pane-source nil
  "Manuscript to focus after this pane closes.")
(defvar-local tategaki-pane-close-function nil
  "Optional pane-specific close command, called in the clicked pane.")
(defvar-local tategaki-pane--original-header nil)
(defvar-local tategaki-pane--installed-header nil)

(defvar tategaki-pane-header-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'tategaki-pane-close)
    (define-key map [mouse-1] #'tategaki-pane-close)
    map)
  "Mouse bindings used only by the pane's close control.")

(defun tategaki-pane-install (&optional source close-function label)
  "Add a persistent close control to this pane, retaining its existing header.
SOURCE is the originating manuscript.  CLOSE-FUNCTION can implement save
prompts or cleanup; nil hides the pane without killing its buffer.  LABEL
names the pane when it has no existing header.  Repeated calls are safe."
  (unless (eq header-line-format tategaki-pane--installed-header)
    (setq tategaki-pane--original-header header-line-format))
  (setq-local tategaki-pane-source source)
  (setq-local tategaki-pane-close-function close-function)
  (setq-local tategaki-pane--installed-header
              (list " " (propertize "[閉じる]" 'face 'link 'mouse-face 'highlight
                                    'help-echo "このペインを閉じて原稿へ戻る"
                                    'local-map tategaki-pane-header-map)
                    "  " (or tategaki-pane--original-header label "")))
  (setq-local header-line-format tategaki-pane--installed-header))

(defun tategaki-pane-close (&optional event)
  "Close the pane at mouse EVENT, or the selected pane, and return to its source.
A custom close command may keep the pane open to ask about unsaved changes.
Ordinary panes are hidden, never killed, so editable copies remain intact."
  (interactive (list (when (mouse-event-p last-input-event) last-input-event)))
  (let* ((window (if event (posn-window (event-start event)) (selected-window)))
         (panel (and (window-live-p window) (window-buffer window))))
    (unless (and panel (buffer-local-value 'tategaki-pane--installed-header panel))
      (user-error "閉じるペインがありません"))
    (let ((source (buffer-local-value 'tategaki-pane-source panel))
          (close (buffer-local-value 'tategaki-pane-close-function panel))
          (frame (window-frame window)))
      (select-window window)
      (with-current-buffer panel
        (if close
            (if (commandp close) (call-interactively close) (funcall close))
          (quit-window nil window)))
      ;; Settings can remain visible while the user chooses Save or Discard.
      (unless (and (window-live-p window) (eq (window-buffer window) panel))
        (when (buffer-live-p source)
          (let ((source-window (get-buffer-window source frame)))
            (when (window-live-p source-window) (select-window source-window))))))))

(provide 'tategaki-pane)
;;; tategaki-pane.el ends here
