;;; tategaki-rag.el --- Bounded manuscript and resource context -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'tategaki-semantic)
(require 'tategaki-project)
(require 'tategaki-corpus)
(defcustom tategaki-rag-context-limit 12000 "Maximum context characters sent for a question."
  :type 'integer :group 'tategaki-ai)
(defcustom tategaki-rag-resource-limit 2000000 "Maximum resource bytes per file."
  :type 'integer :group 'tategaki-ai)
(defcustom tategaki-rag-resource-total-limit 4000000
  "Maximum resource bytes inspected in one explicit retrieval."
  :type 'integer :group 'tategaki-ai)
(declare-function tategaki-world-context "tategaki-world" (&optional cutoff character))
(declare-function tategaki-timeline-context "tategaki-timeline" (&optional cutoff))
(declare-function tategaki-knowledge-filter-chunks "tategaki-knowledge" (chunks character &optional cutoff))

(defun tategaki-rag-resource-chunks ()
  "Read text resources from this project's explicit resources directory.
Symlinks and unsupported binary formats are excluded.  Resource passages remain
clearly marked as research material, never manuscript facts."
  (let* ((root (tategaki-project-root))
         (directory (and root (expand-file-name ".tategaki/resources/" root)))
         (excluded (mapcar (lambda (entry) (file-truename (alist-get 'file entry)))
                           (seq-filter (lambda (entry) (not (eq (alist-get 'enabled entry) t)))
                                       (tategaki-corpus--read root))))
         (remaining tategaki-rag-resource-total-limit) chunks)
    (when (and directory (file-directory-p directory) (not (file-symlink-p directory)))
      (dolist (file (seq-take (directory-files directory t "\\.\\(?:txt\\|md\\|org\\)\\'") 100))
        (when (and (file-regular-p file) (not (file-symlink-p file))
                   (not (member (file-truename file) excluded))
                   (file-readable-p file)
                   (<= (file-attribute-size (file-attributes file))
                       (min remaining tategaki-rag-resource-limit)))
          (setq remaining (- remaining (file-attribute-size (file-attributes file))))
          (let ((document (tategaki-corpus--document
                           `((file . ,(file-truename file)) (kind . "resource")))))
            (dolist (chunk (plist-get document :chunks)) (push chunk chunks))))))
    (nreverse chunks)))

(defun tategaki-rag--cancel-transport (transport)
  "Cancel one provider buffer or corpus TRANSPORT job."
  (cond ((bufferp transport) (tategaki-ai-cancel transport))
        ((and (listp transport) (plist-get transport :snapshot))
         (tategaki-corpus-cancel transport))))

(defun tategaki-rag-cancel (job)
  "Cancel every stage in a RAG JOB, including a pending corpus request."
  (when (and (listp job) (plist-get job :rag-job) (not (plist-get job :cancelled)))
    (setf (plist-get job :cancelled) t)
    (unwind-protect
        (unless (plist-get job :done)
          (setf (plist-get job :done) t)
          (funcall (plist-get job :callback)
                   '(:ok nil :chunks nil :message "検索を取り消しました")))
      (dolist (transport (plist-get job :transports))
        (tategaki-rag--cancel-transport transport)))))

(defun tategaki-rag--track (job transport)
  "Retain TRANSPORT in JOB without overwriting a synchronously started stage."
  (when (or (bufferp transport) (and (listp transport) (plist-get transport :snapshot)))
    (if (plist-get job :cancelled) (tategaki-rag--cancel-transport transport)
      (cl-pushnew transport (plist-get job :transports) :test #'eq)))
  transport)

(defun tategaki-rag--unique-citation (label chunk labels)
  "Disambiguate LABEL for CHUNK against the per-answer LABELS table."
  (let ((identity (cons (plist-get chunk :document) (plist-get chunk :start)))
        (candidate label) (number 1))
    (while (and (gethash candidate labels)
                (not (equal identity (gethash candidate labels))))
      (cl-incf number)
      (setq candidate (format "%s#%d]" (substring label 0 -1) number)))
    (puthash candidate identity labels)
    candidate))

(defun tategaki-rag-context (query callback &optional cutoff region character)
  "Gather grounded context for QUERY asynchronously through CUTOFF.
REGION is a source-position pair.  CHARACTER limits known facts to that person.
CALLBACK receives :chunks, :text and :method."
  (let* ((source (tategaki-semantic-source))
         (root (with-current-buffer source (tategaki-project-root)))
         (registry (unless (or cutoff character) (tategaki-corpus--read root)))
         (context-limit (with-current-buffer source tategaki-rag-context-limit))
         (position (with-current-buffer source (point)))
         (all (with-current-buffer source
                (let ((chunks (tategaki-semantic-chunks source cutoff)))
                  (if (not character) chunks
                    (require 'tategaki-knowledge)
                    (tategaki-knowledge-filter-chunks chunks character cutoff)))))
         (near (seq-filter
                (lambda (chunk)
                  (if region
                      (and (< (plist-get chunk :start) (cdr region))
                           (> (plist-get chunk :end) (car region)))
                    (and (<= (plist-get chunk :start) position)
                         (>= (plist-get chunk :end) position)))) all))
         (near-index (cl-position (car near) all))
         (surrounding (when near-index
                        (seq-subseq all (max 0 (1- near-index))
                                    (min (length all) (+ near-index 2)))))
         (resources (unless (or cutoff character)
                      (tategaki-semantic-lexical-search query (tategaki-rag-resource-chunks) 3)))
         (world (when (require 'tategaki-world nil t)
                  (tategaki-world-context cutoff character)))
         (timeline (when (and (not character) (require 'tategaki-timeline nil t))
                     (tategaki-timeline-context cutoff)))
         (extra-context
          (concat (when (and world (not (string-empty-p world)))
                    (concat "\n\n作品設定（作者の登録情報）:\n" world))
                  (when (and timeline (not (string-empty-p timeline)))
                    (concat "\n\n作品時間:\n" timeline))))
         (extra-context (substring extra-context 0
                                   (min (max 0 (/ context-limit 3)) (length extra-context))))
         (hash (tategaki-semantic-hash source))
         (configuration (with-current-buffer source
                          (list tategaki-ai-enabled tategaki-ai-endpoint tategaki-ai-model
                                tategaki-ai-embedding-model tategaki-ai-provider)))
         (document (with-current-buffer source (or buffer-file-name (buffer-name))))
         (job (list :rag-job t :done nil :cancelled nil :transports nil :callback callback)))
    (cl-labels
        ((fresh-p ()
          (condition-case nil
           (and (buffer-live-p source) (equal hash (tategaki-semantic-hash source))
                (or cutoff character (equal registry (tategaki-corpus--read root)))
                (equal configuration
                       (with-current-buffer source
                         (list tategaki-ai-enabled tategaki-ai-endpoint tategaki-ai-model
                               tategaki-ai-embedding-model tategaki-ai-provider))))
           (error nil)))
         (finish (result)
           (unless (plist-get job :done)
             (setf (plist-get job :done) t)
             (funcall callback
                      (if (fresh-p) result
                        '(:ok nil :chunks nil :message "原稿または AI 設定が変更されました。再実行してください")))))
         (assemble (result corpus)
          (unless (plist-get job :done)
           (if (or (not (plist-get result :ok))
                   (and corpus (not (plist-get corpus :ok))))
               (finish (if (plist-get result :ok) corpus result))
            (let ((candidates (append near (plist-get result :chunks) surrounding
                                      (plist-get corpus :chunks) resources))
                  (remaining (max 0 (- context-limit (length extra-context))))
                  (labels (make-hash-table :test #'equal)) chunks parts seen)
              (if (not (cl-every #'tategaki-semantic-chunk-current-p candidates))
                  (finish '(:ok nil :chunks nil :message "原稿・資料が変更されたため送信を中止しました。再実行してください"))
               (dolist (chunk candidates)
                (let ((id (format "%s:%s" (plist-get chunk :document) (plist-get chunk :start))))
                  (when (and (> remaining 0) (not (member id seen)))
                    (push id seen)
                    (let* ((citation
                            (cond ((eq (plist-get chunk :kind) 'resource)
                                   (format "[資料:%s:%d]" (file-name-nondirectory (plist-get chunk :document))
                                           (plist-get chunk :start)))
                                  ((not (equal document (plist-get chunk :document)))
                                   (format "[原稿:%s:%s:%d]"
                                           (file-name-nondirectory (plist-get chunk :document))
                                           (plist-get chunk :chapter) (plist-get chunk :start)))
                                  (t (format "[%s:%d]" (plist-get chunk :chapter) (plist-get chunk :start)))))
                           (citation (tategaki-rag--unique-citation citation chunk labels))
                           (overhead (+ (length citation) 1 (if parts 2 0)))
                           (available (max 0 (- remaining overhead))))
                      (when (> available 0)
                        (let ((text (substring (plist-get chunk :text) 0
                                               (min available (length (plist-get chunk :text))))))
                          (push (plist-put (copy-sequence chunk) :citation citation) chunks)
                          (push (concat citation "\n" text) parts)
                          (setq remaining (- remaining overhead (length text)))))))))
              (finish
               (list :ok t :method (if (plist-get corpus :chunks)
                                      (format "%s / 登録資料:%s" (plist-get result :method) (plist-get corpus :method))
                                    (plist-get result :method))
                     :notice (let ((notices (delq nil (list (plist-get result :notice)
                                                            (and (plist-get corpus :chunks) (plist-get corpus :notice))))))
                               (and notices (string-join notices " / ")))
                     :chunks (nreverse chunks) :fresh-p #'fresh-p
                     :text (concat (mapconcat #'identity (nreverse parts) "\n\n") extra-context))))))))
         (source-ready (result)
           (unless (plist-get job :done)
             (if (or (not (plist-get result :ok)) (not (fresh-p))) (finish result)
               ;; A cutoff or character question must never query other files.
               (if (or cutoff character) (assemble result nil)
                 (with-current-buffer source
                   (tategaki-rag--track
                    job (tategaki-corpus-retrieve
                         query (lambda (corpus) (assemble result corpus)) nil t))))))))
     (condition-case error-data
      (tategaki-rag--track
       job (funcall
     (if character
         (lambda (query consumer &rest _)
           (funcall consumer
                    (list :ok t :method 'character-scoped
                          :notice "作者が確認した公開範囲のみ。未登録の知識は不明"
                          :chunks (append (tategaki-semantic-lexical-search query all)
                                          (seq-take all 6)))))
       #'tategaki-semantic-retrieve)
     query
     #'source-ready cutoff t))
      (error (finish (list :ok nil :chunks nil :message (error-message-string error-data))))))
    job))

(provide 'tategaki-rag)
;;; tategaki-rag.el ends here
