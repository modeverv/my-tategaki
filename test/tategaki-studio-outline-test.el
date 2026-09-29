;;; tategaki-studio-outline-test.el --- Writing with a chapter sidebar -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'cl-lib)
(require 'tategaki-studio)
(require 'tategaki-outline)
(require 'tategaki-pane)

(defmacro tategaki-studio-outline-test--source (&rest body)
  "Run BODY with a real Studio source and clean up its isolated resources."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "tategaki-studio-outline-" t))
          (default-directory (file-name-as-directory directory))
          (tategaki-project-default-file (expand-file-name "defaults.json" directory))
          (tategaki-session-file (expand-file-name "session.json" directory))
          (tategaki-history-directory (expand-file-name "history/" directory))
          (before (buffer-list))
          (source (generate-new-buffer " *outline writing manuscript*")))
     (unwind-protect
         (save-window-excursion
           (delete-other-windows)
           (switch-to-buffer source)
           (text-mode)
           (insert "# 第一章 出会い\n本文が始まる。\n## 第一節 雨\n雨が降った。\n# 第二章 再会\n物語は続く。\n")
           (buffer-enable-undo)
           (setq buffer-undo-list nil)
           (goto-char (point-max)) (insert "未保存の続き。\n")
           (goto-char 17) (set-mark 25)
           (tategaki-studio-mode 1)
           ,@body)
       (when (buffer-live-p source)
         (with-current-buffer source
           (when tategaki-studio-mode (tategaki-studio-mode -1))
           (when tategaki-mode (tategaki-mode -1))))
       (dolist (buffer (cl-set-difference (buffer-list) before))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (let ((kill-buffer-query-functions nil))
               (set-buffer-modified-p nil) (kill-buffer buffer)))))
       (delete-directory directory t))))

(defun tategaki-studio-outline-test--state (source)
  "Capture SOURCE content and editing state."
  (with-current-buffer source
    (list (buffer-string) (point) (mark t) buffer-undo-list (buffer-modified-p))))

(defun tategaki-studio-outline-test--unchanged (source state)
  "Require SOURCE editing state to equal STATE, including Undo identity."
  (with-current-buffer source
    (should (equal (buffer-string) (nth 0 state)))
    (should (= (point) (nth 1 state)))
    (should (equal (mark t) (nth 2 state)))
    (should (eq buffer-undo-list (nth 3 state)))
    (should (eq (buffer-modified-p) (nth 4 state)))))

(defun tategaki-studio-outline-test--toolbar-handler (command)
  "Return the actual toolbar handler associated with COMMAND."
  (let* ((toolbar (tategaki-studio--toolbar))
         (position (text-property-any 0 (length toolbar) 'help-echo (symbol-name command) toolbar)))
    (should position)
    (should (string-match-p "目次" toolbar))
    (lookup-key (get-text-property position 'local-map toolbar) [header-line mouse-1])))

(defun tategaki-studio-outline-test--click-header (window command)
  "Dispatch COMMAND from WINDOW's installed Studio toolbar."
  (let ((handler (with-current-buffer (window-buffer window)
                   (tategaki-studio-outline-test--toolbar-handler command))))
    (should (commandp handler))
    (funcall handler (list 'mouse-1 (list window 'header-line '(2 . 2) 0)))))

(defun tategaki-studio-outline-test--close (window)
  "Dispatch WINDOW's persistent close action."
  (let* ((header (buffer-local-value 'header-line-format (window-buffer window)))
         (control (cl-find-if (lambda (item) (and (stringp item)
                                                  (string-match-p "\\[閉じる\\]" item))) header))
         (handler (and control (lookup-key (get-text-property 0 'local-map control)
                                           [header-line mouse-1]))))
    (should (eq handler #'tategaki-pane-close))
    (funcall handler (list 'mouse-1 (list window 'header-line '(2 . 2) 0)))))

(defun tategaki-studio-outline-test--other-pane (source)
  "Create an unrelated closable tool pane associated with SOURCE."
  (let ((buffer (generate-new-buffer " *outline unrelated tool*")))
    (with-current-buffer buffer
      (insert "別のツール\n")
      (special-mode)
      (tategaki-pane-install source nil "別のツール"))
    (display-buffer-in-side-window buffer '((side . bottom) (slot . 9) (window-height . 0.2)))
    buffer))

(ert-deftest tategaki-studio-outline-toolbar-and-key-reachable-in-every-layout ()
  (tategaki-studio-outline-test--source
    (should (eq (key-binding (kbd "C-c s o")) #'tategaki-studio-toggle-outline))
    (dolist (state '(write review))
      (dolist (width '(45 120))
        (let ((tategaki-studio-state state))
          (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) width)))
            (should (commandp (tategaki-studio-outline-test--toolbar-handler
                                #'tategaki-studio-toggle-outline)))))))))

(ert-deftest tategaki-studio-outline-toggle-keeps-writing-focus-and-other-pane ()
  (tategaki-studio-outline-test--source
    (let* ((state (tategaki-studio-outline-test--state source))
           (source-window (get-buffer-window source))
           (other (tategaki-studio-outline-test--other-pane source)))
      (select-window (get-buffer-window other))
      (tategaki-studio-outline-test--click-header source-window #'tategaki-studio-toggle-outline)
      (should (eq (selected-window) source-window))
      (let ((outline (buffer-local-value 'tategaki-outline--buffer source)))
        (should (get-buffer-window outline))
        (should (eq (buffer-local-value 'tategaki-outline--source outline) source))
        (should (get-buffer-window other))
        (should (eq (buffer-local-value 'tategaki-studio-state source) 'write))
        (tategaki-studio-outline-test--click-header source-window #'tategaki-studio-toggle-outline)
        (should-not (get-buffer-window outline))
        (should (get-buffer-window other))
        (should (eq (selected-window) source-window)))
      (tategaki-studio-outline-test--unchanged source state))))

(ert-deftest tategaki-studio-outline-manuscript-menu-opens-source-outline ()
  (tategaki-studio-outline-test--source
    (let ((state (tategaki-studio-outline-test--state source)))
      (tategaki-studio-menu)
      (let ((menu (current-buffer)))
        (goto-char (point-min)) (search-forward "目次")
        (let ((button (button-at (1- (point)))))
          (should button) (button-activate button))
        (should (eq (window-buffer (selected-window)) source))
        (should (get-buffer-window menu))
        (should (get-buffer-window (buffer-local-value 'tategaki-outline--buffer source))))
      (tategaki-studio-outline-test--unchanged source state))))

(ert-deftest tategaki-studio-outline-write-retains-current-outline-and-hides-review-tools ()
  (tategaki-studio-outline-test--source
    (let ((state (tategaki-studio-outline-test--state source)))
      (tategaki-studio-review)
      (let ((outline (buffer-local-value 'tategaki-outline--buffer source))
            (other (tategaki-studio-outline-test--other-pane source)))
        (should (get-buffer-window outline))
        (tategaki-studio-command #'tategaki-studio-write source)
        (should (get-buffer-window outline)) (should-not (get-buffer-window other))
        (should (= 2 (length (window-list))))
        (should (eq (window-buffer (selected-window)) source))
        (tategaki-studio-write)
        (should (eq outline (buffer-local-value 'tategaki-outline--buffer source)))
        (should (get-buffer-window outline))
        (tategaki-studio-review)
        (should (get-buffer-window other)) (should (get-buffer-window outline))
        (tategaki-studio-write)
        (should (get-buffer-window outline)) (should-not (get-buffer-window other)))
      (tategaki-studio-outline-test--unchanged source state))))

(ert-deftest tategaki-studio-outline-write-does-not-reopen-closed-outline ()
  (tategaki-studio-outline-test--source
    (let ((state (tategaki-studio-outline-test--state source)))
      (tategaki-studio-toggle-outline)
      (let ((outline (buffer-local-value 'tategaki-outline--buffer source)))
        (tategaki-studio-outline-test--close (get-buffer-window outline))
        (should-not (buffer-live-p outline)))
      (tategaki-studio-outline-test--other-pane source)
      (tategaki-studio-command #'tategaki-studio-write source)
      (should (= 1 (length (window-list))))
      (should-not (buffer-local-value 'tategaki-outline--buffer source))
      (tategaki-studio-outline-test--unchanged source state))))

(ert-deftest tategaki-studio-outline-write-does-not-retain-another-manuscripts-outline ()
  (tategaki-studio-outline-test--source
    (let ((state (tategaki-studio-outline-test--state source))
          (foreign (generate-new-buffer " *other outline manuscript*")))
      (with-current-buffer foreign (text-mode) (insert "# 別の原稿\n別本文。\n"))
      (set-window-buffer (split-window-right) foreign)
      (with-current-buffer foreign (tategaki-outline))
      (let ((outline (buffer-local-value 'tategaki-outline--buffer foreign)))
        (should (get-buffer-window outline))
        (tategaki-studio-command #'tategaki-studio-write source)
        (should-not (get-buffer-window outline))
        (should (= 1 (length (window-list))))
        (should (eq (window-buffer (selected-window)) source)))
      (tategaki-studio-outline-test--unchanged source state))))

(ert-deftest tategaki-studio-outline-close-controls-preserve-the-other-visible-pane ()
  (tategaki-studio-outline-test--source
    (let ((state (tategaki-studio-outline-test--state source)))
      (tategaki-studio-toggle-outline)
      (let ((outline (buffer-local-value 'tategaki-outline--buffer source))
            (other (tategaki-studio-outline-test--other-pane source)))
        (select-window (get-buffer-window outline))
        (tategaki-studio-outline-test--close (get-buffer-window other))
        (should (get-buffer-window outline)) (should-not (get-buffer-window other))
        (display-buffer-in-side-window other '((side . bottom) (slot . 9) (window-height . 0.2)))
        (select-window (get-buffer-window other))
        (tategaki-studio-outline-test--close (get-buffer-window outline))
        (should-not (buffer-live-p outline)) (should (get-buffer-window other))
        (should (eq (window-buffer (selected-window)) source))
        (with-current-buffer source
          (should-not tategaki-outline--buffer)
          (should-not (memq #'tategaki-outline--after-change after-change-functions))))
      (tategaki-studio-outline-test--unchanged source state))))

(provide 'tategaki-studio-outline-test)
;;; tategaki-studio-outline-test.el ends here
