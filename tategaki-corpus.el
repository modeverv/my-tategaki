;;; tategaki-corpus.el --- Explicit manuscript and resource collections -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Only individually registered local files are read.  No directory scan or
;; automatic document transmission is performed by registration or the panel.
;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'button)
(require 'subr-x)
(require 'tategaki-semantic)
(require 'tategaki-project)
(require 'tategaki-history)

(defgroup tategaki-corpus nil "Explicitly selected novel documents." :group 'tategaki-ai)
(defcustom tategaki-corpus-max-file-size (* 5 1024 1024)
  "Maximum bytes of one explicitly registered document."
  :type 'integer :group 'tategaki-corpus)
(defvar-local tategaki-corpus--jobs nil)
(defvar-local tategaki-corpus--source nil)
(defvar-local tategaki-corpus--root nil)
(defvar-local tategaki-corpus--status "")
(defvar tategaki-studio-source)

(defun tategaki-corpus--file (root &optional index)
  "Return the registry or INDEX cache file inside ROOT."
  (expand-file-name (if index ".tategaki/corpus-index.json" ".tategaki/corpus.json") root))

(defun tategaki-corpus--local-path-p (file)
  "Whether FILE is an absolute local filename."
  (and (stringp file) (file-name-absolute-p file) (not (file-remote-p file))))

(defun tategaki-corpus--read (root)
  "Read ROOT's explicit registry, preserving malformed data on failure."
  (let* ((file (tategaki-corpus--file root))
         (data (tategaki-corpus--read-json file (* 1024 1024))))
    (when (file-exists-p file)
      (unless (and (listp data) (equal (alist-get 'schema_version data) 1)
                   (listp (alist-get 'documents data))
                   (cl-every
                    (lambda (entry)
                      (and (listp entry)
                           (tategaki-corpus--local-path-p (alist-get 'file entry))
                           (member (alist-get 'kind entry) '("manuscript" "resource"))
                           (assq 'enabled entry)
                           (memq (alist-get 'enabled entry) '(t nil :json-false))))
                    (alist-get 'documents data)))
        (user-error "登録資料の JSON が不正です。ファイルを保護しました: %s" file)))
    (alist-get 'documents data)))

(defun tategaki-corpus--read-json (file limit)
  "Read JSON FILE only when its size is at most LIMIT bytes."
  (when (and (file-exists-p file)
             (> (file-attribute-size (file-attributes file)) limit))
    (user-error "資料索引の JSON がサイズ上限を超えています: %s" file))
  (tategaki-history--read-json file))

(defun tategaki-corpus--write (root documents)
  "Atomically write validated DOCUMENTS to ROOT's registry."
  (tategaki-corpus--read root)
  (setq documents (copy-tree documents))
  (dolist (entry documents)
    (setf (alist-get 'enabled entry) (if (eq (alist-get 'enabled entry) t) t :json-false)))
  (tategaki-history--write-json
   (tategaki-corpus--file root)
   `((schema_version . 1) (documents . ,(vconcat documents)))))

(defun tategaki-corpus--context ()
  "Return (SOURCE . ROOT) from an ordinary manuscript or this module's panel."
  (if (derived-mode-p 'tategaki-corpus-mode)
      (progn
        (unless (buffer-live-p tategaki-corpus--source)
          (user-error "原稿が閉じられています"))
        (cons tategaki-corpus--source tategaki-corpus--root))
    (let ((source (tategaki-semantic-source)))
      (cons source (with-current-buffer source (tategaki-project-root))))))

;;;###autoload
(defun tategaki-corpus-register (file &optional kind)
  "Register one explicitly chosen FILE as KIND, manuscript or resource.
Registration stores a path only; it never sends text to an AI provider."
  (interactive (list (read-file-name "登録する原稿・資料: " nil nil t)
                     (intern (completing-read "種類: " '("manuscript" "resource") nil t))))
  (unless (tategaki-corpus--local-path-p (expand-file-name file))
    (user-error "ローカルファイルを選択してください"))
  (setq file (file-truename file) kind (or kind 'resource))
  (unless (and (file-regular-p file) (file-readable-p file))
    (user-error "読み込める通常ファイルを選択してください"))
  (unless (memq kind '(manuscript resource)) (user-error "Unknown document kind"))
  (let* ((root (cdr (tategaki-corpus--context)))
         (documents (tategaki-corpus--read root))
         (record `((file . ,file) (kind . ,(symbol-name kind)) (enabled . t))))
    (setq documents (cl-remove file documents :key (lambda (item) (alist-get 'file item))
                               :test #'equal))
    (tategaki-corpus--write root (append documents (list record)))
    record))

(defun tategaki-corpus-set-enabled (file enabled)
  "Select or exclude registered FILE using ENABLED, without deleting the file."
  (unless (tategaki-corpus--local-path-p (expand-file-name file))
    (user-error "ローカルファイルを選択してください"))
  (setq file (file-truename file))
  (let* ((root (cdr (tategaki-corpus--context)))
         (documents (tategaki-corpus--read root))
         (record (cl-find file documents :key (lambda (item) (alist-get 'file item))
                          :test #'equal)))
    (unless record (user-error "このファイルは登録されていません"))
    (setf (alist-get 'enabled record) (if enabled t :json-false))
    (tategaki-corpus--write root documents)))

(defun tategaki-corpus-remove (file)
  "Remove FILE from this collection without deleting it from disk."
  (unless (tategaki-corpus--local-path-p (expand-file-name file))
    (user-error "ローカルファイルを選択してください"))
  (setq file (file-truename file))
  (let* ((root (cdr (tategaki-corpus--context)))
         (documents (tategaki-corpus--read root)))
    (tategaki-corpus--write
     root (cl-remove file documents :key (lambda (item) (alist-get 'file item)) :test #'equal))))

(defun tategaki-corpus--live-buffer (file)
  "Find the live visiting buffer for FILE, including symlink aliases."
  (or (get-file-buffer file)
      (cl-find-if (lambda (buffer)
                    (with-current-buffer buffer
                      (and buffer-file-name
                           (equal file (or buffer-file-truename
                                           (ignore-errors (file-truename buffer-file-name)))))))
                  (buffer-list))))

(defun tategaki-corpus--document (entry &optional hash-only)
  "Read registered ENTRY, preferring live unsaved text.  HASH-ONLY skips chunks."
  (let* ((file (alist-get 'file entry))
         (live (tategaki-corpus--live-buffer file)))
    (unless (or live (and (file-regular-p file) (file-readable-p file)))
      (user-error "登録ファイルを開けません: %s" file))
    (when (and (not live)
               (> (file-attribute-size (file-attributes file)) tategaki-corpus-max-file-size))
      (user-error "登録ファイルが上限を超えています: %s" file))
    (cl-labels ((snapshot ()
                  (when (> (buffer-size) tategaki-corpus-max-file-size)
                    (user-error "登録バッファが上限を超えています: %s" file))
                  (let ((hash (tategaki-semantic-hash))
                        (chunks (unless hash-only (tategaki-semantic-chunks))))
                    (dolist (chunk chunks)
                      (plist-put chunk :document file)
                      (plist-put chunk :buffer live)
                      (plist-put chunk :kind (intern (alist-get 'kind entry))))
                    (list :file file :hash hash :chunks chunks))))
      (if live (with-current-buffer live (snapshot))
        (with-temp-buffer
          (insert-file-contents file)
          ;; Do not leave a visiting-file association on the scratch reader:
          ;; killing a modified temporary buffer would otherwise ask to save.
          (let ((buffer-file-name file) (default-directory (file-name-directory file)))
            (snapshot)))))))

(defun tategaki-corpus--snapshot (source root resources-only)
  "Read selected documents in ROOT using SOURCE's chunk configuration."
  (with-current-buffer source
    (let* ((registry (tategaki-corpus--read root))
           (entries (seq-filter
                     (lambda (entry)
                       (and (eq (alist-get 'enabled entry) t)
                            (or (not resources-only)
                                (equal (alist-get 'kind entry) "resource")))) registry))
           (tategaki-semantic-chunk-size tategaki-semantic-chunk-size)
           (documents (mapcar #'tategaki-corpus--document entries)))
      (list :source source :root root :registry registry :entries entries
            :documents documents :model (tategaki-semantic--model-key)
            :enabled tategaki-ai-enabled
            :count tategaki-semantic-result-count
            :chunks (apply #'append (mapcar (lambda (doc) (plist-get doc :chunks)) documents))))))

(defun tategaki-corpus--valid-p (snapshot)
  "Whether SNAPSHOT still names the same selected content and provider."
  (condition-case nil
      (and (buffer-live-p (plist-get snapshot :source))
           (with-current-buffer (plist-get snapshot :source)
             (and (equal (plist-get snapshot :model) (tategaki-semantic--model-key))
                  (eq (plist-get snapshot :enabled) tategaki-ai-enabled)))
           (equal (plist-get snapshot :registry)
                  (tategaki-corpus--read (plist-get snapshot :root)))
           (cl-every
            #'identity
            (cl-mapcar (lambda (entry doc)
                         (equal (plist-get doc :hash)
                                (plist-get (tategaki-corpus--document entry t) :hash)))
                       (plist-get snapshot :entries) (plist-get snapshot :documents))))
    (error nil)))

(defun tategaki-corpus--signature (snapshot)
  "Return a JSON-compatible content and embedding identity for SNAPSHOT."
  (secure-hash
   'sha256
   (prin1-to-string
    (list (plist-get snapshot :model)
          (mapcar (lambda (doc) (list (plist-get doc :file) (plist-get doc :hash)))
                  (plist-get snapshot :documents))
          (mapcar (lambda (chunk) (list (plist-get chunk :hash) (plist-get chunk :start)
                                       (plist-get chunk :end)))
                  (plist-get snapshot :chunks))))))

(defun tategaki-corpus--vectors-valid-p (vectors count)
  "Validate COUNT numeric VECTORS in one consistent embedding space."
  (and (proper-list-p vectors) (= (length vectors) count)
       (or (zerop count)
           (and (consp (car vectors)) (proper-list-p (car vectors))
                (let ((dimension (length (car vectors))))
             (and (> dimension 0)
                  (cl-every (lambda (vector)
                              (and (proper-list-p vector) (= (length vector) dimension)
                                   (cl-every (lambda (value)
                                               (and (numberp value) (= value value)
                                                    (<= (abs value) 1.0e100))) vector))) vectors)))))))

(defun tategaki-corpus--cached-vectors (snapshot)
  "Read a matching safe vector cache for SNAPSHOT, ignoring damaged caches."
  (condition-case nil
      (let* ((data (tategaki-corpus--read-json
                    (tategaki-corpus--file (plist-get snapshot :root) t) (* 64 1024 1024)))
             (vectors (alist-get 'vectors data)))
        (when (and (equal (alist-get 'schema_version data) 1)
                   (equal (alist-get 'signature data) (tategaki-corpus--signature snapshot))
                   (tategaki-corpus--vectors-valid-p vectors (length (plist-get snapshot :chunks))))
          vectors))
    (error nil)))

(defun tategaki-corpus--job (snapshot callback)
  "Create a cancellable operation for SNAPSHOT delivering CALLBACK once."
  (let ((job (list :snapshot snapshot :callback callback :done nil :request nil :timer nil)))
    (with-current-buffer (plist-get snapshot :source)
      (push job tategaki-corpus--jobs)
      (add-hook 'kill-buffer-hook #'tategaki-corpus--cancel-buffer nil t))
    job))

(defun tategaki-corpus--finish (job result)
  "Complete JOB with RESULT at most once."
  (unless (plist-get job :done)
    (setf (plist-get job :done) t)
    (when (timerp (plist-get job :timer)) (cancel-timer (plist-get job :timer)))
    (let ((source (plist-get (plist-get job :snapshot) :source)))
      (when (buffer-live-p source)
        (with-current-buffer source
          (setq tategaki-corpus--jobs (delq job tategaki-corpus--jobs)))))
    (funcall (plist-get job :callback) result)))

(defun tategaki-corpus-cancel (job)
  "Cancel JOB and its live provider request, with exactly one callback."
  (when (and (listp job) (functionp (plist-get job :callback))
             (not (plist-get job :done)))
    (unwind-protect
        (tategaki-corpus--finish job '(:ok nil :chunks nil :method cancelled :message "資料検索を中止しました"))
      (tategaki-ai-cancel (plist-get job :request)))))

(defun tategaki-corpus--cancel-buffer ()
  "Cancel every operation owned by the source being killed."
  (mapc #'tategaki-corpus-cancel (copy-sequence tategaki-corpus--jobs)))

(defun tategaki-corpus--live-job-p (job)
  "Discard stale JOB, returning non-nil only while it remains usable."
  (unless (plist-get job :done)
    (if (tategaki-corpus--valid-p (plist-get job :snapshot)) t
      (tategaki-corpus--finish
       job '(:ok nil :chunks nil :method stale :message "原稿・資料・登録または AI 設定が変更されました。再実行してください"))
      nil)))

;;;###autoload
(defun tategaki-corpus-index (&optional callback)
  "Asynchronously embed only selected registered documents.
CALLBACK receives :ok and :chunks; return a cancellable job."
  (interactive)
  (pcase-let* ((`(,source . ,root) (tategaki-corpus--context))
               (snapshot (tategaki-corpus--snapshot source root nil))
               (remaining (plist-get snapshot :chunks))
               (_authorized (with-current-buffer source (when remaining (tategaki-ai-authorize))))
               (job (tategaki-corpus--job
                     snapshot (or callback (lambda (result) (message "%s" (plist-get result :message))))))
               (vectors nil))
    (cl-labels
        ((step ()
           (when (tategaki-corpus--live-job-p job)
             (if (null remaining)
                 (condition-case error-data
                     (let ((ordered (nreverse vectors)))
                       (unless (tategaki-corpus--vectors-valid-p ordered (length (plist-get snapshot :chunks)))
                         (error "Embedding vectors have inconsistent dimensions"))
                       (tategaki-history--write-json
                        (tategaki-corpus--file root t)
                        `((schema_version . 1) (signature . ,(tategaki-corpus--signature snapshot))
                          (vectors . ,(vconcat (mapcar #'vconcat ordered)))))
                       (tategaki-corpus--finish
                        job (list :ok t :chunks (plist-get snapshot :chunks) :method 'semantic
                                  :message "登録した原稿・資料の意味索引を更新しました")))
                   (error (tategaki-corpus--finish
                           job (list :ok nil :chunks nil :message (error-message-string error-data)))))
               (let ((batch (seq-take remaining 16)))
                 (setq remaining (nthcdr (length batch) remaining))
                 (with-current-buffer source
                   (setf (plist-get job :request)
                         (tategaki-ai-embed
                          (mapcar (lambda (chunk) (plist-get chunk :text)) batch)
                          (lambda (result)
                            (when (tategaki-corpus--live-job-p job)
                              (if (not (and (plist-get result :ok)
                                            (tategaki-corpus--vectors-valid-p (plist-get result :vectors)
                                                                              (length batch))))
                                  (tategaki-corpus--finish
                                   job (list :ok nil :chunks nil :message
                                             (or (plist-get result :message) "Embedding の応答が不正です")))
                                (dolist (vector (plist-get result :vectors)) (push vector vectors))
                                (setf (plist-get job :timer) (run-at-time 0 nil #'step))))) t))))))))
      (step))
    job))

;;;###autoload
(defun tategaki-corpus-retrieve (query callback &optional resources-only authorized)
  "Search registered files for QUERY, delivering :ok :chunks :method to CALLBACK.
RESOURCES-ONLY excludes other manuscripts.  AUTHORIZED means this same
operation already obtained provider consent.  Return a cancellable job."
  (let (job)
   (condition-case error-data
      (pcase-let* ((`(,source . ,root) (tategaki-corpus--context))
                   (snapshot (tategaki-corpus--snapshot source root nil))
                   (chunks (if resources-only
                               (seq-filter (lambda (chunk) (eq (plist-get chunk :kind) 'resource))
                                           (plist-get snapshot :chunks))
                             (plist-get snapshot :chunks)))
                   (vectors (tategaki-corpus--cached-vectors snapshot)))
        (setq job (tategaki-corpus--job snapshot callback))
        (cl-labels
            ((fallback (notice)
               (when (tategaki-corpus--live-job-p job)
                 (tategaki-corpus--finish
                  job (list :ok t :method 'lexical :notice notice
                            :chunks (tategaki-semantic-lexical-search
                                     query chunks (plist-get snapshot :count)))))))
          (if (not (and chunks vectors (plist-get snapshot :enabled)))
              (fallback "登録資料の意味索引が未作成または古いため、語句検索を使用")
            (with-current-buffer source
              (setf (plist-get job :request)
                    (tategaki-ai-embed
                     (list query)
                     (lambda (result)
                       (when (tategaki-corpus--live-job-p job)
                         (if (not (and (plist-get result :ok)
                                       (tategaki-corpus--vectors-valid-p (plist-get result :vectors) 1)
                                       (= (length (car (plist-get result :vectors)))
                                          (length (car vectors)))))
                             (fallback (plist-get result :message))
                           (let ((query-vector (car (plist-get result :vectors))) scored)
                             (cl-mapc (lambda (chunk vector)
                                        (when (or (not resources-only) (eq (plist-get chunk :kind) 'resource))
                                          (push (cons (tategaki-semantic-cosine query-vector vector) chunk) scored)))
                                      (plist-get snapshot :chunks) vectors)
                             (tategaki-corpus--finish
                              job (list :ok t :method 'semantic
                                        :chunks (mapcar #'cdr
                                                        (seq-take (sort scored (lambda (a b) (> (car a) (car b))))
                                                                  (plist-get snapshot :count))))))))) authorized))))
        job))
    (error
     (let ((result (list :ok nil :chunks nil :message (error-message-string error-data))))
       (if job (tategaki-corpus--finish job result) (funcall callback result)))
     job))))

(defun tategaki-corpus-visit (chunk)
  "Visit CHUNK only if its live or saved source still has the expected hash."
  (let* ((origin (tategaki-semantic--reference-origin))
         (file (plist-get chunk :document))
         (entry `((file . ,file) (kind . "resource")))
         (current (tategaki-corpus--document entry t)))
    (unless (equal (plist-get current :hash) (plist-get chunk :source-hash))
      (user-error "資料が変更されています。検索をやり直してください"))
    (let ((buffer (or (tategaki-corpus--live-buffer file) (find-file-noselect file))))
      (tategaki-semantic--install-reference-pane origin buffer)
      (pop-to-buffer buffer)
      (widen)
      (goto-char (plist-get chunk :start)))))

(define-derived-mode tategaki-corpus-mode special-mode "Tategaki資料"
  "Explicit collection registration, selection and search.")

(defun tategaki-corpus--refresh-panel ()
  "Render the current collection panel without reading document contents."
  (let ((inhibit-read-only t) (source tategaki-corpus--source)
        (panel (current-buffer)))
    (erase-buffer)
    (insert "原稿・資料コレクション\n登録したファイルだけを検索します。\n\n")
    (dolist (item '(("原稿を登録" . manuscript) ("資料を登録" . resource)))
      (let ((kind (cdr item)))
        (insert-text-button
         (car item) 'follow-link t
         'action (lambda (_)
                   (tategaki-corpus-register (read-file-name "登録するファイル: " nil nil t) kind)
                   (tategaki-corpus--refresh-panel))))
      (insert "  "))
    (insert-text-button
     "意味索引を更新" 'follow-link t
     'action (lambda (_)
               (with-current-buffer source
                 (tategaki-corpus-index
                  (lambda (result)
                    (when (buffer-live-p panel)
                      (with-current-buffer panel
                        (setq tategaki-corpus--status (plist-get result :message))
                        (tategaki-corpus--refresh-panel))))))))
    (insert "  ")
    (insert-text-button "検索" 'follow-link t
                        'action (lambda (_) (call-interactively #'tategaki-corpus-search)))
    (insert "  ")
    (insert-text-button "中止" 'follow-link t
                        'action (lambda (_) (with-current-buffer source (tategaki-corpus--cancel-buffer))))
    (insert "\n\n" (or tategaki-corpus--status "") "\n\n")
    (dolist (entry (tategaki-corpus--read tategaki-corpus--root))
      (let ((file (alist-get 'file entry)) (enabled (eq (alist-get 'enabled entry) t)))
        (insert-text-button
         (if enabled "[対象]" "[除外]") 'follow-link t
         'action (lambda (_) (tategaki-corpus-set-enabled file (not enabled))
                   (tategaki-corpus--refresh-panel)))
        (insert (format " %s  %s  " (alist-get 'kind entry) file))
        (insert-text-button
         "登録解除" 'follow-link t
         'action (lambda (_) (tategaki-corpus-remove file) (tategaki-corpus--refresh-panel)))
        (insert "\n")))
    (goto-char (point-min))))

;;;###autoload
(defun tategaki-corpus ()
  "Open the explicit manuscript and resource collection panel."
  (interactive)
  (pcase-let* ((`(,source . ,root) (tategaki-corpus--context))
               (panel (get-buffer-create (format "*Tategaki Corpus: %s*" (abbreviate-file-name root)))))
    (with-current-buffer panel
      (tategaki-corpus-mode)
      (setq-local tategaki-corpus--source source tategaki-studio-source source
                  tategaki-corpus--root root)
      (tategaki-pane-install source nil "作品・資料")
      (tategaki-corpus--refresh-panel))
    (pop-to-buffer panel '((display-buffer-in-side-window) (side . right) (slot . 1)))
    panel))

;;;###autoload
(defun tategaki-corpus-search (query)
  "Search selected collection documents for QUERY with clickable citations."
  (interactive "s登録原稿・資料を検索: ")
  (let ((source (car (tategaki-corpus--context))))
    (tategaki-semantic--search-run
     source (format "*Tategaki Corpus Search: %s*" (buffer-name source))
     query "作品・資料検索" #'tategaki-corpus-retrieve #'tategaki-corpus-cancel
     (lambda (result)
       (insert (format "%s — %s\n%s\n\n" query (or (plist-get result :method) "")
                       (or (plist-get result :notice) (plist-get result :message) "")))
       (dolist (chunk (plist-get result :chunks))
         (insert-text-button
          (format "%s [%s:%d]" (file-name-nondirectory (plist-get chunk :document))
                  (plist-get chunk :chapter) (plist-get chunk :start))
          'follow-link t 'action (lambda (_) (tategaki-corpus-visit chunk)))
         (insert "\n" (plist-get chunk :text) "\n\n"))
       (unless (plist-get result :chunks) (insert "一致する箇所はありません。\n"))))))

(provide 'tategaki-corpus)
;;; tategaki-corpus.el ends here
