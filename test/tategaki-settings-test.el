;;; tategaki-settings-test.el --- Settings transactions and safe persistence -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'tategaki-settings)
(require 'tategaki-export)

(defmacro tategaki-settings-test--project (&rest body)
  "Run BODY with an isolated manuscript, settings store and project directory."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "tategaki-settings-test-" t))
          (tategaki-project-default-file (expand-file-name "defaults.json" directory))
          (source (generate-new-buffer " *settings-source*"))
          settings)
     (unwind-protect
         (save-window-excursion
           (with-current-buffer source
             (setq default-directory (file-name-as-directory directory)
                   buffer-file-name (expand-file-name "manuscript.txt" directory))
             (buffer-enable-undo)
             (insert "第一章\n日本人であることを考えるのであろう。\n")
             (setq buffer-undo-list nil)
             (set-buffer-modified-p nil)
             ,@body))
       (when (buffer-live-p settings)
         (with-current-buffer settings
           (let ((tategaki-settings--allow-kill t)) (kill-buffer settings))))
       (when (buffer-live-p source) (kill-buffer source))
       (delete-directory directory t))))

(ert-deftest tategaki-project-json-roundtrip-and-nearest-root ()
  (tategaki-settings-test--project
    (tategaki-project-save '((title . "夏の終わり") (author . "山田花子")
                             (language . "ja") (identifier . "book:1")
                             (settings . ((manuscript-size . (20 . 20))
                                          (manuscript-grid . nil) (ai-provider . ollama)))))
    (tategaki-project-save '((author . "別名")))
    (let ((child (expand-file-name "chapters/second" directory)))
      (make-directory child t)
      (should (equal (tategaki-project-root child) (file-name-as-directory directory))))
    (setq tategaki-project-session-settings nil)
    (tategaki-project-apply-settings)
    (should (equal tategaki-manuscript-size '(20 . 20)))
    (should-not tategaki-manuscript-grid)
    (should (eq (symbol-value 'tategaki-ai-provider) 'ollama))
    (should (equal (tategaki-project-metadata)
                   '(:title "夏の終わり" :author "別名" :language "ja" :identifier "book:1")))))

(ert-deftest tategaki-project-scope-precedence-and-isolation ()
  (tategaki-settings-test--project
    (tategaki-project-save '((author . "既定著者")
                             (settings . ((character-spacing . 1) (padding-top . 5)))) 'default)
    (tategaki-project-save '((title . "作品A") (settings . ((character-spacing . 2)))) 'project)
    (tategaki-project-save '((title . "セッションA") (settings . ((character-spacing . 3)))) 'session)
    (tategaki-project-apply-settings)
    (should (= tategaki-character-spacing 3))
    (should (= tategaki-padding-top 5))
    (should (equal (plist-get (tategaki-project-metadata) :title) "セッションA"))
    (with-temp-buffer
      (setq default-directory (file-name-as-directory directory))
      (tategaki-project-apply-settings)
      (should (= tategaki-character-spacing 2))
      (should (equal (plist-get (tategaki-project-metadata) :title) "作品A")))
    (with-temp-buffer
      (let ((other (make-temp-file "tategaki-other-" t)))
        (unwind-protect
            (progn (setq default-directory (file-name-as-directory other))
                   (tategaki-project-apply-settings)
                   (should (= tategaki-character-spacing 1))
                   (should-not (plist-get (tategaki-project-metadata) :title)))
          (delete-directory other t))))))

(ert-deftest tategaki-project-corrupt-json-never-edits-source ()
  (tategaki-settings-test--project
    (let ((original (buffer-string)) (undo buffer-undo-list)
          (file (tategaki-project-file)))
      (make-directory (file-name-directory file) t)
      (dolist (invalid '("{broken" "{\"schema_version\": 1, \"settings\": 42}"
                         "{\"schema_version\": 99}" "[]"
                         "{\"schema_version\": 1} trailing content"))
        (with-temp-file file (insert invalid))
        (cl-letf (((symbol-function 'display-warning) #'ignore))
          (should-not (tategaki-project-load))
          (tategaki-project-apply-settings))
        (should-error (tategaki-project-save '((title . "replacement"))) :type 'user-error)
        (should (equal original (buffer-string)))
        (should (eq undo buffer-undo-list))
        (should-not (buffer-modified-p))
        (should (equal invalid (with-temp-buffer (insert-file-contents file) (buffer-string))))))))

(ert-deftest tategaki-project-rejects-unsafe-and-invalid-settings ()
  (tategaki-settings-test--project
    (tategaki-project-save '((settings . ((eval . "(delete-file \"manuscript.txt\")")
                                          (character-spacing . -20)
                                          (manuscript-size . [0 20])
                                          (ai-provider . "unknown")
                                          (padding-left . 9)))))
    (tategaki-project-apply-settings)
    (should-not (local-variable-p 'eval))
    (should (= tategaki-character-spacing 0))
    (should-not tategaki-manuscript-size)
    (should (= tategaki-padding-left 9))))

(ert-deftest tategaki-settings-preview-preserves-source-undo-point-and-modified ()
  (tategaki-settings-test--project
    (goto-char 8)
    (let ((original (buffer-string)) (undo buffer-undo-list) (position (point)))
      (setq settings (tategaki-settings source))
      (with-current-buffer settings
        (dolist (entry '((title . "作品タイトル") (author . "著者") (language . "ja")
                         (identifier . "urn:book:123") (font-family . "Hiragino Mincho ProN")
                         (text-scale . 1) (manuscript-size . (20 . 20)) (manuscript-grid . t)
                         (manuscript-spread . t) (character-spacing . 2) (line-spacing . 12)
                         (padding-top . 20) (padding-bottom . 20) (padding-left . 16)
                         (padding-right . 16) (writing-auto-indent . nil)
                         (writing-electric-pair . nil) (history-idle-interval . nil)
                         (proofread-live . t) (ai-model . "test-model") (tts-rate . 1.2)))
          (tategaki-settings-set (car entry) (cdr entry)))
        (tategaki-settings--step 'character-spacing 1))
      (with-current-buffer source
        (should (equal original (buffer-string)))
        (should (eq undo buffer-undo-list))
        (should (= position (point)))
        (should-not (buffer-modified-p))
        (should (= tategaki-character-spacing 3))
        (should (equal tategaki-settings-font-family "Hiragino Mincho ProN")))
      (with-current-buffer settings (tategaki-settings-revert))
      (with-current-buffer source
        (should (equal original (buffer-string)))
        (should (eq undo buffer-undo-list))
        (should-not (buffer-modified-p))
        (should (= tategaki-character-spacing 0))
        (should-not (local-variable-p 'tategaki-character-spacing))))))

(ert-deftest tategaki-settings-widget-edit-and-buttons-use-source ()
  (tategaki-settings-test--project
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (should-not widget-image-enable)
      (let ((widget (alist-get 'title tategaki-settings--widgets)))
        (widget-value-set widget "クリックと入力")
        (widget-apply widget :notify widget))
      (let ((checkbox (alist-get 'manuscript-grid tategaki-settings--widgets)))
        (widget-apply-action checkbox))
      (should (equal (alist-get 'title tategaki-settings--values) "クリックと入力"))
      (should (eq (lookup-key (current-local-map) (kbd "TAB")) #'widget-forward))
      (should (eq (lookup-key (current-local-map) (kbd "<backtab>")) #'widget-backward)))
    (should (equal (plist-get (tategaki-project-metadata source) :title) "クリックと入力"))
    (should (buffer-local-value 'tategaki-manuscript-grid source))))

(ert-deftest tategaki-settings-save-only-changes-selected-scope ()
  (tategaki-settings-test--project
    (tategaki-project-save '((title . "作品だけの名前") (author . "作品著者")))
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (setq tategaki-settings--scope 'default)
      (tategaki-settings-set 'character-spacing 4)
      (tategaki-settings-save))
    (let ((defaults (tategaki-project--read tategaki-project-default-file)))
      (should-not (assq 'title defaults))
      (should-not (assq 'author defaults))
      (should (= (alist-get 'character-spacing (alist-get 'settings defaults)) 4)))
    (should (equal (alist-get 'title (tategaki-project-load)) "作品だけの名前"))
    (should-not (buffer-local-value 'tategaki-project-session-settings source))))

(ert-deftest tategaki-settings-save-and-reopen-metadata ()
  (tategaki-settings-test--project
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (tategaki-settings-set 'title "夏の終わり")
      (tategaki-settings-set 'author "山田花子")
      (tategaki-settings-set 'language "ja")
      (tategaki-settings-set 'identifier "urn:novel:summer")
      (tategaki-settings-set 'manuscript-size '(20 . 20))
      (tategaki-settings-set 'ai-embedding-model "local-embedding-model")
      (tategaki-settings-save)
      (should-not (tategaki-settings--changes)))
    ;; Simulate a fresh Emacs buffer, with no in-memory project or session data.
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name "chapter2.txt" directory)
            default-directory (file-name-as-directory directory))
      (tategaki-project-apply-settings)
      (should (equal tategaki-manuscript-size '(20 . 20)))
      (should (equal (symbol-value 'tategaki-ai-embedding-model) "local-embedding-model"))
      (should (equal (plist-get (tategaki-project-metadata) :title) "夏の終わり"))
      (should (equal (plist-get (tategaki-project-metadata) :author) "山田花子"))
      (should (equal (plist-get (tategaki-project-metadata) :identifier) "urn:novel:summer")))))

(ert-deftest tategaki-settings-close-cancel-discard-restores-last-save ()
  (tategaki-settings-test--project
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (tategaki-settings-set 'character-spacing 5)
      (tategaki-settings-save)
      (tategaki-settings-set 'character-spacing 9)
      (tategaki-settings-close)
      (should tategaki-settings--closing)
      (should (string-match-p "保存せず閉じる" (buffer-string)))
      ;; Cancel keeps the transaction and preview alive.
      (setq tategaki-settings--closing nil)
      (tategaki-settings--render)
      (should (= (buffer-local-value 'tategaki-character-spacing source) 9))
      (tategaki-settings-discard))
    (should-not (buffer-live-p settings))
    (should (= (buffer-local-value 'tategaki-character-spacing source) 5))))

(ert-deftest tategaki-settings-open-revert-after-save-is-unsaved ()
  (tategaki-settings-test--project
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (tategaki-settings-set 'title "保存したタイトル")
      (tategaki-settings-save)
      (tategaki-settings-revert)
      (should (tategaki-settings--changes))
      (should (equal (plist-get (tategaki-project-metadata source) :title) "manuscript"))
      (should (equal (with-current-buffer source (alist-get 'title (tategaki-project-load)))
                     "保存したタイトル"))
      (tategaki-settings-discard))
    (should (equal (plist-get (tategaki-project-metadata source) :title) "保存したタイトル"))))

(ert-deftest tategaki-export-project-precedence-and-explicit-override ()
  (tategaki-settings-test--project
    (setq-local tategaki-export-metadata '((title . "buffer") (author . "buffer author") (language . "en")))
    (tategaki-project-save '((title . "project") (author . "project author")))
    (let ((metadata (tategaki-export--metadata '((title . "profile") (author . "profile author")))))
      (should (equal (alist-get 'title metadata) "project"))
      (should (equal (alist-get 'author metadata) "project author"))
      (should (equal (alist-get 'language metadata) "en")))
    (let* ((snapshot (tategaki-export-model-snapshot nil '((title . "explicit"))))
           (metadata (alist-get 'metadata (plist-get snapshot :model))))
      (should (equal (alist-get 'title metadata) "explicit"))
      (should (equal (alist-get 'author metadata) "project author"))
      (should (equal (plist-get snapshot :text) (buffer-string))))))

(ert-deftest tategaki-settings-health-result-stays-in-ui ()
  (tategaki-settings-test--project
    (setq settings (tategaki-settings source))
    (let (received-buffer)
      (cl-letf (((symbol-function 'tategaki-ai-health)
                 (lambda (callback) (setq received-buffer (current-buffer))
                   (funcall callback '(:ok t :message "Model: qwen-test")))))
        (with-current-buffer settings
          (tategaki-settings-test-ai)
          (should (string-match-p "✓ 接続成功 Model: qwen-test" (buffer-string)))))
      (should (eq received-buffer source)))))

(ert-deftest tategaki-settings-transaction-commands-never-kill-manuscript ()
  (tategaki-settings-test--project
    (let ((original (buffer-string)))
      (dolist (command '(tategaki-settings-save tategaki-settings-revert
                         tategaki-settings-close tategaki-settings-discard
                         tategaki-settings--finish tategaki-settings--save-and-close
                         tategaki-settings-test-ai tategaki-settings-choose-voice))
        (should-error (funcall command) :type 'user-error)
        (should (buffer-live-p source))
        (should (equal original (buffer-string)))))))

(ert-deftest tategaki-settings-close-targets-its-window-not-selected-source ()
  (tategaki-settings-test--project
    (switch-to-buffer source)
    (setq settings (tategaki-settings source))
    (select-window (get-buffer-window source))
    (with-current-buffer settings (tategaki-settings-discard))
    (should (buffer-live-p source))
    (should-not (buffer-live-p settings))
    (should (eq (window-buffer (selected-window)) source))))

(ert-deftest tategaki-settings-custom-lisp-values-remain-valid-menu-choices ()
  (tategaki-settings-test--project
    (setq-local tategaki-manuscript-size '(42 . 17))
    (set (make-local-variable 'tategaki-history-idle-interval) 120)
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (dolist (key '(manuscript-size history-idle-interval))
        (should-not (widget-apply (alist-get key tategaki-settings--widgets) :validate))))))

(ert-deftest tategaki-settings-real-field-edit-after-rerender ()
  (tategaki-settings-test--project
    (let ((original (buffer-string)) (undo buffer-undo-list))
      (setq settings (tategaki-settings source))
      (with-current-buffer settings
        (tategaki-settings--step 'text-scale 1)
        (goto-char (widget-field-start (alist-get 'title tategaki-settings--widgets)))
        (execute-kbd-macro (kbd "C-a C-k"))
        (should (eq (key-binding (kbd "S")) #'self-insert-command))
        (should (eq (key-binding (vector ?夏)) #'self-insert-command))
        (execute-kbd-macro "Summer")
        (should (equal (alist-get 'title tategaki-settings--values) "Summer"))
        (execute-kbd-macro (kbd "C-a C-k"))
        (execute-kbd-macro (vconcat "夏の終わり"))
        (execute-kbd-macro (kbd "TAB"))
        (execute-kbd-macro (vconcat "山田花子"))
        (execute-kbd-macro (kbd "TAB"))
        (should (equal (alist-get 'title tategaki-settings--values) "夏の終わり"))
        (should (equal (alist-get 'author tategaki-settings--values) "山田花子"))
        (should (string-match-p "タイトル  夏の終わり" (buffer-string)))
        (should (string-match-p "著者名  山田花子" (buffer-string))))
      (with-current-buffer source
        (should (equal original (buffer-string)))
        (should (eq undo buffer-undo-list))
        (should-not (buffer-modified-p))))))

(ert-deftest tategaki-settings-save-refuses-visible-invalid-numeric-input ()
  (tategaki-settings-test--project
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (goto-char (widget-field-start (alist-get 'character-spacing tategaki-settings--widgets)))
      (execute-kbd-macro (kbd "C-a C-k"))
      (execute-kbd-macro "oops")
      (should-error (tategaki-settings-save) :type 'user-error)
      (should (= (buffer-local-value 'tategaki-character-spacing source) 0))
      (should-not (file-exists-p (with-current-buffer source (tategaki-project-file))))
      (should (equal (widget-value (alist-get 'character-spacing tategaki-settings--widgets)) "oops"))
      (execute-kbd-macro (kbd "C-a C-k"))
      (execute-kbd-macro "7")
      (tategaki-settings-save))
    (should (= (alist-get 'character-spacing (alist-get 'settings (tategaki-project-load))) 7))))

(provide 'tategaki-settings-test)
;;; tategaki-settings-test.el ends here
