;;; tategaki-lookup.el --- Lookup dictionaries beside the manuscript -*- lexical-binding: t; -*-

;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; Lookup remains optional.  Its own dictionary agents and entry links are
;; used unchanged; its result buffers are displayed alongside the manuscript.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'thingatpt)
(require 'tategaki-pane)

(defgroup tategaki-lookup nil "Dictionary consultation in Studio." :group 'text)
(defcustom tategaki-lookup-window-width 0.35
  "Width of dictionary side windows, in columns or fraction of the frame."
  :type 'number :group 'tategaki-lookup)
(defvar lookup-content-buffer)
(defvar lookup-entry-buffer)
(defvar lookup-select-buffer)
(defvar lookup-help-buffer)
(defvar lookup-buffer-list)
(defvar lookup-current-session)
(defvar lookup-last-session)
(defvar lookup-main-window)
(defvar lookup-sub-window)
(defvar lookup-start-window)
(defvar lookup-open-function)
(defvar lookup-save-configuration)
(defvar tategaki-studio-source)
(declare-function lookup-pattern "lookup" (pattern &optional module))
(declare-function lookup-hide-buffer "lookup" (buffer))

(defvar tategaki-lookup--active-context nil)
(defvar-local tategaki-lookup--context nil)
(defvar-local tategaki-lookup--source-context nil)
;; Lookup's Content renderer explicitly kills locals before setting its mode.
(put 'tategaki-lookup--context 'permanent-local t)

(defun tategaki-lookup--new-context (source)
  "Create independent Lookup buffers and window state for SOURCE."
  (list :source source :frame (selected-frame) :buffers nil :names nil
        :main nil :sub nil :current-session nil :last-session nil
        :entry (generate-new-buffer-name (format "*Studio Lookup Entry: %s*" (buffer-name source)))
        :content (generate-new-buffer-name (format "*Studio Lookup Content: %s*" (buffer-name source)))
        :select (generate-new-buffer-name (format "*Studio Lookup Dictionaries: %s*" (buffer-name source)))
        :help (generate-new-buffer-name (format "*Studio Lookup Help: %s*" (buffer-name source)))))

(defun tategaki-lookup--call (context function arguments)
  "Call FUNCTION with ARGUMENTS using CONTEXT's private Lookup state."
  (if (eq context tategaki-lookup--active-context)
      (apply function arguments)
    (let* ((tategaki-lookup--active-context context)
           (lookup-entry-buffer (plist-get context :entry))
           (lookup-content-buffer (plist-get context :content))
           (lookup-select-buffer (plist-get context :select))
           (lookup-help-buffer (plist-get context :help))
           (lookup-buffer-list (plist-get context :buffers))
           (lookup-main-window (and (window-live-p (plist-get context :main))
                                    (plist-get context :main)))
           (lookup-sub-window (and (window-live-p (plist-get context :sub))
                                   (plist-get context :sub)))
           (lookup-start-window (and (buffer-live-p (plist-get context :source))
                                      (get-buffer-window (plist-get context :source)
                                                         (plist-get context :frame))))
           (lookup-current-session (plist-get context :current-session))
           (lookup-last-session (plist-get context :last-session))
           (lookup-save-configuration nil))
      (unwind-protect (apply function arguments)
        (setf (plist-get context :main) (and (window-live-p lookup-main-window) lookup-main-window)
              (plist-get context :sub) (and (window-live-p lookup-sub-window) lookup-sub-window)
              (plist-get context :current-session) lookup-current-session
              (plist-get context :last-session) lookup-last-session)))))

(defun tategaki-lookup--around-command (function &rest arguments)
  "Confine Lookup commands originating in an owned pane to its context."
  (let ((context (or tategaki-lookup--active-context tategaki-lookup--context)))
    (if context (tategaki-lookup--call context function arguments)
      (apply function arguments))))

(defun tategaki-lookup--install-buffer (buffer context)
  "Attach a persistent close control to BUFFER belonging to CONTEXT."
  (cl-pushnew buffer (plist-get context :buffers))
  (with-current-buffer buffer
    (setq-local tategaki-lookup--context context)
    (setq-local tategaki-studio-source (plist-get context :source))
    (tategaki-pane-install (plist-get context :source) #'tategaki-lookup-close "辞書")
    ;; Copy, never modify Lookup's shared maps (or Help mode's shared map).
    (let ((map (copy-keymap (or (current-local-map) (make-sparse-keymap)))))
      (define-key map (kbd "q") #'tategaki-lookup-close)
      (use-local-map map)))
  buffer)

(defun tategaki-lookup--open-buffer (function name)
  "Namespace Lookup's buffer NAME only when called from a Studio pane."
  (let ((context (or tategaki-lookup--active-context tategaki-lookup--context)))
    (if (not context) (funcall function name)
      (let* ((known (mapcar (lambda (key) (plist-get context key)) '(:entry :content :select :help)))
             (private (if (member name known) name
                        (or (cdr (assoc name (plist-get context :names)))
                            (let ((new (generate-new-buffer-name
                                        (format "*Studio Lookup %s: %s*"
                                                (string-trim name "[ *]+" "[ *]+")
                                                (buffer-name (plist-get context :source))))))
                              (push (cons name new) (plist-get context :names)) new)))))
        (tategaki-lookup--call
         context (lambda () (tategaki-lookup--install-buffer (funcall function private) context)) nil)))))

(defun tategaki-lookup--show (buffer context slot &optional select)
  "Display owned BUFFER in CONTEXT's side SLOT; optionally SELECT it."
  (tategaki-lookup--install-buffer buffer context)
  (let ((window (display-buffer-in-side-window
                 buffer `((side . right) (slot . ,slot)
                          (window-width . ,tategaki-lookup-window-width)
                          ,@(when (= slot 3) '((window-height . 0.25)))))))
    (set-window-parameter window 'tategaki-lookup-context context)
    (cond ((= slot 3) (setq lookup-main-window window))
          ((= slot 4) (setq lookup-sub-window window)))
    (when select (select-window window))
    buffer))

(defun tategaki-lookup--display (function &optional buffer)
  "Wrap Lookup's main-buffer display, preserving ordinary Lookup behavior."
  (let ((context (or tategaki-lookup--active-context tategaki-lookup--context)))
    (if (not context) (funcall function buffer)
      (tategaki-lookup--call context #'tategaki-lookup--show
                            (list (get-buffer (or buffer (current-buffer))) context 3 t)))))

(defun tategaki-lookup--display-content (function buffer)
  "Keep content and entry-information buffers in their own Studio side pane."
  (let ((context (or tategaki-lookup--active-context tategaki-lookup--context)))
    (if (not context) (funcall function buffer)
      (tategaki-lookup--call context #'tategaki-lookup--show
                            (list (get-buffer buffer) context 4)))))

(defun tategaki-lookup--display-help (function buffer)
  "Display Lookup help beside the source instead of replacing its window."
  (let ((context (or tategaki-lookup--active-context tategaki-lookup--context)))
    (if (not context) (funcall function buffer)
      (tategaki-lookup--call context #'tategaki-lookup--show
                            (list (get-buffer buffer) context 5 t)))))

(defun tategaki-lookup--entry-window (function)
  "Reopen a closed Studio entry pane when Lookup Content asks to focus it."
  (let ((context (or tategaki-lookup--active-context tategaki-lookup--context)))
    (if (not context) (funcall function)
      (let ((entry (get-buffer (plist-get context :entry))))
        (unless entry (user-error "辞書の検索結果がありません。もう一度検索してください"))
        (tategaki-lookup--call context #'tategaki-lookup--show (list entry context 3 t))))))

(defun tategaki-lookup-close ()
  "Hide this Studio Lookup pane using Lookup's own window cleanup."
  (interactive)
  (unless tategaki-lookup--context (user-error "Studio の辞書ペインで操作してください"))
  (let* ((context tategaki-lookup--context) (buffer (current-buffer))
         (source (plist-get context :source)))
    (tategaki-lookup--call
     context (lambda ()
               (if (fboundp 'lookup-hide-buffer) (lookup-hide-buffer buffer)
                 (let ((window (get-buffer-window buffer)))
                   (when window (quit-window nil window))))) nil)
    (let ((window (and (buffer-live-p source)
                       (get-buffer-window source (plist-get context :frame)))))
      (when (window-live-p window) (select-window window)))))

(defun tategaki-lookup--advise-keymap (map)
  "Contextualize Lookup commands in MAP without changing the shared keymap."
  (map-keymap
   (lambda (_key command)
     (cond ((keymapp command) (tategaki-lookup--advise-keymap command))
           ((and (symbolp command) (string-prefix-p "lookup-" (symbol-name command)))
            (advice-add command :around #'tategaki-lookup--around-command)))) map))

(defun tategaki-lookup--install-advice ()
  "Install no-op-outside-Studio adapters for Lookup display and commands."
  (dolist (function '(lookup lookup-pattern lookup-session-display
                     lookup-entry-display lookup-entry-append lookup-entry-excursion
                     lookup-content-display lookup-select-display))
    (advice-add function :around #'tategaki-lookup--around-command))
  (advice-add 'lookup-open-buffer :around #'tategaki-lookup--open-buffer)
  (advice-add 'lookup-pop-to-buffer :around #'tategaki-lookup--display)
  (advice-add 'lookup-display-buffer :around #'tategaki-lookup--display-content)
  (advice-add 'lookup-display-help :around #'tategaki-lookup--display-help)
  (advice-add 'lookup-content-entry-window :around #'tategaki-lookup--entry-window)
  (dolist (map '(lookup-entry-mode-map lookup-content-mode-map lookup-select-mode-map))
    (when (and (boundp map) (keymapp (symbol-value map)))
      (tategaki-lookup--advise-keymap (symbol-value map)))))

(dolist (feature '(lookup lookup-entry lookup-content lookup-select))
  (eval-after-load feature #'tategaki-lookup--install-advice))

(defun tategaki-lookup--query ()
  "Choose active region, word at point, or an explicitly entered query."
  (or (and (use-region-p)
           (let ((text (string-trim (buffer-substring-no-properties
                                     (region-beginning) (region-end)))))
             (unless (string-empty-p text) text)))
      (let ((word (thing-at-point 'word t)))
        (and word (not (string-empty-p (string-trim word))) word))
      (read-string "辞書で調べる語: ")))

;;;###autoload
(defun tategaki-lookup-word (&optional query)
  "Consult Lookup for QUERY in a side window without moving source point.
Without QUERY, prefer active region, then word at point, then manual input.
Install and configure the existing Emacs Lookup package to use dictionaries."
  (interactive)
  (unless (require 'lookup nil t)
    (user-error "辞書には Emacs Lookup が必要です。Lookup を load-path に追加し、辞書を設定してください"))
  (unless (fboundp 'lookup-pattern)
    (user-error "この Lookup には lookup-pattern がありません"))
  (let* ((source (or (and (boundp 'tategaki-studio-source)
                           (buffer-live-p tategaki-studio-source) tategaki-studio-source)
                     (current-buffer)))
         (query (string-trim (or query (with-current-buffer source (tategaki-lookup--query)))))
         (context (with-current-buffer source
                    (or tategaki-lookup--source-context
                        (setq tategaki-lookup--source-context (tategaki-lookup--new-context source)))))
         content entries)
    (when (string-empty-p query) (user-error "検索する語を入力してください"))
    (with-current-buffer source
      (save-mark-and-excursion
        (save-selected-window
          (tategaki-lookup--call
           context
           (lambda ()
            (condition-case error-data
                (progn
                  (lookup-pattern query)
                  (setq content (and (boundp 'lookup-content-buffer)
                                     (get-buffer lookup-content-buffer)))
                  (setq entries (and (boundp 'lookup-entry-buffer)
                                     (get-buffer lookup-entry-buffer))))
              (error (user-error "Lookup: %s" (error-message-string error-data))))) nil))))
    (unless (or content entries) (user-error "Lookup は検索結果バッファを返しませんでした"))
    (save-selected-window
      (tategaki-lookup--call context
                            (lambda ()
                              (when entries (tategaki-lookup--show entries context 3))
                              (when content (tategaki-lookup--show content context 4))) nil))
    (or content entries)))

;;;###autoload
(defalias 'tategaki-lookup #'tategaki-lookup-word)

(provide 'tategaki-lookup)
;;; tategaki-lookup.el ends here
