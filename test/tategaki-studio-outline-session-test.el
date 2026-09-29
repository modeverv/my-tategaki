;;; tategaki-studio-outline-session-test.el --- Persist writing outlines -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'tategaki-studio)
(require 'tategaki-session)
(require 'tategaki-reader)
(require 'tategaki-outline)

(defmacro tategaki-studio-outline-session-test--with-source (&rest body)
  "Run BODY with real outline windows and isolated dirty source/session data.
Only graphical typesetting is disabled; Studio layout and Reader run normally."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "tategaki-outline-session-test-" t))
          (tategaki-session-file (expand-file-name "session.json" directory))
          (tategaki-history-directory (expand-file-name "history/" directory))
          (tategaki-project-default-file (expand-file-name "defaults.json" directory))
          (source (generate-new-buffer " *outline-session-source*")))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer source)
           (text-mode)
           (setq buffer-file-name (expand-file-name "novel.txt" directory)
                 default-directory (file-name-as-directory directory))
           (insert "第一章\n執筆する本文。\n第二章\n読書する本文。\n")
           (write-region (point-min) (point-max) buffer-file-name nil 'silent)
           (buffer-enable-undo)
           (insert "未保存の加筆。")
           (goto-char 8) (set-mark 3) (setq mark-active t)
           (setq-local tategaki-studio-mode t)
           (setq-local tategaki-studio-state 'write)
           (setq-local tategaki-mode nil)
           (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil))
                     ((symbol-function 'tategaki-refresh) #'ignore))
             ,@body))
       (when (buffer-live-p source)
         (with-current-buffer source
           (when tategaki-reader-mode (tategaki-reader-mode -1))
           (tategaki-outline-cleanup)
           (setq tategaki-studio-mode nil)
           (set-buffer-modified-p nil))
         (kill-buffer source))
       (delete-directory directory t))))

(defun tategaki-studio-outline-session-test--visible-p ()
  "Return whether this source's outline is displayed."
  (and (buffer-live-p tategaki-outline--buffer)
       (get-buffer-window tategaki-outline--buffer) t))

(defun tategaki-studio-outline-session-test--source-state ()
  "Capture text, editing and navigation invariants of the current source."
  (list (buffer-string) buffer-undo-list (buffer-chars-modified-tick)
        (buffer-modified-p) (point) (mark t) mark-active))

(ert-deftest tategaki-studio-outline-session-json-restores-write-open-and-closed ()
  (dolist (visible '(nil t))
    (tategaki-studio-outline-session-test--with-source
      (save-selected-window (tategaki-outline))
      (unless visible (tategaki-outline t))
      (let ((state (tategaki-studio-outline-session-test--source-state))
            (source-window (selected-window)))
        (tategaki-session-save)
        (let ((record (car (alist-get 'sessions (tategaki-session--read)))))
          (should (equal (alist-get 'state record) "write"))
          (should (eq visible (tategaki-session--true-p (alist-get 'outline record))))
          ;; Restore over the opposite current state, including a visible
          ;; outline when the saved session explicitly says it was closed.
          (save-selected-window (tategaki-outline visible))
          (goto-char (point-max))
          (should (eq source (tategaki-session-restore record)))
          (should (eq tategaki-studio-state 'write))
          (should (eq visible (tategaki-studio-outline-session-test--visible-p)))
          (should (eq (window-buffer (selected-window)) source))
          (should (eq (selected-window) source-window))
          (should (equal state (tategaki-studio-outline-session-test--source-state)))
          (should (eq (nth 1 state) buffer-undo-list))
          (tategaki-outline--idle-refresh source)
          (should (eq visible (tategaki-studio-outline-session-test--visible-p)))
          (should-not (string-match-p "未保存"
                                      (with-temp-buffer
                                        (insert-file-contents (alist-get 'file record))
                                        (buffer-string)))))))))

(ert-deftest tategaki-studio-outline-session-false-overrides-review-default ()
  (tategaki-studio-outline-session-test--with-source
    (let ((record (tategaki-session--capture)))
      (setf (alist-get 'state record) "review"
            (alist-get 'outline record) :json-false)
      (tategaki-session--apply record)
      (should (eq tategaki-studio-state 'review))
      (should-not (tategaki-studio-outline-session-test--visible-p))
      (should-not (buffer-live-p tategaki-outline--buffer))
      (should-not (memq #'tategaki-outline--post-command post-command-hook))
      (should (eq (window-buffer (selected-window)) source)))))

(ert-deftest tategaki-studio-outline-session-old-record-does-not-imply-close ()
  (tategaki-studio-outline-session-test--with-source
    (save-selected-window (tategaki-outline))
    (let ((record (assq-delete-all 'outline (tategaki-session--capture)))
          (outline tategaki-outline--buffer))
      ;; Stay in Review so a legacy record exercises the no-key policy
      ;; independently of Write's separate keep-outline layout feature.
      (setq-local tategaki-studio-state 'review)
      (setf (alist-get 'state record) "review")
      (tategaki-session--apply record)
      (should (eq outline tategaki-outline--buffer))
      (should (tategaki-studio-outline-session-test--visible-p)))))

(ert-deftest tategaki-studio-outline-session-reader-roundtrip-preserves-close-intent ()
  (dolist (visible '(nil t))
    (tategaki-studio-outline-session-test--with-source
      (save-selected-window (tategaki-outline))
      (unless visible (tategaki-outline t))
      (let ((state (tategaki-studio-outline-session-test--source-state))
            (source-window (selected-window)))
        (tategaki-reader-mode 1)
        (should-not (tategaki-studio-outline-session-test--visible-p))
        (goto-char (point-max))
        (tategaki-session-save)
        (let ((record (car (alist-get 'sessions (tategaki-session--read)))))
          (should (eq visible (tategaki-session--true-p (alist-get 'outline record))))
          (should (= (nth 4 state) (alist-get 'point record)))
          (should (equal "write" (alist-get 'state record))))
        ;; A pending idle refresh is allowed to update the hidden list, but
        ;; must never redisplay it while Reader owns the window layout.
        (tategaki-outline--idle-refresh source)
        (should-not (tategaki-studio-outline-session-test--visible-p))
        (tategaki-reader-mode -1)
        (should (eq visible (tategaki-studio-outline-session-test--visible-p)))
        (should (eq source-window (selected-window)))
        (should (equal state (tategaki-studio-outline-session-test--source-state)))
        (should (eq (nth 1 state) buffer-undo-list))
        ;; An explicit close before the next Reader visit must supersede
        ;; the previously open state; no old snapshot can resurrect it.
        (when visible
          (with-current-buffer tategaki-outline--buffer (tategaki-outline-close))
          (tategaki-reader-mode 1)
          (tategaki-reader-mode -1)
          (should-not (tategaki-studio-outline-session-test--visible-p)))))))

(provide 'tategaki-studio-outline-session-test)
;;; tategaki-studio-outline-session-test.el ends here
