;;; tategaki-studio-test.el --- Studio integration regressions -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'tategaki-studio)
(require 'tategaki-reader)

(defmacro tategaki-studio-test--with-manuscript (&rest body)
  "Run BODY in an isolated Studio manuscript and restore windows afterward."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "tategaki-studio-test-" t))
          (default-directory (file-name-as-directory directory))
          (tategaki-project-default-file (expand-file-name "defaults.json" directory))
          (tategaki-session-file (expand-file-name "session.json" directory))
          (tategaki-history-directory (expand-file-name "history/" directory)))
     (unwind-protect
         (save-window-excursion
           (with-temp-buffer
             (text-mode)
             (insert "第一章\n「日本人であることを考えるのであろう」\n第二章\n物語の続き。\n")
             (goto-char 5)
             (switch-to-buffer (current-buffer))
             (let ((source (current-buffer)))
               (unwind-protect (progn ,@body)
                 (when (buffer-live-p source)
                   (with-current-buffer source
                     (when tategaki-reader-mode (tategaki-reader-mode -1))
                     (when tategaki-studio-mode (tategaki-studio-mode -1))
                     (when tategaki-mode (tategaki-mode -1))))))))
       (delete-directory directory t))))

(ert-deftest tategaki-studio-enable-disable-preserves-manuscript-and-layout ()
  (tategaki-studio-test--with-manuscript
    (buffer-enable-undo)
    (setq-local header-line-format "before-header")
    (setq-local mode-line-format "before-status")
    (let ((text (buffer-string)) (undo buffer-undo-list) (position (point))
          (other (get-buffer-create " *studio-existing-window*")))
      (unwind-protect
          (progn
            (set-window-buffer (split-window-right) other)
            (tategaki-studio-mode 1)
            (should (eq tategaki-studio-state 'write))
            (should (= 1 (length (window-list))))
            (should tategaki-mode)
            (should tategaki-history-mode)
            (should (timerp tategaki-history--timer))
            (tategaki-studio-mode -1)
            (should tategaki-mode)
            (should-not tategaki-history-mode)
            (should-not tategaki-history--timer)
            (should (get-buffer-window other))
            (should (equal header-line-format "before-header"))
            (should (equal mode-line-format "before-status"))
            (should (equal text (buffer-string)))
            (should (eq undo buffer-undo-list))
            (should (= position (point)))
            (should (buffer-modified-p)))
        (kill-buffer other)))))

(ert-deftest tategaki-studio-review-write-review-restores-tool-windows ()
  (tategaki-studio-test--with-manuscript
    (tategaki-studio-mode 1)
    (tategaki-studio-review)
    (should (eq tategaki-studio-state 'review))
    (should (get-buffer-window tategaki-outline--buffer))
    (let ((panel (get-buffer-create " *studio-review-panel*")))
      (unwind-protect
          (progn
            (display-buffer-in-side-window panel '((side . right) (slot . 3)))
            (tategaki-studio-write)
            (should (= 2 (length (window-list))))
            (should (get-buffer-window tategaki-outline--buffer))
            (should-not (get-buffer-window panel))
            (tategaki-studio-review)
            (should (get-buffer-window panel))
            (should (get-buffer-window tategaki-outline--buffer)))
        (kill-buffer panel)))))

(ert-deftest tategaki-studio-toolbar-keeps-the-correct-source-in-each-closure ()
  (tategaki-studio-test--with-manuscript
    (let* ((label (tategaki-studio--button "動作" 'tategaki-studio-test--command))
           (map (get-text-property 0 'local-map label))
           (handler (lookup-key map [header-line mouse-1]))
           (source-window (selected-window)) called)
      (cl-letf (((symbol-function 'tategaki-studio-test--command)
                 (lambda () (interactive) (setq called (current-buffer)))))
        (with-temp-buffer
          (funcall handler (list 'mouse-1 (list source-window 'header-line '(1 . 1) 0)))))
      (should (eq called source))
      (should (eq (window-buffer (selected-window)) source)))))

(ert-deftest tategaki-studio-source-resolver-supports-tools-and-outline ()
  (tategaki-studio-test--with-manuscript
    (should (eq source (tategaki-studio-source-buffer)))
    (with-temp-buffer
      (should (eq (current-buffer) (tategaki-studio-source-buffer))))
    (with-temp-buffer
      (special-mode)
      (setq-local tategaki-studio-source source)
      (should (eq source (tategaki-studio-source-buffer))))
    (with-temp-buffer
      (special-mode)
      (setq-local tategaki-outline--source source)
      (should (eq source (tategaki-studio-source-buffer))))
    (with-temp-buffer
      (special-mode)
      (should-error (tategaki-studio-source-buffer) :type 'user-error))))

(ert-deftest tategaki-studio-startup-failure-rolls-back-lifecycle ()
  (tategaki-studio-test--with-manuscript
    (setq-local header-line-format "original")
    (let ((text (buffer-string)) (undo buffer-undo-list))
      (cl-letf (((symbol-function 'tategaki-proofread-mode)
                 (lambda (arg) (when (> arg 0) (error "startup failure")))))
        (should-error (tategaki-studio-mode 1)))
      (should-not tategaki-studio-mode)
      (should-not tategaki-studio--saved)
      (should-not tategaki-mode)
      (should-not tategaki-history-mode)
      (should-not tategaki-history--timer)
      (should (equal header-line-format "original"))
      (should (equal text (buffer-string)))
      (should (eq undo buffer-undo-list))
      (should-not (file-exists-p tategaki-session-file)))))

(ert-deftest tategaki-studio-disable-leaves-reader-without-stale-ui ()
  (tategaki-studio-test--with-manuscript
    (setq-local header-line-format "original")
    (tategaki-studio-mode 1)
    (tategaki-studio-review)
    (tategaki-reader-mode 1)
    (should buffer-read-only)
    (tategaki-studio-mode -1)
    (should-not tategaki-reader-mode)
    (should-not tategaki-reader--saved)
    (should-not buffer-read-only)
    (should (equal header-line-format "original"))
    (should tategaki-mode)))

(ert-deftest tategaki-studio-session-restores-view-without-saving-dirty-text ()
  (tategaki-studio-test--with-manuscript
    (let ((file (expand-file-name "novel.txt" directory)))
      (write-region (point-min) (point-max) file nil 'silent)
      (set-visited-file-name file t)
      (tategaki-studio-mode 1)
      (tategaki-studio-review)
      (goto-char 8)
      (let ((record (tategaki-session-save)))
        (tategaki-studio-mode -1)
        (goto-char (point-max)) (insert "未保存の追加")
        (let ((text (buffer-string)) (undo buffer-undo-list))
          ;; Exercise the session startup path even in batch's terminal frame.
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
            (tategaki-session-restore record))
          (should tategaki-studio-mode)
          (should (eq tategaki-studio-state 'review))
          (should (= (point) 8))
          (should (equal text (buffer-string)))
          (should (eq undo buffer-undo-list))
          (should (buffer-modified-p))
          (should-not (string-match-p "未保存" (with-temp-buffer
                                                  (insert-file-contents file)
                                                  (buffer-string)))))))))

(ert-deftest tategaki-studio-rejects-nontext-buffer-without-hooks ()
  (with-temp-buffer
    (special-mode)
    (should-error (tategaki-studio-mode 1) :type 'user-error)
    (should-not tategaki-studio-mode)
    (should-not tategaki-studio--saved)
    (should-not (memq #'tategaki-studio--exit kill-buffer-hook))))

(provide 'tategaki-studio-test)
;;; tategaki-studio-test.el ends here
