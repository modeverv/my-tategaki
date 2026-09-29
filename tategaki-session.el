;;; tategaki-session.el --- Resume a manuscript without replacing text -*- lexical-binding: t; -*-

;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; Only navigation and display state is saved here.  Dirty text belongs to
;; ordinary Emacs buffers and independent history snapshots, never this file.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tategaki-history)
(require 'tategaki-manuscript)
(require 'tategaki-typeset)

(defgroup tategaki-session nil "Resume manuscript editing." :group 'text)
(defcustom tategaki-session-file
  (expand-file-name "my-tategaki/session.json"
                    (or (getenv "XDG_STATE_HOME") "~/.local/state/"))
  "File containing recent manuscript locations and display settings."
  :type 'file :group 'tategaki-session)
(defcustom tategaki-session-recent-limit 30
  "Maximum number of recent manuscripts retained."
  :type 'natnum :group 'tategaki-session)
(defcustom tategaki-session-startup-action nil
  "Optional action after Emacs starts.
Nil leaves the normal startup unchanged.  `welcome' shows the Studio start
screen; `resume' opens the last available manuscript at its saved position.
Only navigation is restored; unsaved text remains in separate history copies."
  :type '(choice (const :tag "Normal Emacs startup" nil)
                 (const :tag "Show Studio welcome" welcome)
                 (const :tag "Resume last manuscript" resume))
  :group 'tategaki-session)
(defvar-local tategaki-session-restored-page nil
  "Last saved page, retained as navigation context after restoration.")
(defvar-local tategaki-session-active-chapter nil
  "Last saved chapter title, retained when the document has since changed.")
(defvar tategaki--page)
(defvar tategaki--scroll-start)
(defvar tategaki--text-scale-amount)
(defvar tategaki-outline--buffer)
(defvar tategaki-studio-state)
(defvar tategaki-studio-mode)
(defvar tategaki-reader--saved)
(declare-function tategaki--text-scale-apply "tategaki" ())
(declare-function tategaki-refresh "tategaki" ())
(declare-function tategaki-outline "tategaki-outline" (&optional close))
(declare-function tategaki-studio-mode "tategaki-studio" (&optional arg))
(declare-function tategaki-studio-set-state "tategaki-studio" (state))
(declare-function tategaki-studio-source-buffer "tategaki-studio" ())
(declare-function tategaki-studio-welcome "tategaki-studio" ())

(defun tategaki-session--read ()
  "Read session data, refusing to overwrite malformed existing data."
  (let ((data (tategaki-history--read-json tategaki-session-file)))
    (when (and (file-exists-p tategaki-session-file)
               (not (and (listp data) (eq (alist-get 'version data) 1)
                         (listp (alist-get 'sessions data)))))
      (user-error "Invalid session file: %s" tategaki-session-file))
    data))

(defun tategaki-session-recent-files (&optional limit)
  "Return up to LIMIT existing manuscript filenames, most recent first."
  (condition-case error-data
      (let ((files (cl-loop for record in (alist-get 'sessions (tategaki-session--read))
                            for file = (alist-get 'file record)
                            when (and (stringp file) (not (file-remote-p file))
                                      (file-regular-p file)) collect file)))
        (seq-take files (or limit tategaki-session-recent-limit)))
    (error (message "Recent manuscripts unavailable: %s" (error-message-string error-data))
           nil)))

(defun tategaki-session--editing-value (symbol reader &optional default)
  "Return SYMBOL's editing value before READER, or DEFAULT if unbound.
READER is the active Reader's saved state, or nil.  Its local entries keep
nil values and inherited defaults distinct from absent snapshot entries."
  (let ((entry (assq symbol (plist-get reader :locals))))
    (cond (entry (if (nth 2 entry) (nth 3 entry) default))
          ((boundp symbol) (symbol-value symbol))
          (t default))))

(defun tategaki-session--capture ()
  "Capture editing data, excluding any temporary Reader display state."
  (let* ((reader (bound-and-true-p tategaki-reader--saved))
         (position (if reader (plist-get reader :point) (point)))
         (saved-mark (if reader (plist-get reader :mark) (mark t)))
         (saved-mark-active (if reader (plist-get reader :mark-active) mark-active))
         (stats (condition-case nil
                    (save-excursion
                      (save-restriction
                        (widen)
                        (goto-char (max (point-min) (min (point-max) position)))
                        (tategaki-manuscript-statistics)))
                  (error nil)))
         (scroll (tategaki-session--editing-value 'tategaki--scroll-start reader))
         (size (tategaki-session--editing-value 'tategaki-manuscript-size reader))
         (outline (if (plist-member reader :outline-visible)
                      (plist-get reader :outline-visible)
                    (and (boundp 'tategaki-outline--buffer)
                         (buffer-live-p tategaki-outline--buffer)
                         (get-buffer-window tategaki-outline--buffer)))))
    `((file . ,(and buffer-file-name (expand-file-name buffer-file-name)))
      (buffer . ,(buffer-name))
      (saved_at . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z"))
      (point . ,position) (mark . ,saved-mark)
      (mark_active . ,(if saved-mark-active t :json-false))
      (page . ,(tategaki-session--editing-value 'tategaki--page reader 0))
      (scroll_start . ,(if (markerp scroll) (marker-position scroll) scroll))
      (text_scale . ,(tategaki-session--editing-value 'tategaki--text-scale-amount reader 0))
      (manuscript_size . ,(and size (vector (car size) (cdr size))))
      (spread . ,(if (tategaki-session--editing-value 'tategaki-manuscript-spread reader)
                     t :json-false))
      (fit_window . ,(if (tategaki-session--editing-value 'tategaki-manuscript-fit-window reader)
                         t :json-false))
      (grid . ,(if (tategaki-session--editing-value 'tategaki-manuscript-grid reader)
                   t :json-false))
      (typesetting . ,(if (tategaki-session--editing-value 'tategaki-typesetting reader)
                          t :json-false))
      (studio . ,(if (bound-and-true-p tategaki-studio-mode) t :json-false))
      (state . ,(if (eq (tategaki-session--editing-value 'tategaki-studio-state reader) 'review)
                    "review" "write"))
      (outline . ,(if outline t :json-false))
      (chapter . ,(plist-get stats :chapter-title))
      (history_document . ,(tategaki-history--id)))))

;;;###autoload
(defun tategaki-session-save (&optional buffer)
  "Save BUFFER's navigation/display state without saving its text.
Fileless buffers have snapshots but cannot be reopened after Emacs exits."
  (interactive)
  (with-current-buffer (or buffer (tategaki-history--source-buffer))
    (let* ((data (tategaki-session--read))
           (record (tategaki-session--capture))
           (file (alist-get 'file record))
           (existing (alist-get 'sessions data)))
      (when file
        (setq existing (cl-remove file existing :key (lambda (item) (alist-get 'file item))
                                  :test #'equal))
        (tategaki-history--write-json
         tategaki-session-file
         `((version . 1)
           (sessions . ,(vconcat (seq-take (cons record existing)
                                          (max 1 tategaki-session-recent-limit)))))))
      (when (called-interactively-p 'interactive)
        (message (if file "執筆位置を保存しました" "執筆位置を復元するには原稿をファイルに保存してください")))
      record)))

(defun tategaki-session--valid-position (value)
  "Return VALUE clamped to this buffer, or nil for invalid input."
  (and (integerp value) (max (point-min) (min (point-max) value))))

(defun tategaki-session--true-p (value)
  "Interpret only literal JSON/Elisp true VALUE as enabled."
  (eq value t))

(defun tategaki-session--apply (record)
  "Apply validated fields in RECORD to this buffer without touching its text."
  (let* ((size (alist-get 'manuscript_size record))
         (size (if (vectorp size) (append size nil) size))
         (scale (alist-get 'text_scale record))
         (page (alist-get 'page record))
         (chapter (alist-get 'chapter record))
         (history-id (alist-get 'history_document record)))
    (when (and (tategaki-session--true-p (alist-get 'studio record))
               (display-graphic-p) (require 'tategaki-studio nil t))
      (tategaki-studio-mode 1))
    (when (or (null size)
              (and (proper-list-p size) (= (length size) 2)
                   (cl-every (lambda (n) (and (integerp n) (> n 0) (<= n 1000))) size)))
      (setq-local tategaki-manuscript-size (and size (cons (car size) (cadr size)))))
    (setq-local tategaki-manuscript-spread (tategaki-session--true-p (alist-get 'spread record)))
    (when (assq 'fit_window record)
      (setq-local tategaki-manuscript-fit-window
                  (tategaki-session--true-p (alist-get 'fit_window record))))
    (setq-local tategaki-manuscript-grid (tategaki-session--true-p (alist-get 'grid record)))
    (setq-local tategaki-typesetting (tategaki-session--true-p (alist-get 'typesetting record)))
    (when (and (numberp scale) (<= -20 scale) (<= scale 20))
      (setq-local tategaki--text-scale-amount scale)
      (when (and (bound-and-true-p tategaki-mode) (fboundp 'tategaki--text-scale-apply))
        (tategaki--text-scale-apply)))
    (when (and (integerp page) (>= page 0))
      (setq-local tategaki--page page)
      (setq tategaki-session-restored-page page))
    (when (stringp chapter) (setq tategaki-session-active-chapter chapter))
    (when (and (stringp history-id)
               (string-match-p "\\`[[:xdigit:]]\\{64\\}\\'" history-id))
      (setq-local tategaki-history--document-id history-id))
    (save-restriction
      (widen)
      (when-let* ((position (tategaki-session--valid-position (alist-get 'point record))))
        (goto-char position))
      (set-marker (mark-marker) (tategaki-session--valid-position (alist-get 'mark record)))
      (setq mark-active (and (mark t) (tategaki-session--true-p (alist-get 'mark_active record))))
      (let ((scroll (alist-get 'scroll_start record)))
        ;; This is a zero-based visual column, not a source character position.
        (setq-local tategaki--scroll-start
                    (and (integerp scroll) (>= scroll 0) scroll))))
    (let ((state (if (equal (alist-get 'state record) "review") 'review 'write)))
      (if (and (bound-and-true-p tategaki-studio-mode) (fboundp 'tategaki-studio-set-state))
          (tategaki-studio-set-state state)
        (setq-local tategaki-studio-state state)))
    (when (and (bound-and-true-p tategaki-mode) (fboundp 'tategaki-refresh))
      (tategaki-refresh))
    (when (and (assq 'outline record) (require 'tategaki-outline nil t))
      ;; Apply both states after the Studio layout: Write can retain an open
      ;; outline, while entering Review may have opened one by default.
      ;; Missing keys in older records leave the existing layout alone.
      (save-selected-window
        (tategaki-outline (not (tategaki-session--true-p (alist-get 'outline record))))))))

;;;###autoload
(defun tategaki-session-restore (&optional record)
  "Open RECORD's file and restore navigation/display state.
With no RECORD, choose a saved manuscript.  Existing dirty buffers are reused
without reverting or replacing their text.  Session files contain JSON data,
never Lisp to evaluate."
  (interactive)
  (unless record
    (let* ((records (alist-get 'sessions (tategaki-session--read)))
           (choices (cl-loop for item in records for file = (alist-get 'file item)
                             when (stringp file) collect (cons file item))))
      (unless choices (user-error "保存済みの執筆セッションがありません"))
      (setq record (cdr (assoc (completing-read "再開する原稿: " choices nil t) choices)))))
  (let ((file (and (listp record) (alist-get 'file record))))
    (unless (and (stringp file) (file-name-absolute-p file) (not (file-remote-p file)))
      (user-error "Session must refer to an absolute local manuscript filename"))
    (unless (or (get-file-buffer file) (file-readable-p file))
      (user-error "保存した原稿が見つかりません: %s" file))
    (let ((buffer (find-file-noselect file)))
      (pop-to-buffer buffer)
      (with-current-buffer buffer (tategaki-session--apply record))
      buffer)))

;;;###autoload
(defun tategaki-session-open-last ()
  "Resume the most recently saved available manuscript."
  (interactive)
  (let ((record (cl-find-if
                 (lambda (item)
                   (let ((file (alist-get 'file item)))
                     (and (stringp file) (not (file-remote-p file))
                          (or (get-file-buffer file) (file-readable-p file)))))
                 (alist-get 'sessions (tategaki-session--read)))))
    (unless record (user-error "再開できる原稿がありません"))
    (tategaki-session-restore record)))

(defun tategaki-session--save-on-exit ()
  "Persist active Studio sessions before Emacs terminates.
Keep unsaved manuscripts in independent history snapshots when history is
enabled.  Never save their visiting files or change their modified state."
  (let* ((preferred (and (fboundp 'tategaki-studio-source-buffer)
                         (ignore-errors (tategaki-studio-source-buffer))))
         (buffers (buffer-list)))
    ;; The manuscript used at shutdown should remain first in recent files.
    (when (memq preferred buffers)
      (setq buffers (append (delq preferred buffers) (list preferred))))
    (dolist (buffer buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (bound-and-true-p tategaki-studio-mode)
            (condition-case error-data
                (progn
                  (when (and (buffer-modified-p)
                             (bound-and-true-p tategaki-history-mode)
                             tategaki-history-enabled)
                    (tategaki-history-snapshot 'exit))
                  (tategaki-session-save buffer))
              (error (message "Studio: 終了時の保存失敗 (%s): %s"
                              (buffer-name) (error-message-string error-data))))))))))

(defun tategaki-session--startup ()
  "Perform the explicitly configured Studio startup action."
  (when (and (not noninteractive) tategaki-session-startup-action)
    (condition-case error-data
        (pcase tategaki-session-startup-action
          ('welcome (require 'tategaki-studio) (tategaki-studio-welcome))
          ('resume (tategaki-session-open-last)))
      (error (message "Studio: 前回の作業を開けません: %s"
                      (error-message-string error-data))))))

(add-hook 'kill-emacs-hook #'tategaki-session--save-on-exit)
(add-hook 'emacs-startup-hook #'tategaki-session--startup t)

(provide 'tategaki-session)
;;; tategaki-session.el ends here
