;;; tategaki-search-pane-test.el --- Search pane cancellation boundaries -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'cl-lib)
(require 'tategaki-studio)
(require 'tategaki-corpus)
(require 'tategaki-pane)

(defmacro tategaki-search-pane-test--isolated (&rest body)
  "Run BODY with a dirty synthetic manuscript and isolated windows/files."
  (declare (indent 0) (debug t))
  `(let* ((before (buffer-list))
          (directory (make-temp-file "tategaki-search-pane-" t))
          (source (generate-new-buffer " *search pane manuscript*")))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer source)
           (setq-local default-directory directory)
           (buffer-enable-undo)
           (insert "第一章\n合成の本文。未保存です。\n")
           (goto-char 3) (set-mark 2)
           ,@body)
       (dolist (buffer (buffer-list))
         (when (and (buffer-live-p buffer) (not (memq buffer before)))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory directory t))))

(defun tategaki-search-pane-test--request (kind source callback)
  "Make a synthetic KIND request using actual transport cancellation hooks."
  (let ((transport (generate-new-buffer " *search pending transport*")))
    (with-current-buffer transport
      (setq-local tategaki-ai--cancel
                  (lambda () (funcall callback '(:ok nil :message "cancel callback")))))
    (if (eq kind 'semantic) transport
      (let ((job (tategaki-corpus--job (list :source source) callback)))
        (setf (plist-get job :request) transport)
        job))))

(defun tategaki-search-pane-test--transport (kind request)
  "Return KIND REQUEST's synthetic transport buffer."
  (if (eq kind 'semantic) request (plist-get request :request)))

(defmacro tategaki-search-pane-test--deferred (kind &rest body)
  "Run BODY while collecting KIND search requests and callbacks."
  (declare (indent 1) (debug t))
  `(let ((retrieve (if (eq ,kind 'semantic)
                       'tategaki-semantic-retrieve 'tategaki-corpus-retrieve))
         (search (if (eq ,kind 'semantic) #'tategaki-semantic-search #'tategaki-corpus-search))
         requests callbacks)
     (cl-letf (((symbol-function retrieve)
                (lambda (_query callback &rest _)
                  (push callback callbacks)
                  (let ((request (tategaki-search-pane-test--request ,kind source callback)))
                    (push request requests)
                    request))))
       ,@body)))

(ert-deftest tategaki-search-pane-close-invalidates-before-cancel-callback ()
  (dolist (kind '(semantic corpus))
    (tategaki-search-pane-test--isolated
      (let ((text (buffer-string)) (undo buffer-undo-list)
            (tick (buffer-chars-modified-tick))
            (index (list :independent-index t))
            (other-job (tategaki-corpus--job (list :source source) #'ignore)))
        (setq-local tategaki-semantic--job index)
        (tategaki-search-pane-test--deferred kind
          (let* ((panel (funcall search "閉じる前の検索"))
                 (pending (car callbacks))
                 (transport (tategaki-search-pane-test--transport kind (car requests))))
            (should (get-buffer-window panel))
            (select-window (get-buffer-window panel))
            (should (string-match-p "検索中" (buffer-string)))
            (should tategaki-pane--installed-header)
            (let ((loading (buffer-string)))
              (call-interactively (key-binding (kbd "q")))
              (should-not (get-buffer-window panel))
              (should-not (buffer-live-p transport))
              (funcall pending '(:ok t :method late :message "遅れた結果"))
              (should-not (get-buffer-window panel))
              (should (equal loading (with-current-buffer panel (buffer-string)))))
            (with-current-buffer source
              (should (equal text (buffer-string)))
              (should (eq undo buffer-undo-list))
              (should (= tick (buffer-chars-modified-tick)))
              (should (buffer-modified-p))
              (should (= 3 (point))) (should (= 2 (mark t)))
              (should (eq index tategaki-semantic--job))
              (should (memq other-job tategaki-corpus--jobs))
              (should-not (plist-get other-job :done)))))))))

(ert-deftest tategaki-search-pane-new-search-rejects-previous-generation ()
  (dolist (kind '(semantic corpus))
    (tategaki-search-pane-test--isolated
      (tategaki-search-pane-test--deferred kind
        (let* ((panel (funcall search "一回目"))
               (first (car callbacks))
               (transport (tategaki-search-pane-test--transport kind (car requests))))
          (should (eq panel (funcall search "二回目")))
          (should-not (buffer-live-p transport))
          (funcall first '(:ok t :message "古い結果"))
          (with-current-buffer panel
            (should (string-match-p "二回目.*検索中" (buffer-string)))
            (should-not (string-match-p "古い結果" (buffer-string))))
          (funcall (car callbacks) '(:ok t :method lexical :message "最新の結果"))
          (funcall first '(:ok t :message "再度届いた古い結果"))
          (with-current-buffer panel
            (should (string-match-p "最新の結果" (buffer-string)))
            (should-not (string-match-p "古い結果" (buffer-string)))
            (should-not tategaki-semantic--search-request)
            (should-not tategaki-semantic--search-token)))))))

(ert-deftest tategaki-search-pane-kill-does-not-recreate-on-late-result ()
  (dolist (kind '(semantic corpus))
    (tategaki-search-pane-test--isolated
      (tategaki-search-pane-test--deferred kind
        (let* ((panel (funcall search "検索")) (name (buffer-name panel))
               (pending (car callbacks))
               (transport (tategaki-search-pane-test--transport kind (car requests))))
          (kill-buffer panel)
          (should-not (buffer-live-p transport))
          (funcall pending '(:ok t :message "late"))
          (should-not (get-buffer name)))))))

(ert-deftest tategaki-search-pane-hidden-window-is-not-redisplayed-on-completion ()
  (dolist (kind '(semantic corpus))
    (tategaki-search-pane-test--isolated
      (tategaki-search-pane-test--deferred kind
        (let ((panel (funcall search "検索")))
          ;; Ordinary window removal bypasses the dedicated close command.
          (quit-window nil (get-buffer-window panel))
          (funcall (car callbacks) '(:ok t :message "完了"))
          (should-not (get-buffer-window panel))
          (with-current-buffer panel
            (should (string-match-p "完了" (buffer-string)))))))))

(ert-deftest tategaki-search-pane-close-before-handle-return-still-cancels ()
  (dolist (kind '(semantic corpus))
    (tategaki-search-pane-test--isolated
      (let ((retrieve (if (eq kind 'semantic)
                          'tategaki-semantic-retrieve 'tategaki-corpus-retrieve))
            (search (if (eq kind 'semantic) #'tategaki-semantic-search #'tategaki-corpus-search))
            request panel)
        (cl-letf (((symbol-function retrieve)
                   (lambda (_query callback &rest _)
                     (setq request (tategaki-search-pane-test--request kind source callback))
                     (setq panel (get-buffer (if (eq kind 'semantic) "*Tategaki Search*"
                                               (format "*Tategaki Corpus Search: %s*" (buffer-name source)))))
                     (select-window (get-buffer-window panel))
                     (tategaki-pane-close)
                     request)))
          (funcall search "検索")
          (should-not (get-buffer-window panel))
          (should-not (buffer-live-p (tategaki-search-pane-test--transport kind request))))))))

(ert-deftest tategaki-search-pane-synchronous-lexical-results-have-source-links ()
  (dolist (search '(tategaki-semantic-search tategaki-corpus-search))
    (tategaki-search-pane-test--isolated
      (when (eq search 'tategaki-corpus-search)
        (setq buffer-file-name (expand-file-name "registered.txt" directory))
        (write-region (point-min) (point-max) buffer-file-name nil 'silent)
        (tategaki-corpus-register buffer-file-name 'manuscript))
      (let ((tategaki-ai-enabled nil)
            (text (buffer-string)) (undo buffer-undo-list))
        (let ((panel (funcall search "合成")))
          (with-current-buffer panel
            (should tategaki-pane--installed-header)
            (should (string-match-p "lexical" (buffer-string)))
            (should-not (string-match-p "検索中" (buffer-string)))
            (should (next-button (point-min)))
            (should-not tategaki-semantic--search-request)
            (should-not tategaki-semantic--search-token))
          (with-current-buffer source
            (should (equal text (buffer-string)))
            (should (eq undo buffer-undo-list))))))))

(ert-deftest tategaki-corpus-registration-pane-close-keeps-independent-index-job ()
  (tategaki-search-pane-test--isolated
    (let* ((job (tategaki-corpus--job (list :source source) #'ignore))
           (panel (tategaki-corpus)))
      (should (eq (window-buffer (selected-window)) panel))
      (should tategaki-pane--installed-header)
      (tategaki-pane-close)
      (should-not (get-buffer-window panel))
      (with-current-buffer source
        (should (memq job tategaki-corpus--jobs))
        (should-not (plist-get job :done))))))

(ert-deftest tategaki-search-reference-panes-preserve-editable-files-and-studio-headers ()
  (dolist (visit '(tategaki-semantic-visit tategaki-corpus-visit))
    (tategaki-search-pane-test--isolated
      (let* ((file (expand-file-name "reference.txt" directory))
             (panel (generate-new-buffer " *reference originating pane*"))
             (reference (progn (write-region "合成の資料。" nil file nil 'silent)
                               (find-file-noselect file))))
        (with-current-buffer panel (setq-local tategaki-studio-source source))
        (with-current-buffer reference
          (buffer-enable-undo) (goto-char (point-max)) (insert "未保存")
          (setq-local header-line-format "資料ヘッダー"))
        (let ((chunk (with-current-buffer reference (car (tategaki-semantic-chunks))))
              (text (with-current-buffer reference (buffer-string)))
              (undo (buffer-local-value 'buffer-undo-list reference)))
          (with-current-buffer panel (funcall visit chunk))
          (with-current-buffer reference
            (should (eq source tategaki-pane-source))
            (should tategaki-pane--installed-header)
            (should (equal tategaki-pane--original-header "資料ヘッダー"))
            (should (eq (key-binding (kbd "q")) #'self-insert-command))
            (should-not tategaki-studio-source))
          (select-window (get-buffer-window reference))
          (tategaki-pane-close)
          (with-current-buffer reference
            (should (equal text (buffer-string)))
            (should (eq undo buffer-undo-list))
            (should (buffer-modified-p)))
          ;; An existing Studio manuscript is an editor, not an auxiliary pane.
          (with-current-buffer reference
            (setq-local tategaki-studio-mode t)
            (setq-local header-line-format "Studio 原稿の操作"))
          (with-current-buffer panel (funcall visit chunk))
          (with-current-buffer reference
            (should (equal header-line-format "Studio 原稿の操作")))
          ;; The original source must never acquire a close control from a hit.
          (with-current-buffer source
            (setq-local header-line-format "元原稿の操作")
            (setq chunk (car (tategaki-semantic-chunks))))
          (when (eq visit 'tategaki-corpus-visit)
            (with-current-buffer source
              (setq buffer-file-name (expand-file-name "source.txt" directory))
              (setq chunk (car (tategaki-semantic-chunks)))))
          (with-current-buffer panel (funcall visit chunk))
          (with-current-buffer source
            (should (equal header-line-format "元原稿の操作"))
            (should-not tategaki-pane--installed-header)))))))

(provide 'tategaki-search-pane-test)
;;; tategaki-search-pane-test.el ends here
