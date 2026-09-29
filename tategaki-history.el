;;; tategaki-history.el --- Independent manuscript snapshots -*- lexical-binding: t; -*-

;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; Content-addressed UTF-8 snapshots never write to the manuscript.  The
;; manifest is replaced atomically after its snapshot has reached disk.

;;; Code:
(require 'tategaki-pane)

(require 'cl-lib)
(require 'json)
(require 'button)
(require 'subr-x)

(defgroup tategaki-history nil "Manuscript snapshots." :group 'text)
(defcustom tategaki-history-directory
  (expand-file-name "my-tategaki/history/"
                    (or (getenv "XDG_DATA_HOME") "~/.local/share/"))
  "Directory for snapshots, separate from manuscript files."
  :type 'directory :group 'tategaki-history)
(defcustom tategaki-history-enabled t
  "Whether Studio records save and idle snapshots in this buffer."
  :type 'boolean :group 'tategaki-history)
(defcustom tategaki-history-idle-interval 120
  "Idle seconds between snapshots, or nil for save snapshots only."
  :type '(choice (const :tag "Save only" nil) number)
  :group 'tategaki-history)
(make-variable-buffer-local 'tategaki-history-enabled)
(make-variable-buffer-local 'tategaki-history-idle-interval)

(defvar-local tategaki-history--document-id nil)
(defvar-local tategaki-history--timer nil)
(defvar-local tategaki-history--source nil)
(defvar-local tategaki-history--last-tick nil)
(defvar tategaki-history-mode)
(defvar tategaki-studio-source)
(declare-function tategaki-diff-buffers "tategaki-diff" (old new))

(defun tategaki-history--read-json (file)
  "Read FILE as data, returning nil when it does not exist.
Malformed existing files signal an error; they must not be overwritten."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (let ((json-object-type 'alist) (json-array-type 'list)
            (json-key-type 'symbol) (json-false nil) (json-null nil))
        (let ((data (json-read)))
          (skip-chars-forward " \t\r\n")
          (unless (eobp) (user-error "Unexpected content after JSON in %s" file))
          data)))))

(defun tategaki-history--atomic-write (file text)
  "Atomically write UTF-8 TEXT to FILE with private permissions."
  (let* ((directory (file-name-directory file)) temporary)
    (make-directory directory t)
    (setq temporary (make-temp-file (expand-file-name ".tategaki-" directory)))
    (unwind-protect
        (let ((coding-system-for-write 'utf-8-unix)
              (write-region-inhibit-fsync nil))
          (set-file-modes temporary #o600)
          (write-region text nil temporary nil 'silent)
          (rename-file temporary file t))
      (when (file-exists-p temporary) (delete-file temporary)))))

(defun tategaki-history--write-json (file data)
  "Atomically write JSON DATA to FILE."
  (let ((json-encoding-pretty-print t))
    (tategaki-history--atomic-write file (concat (json-encode data) "\n"))))

(defun tategaki-history--adopt-file-id (old-id new-id)
  "Carry unsaved or Save As history from OLD-ID into stable NEW-ID.
Leave the old archive intact until the new manifest is durable."
  (let* ((old (tategaki-history--manifest old-id))
         (new (tategaki-history--manifest new-id))
         (directory (tategaki-history--directory new-id))
         (entries (copy-tree (append (alist-get 'snapshots new)
                                     (alist-get 'snapshots old)))))
    (dolist (record (alist-get 'snapshots old))
      (let ((file (expand-file-name (alist-get 'file record) directory)))
        (unless (file-exists-p file)
          (tategaki-history--atomic-write file (tategaki-history--snapshot-text record)))))
    (when entries
      (dolist (record entries) (setf (alist-get 'document record) new-id))
      (setq entries (cl-stable-sort entries #'string>
                                    :key (lambda (record) (alist-get 'timestamp record))))
      (tategaki-history--write-json
       (expand-file-name "manifest.json" directory)
       `((version . 1) (document . ,new-id) (file . ,buffer-file-name)
         (buffer . ,(buffer-name)) (snapshots . ,(vconcat entries)))))))

(defun tategaki-history--id ()
  "Return a stable document identifier, carrying history across first save."
  (let ((file-id (and buffer-file-name
                      (secure-hash 'sha256 (expand-file-name buffer-file-name)))))
    (when (and file-id tategaki-history--document-id
               (not (equal file-id tategaki-history--document-id)))
      (tategaki-history--adopt-file-id tategaki-history--document-id file-id)
      (setq tategaki-history--document-id file-id))
    (or tategaki-history--document-id
        (setq tategaki-history--document-id
              (or file-id (secure-hash 'sha256
                                       (format "%s:%s:%s:%s" (emacs-pid) (current-time)
                                               (random) (buffer-name))))))))

(defun tategaki-history--directory (id)
  "Return the history directory for validated document ID."
  (unless (and (stringp id)
               (string-match-p "\\`[[:xdigit:]]\\{64\\}\\'" id))
    (user-error "Invalid history document identifier"))
  (expand-file-name (concat id "/") tategaki-history-directory))

(defun tategaki-history--manifest (id)
  "Read the manifest for document ID without accepting corrupt data."
  (let* ((file (expand-file-name "manifest.json" (tategaki-history--directory id)))
         (data (tategaki-history--read-json file)))
    (when (and (file-exists-p file)
               (not (and (listp data) (eq (alist-get 'version data) 1)
                         (equal (alist-get 'document data) id)
                         (listp (alist-get 'snapshots data))
                         (cl-every
                          (lambda (record)
                            (let ((sha (alist-get 'sha256 record)))
                              (and (equal (alist-get 'document record) id)
                                   (stringp sha)
                                   (string-match-p "\\`[[:xdigit:]]\\{64\\}\\'" sha)
                                   (equal (alist-get 'file record)
                                          (concat "snapshots/" sha ".txt"))
                                   (stringp (alist-get 'timestamp record))
                                   (natnump (alist-get 'characters record)))))
                          (alist-get 'snapshots data)))))
      (user-error "Invalid history manifest; existing history was preserved"))
    data))

;;;###autoload
(defun tategaki-history-snapshot (&optional reason buffer)
  "Snapshot BUFFER's complete text, including unsaved edits.
REASON is a label such as save, idle or manual.  Return the snapshot record.
Identical consecutive content adds no entry; older identical text reuses its
SHA-256 snapshot file.  Source text, undo and modified state stay intact."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (save-restriction
      (widen)
      (let* ((id (tategaki-history--id))
             (directory (tategaki-history--directory id))
             (manifest (tategaki-history--manifest id))
             (entries (alist-get 'snapshots manifest))
             (text (buffer-substring-no-properties (point-min) (point-max)))
             (sha (secure-hash 'sha256 (encode-coding-string text 'utf-8-unix)))
             (file (concat "snapshots/" sha ".txt"))
             (record (car entries)))
        (unless (equal sha (alist-get 'sha256 record))
          (unless (file-exists-p (expand-file-name file directory))
            (tategaki-history--atomic-write (expand-file-name file directory) text))
          (setq record `((document . ,id) (sha256 . ,sha) (file . ,file)
                         (timestamp . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z"))
                         (characters . ,(length text))
                         (reason . ,(format "%s" (or reason 'manual)))
                         (dirty . ,(if (buffer-modified-p) t :json-false))))
          (tategaki-history--write-json
           (expand-file-name "manifest.json" directory)
           `((version . 1) (document . ,id) (file . ,buffer-file-name)
             (buffer . ,(buffer-name)) (snapshots . ,(vconcat (cons record entries))))))
        (setq tategaki-history--last-tick (buffer-chars-modified-tick))
        (when (called-interactively-p 'interactive) (message "原稿の履歴を保存しました"))
        record))))

(defun tategaki-history--automatic-snapshot (reason buffer)
  "Record REASON for live BUFFER, reporting failures without stopping edits."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and tategaki-history-mode tategaki-history-enabled
                 (or (eq reason 'save)
                     (not (equal tategaki-history--last-tick
                                 (buffer-chars-modified-tick)))))
        (condition-case error-data
            (tategaki-history-snapshot reason)
          (error (display-warning 'tategaki-history
                                  (format "Snapshot failed: %s"
                                          (error-message-string error-data)))))))))

(defun tategaki-history--after-save ()
  "Record the saved source without interfering with saving."
  (tategaki-history--automatic-snapshot 'save (current-buffer)))

(defun tategaki-history--cancel-timer ()
  "Cancel this buffer's snapshot timer."
  (when (timerp tategaki-history--timer) (cancel-timer tategaki-history--timer))
  (setq tategaki-history--timer nil))

(defun tategaki-history-reconfigure ()
  "Apply enabled/idle settings to this buffer's active history mode."
  (tategaki-history--cancel-timer)
  (when (and tategaki-history-mode tategaki-history-enabled
             (numberp tategaki-history-idle-interval)
             (> tategaki-history-idle-interval 0))
    (setq tategaki-history--timer
          (run-with-idle-timer tategaki-history-idle-interval t
                               #'tategaki-history--automatic-snapshot
                               'idle (current-buffer)))))

;;;###autoload
(define-minor-mode tategaki-history-mode
  "Keep independent save/idle snapshots for the current manuscript."
  :lighter nil
  (if tategaki-history-mode
      (progn
        (add-hook 'after-save-hook #'tategaki-history--after-save nil t)
        (add-hook 'kill-buffer-hook #'tategaki-history--cancel-timer nil t)
        (add-hook 'change-major-mode-hook #'tategaki-history--cancel-timer nil t)
        (tategaki-history-reconfigure))
    (remove-hook 'after-save-hook #'tategaki-history--after-save t)
    (remove-hook 'kill-buffer-hook #'tategaki-history--cancel-timer t)
    (remove-hook 'change-major-mode-hook #'tategaki-history--cancel-timer t)
    (tategaki-history--cancel-timer)))

(defun tategaki-history--source-buffer ()
  "Resolve a history panel to its live source buffer."
  (or (and (buffer-live-p tategaki-history--source) tategaki-history--source)
      (and (boundp 'tategaki-studio-source)
           (buffer-live-p tategaki-studio-source) tategaki-studio-source)
      (current-buffer)))

(defun tategaki-history--read-record ()
  "Choose one record from the current manuscript's history."
  (or (get-text-property (point) 'tategaki-history-record)
      (with-current-buffer (tategaki-history--source-buffer)
        (let* ((records (alist-get 'snapshots (tategaki-history--manifest
                                              (tategaki-history--id))))
               (choices (cl-loop for record in records for index from 1
                                 collect (cons (format "%d  %s  %s字" index
                                                       (alist-get 'timestamp record)
                                                       (alist-get 'characters record))
                                               record))))
          (unless choices (user-error "この原稿にはまだ履歴がありません"))
          (cdr (assoc (completing-read "履歴: " choices nil t) choices))))))

(defun tategaki-history--snapshot-text (record)
  "Read RECORD after validating its path and content hash."
  (let* ((sha (alist-get 'sha256 record))
         (directory (tategaki-history--directory (alist-get 'document record)))
         (file (alist-get 'file record)))
    (unless (and (stringp sha) (string-match-p "\\`[[:xdigit:]]\\{64\\}\\'" sha)
                 (equal file (concat "snapshots/" sha ".txt")))
      (user-error "Invalid snapshot path"))
    (let ((text (with-temp-buffer
                  (let ((coding-system-for-read 'utf-8-unix))
                    (insert-file-contents (expand-file-name file directory)))
                  (buffer-string))))
      (unless (equal sha (secure-hash 'sha256 (encode-coding-string text 'utf-8-unix)))
        (user-error "Snapshot checksum mismatch; source was not changed"))
      text)))

;;;###autoload
(defun tategaki-history-open (&optional record)
  "Open RECORD in a separate read-only buffer."
  (interactive)
  (setq record (or record (tategaki-history--read-record)))
  (let ((source (tategaki-history--source-buffer))
        (text (tategaki-history--snapshot-text record))
        (buffer (generate-new-buffer
                 (format "*原稿履歴: %s*" (alist-get 'timestamp record)))))
    (with-current-buffer buffer
      (insert text)
      (goto-char (point-min))
      (text-mode)
      (setq-local tategaki-studio-source source)
      (setq-local tategaki-history--source source)
      (tategaki-pane-install source nil "原稿履歴")
      (set-buffer-modified-p nil)
      (read-only-mode 1))
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun tategaki-history-restore-as-copy (&optional record)
  "Restore RECORD into a new editable, unsaved copy.
Never replace the manuscript or visit its filename."
  (interactive)
  (let ((buffer (tategaki-history-open record)))
    (with-current-buffer buffer
      (read-only-mode -1)
      (rename-buffer (generate-new-buffer-name "原稿の復元コピー"))
      (setq-local tategaki-studio-source nil)
      (setq-local tategaki-history--source nil)
      (tategaki-pane-install tategaki-pane-source nil "原稿の復元コピー")
      (buffer-enable-undo)
      (set-buffer-modified-p t))
    buffer))

;;;###autoload
(defun tategaki-history-diff (&optional record)
  "Compare RECORD with the complete current manuscript, including dirty text."
  (interactive)
  (setq record (or record (tategaki-history--read-record)))
  (let* ((source (tategaki-history--source-buffer))
         (old-text (tategaki-history--snapshot-text record))
         (new-text (with-current-buffer source
                     (save-restriction (widen)
                                       (buffer-substring-no-properties
                                        (point-min) (point-max))))))
    (if (and (require 'tategaki-diff nil t) (fboundp 'tategaki-diff-buffers))
        (let ((old (generate-new-buffer " *tategaki-history-old*")))
          (unwind-protect
              (progn (with-current-buffer old (insert old-text))
                     (tategaki-diff-buffers old source))
            (kill-buffer old)))
      (require 'diff)
      (let ((old-file (make-temp-file "tategaki-history-old-"))
            (new-file (make-temp-file "tategaki-history-current-")))
        (unwind-protect
            (progn
              (tategaki-history--atomic-write old-file old-text)
              (tategaki-history--atomic-write new-file new-text)
              (let ((buffer (diff-no-select old-file new-file "-u" t)))
                (with-current-buffer buffer
                  (setq-local tategaki-studio-source source)
                  (tategaki-pane-install source nil "原稿の比較"))
                (pop-to-buffer buffer)
                buffer))
          (delete-file old-file) (delete-file new-file))))))

(define-derived-mode tategaki-history-list-mode special-mode "原稿履歴"
  "Clickable snapshot timeline; open, compare or restore a separate copy."
  (setq-local revert-buffer-function (lambda (&rest _) (tategaki-history))))

;;;###autoload
(defun tategaki-history ()
  "Show the manuscript's clickable snapshot timeline in a side window."
  (interactive)
  (let* ((source (tategaki-history--source-buffer))
         (entries (with-current-buffer source
                    (alist-get 'snapshots
                               (tategaki-history--manifest (tategaki-history--id)))))
         (buffer (get-buffer-create (format "*原稿履歴一覧: %s*" (buffer-name source)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (tategaki-history-list-mode)
        (setq-local tategaki-history--source source)
        (setq-local tategaki-studio-source source)
        (tategaki-pane-install source nil "履歴")
        (insert "原稿履歴\n本文は変更しません。復元は新しいコピーを作成します。\n\n")
        (insert-text-button "[今の原稿を記録]" 'follow-link t
                            'action (lambda (_)
                                      (tategaki-history-snapshot 'manual source)
                                      (tategaki-history)))
        (insert "\n\n")
        (cl-loop for tail on entries for record = (car tail)
                 for previous = (cadr tail) do
                 (let ((start (point)))
                   (insert (format "%s  %s字%s\n"
                                   (alist-get 'timestamp record)
                                   (alist-get 'characters record)
                                   (if previous
                                       (format "  %+d" (- (alist-get 'characters record)
                                                          (alist-get 'characters previous))) "")))
                   (dolist (action '(("[開く]" . tategaki-history-open)
                                     ("[比較]" . tategaki-history-diff)
                                     ("[コピー復元]" . tategaki-history-restore-as-copy)))
                     (let ((function (cdr action)) (snapshot record))
                       (insert-text-button (car action) 'follow-link t
                                           'action (lambda (_) (funcall function snapshot)))
                       (insert " ")))
                   (insert "\n\n")
                   (put-text-property start (point) 'tategaki-history-record record)))
        (unless entries (insert "まだ履歴がありません。\n"))
        (goto-char (point-min))))
    (display-buffer-in-side-window buffer '((side . right) (slot . 2) (window-width . 0.4)))
    buffer))

(provide 'tategaki-history)
;;; tategaki-history.el ends here
