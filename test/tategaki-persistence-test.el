;;; tategaki-persistence-test.el --- Studio persistence regressions -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'tategaki-history)
(require 'tategaki-session)
(require 'tategaki-reader)
(require 'tategaki-outline)
(require 'tategaki-lookup)
(defvar tategaki--scroll-start)
(defvar lookup-content-buffer nil)
(defvar lookup-entry-buffer nil)
(defvar lookup-main-window nil)
(defvar lookup-sub-window nil)
(defvar lookup-start-window nil)

(defmacro tategaki-persistence-test--isolated (&rest body)
  "Execute BODY with isolated private persistence directories."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "tategaki-persistence-test-" t))
          (tategaki-history-directory (expand-file-name "history/" directory))
          (tategaki-session-file (expand-file-name "session.json" directory)))
     (unwind-protect (progn ,@body)
       (delete-directory directory t))))

(ert-deftest tategaki-history-keeps-dirty-full-source-and-deduplicates ()
  (tategaki-persistence-test--isolated
    (with-temp-buffer
      (buffer-enable-undo)
      (insert "第一章\n未保存の原稿。\n")
      (goto-char 3)
      (let ((undo buffer-undo-list) (text (buffer-string)) (position (point))
            first second)
        (narrow-to-region 2 5)
        (setq first (tategaki-history-snapshot 'idle)
              second (tategaki-history-snapshot 'save))
        (should (equal first second))
        (should (= (point) position))
        (should (= (point-min) 2))
        (should (eq undo buffer-undo-list))
        (should (buffer-modified-p))
        (should (equal text (tategaki-history--snapshot-text first)))
        (should (= 1 (length (alist-get 'snapshots
                                         (tategaki-history--manifest
                                          (tategaki-history--id))))))
        (should (= #o600 (file-modes
                         (expand-file-name "manifest.json"
                                           (tategaki-history--directory
                                            (tategaki-history--id))))))))))

(ert-deftest tategaki-history-reuses-older-content-with-new-timeline-entry ()
  (tategaki-persistence-test--isolated
    (with-temp-buffer
      (insert "一")
      (let ((first (tategaki-history-snapshot)))
        (insert "二") (tategaki-history-snapshot)
        (delete-char -1)
        (let ((third (tategaki-history-snapshot)))
          (should (equal (alist-get 'file first) (alist-get 'file third)))
          (should (= 3 (length (alist-get 'snapshots
                                           (tategaki-history--manifest
                                            (tategaki-history--id)))))))))))

(ert-deftest tategaki-history-corrupt-manifest-is-preserved ()
  (tategaki-persistence-test--isolated
    (with-temp-buffer
      (insert "本文")
      (let ((path (expand-file-name "manifest.json"
                                    (tategaki-history--directory (tategaki-history--id)))))
        (tategaki-history--atomic-write path "{broken")
        (should-error (tategaki-history-snapshot))
        (should (equal "{broken" (with-temp-buffer (insert-file-contents path)
                                                  (buffer-string))))))))

(ert-deftest tategaki-history-first-save-keeps-fileless-snapshots-on-reopen ()
  (tategaki-persistence-test--isolated
    (let ((file (expand-file-name "first-save.txt" directory)) id)
      (with-temp-buffer
        (insert "未保存の初稿")
        (tategaki-history-snapshot)
        (erase-buffer) (insert "保存する原稿")
        (setq buffer-file-name file)
        (tategaki-history-snapshot 'save)
        (setq id (tategaki-history--id)))
      (with-temp-buffer
        (setq buffer-file-name file)
        (should (equal id (tategaki-history--id)))
        (let ((records (alist-get 'snapshots (tategaki-history--manifest id))))
          (should (= 2 (length records)))
          (should (equal "保存する原稿" (tategaki-history--snapshot-text (car records))))
          (should (equal "未保存の初稿" (tategaki-history--snapshot-text (cadr records)))))))))

(ert-deftest tategaki-persistence-rejects-null-empty-and-trailing-json ()
  (tategaki-persistence-test--isolated
    (with-temp-buffer
      (insert "本文")
      (let ((file (expand-file-name "manifest.json"
                                    (tategaki-history--directory (tategaki-history--id)))))
        (dolist (bad '("null" "{}" "[]" "{} trailing"))
          (tategaki-history--atomic-write file bad)
          (should-error (tategaki-history-snapshot))
          (tategaki-history--atomic-write tategaki-session-file bad)
          (should-error (tategaki-session-save)))))))

(ert-deftest tategaki-history-atomic-failure-keeps-previous-file ()
  (tategaki-persistence-test--isolated
    (let ((file (expand-file-name "atomic.json" directory)))
      (tategaki-history--atomic-write file "original")
      (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (error "disk error"))))
        (should-error (tategaki-history--atomic-write file "replacement")))
      (should (equal "original" (with-temp-buffer (insert-file-contents file)
                                                 (buffer-string))))
      (should-not (directory-files directory nil "\\`\\.tategaki-")))))

(ert-deftest tategaki-history-rejects-path-traversal-and-corrupt-snapshot ()
  (tategaki-persistence-test--isolated
    (with-temp-buffer
      (insert "本文")
      (let* ((record (tategaki-history-snapshot))
             (bad (copy-tree record)))
        (setf (alist-get 'file bad) "../../outside.txt")
        (should-error (tategaki-history--snapshot-text bad) :type 'user-error)
        (tategaki-history--atomic-write
         (expand-file-name (alist-get 'file record)
                           (tategaki-history--directory (tategaki-history--id))) "damaged")
        (should-error (tategaki-history--snapshot-text record) :type 'user-error)))))

(ert-deftest tategaki-history-restore-only-creates-a-separate-copy ()
  (tategaki-persistence-test--isolated
    (with-temp-buffer
      (insert "old")
      (let ((record (tategaki-history-snapshot)) copy)
        (insert " dirty")
        (let ((text (buffer-string)) (undo buffer-undo-list) (source (current-buffer)))
          (save-window-excursion
            (setq copy (tategaki-history-restore-as-copy record)))
          (unwind-protect
              (progn
                (with-current-buffer copy
                  (should (equal (buffer-string) "old"))
                  (should-not buffer-file-name)
                  (should-not buffer-read-only)
                  (should (buffer-modified-p)))
                (with-current-buffer source
                  (should (equal text (buffer-string)))
                  (should (eq undo buffer-undo-list))
                  (should (buffer-modified-p))))
            (kill-buffer copy)))))))

(ert-deftest tategaki-history-mode-obeys-save-only-and-disable-settings ()
  (tategaki-persistence-test--isolated
    (with-temp-buffer
      (insert "本文")
      (setq-local tategaki-history-idle-interval nil)
      (unwind-protect
          (progn
            (tategaki-history-mode 1)
            (should-not tategaki-history--timer)
            (run-hooks 'after-save-hook)
            (should (= 1 (length (alist-get 'snapshots
                                            (tategaki-history--manifest
                                             (tategaki-history--id))))))
            (setq-local tategaki-history-enabled nil)
            (insert "追記")
            (run-hooks 'after-save-hook)
            (should (= 1 (length (alist-get 'snapshots
                                            (tategaki-history--manifest
                                             (tategaki-history--id)))))))
        (tategaki-history-mode -1))
      (should-not (memq #'tategaki-history--after-save after-save-hook)))))

(ert-deftest tategaki-session-roundtrip-preserves-dirty-text-undo-and-locals ()
  (tategaki-persistence-test--isolated
    (let* ((file (expand-file-name "manuscript.txt" directory))
           (buffer (progn (write-region "第一章\n本文です。" nil file nil 'silent)
                          (find-file-noselect file))))
      (unwind-protect
          (with-current-buffer buffer
            (buffer-enable-undo)
            (goto-char 4) (set-mark 2)
            (setq-local tategaki-manuscript-size '(20 . 20))
            (setq-local tategaki-manuscript-spread t)
            (setq-local tategaki-typesetting t)
            (setq-local tategaki--page 2)
            (setq-local tategaki--scroll-start 2)
            (setq-local tategaki--text-scale-amount 1)
            (setq-local tategaki-studio-state 'review)
            (let ((record (tategaki-session-save)))
              (goto-char (point-max)) (insert "未保存")
              (setq-local tategaki-manuscript-size nil)
              (let ((text (buffer-string)) (undo buffer-undo-list))
                (save-window-excursion (tategaki-session-restore record))
                (should (equal text (buffer-string)))
                (should (eq undo buffer-undo-list))
                (should (buffer-modified-p))
                (should (= (point) 4)) (should (= (mark t) 2))
                (should (equal tategaki-manuscript-size '(20 . 20)))
                (should tategaki-manuscript-spread)
                (should tategaki-typesetting)
                (should (eq tategaki-studio-state 'review))
                (should (= tategaki--text-scale-amount 1))
                (should (= tategaki--page 2))
                (should (= tategaki--scroll-start 2)))
              (should (equal (tategaki-session-recent-files) (list file)))))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest tategaki-session-fit-window-roundtrips-both-booleans-from-json ()
  (tategaki-persistence-test--isolated
    (let* ((file (expand-file-name "fit-window.txt" directory))
           (buffer (progn (write-region "合成原稿" nil file nil 'silent)
                          (find-file-noselect file))))
      (unwind-protect
          (with-current-buffer buffer
            (buffer-enable-undo)
            (goto-char (point-max)) (insert "未保存")
            (let ((text (buffer-string)) (undo buffer-undo-list))
              (dolist (fit '(nil t))
                (setq-local tategaki-manuscript-fit-window fit)
                (tategaki-session-save)
                (setq-local tategaki-manuscript-fit-window (not fit))
                (save-window-excursion
                  (tategaki-session-restore
                   (car (alist-get 'sessions (tategaki-session--read)))))
                (should (eq tategaki-manuscript-fit-window fit))
                (should (equal text (buffer-string)))
                (should (eq undo buffer-undo-list))
                (should (buffer-modified-p)))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest tategaki-session-reader-save-and-exit-keep-editing-state ()
  "Actual Reader saves retain the editing view and leave Reader untouched."
  (tategaki-persistence-test--isolated
    (dolist (outline-visible '(nil t))
      (save-window-excursion
        (with-temp-buffer
          (switch-to-buffer (current-buffer))
          (setq buffer-file-name (expand-file-name "reader-session.txt" directory))
          (insert "第一章\n元の執筆位置。\n第二章\nReaderで読む位置。")
          (write-region (point-min) (point-max) buffer-file-name nil 'silent)
          (buffer-enable-undo)
          (goto-char (point-max)) (insert "未保存")
          (setq-local tategaki-studio-mode t)
          (setq-local tategaki-history-mode nil)
          (setq-local tategaki-manuscript-size '(20 . 20))
          (setq-local tategaki-manuscript-spread nil)
          (setq-local tategaki-manuscript-fit-window nil)
          (setq-local tategaki-manuscript-grid t)
          (setq-local tategaki-typesetting nil)
          (setq-local tategaki-studio-state 'review)
          (setq-local tategaki--page 2)
          (setq-local tategaki--scroll-start 3)
          (setq-local tategaki--text-scale-amount 1)
          (save-selected-window (tategaki-outline))
          (unless outline-visible
            ;; An alive but hidden outline must remain hidden on restart.
            (delete-window (get-buffer-window tategaki-outline--buffer)))
          (goto-char 8) (set-mark 3) (setq mark-active t)
          (let ((source (current-buffer)) (text (buffer-string))
                (undo buffer-undo-list) (outline tategaki-outline--buffer))
            (unwind-protect
                (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
                  (tategaki-session-save)
                  (let ((editing (car (alist-get 'sessions (tategaki-session--read)))))
                    (should (equal "第一章" (alist-get 'chapter editing)))
                    (tategaki-reader-mode 1)
                    (goto-char (point-max)) (set-mark 2) (setq mark-active nil)
                    (setq-local tategaki--page 12)
                    (setq-local tategaki--scroll-start 40)
                    (should tategaki-manuscript-fit-window)
                    (should-not (get-buffer-window outline))
                    (let ((windows (current-window-configuration))
                          (reader-point (point)))
                      (dolist (save-function '(tategaki-session-save tategaki-session--save-on-exit))
                        (funcall save-function)
                        (let ((record (car (alist-get 'sessions (tategaki-session--read)))))
                          (dolist (key '(point mark mark_active page scroll_start text_scale
                                              manuscript_size spread fit_window grid typesetting
                                              studio state outline chapter history_document))
                            (should (equal (alist-get key record) (alist-get key editing)))))
                        (should tategaki-reader-mode)
                        (should buffer-read-only)
                        (should (= reader-point (point)))
                        (should (= 2 (mark t)))
                        (should-not mark-active)
                        (should (= tategaki--page 12))
                        (should (= tategaki--scroll-start 40))
                        (should (window-configuration-equal-p windows (current-window-configuration)))
                        (should (equal text (buffer-string)))
                        (should (eq undo buffer-undo-list))
                        (should (buffer-modified-p))))
                    (tategaki-reader-mode -1)
                    (tategaki-outline-cleanup)
                    (setq-local tategaki-studio-mode nil)
                    (setq-local tategaki-manuscript-size '(40 . 17))
                    (setq-local tategaki-manuscript-spread t)
                    (setq-local tategaki-manuscript-fit-window t)
                    (setq-local tategaki-manuscript-grid nil)
                    (setq-local tategaki-typesetting t)
                    (setq-local tategaki-studio-state 'write)
                    (goto-char (point-max))
                    (should (eq source (tategaki-session-restore
                                        (car (alist-get 'sessions (tategaki-session--read))))))
                    (should (equal tategaki-manuscript-size '(20 . 20)))
                    (should-not tategaki-manuscript-spread)
                    (should-not tategaki-manuscript-fit-window)
                    (should tategaki-manuscript-grid)
                    (should-not tategaki-typesetting)
                    (should (eq tategaki-studio-state 'review))
                    (should (= 8 (point))) (should (= 3 (mark t)))
                    (should mark-active)
                    (should (= 2 tategaki--page))
                    (should (= 3 tategaki--scroll-start))
                    (should (eq outline-visible
                                (and (buffer-live-p tategaki-outline--buffer)
                                     (get-buffer-window tategaki-outline--buffer) t)))
                    (should (equal text (buffer-string)))
                    (should (eq undo buffer-undo-list))
                    (should (buffer-modified-p))))
              (when tategaki-reader-mode (tategaki-reader-mode -1))
              (tategaki-outline-cleanup)
              (set-buffer-modified-p nil))))))))

(ert-deftest tategaki-session-reader-retains-inherited-nil-and-unbound-settings ()
  (with-temp-buffer
    (insert "合成原稿")
    (setq-local tategaki-manuscript-size '(40 . 17))
    (setq-local tategaki-manuscript-fit-window t)
    (setq-local tategaki--page 9)
    (setq-local tategaki-reader--saved
                '(:point 1 :mark nil :mark-active nil :outline-visible nil
                  :locals ((tategaki-manuscript-size nil t nil)
                           (tategaki-manuscript-fit-window nil t nil)
                           (tategaki--page nil nil nil))))
    (let ((record (tategaki-session--capture)))
      (should-not (alist-get 'manuscript_size record))
      (should-not (tategaki-session--true-p (alist-get 'fit_window record)))
      (should (= 0 (alist-get 'page record)))
      (should-not (alist-get 'mark record))
      (should-not (tategaki-session--true-p (alist-get 'mark_active record))))))

(ert-deftest tategaki-session-clamps-point-and-rejects-unsafe-fields ()
  (with-temp-buffer
    (insert "本文")
    (setq-local tategaki-manuscript-size '(20 . 20))
    (tategaki-session--apply
     '((point . 999) (mark . -4) (page . "bad") (scroll_start . 999)
       (text_scale . 90000) (manuscript_size . (0 100))
       (spread . :json-false) (typesetting . "true")))
    (should (= (point) (point-max)))
    (should (= (mark) (point-min)))
    (should (equal tategaki-manuscript-size '(20 . 20)))
    (should-not tategaki-manuscript-spread)
    (should-not tategaki-typesetting)))

(ert-deftest tategaki-session-corruption-does-not-get-overwritten ()
  (tategaki-persistence-test--isolated
    (tategaki-history--atomic-write tategaki-session-file "{bad")
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name "book.txt" directory))
      (should-error (tategaki-session-save)))
    (should-not (tategaki-session-recent-files))
    (should (equal "{bad" (with-temp-buffer
                           (insert-file-contents tategaki-session-file)
                           (buffer-string))))))

(ert-deftest tategaki-lookup-query-prefers-region-then-word-then-prompt ()
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 3)
    (should (equal "alpha" (tategaki-lookup--query)))
    (let ((transient-mark-mode t))
      (set-mark 7) (goto-char 11) (activate-mark)
      (should (equal "beta" (tategaki-lookup--query))))
    (erase-buffer)
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "手入力")))
      (should (equal "手入力" (tategaki-lookup--query))))))

(ert-deftest tategaki-lookup-keeps-source-position-and-displays-live-results ()
  (let ((require-original (symbol-function 'require))
        (lookup-content-buffer " *tategaki-test-content*")
        (lookup-entry-buffer " *tategaki-test-entry*")
        lookup-main-window lookup-sub-window lookup-start-window owned-buffers result)
    (unwind-protect
        (save-window-excursion
          (with-temp-buffer
            (switch-to-buffer (current-buffer))
            (insert "manuscript") (goto-char 3) (set-mark 2)
            (let ((source (current-buffer)) (text (buffer-string)) (undo buffer-undo-list))
              (cl-letf (((symbol-function 'require)
                         (lambda (feature &rest args)
                           (if (eq feature 'lookup) t
                             (apply require-original feature args))))
                        ((symbol-function 'lookup-pattern)
                         (lambda (query)
                           (should (equal query "term"))
                           (goto-char (point-max))
                           (switch-to-buffer (get-buffer-create lookup-entry-buffer))
                           (with-current-buffer (get-buffer-create lookup-content-buffer)
                             (insert "dictionary result")))))
                (setq result (tategaki-lookup-word "term")
                      owned-buffers (plist-get tategaki-lookup--source-context :buffers)))
              (should (eq (current-buffer) source))
              (should (= (point) 3)) (should (= (mark) 2))
              (should (equal text (buffer-string)))
              (should (eq undo buffer-undo-list))
              (should (eq (window-parameter (get-buffer-window result)
                                            'window-side) 'right)))))
      (dolist (name (append owned-buffers (list lookup-content-buffer lookup-entry-buffer)))
        (when (get-buffer name) (kill-buffer name))))))

(ert-deftest tategaki-lookup-missing-dependency-is-actionable ()
  (cl-letf (((symbol-function 'require) (lambda (&rest _) nil)))
    (should-error (tategaki-lookup-word "test") :type 'user-error)))

(ert-deftest tategaki-session-exit-saves-final-position-and-dirty-history ()
  (tategaki-persistence-test--isolated
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name "exit.txt" directory))
      (insert "保存した本文")
      (write-region (point-min) (point-max) buffer-file-name nil 'silent)
      (setq-local tategaki-studio-mode t)
      (setq-local tategaki-history-mode t)
      (setq-local tategaki-history-enabled t)
      (buffer-enable-undo)
      (goto-char (point-max)) (insert "未保存") (goto-char 4)
      (let ((text (buffer-string)) (undo buffer-undo-list)
            (file buffer-file-name))
        (tategaki-session--save-on-exit)
        (should (= 4 (alist-get 'point
                                (car (alist-get 'sessions (tategaki-session--read))))))
        (should (equal text (tategaki-history--snapshot-text
                             (car (alist-get 'snapshots (tategaki-history--manifest
                                                        (tategaki-history--id)))))))
        (should (equal "保存した本文"
                       (with-temp-buffer (insert-file-contents file)
                                         (buffer-string))))
        (should (eq undo buffer-undo-list))
        (should (buffer-modified-p))))))

(ert-deftest tategaki-session-startup-is-opt-in-and-errors-are-nondestructive ()
  (let ((noninteractive nil) called)
    (cl-letf (((symbol-function 'tategaki-session-open-last)
               (lambda () (setq called t) (user-error "missing manuscript"))))
      (let ((tategaki-session-startup-action nil))
        (tategaki-session--startup) (should-not called))
      (let ((tategaki-session-startup-action 'resume))
        (tategaki-session--startup) (should called)))))

(ert-deftest tategaki-session-restores-zero-based-scroll-column ()
  (with-temp-buffer
    (insert "本文")
    (tategaki-session--apply '((scroll_start . 0)))
    (should (eql tategaki--scroll-start 0))
    (tategaki-session--apply '((scroll_start . -1)))
    (should-not tategaki--scroll-start)))

(provide 'tategaki-persistence-test)
;;; tategaki-persistence-test.el ends here
