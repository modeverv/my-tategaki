;;; tategaki-lookup-pane-test.el --- Scoped dictionary pane controls -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'cl-lib)
(require 'tategaki-lookup)
(defvar lookup-entry-buffer nil)
(defvar lookup-main-window nil)
(defvar lookup-sub-window nil)
(defvar lookup-current-session nil)
(defvar lookup-last-session nil)

(defmacro tategaki-lookup-pane-test--source (&rest body)
  "Run BODY with a source and owned private Lookup context."
  (declare (indent 0) (debug t))
  `(let ((source (generate-new-buffer " *Lookup pane source*")) context)
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer source)
           (text-mode)
           (buffer-enable-undo)
           (insert "未保存の原稿です。") (goto-char 4) (set-mark 2)
           (setq context (tategaki-lookup--new-context source))
           ,@body)
       (dolist (buffer (append (plist-get context :buffers) (list source)))
         (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest tategaki-lookup-pane-normal-lookup-keeps-original-displays ()
  (let ((tategaki-lookup--active-context nil) (tategaki-lookup--context nil) calls)
    (dolist (adapter '(tategaki-lookup--display tategaki-lookup--display-content
                       tategaki-lookup--display-help tategaki-lookup--open-buffer))
      (should (eq (funcall adapter (lambda (value) (push value calls) 'original) "normal")
                  'original)))
    (should (equal calls '("normal" "normal" "normal" "normal")))))

(ert-deftest tategaki-lookup-pane-private-information-survives-mode-reset ()
  (tategaki-lookup-pane-test--source
    (let ((ordinary (get-buffer-create "*Entry Information*")) private)
      (unwind-protect
          (progn
            (with-current-buffer ordinary (insert "ordinary lookup sentinel"))
            (tategaki-lookup--call
             context
             (lambda ()
               (setq private (tategaki-lookup--open-buffer #'get-buffer-create "*Entry Information*"))
               (with-current-buffer private
                 (help-mode)
                 (should (eq tategaki-lookup--context context))
                 (should-not tategaki-pane--installed-header)
                 (tategaki-lookup--display-content #'ignore private)
                 (should tategaki-pane--installed-header)
                 (should (eq (key-binding (kbd "q")) #'tategaki-lookup-close)))) nil)
            (should-not (eq ordinary private))
            (with-current-buffer ordinary
              (should (equal (buffer-string) "ordinary lookup sentinel"))
              (should-not tategaki-lookup--context)
              (should-not tategaki-pane--installed-header))
            (should (eq (lookup-key help-mode-map (kbd "q")) #'quit-window)))
        (kill-buffer ordinary)))))

(ert-deftest tategaki-lookup-pane-close-only-clicked-window-and-recreate-main ()
  (tategaki-lookup-pane-test--source
    (let ((text (buffer-string)) (undo buffer-undo-list) (position (point))
          (ordinary (generate-new-buffer " *Ordinary Lookup window*"))
          entry content help other-window content-window help-window)
      (unwind-protect
          (progn
            (setq other-window (display-buffer-in-side-window ordinary '((side . left))))
            (tategaki-lookup--call
             context
             (lambda ()
               (setq entry (tategaki-lookup--open-buffer #'get-buffer-create lookup-entry-buffer)
                     content (tategaki-lookup--open-buffer #'get-buffer-create lookup-content-buffer)
                     help (tategaki-lookup--open-buffer #'get-buffer-create lookup-help-buffer))
               (tategaki-lookup--show entry context 3)
               (tategaki-lookup--show content context 4)
               (tategaki-lookup--show help context 5)) nil)
            (setq content-window (get-buffer-window content) help-window (get-buffer-window help))
            (let ((event (list 'mouse-1 (list (get-buffer-window entry) 'header-line '(5 . 5) 0))))
              (tategaki-pane-close event))
            (should-not (get-buffer-window entry))
            (should (eq (get-buffer-window content) content-window))
            (should (eq (get-buffer-window help) help-window))
            (should (eq (get-buffer-window ordinary) other-window))
            (should (eq (window-buffer (selected-window)) source))
            (with-current-buffer content
              (tategaki-lookup--display #'ignore entry))
            (should (get-buffer-window entry))
            (with-current-buffer source
              (should (equal text (buffer-string)))
              (should (eq undo buffer-undo-list))
              (should (= position (point)))
              (should (buffer-modified-p))))
        (kill-buffer ordinary)))))

(ert-deftest tategaki-lookup-pane-context-keeps-ordinary-window-and-session-state ()
  (tategaki-lookup-pane-test--source
    (let ((lookup-entry-buffer "ordinary entry") (lookup-main-window (selected-window))
          (lookup-sub-window 'ordinary-sub) (lookup-current-session 'ordinary-session)
          (lookup-last-session 'ordinary-last))
      (tategaki-lookup--call
       context
       (lambda ()
         (should (equal lookup-entry-buffer (plist-get context :entry)))
         (should-not lookup-main-window)
         (setq lookup-current-session 'studio-session lookup-last-session 'studio-last)) nil)
      (should (equal lookup-entry-buffer "ordinary entry"))
      (should (eq lookup-main-window (selected-window)))
      (should (eq lookup-sub-window 'ordinary-sub))
      (should (eq lookup-current-session 'ordinary-session))
      (should (eq lookup-last-session 'ordinary-last))
      (should (eq (plist-get context :current-session) 'studio-session)))))

(provide 'tategaki-lookup-pane-test)
;;; tategaki-lookup-pane-test.el ends here
