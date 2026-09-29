;;; tategaki-corpus-test.el --- Explicit collection safety regressions -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'cl-lib)
(require 'tategaki-corpus)

(defmacro tategaki-corpus-test--isolated (&rest body)
  "Evaluate BODY with synthetic files and an isolated manuscript."
  (declare (indent 0) (debug t))
  `(let* ((directory (file-truename (make-temp-file "tategaki-corpus-test-" t)))
          (default-directory (file-name-as-directory directory))
          (tategaki-project-default-file (expand-file-name "defaults.json" directory))
          (tategaki-session-file (expand-file-name "session.json" directory))
          (tategaki-history-directory (expand-file-name "history/" directory))
          (sea (expand-file-name "sea.txt" directory))
          (forest (expand-file-name "forest.txt" directory))
          (private (expand-file-name "unregistered.txt" directory)))
     (unwind-protect
         (save-window-excursion
           (with-temp-file sea (insert "第一章\n海を渡る船。\n"))
           (with-temp-file forest (insert "森林資料\n森の中に古い城がある。\n"))
           (with-temp-file private (insert "未登録の秘密を送信しない。"))
           (with-temp-buffer
             (text-mode)
             (setq buffer-file-name (expand-file-name "source.txt" directory))
             (insert "現在の作品。")
             (setq-local tategaki-ai-enabled t tategaki-ai-model "fixture-model"
                         tategaki-ai-endpoint "http://localhost:11434/v1"
                         tategaki-ai-embedding-model "fixture-embedding")
             (let ((source (current-buffer)))
               ,@body)))
       (dolist (buffer (buffer-list))
         (when (and (buffer-local-value 'buffer-file-name buffer)
                    (string-prefix-p directory (buffer-local-value 'buffer-file-name buffer)))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory directory t))))

(defun tategaki-corpus-test--embedding (texts callback &optional _authorized)
  "Return deterministic synthetic vectors for TEXTS to CALLBACK."
  (funcall callback
           (list :ok t :vectors
                 (mapcar (lambda (text) (if (string-match-p "海" text) '(1.0 0.0) '(0.0 1.0))) texts))))

(defun tategaki-corpus-test--await (predicate)
  "Allow pending index timers to run until PREDICATE, with a short deadline."
  (let ((limit (+ (float-time) 3)))
    (while (and (not (funcall predicate)) (< (float-time) limit))
      (sleep-for 0.01))
    (should (funcall predicate))))

(defun tategaki-corpus-test--index ()
  "Build the isolated synthetic index with its real asynchronous batch loop."
  (let (result)
    (cl-letf (((symbol-function 'tategaki-ai-embed) #'tategaki-corpus-test--embedding))
      (tategaki-corpus-index (lambda (value) (setq result value)))
      (tategaki-corpus-test--await (lambda () result)))
    (should (plist-get result :ok))))

(ert-deftest tategaki-corpus-register-select-remove-never-scans-or-sends ()
  (tategaki-corpus-test--isolated
    (cl-letf (((symbol-function 'tategaki-ai-embed) (lambda (&rest _) (ert-fail "registration sent data")))
              ((symbol-function 'directory-files-recursively) (lambda (&rest _) (ert-fail "directory scan"))))
      (tategaki-corpus-register sea 'manuscript)
      (tategaki-corpus-register forest 'resource)
      (let ((records (tategaki-corpus--read directory)))
        (should (= (length records) 2))
        (should-not (cl-find private records :key (lambda (r) (alist-get 'file r)) :test #'equal)))
      (tategaki-corpus-set-enabled forest nil)
      (let (result)
        (tategaki-corpus-retrieve "森" (lambda (r) (setq result r)))
        (should (plist-get result :ok))
        (should-not (plist-get result :chunks)))
      (tategaki-corpus-remove sea)
      (should (= (length (tategaki-corpus--read directory)) 1))
      (should (file-exists-p sea))
      (should (file-exists-p forest)))))

(ert-deftest tategaki-corpus-corrupt-registry-is-preserved ()
  (tategaki-corpus-test--isolated
    (let ((file (tategaki-corpus--file directory)))
      (dolist (bad '("{broken" "null" "{}" "{\"schema_version\":1,\"documents\":[]} trailing"))
        (tategaki-history--atomic-write file bad)
        (should-error (tategaki-corpus-register sea) :type 'error)
        (should (equal bad (with-temp-buffer (insert-file-contents file) (buffer-string))))))))

(ert-deftest tategaki-corpus-rejects-remote-and-directory-registration ()
  (tategaki-corpus-test--isolated
    (should-error (tategaki-corpus-register "/ssh:elsewhere:/secret.txt") :type 'user-error)
    (should-error (tategaki-corpus-register directory) :type 'user-error)))

(ert-deftest tategaki-corpus-prefers-dirty-live-text-without-altering-source ()
  (tategaki-corpus-test--isolated
    (tategaki-corpus-register sea 'manuscript)
    (let ((live (find-file-noselect sea)) result)
      (with-current-buffer live
        (goto-char (point-max)) (insert "未保存の海辺。")
        (goto-char 3)
        (let ((text (buffer-string)) (undo buffer-undo-list))
          (with-current-buffer source
            (tategaki-corpus-retrieve "未保存" (lambda (r) (setq result r))))
          (should (equal text (buffer-string)))
          (should (eq undo buffer-undo-list))
          (should (= (point) 3))
          (should (buffer-modified-p))
          (should (string-match-p "未保存" (plist-get (car (plist-get result :chunks)) :text)))
          (should (eq live (plist-get (car (plist-get result :chunks)) :buffer)))))
      (should-not (string-match-p "未保存" (with-temp-buffer (insert-file-contents sea) (buffer-string)))))))

(ert-deftest tategaki-corpus-index-and-search-use-selected-documents-and-cached-vectors ()
  (tategaki-corpus-test--isolated
    (tategaki-corpus-register sea 'manuscript)
    (tategaki-corpus-register forest 'resource)
    (let (sent result)
      (cl-letf (((symbol-function 'tategaki-ai-embed)
                 (lambda (texts callback &optional authorized)
                   (should (equal tategaki-ai-model "fixture-model"))
                   (setq sent (append sent texts))
                   (tategaki-corpus-test--embedding texts callback authorized))))
        (tategaki-corpus-index (lambda (r) (setq result r)))
        (tategaki-corpus-test--await (lambda () result))
        (should (plist-get result :ok))
        (should-not (string-match-p "未登録" (string-join sent)))
        (setq sent nil result nil)
        (tategaki-corpus-retrieve "海" (lambda (r) (setq result r)))
        (should (eq (plist-get result :method) 'semantic))
        (should (equal sent '("海")))
        (should (equal (plist-get (car (plist-get result :chunks)) :document) sea))
        (should-not (plist-get (car (plist-get result :chunks)) :buffer))
        (setq result nil)
        (tategaki-corpus-retrieve "海" (lambda (r) (setq result r)) t)
        (should (eq (plist-get result :method) 'semantic))
        (should (= (length (plist-get result :chunks)) 1))
        (should (eq (plist-get (car (plist-get result :chunks)) :kind) 'resource)))
      (let ((cache (tategaki-corpus--file directory t)))
        (should (= (file-modes cache) #o600))
        (should-not (string-match-p "船" (with-temp-buffer (insert-file-contents cache) (buffer-string))))))))

(ert-deftest tategaki-corpus-stale-or-corrupt-cache-discloses-lexical-fallback ()
  (tategaki-corpus-test--isolated
    (tategaki-corpus-register sea)
    (tategaki-corpus-test--index)
    (with-temp-file sea (insert "海の本文が変化。"))
    (cl-letf (((symbol-function 'tategaki-ai-embed) (lambda (&rest _) (ert-fail "stale vectors used"))))
      (let (result)
        (tategaki-corpus-retrieve "海" (lambda (r) (setq result r)))
        (should (eq (plist-get result :method) 'lexical))
        (should (plist-get result :notice)))
      (tategaki-history--atomic-write (tategaki-corpus--file directory t) "{broken")
      (let (result)
        (tategaki-corpus-retrieve "海" (lambda (r) (setq result r)))
        (should (eq (plist-get result :method) 'lexical))))))

(ert-deftest tategaki-corpus-index-discards-async-response-after-exclusion ()
  (tategaki-corpus-test--isolated
    (tategaki-corpus-register sea)
    (let (pending result)
      (cl-letf (((symbol-function 'tategaki-ai-embed)
                 (lambda (_ callback &optional _authorized) (setq pending callback) nil)))
        (tategaki-corpus-index (lambda (r) (setq result r)))
        (tategaki-corpus-set-enabled sea nil)
        (funcall pending '(:ok t :vectors ((1.0 0.0))))
        (should-not (plist-get result :ok))
        (should (eq (plist-get result :method) 'stale))
        (should-not (file-exists-p (tategaki-corpus--file directory t)))))))

(ert-deftest tategaki-corpus-retrieve-discards-edited-content-or-provider ()
  (dolist (change '(text provider))
    (tategaki-corpus-test--isolated
      (tategaki-corpus-register sea)
      (tategaki-corpus-test--index)
      (let (pending result)
        (cl-letf (((symbol-function 'tategaki-ai-embed)
                   (lambda (_ callback &optional _authorized) (setq pending callback) nil)))
          (tategaki-corpus-retrieve "海" (lambda (r) (setq result r)))
          (if (eq change 'text) (with-temp-file sea (insert "変更後"))
            (setq tategaki-ai-embedding-model "other-model"))
          (funcall pending '(:ok t :vectors ((1.0 0.0))))
          (should-not (plist-get result :ok))
          (should-not (plist-get result :chunks)))))))

(ert-deftest tategaki-corpus-cancel-closes-transport-and-delivers-once ()
  (tategaki-corpus-test--isolated
    (tategaki-corpus-register sea)
    (let ((request (generate-new-buffer " *corpus request*")) pending job responses)
      (unwind-protect
          (cl-letf (((symbol-function 'tategaki-ai-embed)
                     (lambda (_ callback &optional _authorized)
                       (setq pending callback)
                       (with-current-buffer request
                         (setq-local tategaki-ai--cancel
                                     (lambda () (funcall callback '(:ok nil :message "cancelled")))))
                       request)))
            (setq job (tategaki-corpus-index (lambda (r) (push r responses))))
            (tategaki-corpus-cancel job)
            (should-not (buffer-live-p request))
            (should (= (length responses) 1))
            (should (eq (plist-get (car responses) :method) 'cancelled))
            (funcall pending '(:ok t :vectors ((1.0 0.0))))
            (should (= (length responses) 1))
            (should-not (file-exists-p (tategaki-corpus--file directory t))))
        (when (buffer-live-p request) (kill-buffer request))))))

(ert-deftest tategaki-corpus-source-kill-cancels-pending-request ()
  (tategaki-corpus-test--isolated
    (tategaki-corpus-register sea)
    (let ((request (generate-new-buffer " *corpus killed-source request*")) result)
      (cl-letf (((symbol-function 'tategaki-ai-embed) (lambda (&rest _) request)))
        (tategaki-corpus-index (lambda (r) (setq result r)))
        (tategaki-corpus--cancel-buffer)
        (should-not (buffer-live-p request))
        (should (eq (plist-get result :method) 'cancelled))))))

(ert-deftest tategaki-corpus-authorization-failure-leaves-no-pending-job ()
  (tategaki-corpus-test--isolated
    (tategaki-corpus-register sea)
    (tategaki-corpus-test--index)
    (cl-letf (((symbol-function 'tategaki-ai-authorize) (lambda () (user-error "declined"))))
      (should-error (tategaki-corpus-index) :type 'user-error)
      (should-not tategaki-corpus--jobs)
      (let (responses)
        (tategaki-corpus-retrieve "海" (lambda (r) (push r responses)))
        (should (= (length responses) 1))
        (should-not (plist-get (car responses) :ok))
        (should-not tategaki-corpus--jobs)
        (tategaki-corpus--cancel-buffer)
        (should (= (length responses) 1))))))

(ert-deftest tategaki-corpus-citation-checks-live-text-and-opens-unvisited-manuscript ()
  (tategaki-corpus-test--isolated
    (tategaki-corpus-register sea 'manuscript)
    (let (chunk)
      (tategaki-corpus-retrieve "海" (lambda (r) (setq chunk (car (plist-get r :chunks)))))
      (should-not (get-file-buffer sea))
      (tategaki-corpus-visit chunk)
      (should (equal buffer-file-name sea))
      (should (= (point) (plist-get chunk :start)))
      (insert "changed")
      (should-error (tategaki-corpus-visit chunk) :type 'user-error))))

(provide 'tategaki-corpus-test)
;;; tategaki-corpus-test.el ends here
