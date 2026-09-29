;;; tategaki-settings-ai-test.el --- Server and model selection -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(unless (featurep 'tategaki-settings-test)
  (load (expand-file-name "tategaki-settings-test.el"
                          (file-name-directory (or load-file-name buffer-file-name))) nil nil t))

(ert-deftest tategaki-settings-ai-visible-provider-choice-saves-and-reopens ()
  (tategaki-settings-test--project
    (tategaki-project-save '((settings . ((ai-endpoint . "http://localhost:1234/v1")
                                         (ai-model . "local-model")))))
    (setq settings (tategaki-settings source))
    (let ((text (with-current-buffer source (buffer-string)))
          (undo (buffer-local-value 'buffer-undo-list source))
          (position (with-current-buffer source (point))))
      (with-current-buffer settings
        (let* ((widget (alist-get 'ai-provider tategaki-settings--widgets))
               (overlay (widget-get widget :button-overlay)))
          ;; The visible provider value itself must open the selection menu.
          (should (string-match-p "\\[.*▼\\]"
                                  (buffer-substring-no-properties
                                   (overlay-start overlay) (overlay-end overlay))))
          (should (eq (widget-at (1+ (overlay-start overlay))) widget))
          (cl-letf (((symbol-function 'widget-choose)
                     (lambda (_title choices &rest _)
                       (cdr (assoc "LM Studio" choices)))))
            (widget-apply widget :action)))
        (should (eq (alist-get 'ai-provider tategaki-settings--values) 'lm-studio))
        (tategaki-settings-save)
        (tategaki-settings-close))
      (should-not (buffer-live-p settings))
      (setq settings (tategaki-settings source))
      (with-current-buffer settings
        (should (eq (widget-value (alist-get 'ai-provider tategaki-settings--widgets)) 'lm-studio))
        (should (string-match-p "Provider: \\[LM Studio ▼\\]" (buffer-string))))
      (with-temp-buffer
        (setq default-directory (file-name-as-directory directory))
        (tategaki-project-apply-settings)
        (should (eq tategaki-ai-provider 'lm-studio)))
      (with-current-buffer source
        (should (equal text (buffer-string))) (should (eq undo buffer-undo-list))
        (should (= position (point))) (should-not (buffer-modified-p))))))

(ert-deftest tategaki-settings-ai-provider-presets-preserve-custom-endpoints ()
  (tategaki-settings-test--project
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (tategaki-settings-set 'ai-endpoint "http://localhost:11434/v1/")
      (let ((widget (alist-get 'ai-provider tategaki-settings--widgets)))
        (widget-value-set widget 'lm-studio)
        (widget-apply widget :notify widget))
      (should (equal (alist-get 'ai-endpoint tategaki-settings--values) "http://127.0.0.1:1234/v1"))
      (should (equal (widget-value (alist-get 'ai-endpoint tategaki-settings--widgets)) "http://127.0.0.1:1234/v1"))
      (tategaki-settings-set 'ai-endpoint "http://127.0.0.1:4444/custom/v1")
      (tategaki-settings-set 'ai-provider 'ollama)
      (should (equal (alist-get 'ai-endpoint tategaki-settings--values) "http://127.0.0.1:4444/custom/v1"))
      (tategaki-settings-use-ai-preset)
      (should (equal (alist-get 'ai-endpoint tategaki-settings--values) "http://127.0.0.1:11434/v1"))
      (tategaki-settings-set 'ai-provider 'openai-compatible)
      (should-error (tategaki-settings-use-ai-preset) :type 'user-error)
      (tategaki-settings-revert)
      (should (equal tategaki-settings--values tategaki-settings--opening-values)))))

(ert-deftest tategaki-settings-ai-model-pickers-preserve-source-and-independent-fields ()
  (tategaki-settings-test--project
    (let ((text (buffer-string)) (undo buffer-undo-list) (position (point)) pending)
      (setq settings (tategaki-settings source))
      (cl-letf (((symbol-function 'tategaki-ai-health) (lambda (callback) (setq pending callback) nil)))
        (with-current-buffer settings
          (tategaki-settings-fetch-models)
          (should (string-match-p "取得しています" (buffer-string)))))
      (funcall pending '(:ok t :models ("chat-日本語" "embedding-test") :message "接続成功"))
      (with-current-buffer settings
        (should (string-match-p "取得済み: 2モデル" (buffer-string)))
        (dolist (choice '((ai-model . "chat-日本語") (ai-embedding-model . "embedding-test")))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt candidates &rest _)
                       (should (equal candidates '("chat-日本語" "embedding-test"))) (cdr choice))))
            (goto-char (point-min))
            (search-forward (if (eq (car choice) 'ai-model) "一覧からModelを選択" "一覧からEmbeddingを選択"))
            (let ((widget (widget-at (1- (point)))))
              (should widget) (widget-apply widget :action))))
        (should (equal (alist-get 'ai-model tategaki-settings--values) "chat-日本語"))
        (should (equal (alist-get 'ai-embedding-model tategaki-settings--values) "embedding-test"))
        (tategaki-settings-set 'ai-model "freeform-model")
        (setq tategaki-settings--scope 'project)
        (tategaki-settings-save))
      (with-current-buffer source
        (should (equal tategaki-ai-model "freeform-model"))
        (should (equal tategaki-ai-embedding-model "embedding-test"))
        (should (equal text (buffer-string))) (should (eq undo buffer-undo-list))
        (should (= position (point))) (should-not (buffer-modified-p))))))

(ert-deftest tategaki-settings-ai-connection-changes-drop-old-and-reordered-responses ()
  (tategaki-settings-test--project
    (setq settings (tategaki-settings source))
    (let (callbacks)
      (cl-letf (((symbol-function 'tategaki-ai-health) (lambda (callback) (push callback callbacks) nil)))
        (with-current-buffer settings
          (tategaki-settings-fetch-models)
          (tategaki-settings-set 'ai-provider 'lm-studio)
          (tategaki-settings-fetch-models)
          (funcall (car callbacks) '(:ok t :models ("new")))
          (funcall (cadr callbacks) '(:ok t :models ("old")))
          (should (equal tategaki-settings--ai-models '("new")))
          (let ((field (alist-get 'ai-endpoint tategaki-settings--widgets)))
            (widget-value-set field "http://localhost:9999/v1")
            (widget-apply field :notify field))
          (should-not tategaki-settings--ai-models)
          (should (string-match-p "接続先が変わりました" (buffer-string)))
          (should-error (tategaki-settings-choose-model 'ai-model) :type 'user-error))))))

(ert-deftest tategaki-settings-ai-external-source-settings-change-discards-result ()
  (tategaki-settings-test--project
    (setq settings (tategaki-settings source))
    (let (pending)
      (cl-letf (((symbol-function 'tategaki-ai-health) (lambda (callback) (setq pending callback) nil)))
        (with-current-buffer settings (tategaki-settings-fetch-models)))
      (with-current-buffer source (setq-local tategaki-ai-endpoint "http://localhost:9999/v1"))
      (funcall pending '(:ok t :models ("stale")))
      (with-current-buffer settings
        (should-not tategaki-settings--ai-models)
        (should (string-match-p "結果を破棄" (buffer-string)))))))

(ert-deftest tategaki-settings-ai-model-picker-rechecks-connection-after-prompt ()
  (tategaki-settings-test--project
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (cl-letf (((symbol-function 'tategaki-ai-health)
                 (lambda (callback) (funcall callback '(:ok t :models ("old-model"))))))
        (tategaki-settings-fetch-models))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _)
                   (tategaki-settings-set 'ai-endpoint "http://localhost:9999/v1") "old-model")))
        (should-error (tategaki-settings-choose-model 'ai-model) :type 'user-error)
        (should-not (equal (alist-get 'ai-model tategaki-settings--values) "old-model"))))))

(ert-deftest tategaki-settings-ai-failure-empty-and-close-cancel ()
  (tategaki-settings-test--project
    (setq settings (tategaki-settings source))
    (dolist (result '((:ok nil :message "server unavailable") (:ok t :models nil)))
      (cl-letf (((symbol-function 'tategaki-ai-health) (lambda (callback) (funcall callback result))))
        (with-current-buffer settings
          (tategaki-settings-fetch-models)
          (should-not tategaki-settings--ai-models)
          (should (string-match-p (if (plist-get result :ok) "0モデル" "server unavailable") (buffer-string))))))
    (let ((request (generate-new-buffer " *settings models request*")) pending cancelled)
      (unwind-protect
          (cl-letf (((symbol-function 'tategaki-ai-health) (lambda (callback) (setq pending callback) request))
                    ((symbol-function 'tategaki-ai-cancel)
                     (lambda (buffer) (should (eq buffer request)) (setq cancelled t)
                       (funcall pending '(:ok nil :message "cancelled")) (kill-buffer buffer))))
            (with-current-buffer settings (tategaki-settings-fetch-models) (tategaki-settings-discard))
            (should cancelled) (should-not (buffer-live-p request))
            (should-not (buffer-live-p settings))
            (funcall pending '(:ok t :models ("late")))
            (should (buffer-live-p source)))
        (when (buffer-live-p request) (kill-buffer request))))))

(ert-deftest tategaki-ai-model-list-validates-shape-and-never-sends-source ()
  (let ((tategaki-ai-endpoint "http://127.0.0.1:1234/v1")
        (tategaki-ai-enabled nil) (tategaki-ai-model "") delivered)
    (dolist (data '(((data . (((id . "日本語") (object . "model")) ((id . "embedding"))
                              ((id . "日本語")) ((id . 42)) ((id . "bad\nname")))))
                    ((data)) ((error . "not a model list")) 42 ((data . "bad"))))
      (cl-letf (((symbol-function 'tategaki-ai--request)
                 (lambda (path payload callback &optional method)
                   (should (equal path "/models")) (should (equal method "GET"))
                   (should-not payload) (funcall callback (list :ok t :data data)))))
        (tategaki-ai-models (lambda (result) (setq delivered result)))
        (if (equal data '((data))) (should (plist-get delivered :ok))
          (if (and (listp data) (listp (alist-get 'data data)) (consp (alist-get 'data data)))
              (should (equal (plist-get delivered :models) '("日本語" "embedding")))
            (should-not (plist-get delivered :ok))))))
    (let ((tategaki-ai-endpoint "file:///tmp/models"))
      (should-error (tategaki-ai-models #'ignore) :type 'user-error))))

(provide 'tategaki-settings-ai-test)
;;; tategaki-settings-ai-test.el ends here
