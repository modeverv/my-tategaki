;;; tategaki-semantic.el --- Source grounded asynchronous search -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'seq)
(require 'tategaki-ai)
(require 'tategaki-pane)

(defcustom tategaki-semantic-chunk-size 800 "Maximum source characters per chunk."
  :type 'integer :group 'tategaki-ai)
(defcustom tategaki-semantic-result-count 6 "Maximum retrieved passages."
  :type 'integer :group 'tategaki-ai)
(defvar-local tategaki-semantic--index nil)
(defvar-local tategaki-semantic--job nil)
(defvar-local tategaki-semantic--search-token nil)
(defvar-local tategaki-semantic--search-request nil)
(defvar-local tategaki-semantic--search-cancel-function nil)
(defconst tategaki-semantic--heading-regexp
  "\\(?:第[^\n　 ]+[章節部話]\\|#+ +\\|\\*+ +\\).*$")
(defconst tategaki-semantic--scene-regexp
  "[ \t　]*\\(?:[*＊][*＊]+\\|---+\\)[ \t　]*$")
(defvar tategaki-studio-source)
(declare-function tategaki-studio-source-buffer "tategaki-studio" (&optional buffer))
(declare-function tategaki-project-root "tategaki-project" (&optional directory))
(declare-function tategaki-refresh "tategaki" ())
(declare-function tategaki-world-query "tategaki-world" (&optional type cutoff character))
(declare-function tategaki-world-scenes "tategaki-world" (&optional cutoff include-candidates))
(declare-function tategaki-world-aliases "tategaki-world" (&optional include-candidates))
(declare-function tategaki-world-scene-range "tategaki-world" (record &optional cutoff))
(declare-function tategaki-world-reference-valid-p "tategaki-world" (reference &optional buffer))
(declare-function tategaki-timeline-records "tategaki-timeline" (&optional cutoff))
(declare-function tategaki-timeline-resolve "tategaki-timeline" (record &optional records seen))

(defun tategaki-semantic-source ()
  "Resolve a manuscript without requiring Studio for ordinary Lisp use."
  (if (fboundp 'tategaki-studio-source-buffer) (tategaki-studio-source-buffer)
    (current-buffer)))

(defun tategaki-semantic-hash (&optional buffer)
  "Hash all source characters in BUFFER, independent of narrowing."
  (with-current-buffer (or buffer (current-buffer))
    (save-restriction (widen)
      (secure-hash 'sha256 (buffer-substring-no-properties (point-min) (point-max))))))

(defun tategaki-semantic-chunks (&optional buffer cutoff)
  "Return source-addressable paragraph chunks from BUFFER through CUTOFF.
Scene breaks and headings are recognized without altering the source."
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (save-restriction
        (widen)
        (let ((limit (min (point-max) (or cutoff (point-max))))
              (document (or buffer-file-name (buffer-name)))
              (hash (tategaki-semantic-hash))
              (chapter "本文") (scene 1) chunks)
          (goto-char (point-min))
          (while (< (point) limit)
            (cond
             ((looking-at "[ \t　]*$") (forward-line 1))
             ((looking-at tategaki-semantic--scene-regexp)
              (cl-incf scene) (forward-line 1))
             (t
              (when (looking-at tategaki-semantic--heading-regexp)
                (setq chapter
                      (string-trim
                       (buffer-substring-no-properties
                        (match-beginning 0) (min limit (match-end 0))))))
              (let ((start (point))
                    (end (min limit (save-excursion
                                      (forward-line 1)
                                      (while (and (< (point) limit)
                                                  (not (looking-at "[ \t　]*$"))
                                                  (not (looking-at tategaki-semantic--heading-regexp))
                                                  (not (looking-at tategaki-semantic--scene-regexp)))
                                        (forward-line 1))
                                      (point)))))
                (when (= start end) (setq end (min limit (1+ start))))
                (while (< start end)
                  (let* ((stop (min end (+ start (max 50 tategaki-semantic-chunk-size))))
                         (text (buffer-substring-no-properties start stop)))
                    (push (list :document document :buffer (current-buffer)
                                :chapter chapter :scene scene :start start :end stop
                                :characters nil :pov nil :story-time nil :kind 'manuscript
                                :hash (secure-hash 'sha256 text) :source-hash hash :text text)
                          chunks)
                    (setq start stop)))
                (goto-char end)))))
          (tategaki-semantic-annotate-chunks (nreverse chunks) cutoff))))))

(defun tategaki-semantic-annotate-chunks (chunks &optional cutoff)
  "Attach author-reviewed people, viewpoint and times to CHUNKS.
Names found literally are tagged as mentions only; they grant no knowledge.
Recompute annotations independently of vector caches when author records change."
  (if (not (require 'tategaki-world nil t)) chunks
    (let* ((people (ignore-errors (tategaki-world-query "Character")))
           (aliases (and (fboundp 'tategaki-world-aliases)
                         (ignore-errors (tategaki-world-aliases))))
           (scenes (and (fboundp 'tategaki-world-scenes)
                        (ignore-errors (tategaki-world-scenes cutoff))))
           (times (when (require 'tategaki-timeline nil t)
                    (seq-remove
                     (lambda (record)
                       (or (member (plist-get record :state) '("inferred" "rejected"))
                           (not (tategaki-world-reference-valid-p
                                 (plist-get record :source)))))
                     (ignore-errors (tategaki-timeline-records cutoff))))))
      (mapcar
       (lambda (chunk)
         (let ((text (plist-get chunk :text)) names viewpoints dates)
           (dolist (person people)
             (let ((name (or (plist-get person :name) (plist-get person :subject))))
               (when (and (stringp name) (not (string-empty-p name))
                          (string-match-p (regexp-quote name) text))
                 (push name names))))
           (dolist (alias aliases)
             (let ((name (plist-get alias :subject)) (variant (plist-get alias :value)))
               (when (and (stringp name) (stringp variant) (not (string-empty-p variant))
                          (string-match-p (regexp-quote variant) text))
                 (push name names))))
           (dolist (scene scenes)
             (let ((range (tategaki-world-scene-range scene cutoff)))
               (when (and range (<= (car range) (plist-get chunk :start))
                          (>= (cdr range) (plist-get chunk :end)))
                 (setq names (append (append (plist-get scene :characters) nil) names))
                 (when (and (stringp (plist-get scene :pov))
                            (not (string-empty-p (plist-get scene :pov))))
                   (push (plist-get scene :pov) viewpoints)))))
           (dolist (record times)
             (let ((ref (plist-get record :source)))
               (when (and (not (equal (plist-get record :state) "inferred"))
                          (not (equal (plist-get record :state) "rejected"))
                          (tategaki-world-reference-valid-p ref)
                          (< (plist-get ref :start) (plist-get chunk :end))
                          (> (plist-get ref :end) (plist-get chunk :start)))
                 (let ((time (tategaki-timeline-resolve record times)))
                   (when time
                     (push (format-time-string "%Y-%m-%d %H:%M" time t) dates))))))
           (setq viewpoints (delete-dups viewpoints)
                 chunk (plist-put chunk :characters (delete-dups names))
                 chunk (plist-put chunk :pov (and (= (length viewpoints) 1) (car viewpoints)))
                 chunk (plist-put chunk :story-time (delete-dups dates)))
           chunk)) chunks))))

(defun tategaki-semantic--model-key ()
  "Identify the embedding space, including the endpoint and selected model."
  (list tategaki-ai-endpoint
        (if (string-empty-p tategaki-ai-embedding-model)
            tategaki-ai-model tategaki-ai-embedding-model)))

(defun tategaki-semantic--cache-file ()
  "Return this saved manuscript's private index path, or nil when unsaved."
  (when (and buffer-file-name (require 'tategaki-project nil t))
    (expand-file-name
     (concat ".tategaki/index/" (secure-hash 'sha256 (expand-file-name buffer-file-name)) ".json")
     (tategaki-project-root))))

(defun tategaki-semantic-save-index ()
  "Atomically persist the current source-checked index as ordinary JSON data."
  (let ((file (tategaki-semantic--cache-file))
        (index tategaki-semantic--index))
    (when (and file tategaki-semantic--index)
      (make-directory (file-name-directory file) t)
      (let ((temporary (make-temp-file (expand-file-name ".index-" (file-name-directory file)))))
        (unwind-protect
            (progn
              (with-temp-file temporary
                (let ((coding-system-for-write 'utf-8-unix))
                  (insert
                   (json-encode
                    `((schema_version . 1)
                      (hash . ,(plist-get index :hash))
                      (model . ,(vconcat (plist-get index :model)))
                      (vectors . ,(vconcat
                                   (mapcar (lambda (c) (vconcat (plist-get c :vector)))
                                           (plist-get index :chunks)))))))))
              (set-file-modes temporary #o600)
              (rename-file temporary file t))
          (when (file-exists-p temporary) (delete-file temporary)))))))

(defun tategaki-semantic-load-index ()
  "Load a matching index, ignoring malformed, stale or foreign-provider caches."
  (let ((file (tategaki-semantic--cache-file)))
    (when (and file (file-readable-p file)
               (< (file-attribute-size (file-attributes file)) (* 64 1024 1024)))
      (condition-case nil
          (let* ((json-object-type 'alist) (json-array-type 'list)
                 (data (json-read-file file))
                 (chunks (tategaki-semantic-chunks))
                 (vectors (alist-get 'vectors data)))
            (when (and (equal (alist-get 'schema_version data) 1)
                       (equal (alist-get 'hash data) (tategaki-semantic-hash))
                       (equal (alist-get 'model data) (tategaki-semantic--model-key))
                       (= (length chunks) (length vectors))
                       (cl-every (lambda (v) (and (consp v) (cl-every #'numberp v))) vectors))
              (setq tategaki-semantic--index
                    (list :hash (alist-get 'hash data) :model (alist-get 'model data)
                          :chunks (cl-mapcar (lambda (c v) (plist-put c :vector v)) chunks vectors)))))
        (error nil)))))

(defun tategaki-semantic-cosine (a b)
  "Return cosine similarity of equal-dimensional nonzero vectors A and B."
  (if (or (/= (length a) (length b)) (null a)) -1.0
    (let ((dot 0.0) (aa 0.0) (bb 0.0))
      (cl-mapc (lambda (x y)
                 (setq dot (+ dot (* x y)) aa (+ aa (* x x)) bb (+ bb (* y y)))) a b)
      (if (or (zerop aa) (zerop bb)) 0.0 (/ dot (sqrt (* aa bb)))))))

(defun tategaki-semantic--tokens (text)
  "Return word tokens plus Japanese bigrams for a useful offline search."
  (let* ((text (downcase text))
         (tokens (split-string text "[^[:alnum:]一-龯ぁ-んァ-ヶー]+" t)) pairs)
    (dolist (token tokens)
      (when (string-match-p "[一-龯ぁ-んァ-ヶ]" token)
        (dotimes (n (max 0 (1- (length token))))
          (push (substring token n (+ n 2)) pairs))))
    (delete-dups (append tokens pairs))))

(defun tategaki-semantic-lexical-search (query chunks &optional count)
  "Return at most COUNT CHUNKS matching QUERY without any external service."
  (let ((tokens (tategaki-semantic--tokens query)) scored)
    (dolist (chunk chunks)
      (let* ((text (downcase (plist-get chunk :text)))
             (score (cl-count-if (lambda (token) (string-match-p (regexp-quote token) text)) tokens)))
        (when (> score 0) (push (cons score chunk) scored))))
    (mapcar #'cdr (seq-take (sort scored (lambda (a b) (> (car a) (car b))))
                           (or count tategaki-semantic-result-count)))))

(defun tategaki-semantic-index (&optional callback)
  "Build an embedding index asynchronously for the current manuscript.
Discard results when source or provider changes.  CALLBACK receives a result."
  (interactive)
  (with-current-buffer (tategaki-semantic-source)
    (tategaki-ai-authorize)
    (let* ((source (current-buffer)) (hash (tategaki-semantic-hash))
           (key (tategaki-semantic--model-key))
           (job (list hash (float-time)))
           (remaining (tategaki-semantic-chunks)) (indexed nil)
           (callback (or callback (lambda (r) (message "%s" (plist-get r :message))))))
      (setq tategaki-semantic--job job)
      (cl-labels
          ((valid () (and (buffer-live-p source)
                          (with-current-buffer source
                            (and (eq job tategaki-semantic--job)
                                 (equal hash (tategaki-semantic-hash))
                                 (equal key (tategaki-semantic--model-key))))))
           (step ()
             (cond
              ((not (valid)) (funcall callback (list :ok nil :message "原稿または設定が変更されたため索引を中止しました")))
              ((null remaining)
               (with-current-buffer source
                 (setq tategaki-semantic--index (list :hash hash :model key :chunks (nreverse indexed))
                       tategaki-semantic--job nil)
                 (condition-case err (tategaki-semantic-save-index)
                   (error (message "索引はメモリ上のみです: %s" (error-message-string err)))))
               (funcall callback (list :ok t :message "意味検索の索引を更新しました")))
              (t
               (let ((batch (seq-take remaining 16)))
                 (setq remaining (nthcdr (length batch) remaining))
                 (with-current-buffer source
                   (tategaki-ai-embed
                    (mapcar (lambda (c) (plist-get c :text)) batch)
                    (lambda (result)
                      (if (not (plist-get result :ok))
                          (progn
                            (when (buffer-live-p source)
                              (with-current-buffer source
                                (when (eq job tategaki-semantic--job)
                                  (setq tategaki-semantic--job nil))))
                            (funcall callback result))
                        (cl-mapc (lambda (chunk vector)
                                   (push (plist-put chunk :vector vector) indexed))
                                 batch (plist-get result :vectors))
                        ;; Yield between batches even with a synchronous test provider.
                        (run-at-time 0 nil #'step))) t)))))))
        (step)))))

(defun tategaki-semantic-retrieve (query callback &optional cutoff authorized)
  "Find QUERY passages, delivering :chunks and :method to CALLBACK.
Use a fresh embedding index when available, otherwise disclose lexical fallback.
Only passages through CUTOFF can be returned."
  (let* ((source (tategaki-semantic-source))
         (chunks (tategaki-semantic-chunks source cutoff))
         (hash (tategaki-semantic-hash source))
         (model (with-current-buffer source (tategaki-semantic--model-key)))
         (count (with-current-buffer source tategaki-semantic-result-count))
         (callback
          (let ((consumer callback))
            (lambda (result)
              (funcall consumer
                       (if (and (buffer-live-p source)
                                (equal hash (tategaki-semantic-hash source))
                                (equal model (with-current-buffer source (tategaki-semantic--model-key))))
                           result
                         (list :ok nil :message "原稿または AI 設定が変更されました。検索をやり直してください"))))))
         (fallback (lambda (&optional reason)
                     (funcall callback
                              (list :ok t :method 'lexical :notice reason
                                    :chunks (tategaki-semantic-lexical-search query chunks count))))))
    (with-current-buffer source
      (unless tategaki-semantic--index (tategaki-semantic-load-index))
      (if (not (and tategaki-ai-enabled tategaki-semantic--index
                    (equal (plist-get tategaki-semantic--index :hash) (tategaki-semantic-hash))
                    (equal (plist-get tategaki-semantic--index :model) (tategaki-semantic--model-key))))
          (funcall fallback "意味索引が未作成または古いため、語句検索を使用")
        (let ((index tategaki-semantic--index))
          (tategaki-ai-embed
           (list query)
           (lambda (result)
             (if (not (plist-get result :ok)) (funcall fallback (plist-get result :message))
               (let ((vector (car (plist-get result :vectors))) scored)
                 (dolist (cached (plist-get index :chunks))
                   ;; Keep source text and author metadata fresh even when
                   ;; only the world/timeline store, not the manuscript, changed.
                   (let ((chunk (cl-find-if
                                 (lambda (item)
                                   (and (= (plist-get item :start) (plist-get cached :start))
                                        (= (plist-get item :end) (plist-get cached :end)))) chunks)))
                     (when chunk
                       (push (cons (tategaki-semantic-cosine vector (plist-get cached :vector)) chunk) scored))))
                 (funcall callback
                          (list :ok t :method 'semantic
                                :chunks (mapcar #'cdr
                                                (seq-take (sort scored (lambda (a b) (> (car a) (car b))))
                                                          count))))))) authorized))))))

(defun tategaki-semantic-chunk-current-p (chunk)
  "Whether CHUNK still matches the authoritative live or saved document."
  (condition-case nil
      (let* ((file (plist-get chunk :document))
             (local-file (and (stringp file) (file-name-absolute-p file) (not (file-remote-p file))))
             (recorded (plist-get chunk :buffer))
             (source (or (and (buffer-live-p recorded) recorded)
                         (and local-file (find-buffer-visiting file)))))
        (and (stringp (plist-get chunk :source-hash))
             (equal (plist-get chunk :source-hash)
                    (if source (tategaki-semantic-hash source)
                      (and local-file (file-regular-p file) (file-readable-p file)
                           (with-temp-buffer (insert-file-contents file)
                                             (tategaki-semantic-hash)))))))
    (error nil)))

(defun tategaki-semantic--reference-origin ()
  "Return an explicit Studio or pane manuscript for a reference visit."
  (or (and (boundp 'tategaki-studio-source)
           (buffer-live-p tategaki-studio-source) tategaki-studio-source)
      (and (buffer-live-p tategaki-pane-source) tategaki-pane-source)
      (and (bound-and-true-p tategaki-studio-mode) (current-buffer))))

(defun tategaki-semantic--install-reference-pane (origin target)
  "Let an auxiliary TARGET close back to ORIGIN without changing editing keys."
  (when (and (buffer-live-p origin) (not (eq origin target)))
    (with-current-buffer target
      (unless (bound-and-true-p tategaki-studio-mode)
        (tategaki-pane-install origin nil "参照資料")))))

(defun tategaki-semantic-visit (chunk)
  "Visit a CHUNK only while its original source hash remains valid."
  (let* ((origin (tategaki-semantic--reference-origin))
         (file (plist-get chunk :document))
         (local-file (and (stringp file) (file-name-absolute-p file) (not (file-remote-p file))))
         (recorded (plist-get chunk :buffer))
         (source (or (and (buffer-live-p recorded) recorded)
                     (and local-file (find-buffer-visiting file)))))
    ;; Live buffers are authoritative, including dirty reference material.
    ;; Unvisited collection manuscripts may have no surviving :buffer.
    (unless (tategaki-semantic-chunk-current-p chunk)
      (user-error "原稿・資料が変更されています。検索・相談をやり直してください"))
    (unless source
      (setq source (find-file-noselect file)))
    ;; Recheck after opening in case a visiting buffer or disk changed.
    (unless (equal (plist-get chunk :source-hash) (tategaki-semantic-hash source))
      (user-error "原稿・資料が変更されています。検索・相談をやり直してください"))
    (tategaki-semantic--install-reference-pane origin source)
    (pop-to-buffer source)
    (widen)
    (goto-char (plist-get chunk :start))
    (when (bound-and-true-p tategaki-mode) (tategaki-refresh))))

(defun tategaki-semantic--search-cancel ()
  "Invalidate this pane's pending search before cancelling its own request."
  (let ((request tategaki-semantic--search-request)
        (cancel tategaki-semantic--search-cancel-function))
    ;; Cancellation may invoke the result callback synchronously.
    (setq tategaki-semantic--search-token nil
          tategaki-semantic--search-request nil
          tategaki-semantic--search-cancel-function nil)
    (when (and request cancel) (funcall cancel request))))

(defun tategaki-semantic--search-close ()
  "Cancel only this pane's search, then hide its results."
  (interactive)
  (tategaki-semantic--search-cancel)
  (quit-window))

(defun tategaki-semantic--search-run (source name query label retrieve cancel render)
  "Prepare a closable search pane NAME before calling RETRIEVE for QUERY.
SOURCE owns the query, LABEL names the header.  RETRIEVE takes QUERY and a
callback and returns a handle accepted by CANCEL.  RENDER receives a result
in the pane buffer.  Completion never displays a window or recreates a pane."
  (let ((panel (get-buffer-create name))
        (token (make-symbol "tategaki-search"))
        completed)
    (with-current-buffer panel
      (tategaki-semantic--search-cancel)
      (special-mode)
      (setq-local tategaki-studio-source source)
      (setq tategaki-semantic--search-token token
            tategaki-semantic--search-cancel-function cancel)
      (tategaki-pane-install source #'tategaki-semantic--search-close label)
      (local-set-key (kbd "q") #'tategaki-pane-close)
      (add-hook 'kill-buffer-hook #'tategaki-semantic--search-cancel nil t)
      (add-hook 'change-major-mode-hook #'tategaki-semantic--search-cancel nil t)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert query " — 検索中…\n")
        (goto-char (point-min))))
    (display-buffer-in-side-window panel '((side . bottom) (slot . 0) (window-height . 0.3)))
    (cl-labels
        ((current-p ()
           (and (buffer-live-p source) (buffer-live-p panel)
                (eq token (buffer-local-value 'tategaki-semantic--search-token panel))))
         (finish (result)
           (when (current-p)
             (setq completed t)
             (with-current-buffer panel
               (setq tategaki-semantic--search-token nil
                     tategaki-semantic--search-request nil
                     tategaki-semantic--search-cancel-function nil)
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (funcall render result)
                 (goto-char (point-min)))))))
      (condition-case error-data
          (let ((request (with-current-buffer source (funcall retrieve query #'finish))))
            (cond ((current-p)
                   (with-current-buffer panel
                     (setq tategaki-semantic--search-request request)))
                  ;; A recursive event loop can close the pane before RETRIEVE
                  ;; returns its handle.  A synchronous completion needs no cancel.
                  ((and request (not completed)) (funcall cancel request))))
        (error (finish (list :ok nil :message (error-message-string error-data))))
        (quit
         (when (current-p)
           (with-current-buffer panel (tategaki-semantic--search-cancel)))
         (signal (car error-data) (cdr error-data)))))
    panel))

(defun tategaki-semantic-search (query)
  "Search the manuscript and show clickable, source-checked passages."
  (interactive "s原稿を検索: ")
  (tategaki-semantic--search-run
   (tategaki-semantic-source) "*Tategaki Search*" query "原稿検索"
   #'tategaki-semantic-retrieve #'tategaki-ai-cancel
   (lambda (result)
     (insert (format "%s — %s\n%s\n\n" query (or (plist-get result :method) "")
                     (or (plist-get result :notice) (plist-get result :message) "")))
     (dolist (chunk (plist-get result :chunks))
       (insert-text-button
        (format "[%s:%d]" (plist-get chunk :chapter) (plist-get chunk :start))
        'follow-link t 'action (lambda (_) (tategaki-semantic-visit chunk)))
       (insert "\n" (plist-get chunk :text) "\n\n"))
     (unless (plist-get result :chunks) (insert "一致する箇所はありません。\n")))))

(provide 'tategaki-semantic)
;;; tategaki-semantic.el ends here
