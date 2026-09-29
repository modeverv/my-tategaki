;;; tategaki-provider-restore-test.el --- Legacy provider recovery -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'tategaki-ai)
(require 'tategaki-project)
(require 'tategaki-settings)

(defmacro tategaki-provider-test--project (&rest body)
  "Run BODY with an isolated legacy project and a dirty manuscript."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "tategaki-provider-test-" t))
          (tategaki-project-default-file (expand-file-name "defaults.json" directory))
          (tategaki-ai-provider 'ollama)
          (source (generate-new-buffer " *provider-source*"))
          (settings nil))
     (unwind-protect
         (save-window-excursion
           (with-current-buffer source
             (setq default-directory (file-name-as-directory directory)
                   buffer-file-name (expand-file-name "novel.txt" directory))
             (buffer-enable-undo)
             (insert "第一章\n未保存の原稿。\n")
             (goto-char 4)
             (set-mark 9)
             (setq mark-active t)
             ,@body))
       (when (buffer-live-p settings)
         (with-current-buffer settings
           (let ((tategaki-settings--allow-kill t)) (kill-buffer settings))))
       (when (buffer-live-p source) (kill-buffer source))
       (delete-directory directory t))))

(defun tategaki-provider-test--write (settings)
  "Replace the isolated project's SETTINGS, including omitted-key cases."
  (let ((file (tategaki-project-file)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (json-encode `((schema_version . 1) (settings . ,settings)))))))

(ert-deftest tategaki-provider-standard-endpoints-are-exact ()
  (dolist (host '("localhost" "127.0.0.1"))
    (dolist (entry '((11434 . ollama) (1234 . lm-studio) (8080 . llama-cpp)))
      (dolist (tail '("" "/" "//"))
        (let ((url (format "http://%s:%s/v1%s" host (car entry) tail)))
          (should (eq (tategaki-ai-provider-for-endpoint url) (cdr entry)))
          (should (tategaki-ai-standard-endpoint-p url))))))
  (dolist (endpoint '(nil "" "http://localhost:1234" "https://localhost:1234/v1"
                     "http://localhost:1235/v1" "http://localhost:1234/custom/v1"
                     "http://localhost:1234/v1?custom=1" "http://localhost:1234/v1#x"
                     "http://user@localhost:1234/v1" "http://localhost.example:1234/v1"
                     "http://192.168.1.2:1234/v1" "http://127.0.0.2:1234/v1"))
    (should-not (tategaki-ai-provider-for-endpoint endpoint))))

(ert-deftest tategaki-provider-legacy-endpoint-restores-without-writing ()
  (tategaki-provider-test--project
    (tategaki-provider-test--write
     '((ai-endpoint . "http://localhost:1234/v1") (ai-enabled . t)
       (ai-model . "synthetic-chat") (ai-embedding-model . "synthetic-embedding")))
    (let* ((file (tategaki-project-file))
           (json (with-temp-buffer (insert-file-contents file) (buffer-string)))
           (text (buffer-string)) (tick (buffer-chars-modified-tick))
           (undo buffer-undo-list) (position (point)) (mark (mark))
           (active mark-active) (dirty (buffer-modified-p)))
      (dotimes (_ 3)
        (tategaki-project-apply-settings)
        (should (eq tategaki-ai-provider 'lm-studio))
        (should (eq tategaki-project--inferred-ai-provider 'lm-studio)))
      (should (equal json (with-temp-buffer (insert-file-contents file) (buffer-string))))
      (should-not (assq 'ai-provider (alist-get 'settings (tategaki-project-load))))
      (should (equal text (buffer-string)))
      (should (= tick (buffer-chars-modified-tick)))
      (should (eq undo buffer-undo-list))
      (should (= position (point)))
      (should (= mark (mark)))
      (should (eq active mark-active))
      (should (eq dirty (buffer-modified-p))))))

(ert-deftest tategaki-provider-inference-recomputes-and-clears-stale-value ()
  (tategaki-provider-test--project
    (dolist (entry '(("http://localhost:1234/v1" . lm-studio)
                     ("http://127.0.0.1:8080/v1/" . llama-cpp)
                     ("http://localhost:11434/v1" . ollama)
                     ("http://localhost:1234/custom/v1" . nil)
                     ("http://localhost:1234/v1" . lm-studio)
                     (nil . nil)))
      (tategaki-provider-test--write (when (car entry) `((ai-endpoint . ,(car entry)))))
      (tategaki-project-apply-settings)
      (should (eq tategaki-project--inferred-ai-provider (cdr entry)))
      (should (eq tategaki-ai-provider (or (cdr entry) 'ollama)))
      (should (eq (local-variable-p 'tategaki-ai-provider) (and (cdr entry) t))))))

(ert-deftest tategaki-provider-explicit-scopes-and-invalid-entry-block-inference ()
  (tategaki-provider-test--project
    (tategaki-provider-test--write '((ai-endpoint . "http://localhost:1234/v1")))
    (tategaki-project-save '((settings . ((ai-provider . openai-compatible)))) 'default)
    (tategaki-project-apply-settings)
    (should (eq tategaki-ai-provider 'openai-compatible))
    (should-not tategaki-project--inferred-ai-provider)
    (tategaki-project-save '((settings . ((ai-provider . llama-cpp)))) 'project)
    (tategaki-project-apply-settings)
    (should (eq tategaki-ai-provider 'llama-cpp))
    (tategaki-project-save '((settings . ((ai-provider . ollama)))) 'session)
    (tategaki-project-apply-settings)
    (should (eq tategaki-ai-provider 'ollama))
    (should-not tategaki-project--inferred-ai-provider)
    ;; A malformed but explicit provider is not permission to guess another.
    (setq tategaki-project-session-settings '((settings . ((ai-provider . nil)))))
    (kill-local-variable 'tategaki-ai-provider)
    (tategaki-project-apply-settings)
    (should-not (local-variable-p 'tategaki-ai-provider))
    (should-not tategaki-project--inferred-ai-provider)))

(ert-deftest tategaki-provider-explicit-locals-are-never-reinferred ()
  (tategaki-provider-test--project
    (tategaki-provider-test--write '((ai-endpoint . "http://localhost:1234/v1")))
    (setq-local tategaki-ai-provider 'openai-compatible)
    (tategaki-project-apply-settings)
    (should (eq tategaki-ai-provider 'openai-compatible))
    (should-not tategaki-project--inferred-ai-provider)
    (kill-local-variable 'tategaki-ai-provider)
    (tategaki-project-apply-settings)
    (should (eq tategaki-project--inferred-ai-provider 'lm-studio))
    ;; Deliberately selecting even the same value transfers ownership.
    (setq-local tategaki-ai-provider 'lm-studio)
    (should-not tategaki-project--inferred-ai-provider)
    (tategaki-provider-test--write '((ai-endpoint . "http://localhost:8080/v1")))
    (tategaki-project-apply-settings)
    (should (eq tategaki-ai-provider 'lm-studio))
    (should-not tategaki-project--inferred-ai-provider)))

(ert-deftest tategaki-provider-watcher-is-local-idempotent-and-preserves-default ()
  (tategaki-provider-test--project
    (tategaki-provider-test--write '((ai-endpoint . "http://localhost:1234/v1")))
    (tategaki-project-apply-settings)
    (with-temp-buffer
      (setq-local tategaki-ai-provider 'llama-cpp)
      (should-not (local-variable-p 'tategaki-project--inferred-ai-provider)))
    (let ((tategaki-ai-provider 'openai-compatible))
      (should (eq tategaki-project--inferred-ai-provider 'lm-studio)))
    (should (eq tategaki-ai-provider 'lm-studio))
    (should (eq (default-value 'tategaki-ai-provider) 'ollama))
    (add-variable-watcher 'tategaki-ai-provider #'tategaki-project--provider-written)
    (should (= 1 (cl-count #'tategaki-project--provider-written
                          (get-variable-watchers 'tategaki-ai-provider))))))

(ert-deftest tategaki-provider-settings-discard-preserves-inference-provenance ()
  (tategaki-provider-test--project
    (tategaki-provider-test--write '((ai-endpoint . "http://localhost:1234/v1")))
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (should (eq (alist-get 'ai-provider tategaki-settings--values) 'lm-studio))
      (tategaki-settings-set 'ai-provider 'llama-cpp)
      (tategaki-settings-discard))
    (with-current-buffer source
      (should (eq tategaki-ai-provider 'lm-studio))
      (should (eq tategaki-project--inferred-ai-provider 'lm-studio))
      (tategaki-provider-test--write '((ai-endpoint . "http://localhost:8080/v1")))
      (tategaki-project-apply-settings)
      (should (eq tategaki-ai-provider 'llama-cpp))
      (should (eq tategaki-project--inferred-ai-provider 'llama-cpp)))))

(provide 'tategaki-provider-restore-test)
;;; tategaki-provider-restore-test.el ends here
