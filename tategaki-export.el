;;; tategaki-export.el --- Asynchronous Docker manuscript export -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; Exports an immutable UTF-8 snapshot through the repository's Docker launcher.
;; Loading this module never starts Docker or changes editor key bindings.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'button)
(require 'tategaki-export-model)

(defgroup tategaki-export nil "Manuscript export using Docker." :group 'text)

(defconst tategaki-export--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing the installed export module.")

(defcustom tategaki-export-program
  (expand-file-name "bin/tategaki-export" tategaki-export--directory)
  "Docker launcher executable.  Its path may contain spaces."
  :type 'file :group 'tategaki-export)

(defcustom tategaki-export-output-directory
  (expand-file-name "dist" tategaki-export--directory)
  "Parent directory for independent export jobs."
  :type 'directory :group 'tategaki-export)

(defcustom tategaki-export-profile "preview"
  "Default profile name or absolute JSON profile path."
  :type 'string :group 'tategaki-export)

(defcustom tategaki-export-formats '("txt" "docx" "pdf" "epub" "html")
  "Default formats offered by `tategaki-export'."
  :type '(repeat string) :group 'tategaki-export)

(defcustom tategaki-export-metadata nil
  "Book metadata alist: title, author, language and identifier.
May be made buffer local.  The title defaults to the current file/buffer name."
  :type '(alist :key-type symbol :value-type string) :group 'tategaki-export)
(make-variable-buffer-local 'tategaki-export-metadata)

(defcustom tategaki-export-input-options nil
  "Overrides for the selected profile's input interpretation.
Nil inherits the profile.  For an explicit override use ((headings . \"org\")).
The headings value is literal, markdown, org or japanese.  Only heading lines
are interpreted; Markdown/Org body text is never parsed as those languages."
  :type '(alist :key-type symbol :value-type string) :group 'tategaki-export)

(defcustom tategaki-export-cancel-startup-timeout 15
  "Seconds to retry cancellation while a job's Docker container is starting."
  :type 'natnum :group 'tategaki-export)

(defvar tategaki-export--jobs (make-hash-table :test #'equal)
  "Jobs started by this Emacs session; external jobs cannot be cancelled here.")
(defvar tategaki-export--last-job nil "ID of the last job started in this session.")

(defun tategaki-export--scope ()
  "Read an explicit export scope when a prefix argument was given."
  (if current-prefix-arg
      (intern (completing-read "出力範囲: " '("full" "region" "narrowed") nil t nil nil "full"))
    'full))

(defun tategaki-export--metadata (&optional profile-metadata)
  "Merge PROFILE-METADATA with buffer metadata and a useful default title."
  (let ((metadata (copy-tree profile-metadata)))
    (dolist (entry tategaki-export-metadata)
      (setf (alist-get (car entry) metadata) (cdr entry)))
    (when (member (tategaki-export-model--get 'title metadata) '(nil "" "無題"))
      (setq metadata (assq-delete-all 'title metadata))
      (push (cons 'title (if buffer-file-name (file-name-base buffer-file-name) (buffer-name))) metadata))
    metadata))

(defun tategaki-export--read-profile (profile)
  "Read named or file PROFILE without loading arbitrary Emacs code."
  (let ((file (if (file-exists-p profile) (expand-file-name profile)
                (expand-file-name (concat "export/profiles/" profile ".json") tategaki-export--directory)))
        (json-object-type 'alist) (json-array-type 'vector) (json-key-type 'symbol))
    (unless (file-readable-p file) (user-error "プロファイルが見つかりません: %s" profile))
    (json-read-file file)))

(defun tategaki-export--append-log (job text)
  "Append TEXT to JOB's log, without selecting its buffer."
  (when-let* ((buffer (get-buffer (plist-get job :buffer))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (goto-char (point-max)) (insert text)))))

(defun tategaki-export--record-early-cancel (job)
  "Preserve JOB's cancelled snapshot if Docker stopped before initialization.
Never overwrite an existing report or claim validation that did not run."
  (let* ((directory (plist-get job :directory))
         (report-path (expand-file-name "report.json" directory))
         (snapshot (plist-get job :snapshot-directory)))
    (unless (file-exists-p report-path)
      (make-directory directory t)
      (dolist (name '("source.txt" "document.json"))
        (let ((from (expand-file-name name snapshot)) (to (expand-file-name name directory)))
          (when (and (file-exists-p from) (not (file-exists-p to)))
            (copy-file from to nil))))
      (let* ((reason "Cancelled before exporter initialization. No format validation ran.")
             (report `((schema_version . 1) (job_id . ,(plist-get job :id))
                       (status . "cancelled")
                       (started_at . ,(format-time-string "%Y-%m-%dT%H:%M:%SZ" (plist-get job :started-at) t))
                       (finished_at . ,(format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))
                       (input_sha256 . ,(plist-get job :source-hash))
                       (source . ,(plist-get job :source))
                       (profile . ,(plist-get job :profile))
                       (formats . ,(mapcar
                                    (lambda (name)
                                      (cons (intern name)
                                            `((status . ,(if (member name (plist-get job :formats))
                                                             "cancelled" "not_requested")))))
                                    '("txt" "docx" "pdf" "epub" "html")))
                       (unverified . ,(vector reason)) (report_origin . "emacs-startup-cancellation")))
             (temporary (make-temp-file (expand-file-name ".cancel-report-" directory))))
        (unwind-protect
            (progn
              (tategaki-export-model-write-json report temporary)
              (rename-file temporary report-path nil)
              (let ((markdown (expand-file-name "report.md" directory)))
                (unless (file-exists-p markdown)
                  (with-temp-buffer
                    (insert (format "# Export %s\n\nStatus: **cancelled**\n\nInput SHA-256: `%s`\n\n%s\n"
                                    (plist-get job :id) (plist-get job :source-hash) reason))
                    (write-region (point-min) (point-max) markdown nil 'silent nil 'excl)))))
          (when (file-exists-p temporary) (delete-file temporary)))))))

(defun tategaki-export--sentinel (process event)
  "Record completion of PROCESS described by EVENT."
  (when (memq (process-status process) '(exit signal))
    (let* ((id (process-get process 'tategaki-job-id))
           (job (gethash id tategaki-export--jobs)))
      (when job
        (when (timerp (plist-get job :cancel-timer))
          (cancel-timer (plist-get job :cancel-timer)))
        (setf (plist-get job :state)
              (cond ((zerop (process-exit-status process)) 'succeeded)
                    ((and (plist-get job :cancel-requested)
                          (or (eq (process-status process) 'signal)
                              (memq (process-exit-status process) '(130 137 143)))) 'cancelled)
                    (t 'failed))
              (plist-get job :finished-at) (current-time)
              (plist-get job :exit-code) (process-exit-status process))
        (puthash id job tategaki-export--jobs)
        (tategaki-export--append-log
         job (format "\n[%s] %s\n結果: %s\n" (plist-get job :state) (string-trim event)
                     (plist-get job :directory)))
        (when (eq (plist-get job :state) 'cancelled)
          (condition-case error
              (tategaki-export--record-early-cancel job)
            (error (tategaki-export--append-log job (format "\n取消レポートの保存に失敗しました: %s\n" error)))))
        (when (file-directory-p (plist-get job :snapshot-directory))
          (delete-directory (plist-get job :snapshot-directory) t))
        (message "縦書き出力 %s: %s (M-x tategaki-export-status)" id (plist-get job :state))))))

(defun tategaki-export--start (formats profile scope)
  "Start FORMATS with PROFILE from explicit SCOPE; return the job ID."
  (unless (file-executable-p tategaki-export-program)
    (user-error "出力ランチャーが実行できません: %s" tategaki-export-program))
  (unless (executable-find "docker")
    (user-error "出力には Docker が必要です。Docker を起動して PATH を確認してください"))
  (unless (and formats (cl-every (lambda (f) (member f '("txt" "docx" "pdf" "epub" "html"))) formats))
    (user-error "出力形式が指定されていないか未対応です: %S" formats))
  (when (and (eq scope 'region) (not (use-region-p)))
    (user-error "選択範囲がありません"))
  (let* ((profile-config (tategaki-export--read-profile profile))
         (input (copy-tree (alist-get 'input profile-config)))
         (_ (dolist (entry tategaki-export-input-options)
              (setf (alist-get (car entry) input) (cdr entry))))
         (snapshot (tategaki-export-model-snapshot
                    scope (tategaki-export--metadata (alist-get 'metadata profile-config)) `((input . ,input))))
         (model (plist-get snapshot :model))
         (hash (alist-get 'sha256 (alist-get 'source model)))
         (nonce (secure-hash 'sha256 (format "%S-%S-%s" (current-time) (random) (emacs-pid))))
         (id (concat "emacs-" (substring hash 0 10) "-" (substring nonce 0 12)))
         (input-dir (make-temp-file "tategaki-export-" t))
         (source-file (expand-file-name "source.txt" input-dir))
         (model-file (expand-file-name "document.json" input-dir))
         (out (expand-file-name tategaki-export-output-directory))
         (directory (expand-file-name id out))
         (buffer (get-buffer-create (format "*Tategaki export %s*" id)))
         (job (list :id id :state 'starting :source-hash hash :source (alist-get 'source model)
                    :profile profile :formats formats :started-at (current-time)
                    :directory directory :snapshot-directory input-dir :buffer (buffer-name buffer)))
         process)
    (condition-case err
        (progn
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file source-file (insert (plist-get snapshot :text))))
          (tategaki-export-model-write-json model model-file)
          (with-current-buffer buffer
            (special-mode)
            (let ((inhibit-read-only t))
              (insert (format "原稿出力: %s\n取得日時: %s\nSHA-256: %s\nプロファイル: %s\n出力先: %s\n\n"
                              id (alist-get 'timestamp (alist-get 'source model)) hash profile directory))))
          (puthash id job tategaki-export--jobs)
          (setq process
                (make-process :name (concat "tategaki-export-" id) :buffer buffer
                              :command (list tategaki-export-program "export" source-file
                                             "--model" model-file "--profile" profile
                                             "--formats" (string-join formats ",")
                                             "--out" out "--job-id" id)
                              :connection-type 'pipe :coding 'utf-8-unix
                              :noquery t :sentinel #'tategaki-export--sentinel))
          (process-put process 'tategaki-job-id id)
          (setf (plist-get job :process) process (plist-get job :state) 'running)
          (puthash id job tategaki-export--jobs)
          (setq tategaki-export--last-job id)
          (message "出力を開始しました: %s。編集は継続できます" id)
          id)
      (error
       (remhash id tategaki-export--jobs)
       (when (file-directory-p input-dir) (delete-directory input-dir t))
       (signal (car err) (cdr err))))))

;;;###autoload
(defun tategaki-export (&optional formats profile scope)
  "Export an immutable snapshot asynchronously and return its job ID.
Interactively choose FORMATS and PROFILE.  A prefix argument explicitly asks
for SCOPE (full, region or narrowed).  Default scope is the full buffer."
  (interactive
   (list (completing-read-multiple "出力形式: " '("txt" "docx" "pdf" "epub" "html")
                                   nil t (string-join tategaki-export-formats ","))
         (completing-read "プロファイル: " '("preview" "submission") nil nil nil nil tategaki-export-profile)
         (tategaki-export--scope)))
  (tategaki-export--start (or formats tategaki-export-formats)
                          (or profile tategaki-export-profile) (or scope 'full)))

;;;###autoload
(defun tategaki-export-all (&optional scope)
  "Export TXT, DOCX, PDF, EPUB and HTML from the same snapshot.
A prefix argument asks for SCOPE explicitly; default scope is the full buffer."
  (interactive (list (tategaki-export--scope)))
  (tategaki-export--start '("txt" "docx" "pdf" "epub" "html") tategaki-export-profile (or scope 'full)))

(defun tategaki-export--select-job ()
  "Select one of this Emacs session's jobs."
  (unless (> (hash-table-count tategaki-export--jobs) 0) (user-error "この Emacs で開始した出力はありません"))
  (completing-read "出力ジョブ: " (hash-table-keys tategaki-export--jobs)
                   nil t nil nil tategaki-export--last-job))

;;;###autoload
(defun tategaki-export-status (&optional id)
  "Show ID's current status, logs and completed report."
  (interactive (list (tategaki-export--select-job)))
  (let* ((id (or id tategaki-export--last-job))
         (job (gethash id tategaki-export--jobs)))
    (unless job (user-error "この Emacs で開始したジョブではありません: %s" id))
    (let ((buffer (get-buffer-create "*Tategaki export status*"))
          (report (expand-file-name "report.md" (plist-get job :directory))))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "ジョブ: %s\n状態: %s\nSHA-256: %s\n\n" id (plist-get job :state) (plist-get job :source-hash)))
          (insert-text-button "ログを表示" 'action (lambda (_) (pop-to-buffer (plist-get job :buffer))) 'follow-link t)
          (insert "  ")
          (insert-text-button "出力フォルダー" 'action (lambda (_) (dired (plist-get job :directory))) 'follow-link t)
          (insert "\n\n")
          (if (file-exists-p report) (insert-file-contents report)
            (insert "レポートはまだ生成されていません。進行状況はログを確認してください。\n")))
        (special-mode) (goto-char (point-min)))
      (pop-to-buffer buffer))))

(defun tategaki-export--cancel-attempt (id deadline)
  "Request cancellation of own job ID, retrying its startup until DEADLINE."
  (when-let* ((job (gethash id tategaki-export--jobs)))
    (when (plist-get job :cancel-requested)
      (let ((buffer (generate-new-buffer (concat " *Tategaki cancel " id "*"))))
        (setf (plist-get job :cancel-buffer) buffer)
        (condition-case err
            (make-process
             :name (concat "tategaki-export-cancel-" id)
             :buffer buffer :noquery t :connection-type 'pipe :coding 'utf-8-unix
             :command (list tategaki-export-program "cancel" id)
             :sentinel
             (lambda (process _event)
               (when (memq (process-status process) '(exit signal))
                 (let ((details (if (buffer-live-p buffer)
                                    (with-current-buffer buffer (buffer-string)) "")))
                   (when (buffer-live-p buffer) (kill-buffer buffer))
                   (cond
                    ((zerop (process-exit-status process))
                     (message "出力の取消を要求しました: %s" id))
                    ((and (process-live-p (plist-get job :process))
                          (< (float-time) deadline))
                     ;; The launcher may still be checking Docker/copying its
                     ;; snapshot, before the named container exists.  Keep the
                     ;; request pending without terminating unrelated processes.
                     (setf (plist-get job :cancel-timer)
                           (run-at-time 0.25 nil #'tategaki-export--cancel-attempt id deadline)))
                    ((process-live-p (plist-get job :process))
                     (setf (plist-get job :cancel-requested) nil)
                     (tategaki-export--append-log job (concat "\n取消要求が時間内に完了しませんでした。再試行できます。\n" details))
                     (message "出力取消を完了できませんでした: %s (ログを確認してください)" id))
                    (t
                     ;; Completion can win the race; its main sentinel records
                     ;; the real exit state, never a fictitious cancellation.
                     (tategaki-export--append-log job "\n取消要求の処理前にジョブが終了しました。\n")))))))
          (error
           (when (buffer-live-p buffer) (kill-buffer buffer))
           (setf (plist-get job :cancel-requested) nil)
           (signal (car err) (cdr err))))))))

;;;###autoload
(defun tategaki-export-cancel (&optional id)
  "Cancel only an active export ID started by this Emacs session.
If its container is still starting, retry asynchronously for a bounded time."
  (interactive (list (tategaki-export--select-job)))
  (let* ((id (or id tategaki-export--last-job)) (job (gethash id tategaki-export--jobs)))
    (unless job (user-error "この Emacs で開始したジョブではありません: %s" id))
    (unless (memq (plist-get job :state) '(starting running)) (user-error "ジョブは既に終了しています"))
    (unless (plist-get job :cancel-requested)
      (setf (plist-get job :cancel-requested) t)
      (puthash id job tategaki-export--jobs)
      (tategaki-export--cancel-attempt id (+ (float-time) tategaki-export-cancel-startup-timeout)))))

(provide 'tategaki-export)
;;; tategaki-export.el ends here
