;;; tategaki-ime.el --- Native IME preedit for vertical text -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Capture the NS input method's display strings without inserting them into
;; the source buffer.  The renderer consumes the propertized text and insertion
;; position below.  NS still owns its overlay and all commit/cancel behavior.

;;; Code:

(require 'cl-lib)

(defvar ns-working-overlay)
(defvar mac-in-echo-area)
(defvar mac-ime-panel-offset-x)
(defvar mac-ime-panel-offset-y)

(defvar-local tategaki-ime--enabled nil)
(defvar-local tategaki-ime--text nil
  "Native preedit string, including its original face properties.")
(defvar-local tategaki-ime--position nil
  "Source position at which the native preedit string is displayed.")
(defvar-local tategaki-ime--selection nil
  "Selected preedit span as (START . LENGTH), or nil for working text.")
(defvar-local tategaki-ime--window nil
  "Window displaying the vertical version of the native preedit.")
(defvar-local tategaki-ime-update-function nil
  "Function called with no arguments after native preedit changes.")
(defvar-local tategaki-ime--native-overlay nil)
(defvar-local tategaki-ime--native-before nil)
(defvar-local tategaki-ime--native-after nil)
(defvar-local tategaki-ime--mirrors nil)
(defvar-local tategaki-ime--panel-offset nil
  "Relative candidate-panel correction as (X . Y), in logical pixels.")
(defvar-local tategaki-ime--panel-original nil
  "Original panel bindings as (SYMBOL LOCAL-P VALUE) entries.")

(defvar tategaki-ime--buffers nil)
(defvar tategaki-ime--updating nil)
(defvar tategaki-ime--pending-buffers nil)

(defconst tategaki-ime--advice
  '((ns-insert-working-text . tategaki-ime--around-working-text)
    (ns-insert-marked-text . tategaki-ime--around-marked-text)
    (ns-delete-working-text . tategaki-ime--around-delete-text)
    (ns-in-echo-area . tategaki-ime--around-in-echo-area)))

(defun tategaki-ime--around-in-echo-area (original &rest args)
  "Keep native preedit in the vertical owner window when calling ORIGINAL.
The source is hidden under a display layer, which NS otherwise treats as
a reason to move preedit into the echo area.  Real echo-area interaction
and other windows retain the native decision with ARGS."
  (if (and tategaki-ime--enabled
           (eq (selected-window) tategaki-ime--window)
           (eq (window-buffer (selected-window)) (current-buffer))
           (not (minibufferp))
           (not (bound-and-true-p isearch-mode))
           (not (and cursor-in-echo-area (current-message))))
      (setq mac-in-echo-area nil)
    (apply original args)))

(defun tategaki-ime--delete-mirrors ()
  "Remove this buffer's copies of the native display overlay."
  (mapc #'delete-overlay tategaki-ime--mirrors)
  (setq tategaki-ime--mirrors nil))

(defun tategaki-ime--restore-panel-offset (&optional forget)
  "Restore original candidate-panel bindings; FORGET also drops geometry."
  (dolist (entry tategaki-ime--panel-original)
    (if (nth 1 entry)
        (set (make-local-variable (car entry)) (nth 2 entry))
      (kill-local-variable (car entry))))
  (setq tategaki-ime--panel-original nil)
  (when forget
    (setq tategaki-ime--panel-offset nil)))

(defun tategaki-ime--sync-panel-offset ()
  "Apply the candidate correction only while its owner window is selected."
  (if (and tategaki-ime--enabled tategaki-ime--panel-offset
           (stringp tategaki-ime--text) (> (length tategaki-ime--text) 0)
           (eq (selected-window) tategaki-ime--window)
           (eq (window-buffer (selected-window)) (current-buffer))
           (boundp 'mac-ime-panel-offset-x)
           (boundp 'mac-ime-panel-offset-y)
           (integerp mac-ime-panel-offset-x)
           (integerp mac-ime-panel-offset-y))
      (progn
        (unless tategaki-ime--panel-original
          (setq tategaki-ime--panel-original
                (mapcar (lambda (symbol)
                          (list symbol (local-variable-p symbol)
                                (symbol-value symbol)))
                        '(mac-ime-panel-offset-x mac-ime-panel-offset-y))))
        (cl-mapc (lambda (entry offset)
                   (set (make-local-variable (car entry))
                        (+ (nth 2 entry) offset)))
                 tategaki-ime--panel-original
                 (list (car tategaki-ime--panel-offset)
                       (cdr tategaki-ime--panel-offset))))
    (tategaki-ime--restore-panel-offset)))

(defun tategaki-ime-set-panel-offset (x y)
  "Set the native candidate-panel correction to X and Y logical pixels.
Positive X moves right and positive Y moves down.  Preserve the user's
original offsets and apply this correction only to the selected vertical
owner during preedit.  Native implementations without panel offsets are
left untouched.  The correction is restored when composition ends."
  (cl-check-type x integer)
  (cl-check-type y integer)
  (when tategaki-ime--enabled
    (setq tategaki-ime--panel-offset (cons x y))
    (tategaki-ime--sync-panel-offset)))

(defun tategaki-ime--restore-native ()
  "Restore the original display strings if NS still owns a live overlay."
  (tategaki-ime--restore-panel-offset t)
  (tategaki-ime--delete-mirrors)
  (when (and (overlayp tategaki-ime--native-overlay)
             (overlay-buffer tategaki-ime--native-overlay))
    (overlay-put tategaki-ime--native-overlay
                 'before-string tategaki-ime--native-before)
    (overlay-put tategaki-ime--native-overlay
                 'after-string tategaki-ime--native-after)))

(defun tategaki-ime-sync-window (&optional window)
  "Display captured preedit vertically in WINDOW, preserving other windows.
When WINDOW is nil, use the existing `tategaki-ime--window'.  This function
only changes display overlays; it does not request another render."
  (when window
    (setq tategaki-ime--window window))
  (tategaki-ime--sync-panel-offset)
  (tategaki-ime--delete-mirrors)
  (when (and tategaki-ime--enabled
             (overlayp tategaki-ime--native-overlay)
             (eq (overlay-buffer tategaki-ime--native-overlay)
                 (current-buffer)))
    (if (and (window-live-p tategaki-ime--window)
             (eq (window-buffer tategaki-ime--window) (current-buffer)))
        (progn
          (overlay-put tategaki-ime--native-overlay 'before-string nil)
          (overlay-put tategaki-ime--native-overlay 'after-string nil)
          (let ((native-window
                 (overlay-get tategaki-ime--native-overlay 'window)))
            (dolist (other (get-buffer-window-list (current-buffer) nil t))
              (when (and (not (eq other tategaki-ime--window))
                         (or (null native-window) (eq native-window other)))
                (let ((mirror (copy-overlay tategaki-ime--native-overlay)))
                  (overlay-put mirror 'window other)
                  (overlay-put mirror 'before-string tategaki-ime--native-before)
                  (overlay-put mirror 'after-string tategaki-ime--native-after)
                  (push mirror tategaki-ime--mirrors))))))
      (tategaki-ime--restore-native))))

(defun tategaki-ime--notify ()
  "Notify the renderer of this buffer's preedit state."
  (when (and tategaki-ime--enabled tategaki-ime-update-function)
    (condition-case err
        (funcall tategaki-ime-update-function)
      (error
       ;; A renderer error must not leave a user's composition invisible.
       (tategaki-ime--restore-native)
       (message "Tategaki IME: %s" (error-message-string err))))))

(defun tategaki-ime--queue-update ()
  "Notify now, or defer notification until a native update is complete."
  (if tategaki-ime--updating
      (cl-pushnew (current-buffer) tategaki-ime--pending-buffers)
    (tategaki-ime--notify)))

(defun tategaki-ime--clear ()
  "Clear this buffer's preedit snapshot after NS removes its overlay."
  (let ((had-state (or tategaki-ime--text tategaki-ime--native-overlay)))
    (tategaki-ime--restore-panel-offset t)
    (tategaki-ime--delete-mirrors)
    (setq tategaki-ime--text nil
          tategaki-ime--position nil
          tategaki-ime--selection nil
          tategaki-ime--native-overlay nil
          tategaki-ime--native-before nil
          tategaki-ime--native-after nil)
    (when had-state
      (tategaki-ime--queue-update))))

(defun tategaki-ime--capture (selection)
  "Capture native overlay text and the selected preedit span SELECTION."
  (when tategaki-ime--enabled
    (if (and (boundp 'ns-working-overlay)
             (overlayp ns-working-overlay)
             (eq (overlay-buffer ns-working-overlay) (current-buffer)))
        (let ((before (overlay-get ns-working-overlay 'before-string))
              (after (overlay-get ns-working-overlay 'after-string)))
          (setq tategaki-ime--native-overlay ns-working-overlay
                tategaki-ime--native-before before
                tategaki-ime--native-after after
                tategaki-ime--text (concat before after)
                tategaki-ime--position (overlay-start ns-working-overlay)
                tategaki-ime--selection selection)
          (tategaki-ime-sync-window)
          (tategaki-ime--queue-update))
      (tategaki-ime--clear))))

(defun tategaki-ime--insert (original args selection)
  "Call native insertion ORIGINAL with ARGS, then capture SELECTION.
Native insertion calls native deletion first.  Defer that intermediate
notification so the renderer sees only the completed preedit update."
  (let ((tategaki-ime--updating t)
        (tategaki-ime--pending-buffers nil))
    (unwind-protect
        (apply original args)
      (tategaki-ime--capture selection)
      (dolist (buffer tategaki-ime--pending-buffers)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (tategaki-ime--notify)))))))

(defun tategaki-ime--around-working-text (original &rest args)
  "Capture working text after calling ORIGINAL with ARGS."
  (tategaki-ime--insert original args nil))

(defun tategaki-ime--around-marked-text (original from length &rest args)
  "Capture marked text after calling ORIGINAL with FROM, LENGTH and ARGS."
  (tategaki-ime--insert original (append (list from length) args)
                        (cons from length)))

(defun tategaki-ime--around-delete-text (original &rest args)
  "Clear the captured state after native deletion ORIGINAL with ARGS."
  (let ((owner (and (boundp 'ns-working-overlay)
                    (overlayp ns-working-overlay)
                    (overlay-buffer ns-working-overlay))))
    (prog1 (apply original args)
      (when (buffer-live-p owner)
        (with-current-buffer owner
          (when tategaki-ime--enabled
            (tategaki-ime--clear)))))))

(defun tategaki-ime--install-advice ()
  "Install available NS adapters when at least one buffer participates."
  (when tategaki-ime--buffers
    (dolist (entry tategaki-ime--advice)
      (when (and (fboundp (car entry))
                 (not (advice-member-p (cdr entry) (car entry))))
        (advice-add (car entry) :around (cdr entry))))))

(defun tategaki-ime--windows-changed (&optional _window-or-frame)
  "Keep native preedit and panel offsets scoped to their owner windows."
  (dolist (buffer tategaki-ime--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (tategaki-ime--sync-panel-offset)
        (when tategaki-ime--text
          (tategaki-ime-sync-window))))))

(defun tategaki-ime-enable (&optional update-function window)
  "Capture native preedit in this buffer for vertical rendering.
UPDATE-FUNCTION runs with no arguments when the snapshot changes.  WINDOW
is the window that displays the vertical preedit, defaulting to selected."
  (when update-function
    (setq tategaki-ime-update-function update-function))
  (setq tategaki-ime--enabled t
        tategaki-ime--window (or window (selected-window)))
  (cl-pushnew (current-buffer) tategaki-ime--buffers)
  (add-hook 'kill-buffer-hook #'tategaki-ime-disable nil t)
  (add-hook 'change-major-mode-hook #'tategaki-ime-disable nil t)
  (add-hook 'window-configuration-change-hook #'tategaki-ime--windows-changed)
  (add-hook 'window-selection-change-functions #'tategaki-ime--windows-changed)
  (add-hook 'window-buffer-change-functions #'tategaki-ime--windows-changed)
  (tategaki-ime--install-advice)
  (if tategaki-ime--native-overlay
      (tategaki-ime-sync-window)
    (when (and (boundp 'ns-working-overlay)
               (overlayp ns-working-overlay)
               (eq (overlay-buffer ns-working-overlay) (current-buffer)))
      (tategaki-ime--capture nil))))

(defun tategaki-ime-disable ()
  "Stop capturing this buffer's preedit and restore native display.
The active composition remains owned by NS; disabling does not commit,
cancel, or change the source buffer.  No render callback runs here."
  (setq tategaki-ime--enabled nil)
  (tategaki-ime--restore-native)
  (tategaki-ime--clear)
  (setq tategaki-ime--window nil
        tategaki-ime-update-function nil
        tategaki-ime--buffers (delq (current-buffer) tategaki-ime--buffers))
  (remove-hook 'kill-buffer-hook #'tategaki-ime-disable t)
  (remove-hook 'change-major-mode-hook #'tategaki-ime-disable t)
  (unless tategaki-ime--buffers
    (remove-hook 'window-configuration-change-hook
                 #'tategaki-ime--windows-changed)
    (remove-hook 'window-selection-change-functions
                 #'tategaki-ime--windows-changed)
    (remove-hook 'window-buffer-change-functions
                 #'tategaki-ime--windows-changed)
    (dolist (entry tategaki-ime--advice)
      (when (fboundp (car entry))
        (advice-remove (car entry) (cdr entry))))))

(with-eval-after-load 'ns-win
  (tategaki-ime--install-advice))

(provide 'tategaki-ime)
;;; tategaki-ime.el ends here
