;;; tategaki-assistant-close-graphical-tests.el --- Dedicated Assistant GUI check -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Launch ONLY in a dedicated Emacs -Q.  This runner exits its Emacs process.
(require 'server)
(defvar tategaki-assistant-close-gui--directory
  (make-temp-file "/tmp/tategaki-close-gui-" t))
(setq server-name "tategaki-isolated-assistant-close-gui"
      server-socket-dir (expand-file-name "sockets" tategaki-assistant-close-gui--directory)
      user-emacs-directory (expand-file-name "userdata/" tategaki-assistant-close-gui--directory)
      load-prefer-newer t inhibit-startup-screen t)
(make-directory server-socket-dir t)
(set-file-modes server-socket-dir #o700)
(make-directory user-emacs-directory t)
(server-start)
(let ((directory (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (file-name-directory (directory-file-name directory)))
  (load (expand-file-name "tategaki-assistant-close-test.el" directory) nil nil t))
(require 'tategaki-studio)

(ert-deftest tategaki-assistant-close-gui-header-after-scroll ()
  (tategaki-assistant-close-test--source
    (setq-local tategaki-history-enabled nil)
    (tategaki-studio-mode 1)
    ;; Model a completed edit command before dispatching a real keyboard
    ;; command; Emacs otherwise adds its normal first undo boundary here.
    (undo-boundary)
    (let ((text (buffer-string)) (undo buffer-undo-list)
          (position (point)) (modified (buffer-modified-p)) reply)
      (setq settings (tategaki-settings))
      (let ((settings-window (get-buffer-window settings)))
        (cl-letf (((symbol-function 'tategaki-rag-context)
                   (lambda (_query callback &rest _)
                     (funcall callback '(:ok t :text "合成原稿" :method lexical))))
                  ((symbol-function 'tategaki-ai-chat)
                   (lambda (_messages callback &rest _) (setq reply callback))))
          (with-current-buffer source (tategaki-ask "閉じる操作の検証"))
          (setq panel (window-buffer (selected-window)))
          (set-buffer panel)
          (with-current-buffer panel
            (tategaki-assistant--write
             (mapconcat (lambda (index) (format "合成の会話履歴 %d" index))
                        (number-sequence 1 100) "\n"))
            (goto-char (point-max)))
          (recenter -1)
          (redisplay t)
          (should (> (window-start (selected-window)) 1))
          (let* ((window (selected-window))
                 (height (window-header-line-height window))
                 (position
                  (cl-loop for x from 0 below (window-pixel-width window) by 2
                           for pos = (posn-at-x-y x (max 1 (/ height 2)) window)
                           for object = (and pos (posn-string pos))
                           for help = (and object (get-text-property (cdr object) 'help-echo (car object)))
                           when (and (stringp help) (string-prefix-p "相談を中止" help))
                           return pos)))
            (should position)
            (should (eq (posn-area position) 'header-line))
            (let ((handler (key-binding [header-line mouse-1] nil nil position)))
              (should (eq handler #'tategaki-assistant-close))
              (select-window settings-window)
              (with-current-buffer source (funcall handler (list 'mouse-1 position)))))
          (should-not (get-buffer-window panel))
          (should (eq (window-buffer (selected-window)) source))
          (should (eq (get-buffer-window settings) settings-window))
          (with-temp-buffer (funcall reply '(:ok t :text "遅延回答は表示しない")))
          (should-not (get-buffer-window panel))
          (with-current-buffer source (tategaki-assistant))
          (set-buffer panel)
          (should-not (string-match-p "遅延回答は表示しない" (buffer-string)))
          (execute-kbd-macro (kbd "q"))
          (should-not (get-buffer-window panel))
          (should (eq (window-buffer (selected-window)) source))
          (should (eq (get-buffer-window settings) settings-window))
          (with-current-buffer source
            (should (equal text (buffer-string)))
            (should (eq undo buffer-undo-list))
            (should (= position (point)))
            (should (eq modified (buffer-modified-p)))))))))

(add-hook
 'emacs-startup-hook
 (lambda ()
   (run-at-time
    1 nil
    (lambda ()
      (let ((status 2))
        (condition-case error-data
            (progn
              (unless (display-graphic-p) (error "GUI required"))
              (set-frame-size nil 150 48)
              (let ((stats (ert-run-tests-batch "^tategaki-assistant-close-gui-")))
                (setq status (if (and (= (ert-stats-completed-expected stats) 1)
                                      (zerop (ert-stats-completed-unexpected stats))) 0 1))))
          (error (message "Assistant close GUI error: %S" error-data)))
        (with-current-buffer "*Messages*"
          (write-region (point-min) (point-max) "/tmp/tategaki-assistant-close-gui-tests.log"))
        (kill-emacs status))))) t)
(add-hook 'kill-emacs-hook
          (lambda () (ignore-errors (delete-directory tategaki-assistant-close-gui--directory t))) t)
(run-at-time 60 nil
             (lambda ()
               (with-current-buffer "*Messages*"
                 (write-region (point-min) (point-max) "/tmp/tategaki-assistant-close-gui-tests.log"))
               (kill-emacs 2)))
;;; tategaki-assistant-close-graphical-tests.el ends here
