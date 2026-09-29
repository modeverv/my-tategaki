;;; tategaki-ai.el --- Optional asynchronous AI providers -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'cl-lib)
(require 'json)
(require 'url)
(require 'url-http)
(require 'subr-x)
(defvar url-http-response-status)
(defvar url-http-end-of-headers)
(defvar-local tategaki-ai--cancel nil)

(defgroup tategaki-ai nil "Optional manuscript assistance." :group 'tategaki)
(defcustom tategaki-ai-enabled nil "Allow explicitly requested AI operations."
  :type 'boolean :group 'tategaki-ai)
(defcustom tategaki-ai-provider 'ollama "Provider speaking the OpenAI-compatible API."
  :type '(choice (const ollama) (const openai-compatible) (const lm-studio) (const llama-cpp))
  :group 'tategaki-ai)
(defcustom tategaki-ai-endpoint "http://localhost:11434/v1"
  "API root, including /v1.  Localhost is used by default."
  :type 'string :group 'tategaki-ai)
(defcustom tategaki-ai-model "" "Chat model name from the provider."
  :type 'string :group 'tategaki-ai)
(defcustom tategaki-ai-embedding-model "" "Embedding model, or empty to use the chat model."
  :type 'string :group 'tategaki-ai)
(defcustom tategaki-ai-allow-remote nil
  "Allow manuscript requests to non-localhost endpoints without a prompt.
Setting this explicitly authorizes transmission of manuscript context."
  :type 'boolean :group 'tategaki-ai)
(defcustom tategaki-ai-timeout 120 "Timeout in seconds for an asynchronous request."
  :type 'number :group 'tategaki-ai)
(defvar tategaki-ai-api-key-function nil
  "Optional zero-argument function returning an API key, e.g. from auth-source.
Keys are never saved in project JSON or included in error messages.")

(defconst tategaki-ai-provider-endpoints
  '((ollama . "http://127.0.0.1:11434/v1")
    (lm-studio . "http://127.0.0.1:1234/v1")
    (llama-cpp . "http://127.0.0.1:8080/v1"))
  "Local API presets.  Custom compatible servers have no implicit preset.")

(defun tategaki-ai-provider-endpoint (provider)
  "Return PROVIDER's standard local API endpoint, or nil for custom servers."
  (alist-get provider tategaki-ai-provider-endpoints))

(defun tategaki-ai-provider-for-endpoint (endpoint)
  "Return the provider of an exact standard local ENDPOINT, or nil.
Accept localhost as an alias of 127.0.0.1 and trailing slashes.  Custom
paths, ports, hosts, credentials and HTTPS servers are never inferred."
  (when (stringp endpoint)
    (car (rassoc (replace-regexp-in-string
                  "\\`http://localhost:" "http://127.0.0.1:"
                  (string-trim-right endpoint "/+"))
                 tategaki-ai-provider-endpoints))))

(defun tategaki-ai-standard-endpoint-p (endpoint)
  "Whether ENDPOINT is empty or one of the built-in local API presets."
  (or (string-empty-p endpoint)
      (tategaki-ai-provider-for-endpoint endpoint)))

(defun tategaki-ai-local-p (&optional endpoint)
  "Whether ENDPOINT has an explicit localhost host and http(s) scheme."
  (let ((url (url-generic-parse-url (or endpoint tategaki-ai-endpoint))))
    (and (member (url-type url) '("http" "https"))
         (member (downcase (or (url-host url) ""))
                 '("localhost" "127.0.0.1" "::1" "[::1]"))
         (not (url-user url)))))

(defun tategaki-ai-authorize ()
  "Validate AI configuration and authorize this explicit manuscript request."
  (unless tategaki-ai-enabled (user-error "AI は無効です。設定画面で有効にしてください"))
  (unless (member (url-type (url-generic-parse-url tategaki-ai-endpoint)) '("http" "https"))
    (user-error "AI endpoint must use http or https"))
  (when (string-empty-p tategaki-ai-model) (user-error "AI Model を設定してください"))
  (or (tategaki-ai-local-p) tategaki-ai-allow-remote
      (and (not noninteractive)
           (yes-or-no-p
            (format "この設定では原稿本文が外部サービス (%s) へ送信されます。送信しますか？ "
                    (url-host (url-generic-parse-url tategaki-ai-endpoint)))))
      (user-error "外部サービスへの送信を中止しました")))

(defun tategaki-ai--request (path payload callback &optional method)
  "Asynchronously request PATH with PAYLOAD and deliver one result to CALLBACK.
Result is (:ok t :data ALIST) or (:ok nil :message STRING).  No redirects are
followed, so a local service cannot silently redirect manuscript data away."
  (let* ((url-request-method (or method "POST"))
         (key (and tategaki-ai-api-key-function (funcall tategaki-ai-api-key-function)))
         (url-request-extra-headers
          (append '(("Content-Type" . "application/json"))
                  (when key (list (cons "Authorization" (concat "Bearer " key))))))
         (url-request-data (and payload (encode-coding-string (json-encode payload) 'utf-8)))
         (url-max-redirections 0)
         (url-show-status nil)
         (endpoint (concat (string-trim-right tategaki-ai-endpoint "/+") path))
         (done nil) timer request)
    (cl-labels ((finish (result)
                 (unless done
                   (setq done t)
                   (when (timerp timer) (cancel-timer timer))
                   (funcall callback result))))
      (condition-case _err
          (setq request
                (url-retrieve
                 endpoint
                 (lambda (status)
                   (let ((response (current-buffer)) result)
                     (unwind-protect
                         (setq result
                               (condition-case _err
                                   (if (or (plist-get status :error)
                                           (not (integerp url-http-response-status))
                                           (< url-http-response-status 200)
                                           (>= url-http-response-status 300))
                                       (list :ok nil :message
                                             (format "AI 接続失敗 (HTTP %s)"
                                                     (or url-http-response-status "network")))
                                     (goto-char (or url-http-end-of-headers (point-min)))
                                     (let ((json-object-type 'alist)
                                           (json-array-type 'list)
                                           (json-key-type 'symbol)
                                           (json-false nil))
                                       ;; url-retrieve leaves JSON response bytes
                                       ;; undecoded even with charset=utf-8.
                                       ;; Decode the body before parsing so source
                                       ;; citation labels retain Japanese text.
                                       (list :ok t :data
                                             (json-read-from-string
                                              (decode-coding-string
                                               (buffer-substring-no-properties
                                                (point) (point-max))
                                               'utf-8)))))
                                 (error (list :ok nil :message "AI の応答を解釈できません"))))
                       (when (buffer-live-p response) (kill-buffer response)))
                     (finish result))) nil t t))
        (error (finish (list :ok nil :message "AI に接続できません"))))
      (unless done
        (if (not (buffer-live-p request))
            (finish (list :ok nil :message "AI 接続を開始できません"))
          (with-current-buffer request
            (setq-local url-max-redirections 0)
            (setq-local tategaki-ai--cancel
                        (lambda () (finish (list :ok nil :message "AI リクエストを中止しました")))))
          (setq timer
                (run-at-time
                 tategaki-ai-timeout nil
                 (lambda ()
                   (finish (list :ok nil :message "AI 接続がタイムアウトしました"))
                   (when (buffer-live-p request)
                     (let ((process (get-buffer-process request)))
                       (when (process-live-p process) (delete-process process)))
                     (kill-buffer request)))))))
      request)))

(defun tategaki-ai-cancel (request)
  "Cancel an asynchronous REQUEST buffer, finishing its callback at most once."
  (when (buffer-live-p request)
    (with-current-buffer request
      (when tategaki-ai--cancel (funcall tategaki-ai--cancel))
      (let ((process (get-buffer-process request)))
        (when (process-live-p process) (delete-process process))))
    (when (buffer-live-p request) (kill-buffer request))))

(defun tategaki-ai-models (callback)
  "Fetch model IDs asynchronously, without sending manuscript data.
CALLBACK receives :ok, :models and :message.  IDs do not imply chat or
embedding capability; OpenAI-compatible lists need not disclose model types."
  (unless (member (url-type (url-generic-parse-url tategaki-ai-endpoint)) '("http" "https"))
    (user-error "AI endpoint must use http or https"))
  (tategaki-ai--request
   "/models" nil
   (lambda (result)
     (funcall callback
              (if (plist-get result :ok)
                  (condition-case nil
                    (let ((data (alist-get 'data (plist-get result :data))))
                    (if (not (and (assq 'data (plist-get result :data)) (listp data)
                                  (cl-every #'listp data)))
                        (list :ok nil :message "モデル一覧の応答が不正です")
                      (let ((models
                             (delete-dups
                              (cl-remove-if-not
                               (lambda (id) (and (stringp id) (not (string-empty-p id))
                                                 (<= (length id) 4096)
                                                 (not (string-match-p "[[:cntrl:]]" id))))
                               (mapcar (lambda (item) (alist-get 'id item)) data)))))
                        (list :ok t :message (if models "接続成功" "接続成功（モデル0件）")
                              :models models))))
                    (error (list :ok nil :message "モデル一覧の応答が不正です")))
                result))) "GET"))

(defun tategaki-ai-health (callback)
  "Check model connectivity without sending manuscript data to CALLBACK."
  (tategaki-ai-models callback))

(defun tategaki-ai-chat (messages callback &optional authorized)
  "Send MESSAGES asynchronously; CALLBACK receives :text or an error.
AUTHORIZED is non-nil when the same interactive operation already consented."
  (unless authorized (tategaki-ai-authorize))
  (tategaki-ai--request
   "/chat/completions"
   `((model . ,tategaki-ai-model) (messages . ,(vconcat messages))
     (stream . :json-false) (temperature . 0.2))
   (lambda (result)
     (if (not (plist-get result :ok)) (funcall callback result)
       (let* ((choice (car (alist-get 'choices (plist-get result :data))))
              (content (alist-get 'content (alist-get 'message choice))))
         (funcall callback (if (stringp content) (list :ok t :text content)
                             (list :ok nil :message "AI の回答本文がありません"))))))))

(defun tategaki-ai-embed (texts callback &optional authorized)
  "Embed TEXTS asynchronously; CALLBACK receives :vectors or an error."
  (unless authorized (tategaki-ai-authorize))
  (tategaki-ai--request
   "/embeddings"
   `((model . ,(if (string-empty-p tategaki-ai-embedding-model)
                   tategaki-ai-model tategaki-ai-embedding-model))
     (input . ,(vconcat texts)))
   (lambda (result)
     (if (not (plist-get result :ok)) (funcall callback result)
       (let* ((data (sort (copy-sequence (alist-get 'data (plist-get result :data)))
                          (lambda (a b) (< (or (alist-get 'index a) 0)
                                          (or (alist-get 'index b) 0)))))
              (vectors (mapcar (lambda (item) (alist-get 'embedding item)) data)))
         (funcall callback
                  (if (and (= (length vectors) (length texts))
                           (cl-every (lambda (v) (and (consp v) (cl-every #'numberp v))) vectors))
                      (list :ok t :vectors vectors)
                    (list :ok nil :message "Embedding の応答が不正です"))))))))

(provide 'tategaki-ai)
;;; tategaki-ai.el ends here
