;;; tategaki-assistant-close-test.el --- Assistant pane lifetime -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'tategaki-assistant)
(require 'tategaki-settings)

(defmacro tategaki-assistant-close-test--source (&rest body)
  "Run BODY with a disposable manuscript and private settings."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "tategaki-assistant-close-" t))
          (source (generate-new-buffer " *Assistant close manuscript*"))
          (tategaki-project-default-file (expand-file-name "defaults.json" directory))
          (tategaki-session-file (expand-file-name "session.json" directory))
          (tategaki-history-directory (expand-file-name "history/" directory))
          settings panel)
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer source)
           (text-mode)
           (setq default-directory (file-name-as-directory directory))
           (setq-local tategaki-ai-enabled t tategaki-ai-model "close-test")
           (buffer-enable-undo)
           (insert "第一章\n未保存の原稿を保護します。\n")
           (goto-char 8)
           (set-mark 12)
           ,@body)
       (dolist (buffer (list panel settings source))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory directory t))))

(ert-deftest tategaki-assistant-close-keeps-settings-source-and-reopen-draft ()
  (tategaki-assistant-close-test--source
    (let ((text (buffer-string)) (position (point)) (mark-position (mark))
          (undo buffer-undo-list) (modified (buffer-modified-p)))
      (setq settings (tategaki-settings))
      (let ((settings-window (get-buffer-window settings)))
        (with-current-buffer source (setq panel (tategaki-assistant)))
        (with-current-buffer panel
          (tategaki-assistant--write (make-string 3000 ?話))
          (goto-char (point-max))
          (insert "次の質問の下書き")
          (should (eq (key-binding (kbd "q")) #'tategaki-assistant-close))
          (should (eq (key-binding (kbd "C-c C-q")) #'tategaki-assistant-close))
          (should (string-match-p "閉じる" (mapconcat #'identity header-line-format ""))))
        ;; Header clicks must work when Lisp's current buffer is unrelated to
        ;; the clicked pane and the Settings window has keyboard focus.
        (let ((event (list 'mouse-1
                           (list (get-buffer-window panel) 'header-line '(5 . 5) 0))))
          (select-window settings-window)
          (with-current-buffer source (tategaki-assistant-close event)))
        (should-not (get-buffer-window panel))
        (should (eq (window-buffer (selected-window)) source))
        (should (eq (get-buffer-window settings) settings-window))
        (with-current-buffer source
          (should (equal (buffer-string) text))
          (should (= (point) position))
          (should (= (mark) mark-position))
          (should (eq buffer-undo-list undo))
          (should (eq (buffer-modified-p) modified))
          (should (eq (tategaki-assistant) panel)))
        (with-current-buffer panel
          (should (string-match-p "次の質問の下書き" (buffer-string)))
          (should (string-match-p (make-string 50 ?話) (buffer-string)))
          (call-interactively (key-binding (kbd "q"))))
        (should-not (get-buffer-window panel))
        (should (eq (get-buffer-window settings) settings-window))))))

(ert-deftest tategaki-assistant-close-cancels-chat-and-ignores-old-reply-after-reopen ()
  (tategaki-assistant-close-test--source
    (let ((transport (generate-new-buffer " *Assistant close transport*"))
          callbacks cancelled)
      (unwind-protect
          (cl-letf (((symbol-function 'tategaki-rag-context)
                     (lambda (_question callback &rest _)
                       (funcall callback '(:ok t :text "合成文脈" :method lexical))))
                    ((symbol-function 'tategaki-ai-chat)
                     (lambda (_messages callback &rest _)
                       (push callback callbacks) transport))
                    ((symbol-function 'tategaki-ai-cancel)
                     (lambda (buffer)
                       (push buffer cancelled)
                       ;; Some transports finish synchronously during cancel.
                       (funcall (car callbacks) '(:ok t :text "CANCEL_CALLBACK")))))
            (tategaki-ask "最初の質問")
            (setq panel (current-buffer))
            (tategaki-assistant-close)
            (should (equal cancelled (list transport)))
            (should-not (get-buffer-window panel))
            (with-temp-buffer (funcall (car callbacks) '(:ok t :text "LATE_ANSWER")))
            (should-not (get-buffer-window panel))
            (with-current-buffer source (tategaki-ask "再度の質問"))
            (with-temp-buffer (funcall (cadr callbacks) '(:ok t :text "OLD_REOPEN_ANSWER")))
            (with-current-buffer panel
              (should tategaki-assistant--busy)
              (should-not (string-match-p (regexp-opt '("CANCEL_CALLBACK" "LATE_ANSWER" "OLD_REOPEN_ANSWER"))
                                          (buffer-string))))
            (with-temp-buffer (funcall (car callbacks) '(:ok t :text "NEW_ANSWER")))
            (with-current-buffer panel
              (should-not tategaki-assistant--busy)
              (should (string-match-p "NEW_ANSWER" (buffer-string)))
              (tategaki-assistant-close)))
        (when (buffer-live-p transport) (kill-buffer transport))))))

(ert-deftest tategaki-assistant-close-cancels-retrieval-and-prevents-chat ()
  (tategaki-assistant-close-test--source
    (let ((job (list :rag-job t)) callback cancelled (chat-calls 0))
      (cl-letf (((symbol-function 'tategaki-rag-context)
                 (lambda (_query function &rest _) (setq callback function) job))
                ((symbol-function 'tategaki-rag-cancel)
                 (lambda (value) (setq cancelled value)
                   (funcall callback '(:ok nil :message "Cancelled"))))
                ((symbol-function 'tategaki-ai-chat)
                 (lambda (&rest _) (cl-incf chat-calls))))
        (tategaki-ask "根拠を検索")
        (setq panel (current-buffer))
        (tategaki-assistant-close)
        (should (eq cancelled job))
        (with-temp-buffer (funcall callback '(:ok t :text "遅延文脈" :method lexical)))
        (should (zerop chat-calls))
        (should-not (get-buffer-window panel))
        (with-current-buffer panel (should-not tategaki-assistant--busy))))))

(provide 'tategaki-assistant-close-test)
;;; tategaki-assistant-close-test.el ends here
