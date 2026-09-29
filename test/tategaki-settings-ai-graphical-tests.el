;;; tategaki-settings-ai-graphical-tests.el --- Native model picker UI -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Launch ONLY in a dedicated Emacs -Q -l /absolute/path/to/this-file.
;; This runner exits that Emacs.  Networking uses a controlled model response.
(require 'ert)
(setq load-prefer-newer t)
(let* ((directory (file-name-directory (or load-file-name buffer-file-name)))
       (root (file-name-directory (directory-file-name directory))))
  (add-to-list 'load-path root)
  (load (expand-file-name "tategaki-settings-ai-test.el" directory) nil nil t))

(ert-deftest tategaki-settings-ai-gui-typing-and-keyboard-model-selection ()
  (should (display-graphic-p))
  (tategaki-settings-test--project
    (let ((text (buffer-string)) (undo buffer-undo-list) (position (point)) pending)
      (setq settings (tategaki-settings source))
      (with-selected-window (get-buffer-window settings)
        (goto-char (widget-field-start (alist-get 'ai-endpoint tategaki-settings--widgets)))
        (execute-kbd-macro (kbd "C-a C-k"))
        (execute-kbd-macro "http://127.0.0.1:1234/v1")
        (execute-kbd-macro (kbd "TAB"))
        (should (equal (alist-get 'ai-endpoint tategaki-settings--values) "http://127.0.0.1:1234/v1"))
        (let* ((widget (alist-get 'ai-provider tategaki-settings--widgets))
               (overlay (widget-get widget :button-overlay))
               (widget-menu-minibuffer-flag t))
          (goto-char (1+ (overlay-start overlay)))
          (should (eq (widget-at) widget))
          (minibuffer-with-setup-hook
              (lambda () (setq unread-command-events
                               (append (listify-key-sequence "LM Studio\r") unread-command-events)))
            (execute-kbd-macro (kbd "RET")))
          (should (eq (widget-value widget) 'lm-studio)))
        (cl-letf (((symbol-function 'tategaki-ai-health) (lambda (callback) (setq pending callback) nil)))
          (tategaki-settings-fetch-models))
        (funcall pending '(:ok t :models ("fixture-chat" "fixture-embedding")))
        (redisplay t)
        (dolist (choice '(("一覧からModelを選択" . "fixture-chat")
                          ("一覧からEmbeddingを選択" . "fixture-embedding")))
          (goto-char (point-min)) (search-forward (car choice))
          (let ((widget (widget-at (1- (point)))))
            (minibuffer-with-setup-hook
                (lambda () (setq unread-command-events
                                 (append (listify-key-sequence (concat (cdr choice) "\r"))
                                         unread-command-events)))
              (widget-apply widget :action))))
        (should (equal (alist-get 'ai-model tategaki-settings--values) "fixture-chat"))
        (should (equal (alist-get 'ai-embedding-model tategaki-settings--values) "fixture-embedding"))
        (tategaki-settings-save)
        (tategaki-settings-close))
      (setq settings (tategaki-settings source))
      (with-current-buffer settings
        (should (eq (widget-value (alist-get 'ai-provider tategaki-settings--widgets)) 'lm-studio))
        (should (string-match-p "Provider: \\[LM Studio ▼\\]" (buffer-string))))
      (with-current-buffer source
        (should (equal text (buffer-string))) (should (eq undo buffer-undo-list))
        (should (= position (point))) (should-not (buffer-modified-p))))))

(run-with-timer
 1 nil
 (lambda ()
   (let* ((stats (ert-run-tests-batch "^tategaki-settings-ai-gui-"))
          (failed (ert-stats-completed-unexpected stats)))
     (with-current-buffer "*Messages*"
       (write-region (point-min) (point-max)
                     (expand-file-name "tategaki-settings-ai-gui-tests.log" temporary-file-directory) nil 'silent))
     (kill-emacs (if (zerop failed) 0 1)))))
;;; tategaki-settings-ai-graphical-tests.el ends here
