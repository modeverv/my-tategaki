;;; tategaki-ai-http-tests.el --- Actual loopback HTTP smoke tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Deliberately not named *-test.el: these opt-in integration tests require Python.
;; Run: Emacs -Q --batch -L . -l test/tategaki-ai-http-tests.el -f ert-run-tests-batch-and-exit
(require 'ert)
(require 'cl-lib)
(require 'tategaki-studio)
(require 'tategaki-assistant)
(require 'tategaki-settings)

(defconst tategaki-ai-http--fixture
  (expand-file-name "support/tategaki_ai_http_fixture.py"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun tategaki-ai-http--wait (predicate &optional timeout)
  "Process actual asynchronous callbacks until PREDICATE succeeds or TIMEOUT."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defmacro tategaki-ai-http--with-fixture (&rest body)
  "Run BODY against a fresh ephemeral localhost fixture and synthetic source."
  (declare (indent 0) (debug t))
  `(let* ((python (or (executable-find "python3") (ert-skip "Python 3 is required")))
          (server-buffer (generate-new-buffer " *Tategaki HTTP fixture*"))
          (server (make-process :name "tategaki-http-fixture" :buffer server-buffer
                                :command (list python "-u" tategaki-ai-http--fixture)
                                :coding 'utf-8-unix :noquery t))
          (source (generate-new-buffer " *Tategaki HTTP synthetic manuscript*"))
          (directory (make-temp-file "tategaki-http-" t))
          (url-proxy-services '(("no_proxy" . "127\\.0\\.0\\.1")))
          (url-automatic-caching nil)
          (process-environment (copy-sequence process-environment))
          fixture-root)
     (unwind-protect
         (save-window-excursion
           (dolist (name '("http_proxy" "https_proxy" "all_proxy" "HTTP_PROXY" "HTTPS_PROXY" "ALL_PROXY"))
             (setenv name nil))
           (tategaki-ai-http--wait
            (lambda () (with-current-buffer server-buffer
                         (string-match-p "\n" (buffer-string)))))
           (setq fixture-root
                 (format "http://127.0.0.1:%d"
                         (with-current-buffer server-buffer
                           (goto-char (point-min))
                           (alist-get 'port (let ((json-object-type 'alist)) (json-read))))))
           (with-current-buffer source
             (text-mode)
             (setq default-directory (file-name-as-directory directory))
             (setq-local tategaki-ai-enabled t)
             (setq-local tategaki-ai-model "fixture-model")
             (setq-local tategaki-ai-embedding-model "fixture-embedding")
             (setq-local tategaki-ai-endpoint (concat fixture-root "/v1"))
             (setq-local tategaki-ai-timeout 3)
             (insert "第1章\n花子は鍵を探しています。\n\n第2章\n海が静かでした。\n")
             (goto-char 6)
             (switch-to-buffer source)
             ,@body))
       (when (process-live-p server) (delete-process server))
       (when (buffer-live-p server-buffer) (kill-buffer server-buffer))
       (when (buffer-live-p source)
         (let ((panel (buffer-local-value 'tategaki-assistant--buffer source)))
           (when (buffer-live-p panel)
             (with-current-buffer panel (tategaki-ai-cancel tategaki-assistant--transport))
             (kill-buffer panel)))
         (kill-buffer source))
       (delete-directory directory t))))

(defun tategaki-ai-http--log (root)
  "Read the local fixture request log beneath ROOT with the real transport."
  (let ((tategaki-ai-endpoint (concat root "/v1")) response)
    (tategaki-ai--request "/fixture/log" nil (lambda (result) (setq response result)) "GET")
    (tategaki-ai-http--wait (lambda () response))
    (should (plist-get response :ok))
    (alist-get 'requests (plist-get response :data))))

(ert-deftest tategaki-ai-http-health-and-chat-roundtrip-unicode ()
  (tategaki-ai-http--with-fixture
    (let (health chat)
      (tategaki-ai-health (lambda (result) (setq health result)))
      (tategaki-ai-http--wait (lambda () health))
      (should (plist-get health :ok))
      (should (member "試験モデル" (plist-get health :models)))
      (tategaki-ai-chat '(((role . "user") (content . "花子と鍵について。")))
                        (lambda (result) (setq chat result)))
      (tategaki-ai-http--wait (lambda () chat))
      (should (plist-get chat :ok))
      (should (string-match-p "花子は鍵" (plist-get chat :text)))
      (let* ((log (tategaki-ai-http--log fixture-root)) (request (cadr log))
             (payload (alist-get 'payload request)))
        (should (equal "GET" (alist-get 'method (car log))))
        (should (equal "/v1/models" (alist-get 'path (car log))))
        (should (equal "POST" (alist-get 'method request)))
        (should (equal "花子と鍵について。" (alist-get 'content (car (alist-get 'messages payload)))))))))

(ert-deftest tategaki-ai-http-embeddings-index-search-and-request-order ()
  (tategaki-ai-http--with-fixture
    (let (indexed found)
      (tategaki-semantic-index (lambda (result) (setq indexed result)))
      (tategaki-ai-http--wait (lambda () indexed))
      (should (plist-get indexed :ok))
      (should (plist-get tategaki-semantic--index :chunks))
      (tategaki-semantic-retrieve "鍵" (lambda (result) (setq found result)))
      (tategaki-ai-http--wait (lambda () found))
      (should (eq 'semantic (plist-get found :method)))
      (should (string-match-p "鍵" (plist-get (car (plist-get found :chunks)) :text)))
      (let ((log (tategaki-ai-http--log fixture-root)))
        (should (= 2 (length log)))
        (should (cl-every (lambda (request) (equal "/v1/embeddings" (alist-get 'path request))) log))
        (should (equal '("鍵") (alist-get 'input (alist-get 'payload (cadr log)))))))))

(ert-deftest tategaki-ai-http-assistant-completes-with-working-source-citation ()
  (tategaki-ai-http--with-fixture
    (buffer-enable-undo)
    (set-buffer-modified-p nil)
    (let ((original (buffer-string)) (undo buffer-undo-list) panel citation)
      (tategaki-ask "鍵について")
      (setq panel (current-buffer))
      (tategaki-ai-http--wait
       (lambda () (with-current-buffer panel (not tategaki-assistant--busy))))
      (with-current-buffer panel
        (should (string-match-p "花子は鍵" (buffer-string)))
        (goto-char (point-min))
        (should (re-search-forward "\\[第1章:[0-9]+\\]" nil t))
        (setq citation (button-at (match-beginning 0)))
        (should citation)
        (button-activate citation))
      (should (eq source (window-buffer (selected-window))))
      (with-current-buffer source
        (should (= 1 (point)))
        (should (equal original (buffer-string)))
        (should (equal undo buffer-undo-list))
        (should-not (buffer-modified-p))))))

(ert-deftest tategaki-ai-http-http-and-malformed-response-errors ()
  (tategaki-ai-http--with-fixture
    (dolist (prefix '("error" "invalid" "missing-choice"))
      (let ((tategaki-ai-endpoint (concat fixture-root "/" prefix "/v1")) response (count 0))
        (tategaki-ai-chat '(((role . "user") (content . "synthetic")))
                          (lambda (result) (setq response result) (cl-incf count)))
        (tategaki-ai-http--wait (lambda () response))
        (should-not (plist-get response :ok))
        (should (= 1 count))
        (should (stringp (plist-get response :message)))))
    (let ((tategaki-ai-endpoint (concat fixture-root "/bad-vector/v1")) response)
      (tategaki-ai-embed '("鍵") (lambda (result) (setq response result)))
      (tategaki-ai-http--wait (lambda () response))
      (should-not (plist-get response :ok)))))

(ert-deftest tategaki-ai-http-timeout-and-cancel-finish-exactly-once ()
  (tategaki-ai-http--with-fixture
    (let ((tategaki-ai-endpoint (concat fixture-root "/slow/v1"))
          (tategaki-ai-timeout 0.05) response request (count 0))
      (setq request (tategaki-ai-chat '(((role . "user") (content . "synthetic")))
                                      (lambda (result) (setq response result) (cl-incf count))))
      (tategaki-ai-http--wait (lambda () response))
      (should-not (plist-get response :ok))
      (should (string-match-p "タイムアウト" (plist-get response :message)))
      (should-not (buffer-live-p request))
      (accept-process-output nil 0.6)
      (should (= 1 count)))
    (let ((tategaki-ai-endpoint (concat fixture-root "/slow/v1")) response request (count 0))
      (setq request (tategaki-ai-chat '(((role . "user") (content . "synthetic")))
                                      (lambda (result) (setq response result) (cl-incf count))))
      (tategaki-ai-cancel request)
      (should response)
      (should-not (plist-get response :ok))
      (should (string-match-p "中止" (plist-get response :message)))
      (should-not (buffer-live-p request))
      (accept-process-output nil 0.6)
      (should (= 1 count)))))

(ert-deftest tategaki-ai-http-redirect-is-refused-without-reaching-target ()
  (tategaki-ai-http--with-fixture
    (let ((tategaki-ai-endpoint (concat fixture-root "/redirect/v1")) response)
      (tategaki-ai-chat '(((role . "user") (content . "synthetic")))
                        (lambda (result) (setq response result)))
      (tategaki-ai-http--wait (lambda () response))
      (should-not (plist-get response :ok)))
    (let ((log (tategaki-ai-http--log fixture-root)))
      (should (= 1 (length log)))
      (should (equal "/redirect/v1/chat/completions" (alist-get 'path (car log)))))))

(ert-deftest tategaki-ai-http-assistant-cancel-drops-late-answer ()
  (tategaki-ai-http--with-fixture
    (setq-local tategaki-ai-endpoint (concat fixture-root "/slow/v1"))
    (tategaki-ask "鍵について")
    (let ((panel (current-buffer)))
      (tategaki-assistant-cancel)
      (accept-process-output nil 0.6)
      (with-current-buffer panel
        (should-not tategaki-assistant--busy)
        (should-not (string-match-p "花子は鍵を探しています" (buffer-string)))
        (should (string-match-p "取り消しました" (buffer-string)))))))

(ert-deftest tategaki-ai-http-settings-model-lists-for-both-providers ()
  (tategaki-ai-http--with-fixture
    (let ((text (buffer-string)) (position (point)) (undo buffer-undo-list)
          (modified (buffer-modified-p))
          (settings (tategaki-settings source)))
      (unwind-protect
          (progn
            (dolist (provider '(ollama lm-studio))
              (with-current-buffer settings
                (tategaki-settings-set 'ai-provider provider)
                (tategaki-settings-set 'ai-endpoint (format "%s/%s/v1" fixture-root provider))
                (tategaki-settings-fetch-models))
              (tategaki-ai-http--wait
               (lambda () (with-current-buffer settings (not tategaki-settings--ai-generation))))
              (with-current-buffer settings
                (should (equal tategaki-settings--ai-models '("fixture-model" "試験モデル")))
                (cl-letf (((symbol-function 'completing-read)
                           (lambda (prompt _collection &rest _)
                             (if (string-prefix-p "Chat" prompt) "fixture-model" "試験モデル"))))
                  (tategaki-settings-choose-model 'ai-model)
                  (tategaki-settings-choose-model 'ai-embedding-model))))
            (with-current-buffer source
              (should (equal tategaki-ai-model "fixture-model"))
              (should (equal tategaki-ai-embedding-model "試験モデル"))
              (should (equal text (buffer-string))) (should (eq undo buffer-undo-list))
              (should (= position (point))) (should (eq modified (buffer-modified-p))))
            (let ((log (tategaki-ai-http--log fixture-root)))
              (should (= 2 (length log)))
              (should (equal (mapcar (lambda (request) (alist-get 'path request)) log)
                             '("/ollama/v1/models" "/lm-studio/v1/models")))
              (should (cl-every (lambda (request) (and (equal (alist-get 'method request) "GET")
                                                      (not (alist-get 'payload request)))) log))))
        (when (buffer-live-p settings) (with-current-buffer settings (tategaki-settings-discard)))))))

(ert-deftest tategaki-ai-http-settings-model-errors-and-connection-change-cancel ()
  (tategaki-ai-http--with-fixture
    (let ((settings (tategaki-settings source)))
      (unwind-protect
          (with-current-buffer settings
            (dolist (prefix '("error" "bad-models" "empty-models"))
              (tategaki-settings-set 'ai-endpoint (format "%s/%s/v1" fixture-root prefix))
              (tategaki-settings-fetch-models)
              (tategaki-ai-http--wait
               (lambda () (with-current-buffer settings (not tategaki-settings--ai-generation))))
              (should-not tategaki-settings--ai-models)
              (should (string-match-p (if (equal prefix "empty-models") "0モデル" "✗")
                                      tategaki-settings--ai-status)))
            (tategaki-settings-set 'ai-endpoint (concat fixture-root "/slow/v1"))
            (tategaki-settings-fetch-models)
            (let ((request tategaki-settings--ai-request))
              (should (buffer-live-p request))
              (tategaki-settings-set 'ai-endpoint (concat fixture-root "/v1"))
              (should-not (buffer-live-p request))
              (accept-process-output nil 0.6)
              (should-not tategaki-settings--ai-models)
              (should (string-match-p "接続先が変わりました" tategaki-settings--ai-status))))
        (when (buffer-live-p settings) (with-current-buffer settings (tategaki-settings-discard)))))))

(provide 'tategaki-ai-http-tests)
;;; tategaki-ai-http-tests.el ends here
