;;; tategaki-session-restart-tests.el --- Two-process GUI restart checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Dedicated GUI process only; this runner terminates Emacs.
;; Set TATEGAKI_RESTART_DIRECTORY to a private shared fixture directory and
;; TATEGAKI_RESTART_PHASE to "save" then "restore" in separate Emacs processes.

(require 'ert)
(require 'cl-lib)
(require 'server)
(setq load-prefer-newer t)
(let ((root (file-name-directory
             (directory-file-name (file-name-directory (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path root))

(defvar tategaki-restart--directory
  (let ((value (getenv "TATEGAKI_RESTART_DIRECTORY")))
    (unless (and value (file-directory-p value)
                 (file-name-absolute-p value))
      (error "A dedicated absolute TATEGAKI_RESTART_DIRECTORY is required"))
    (file-name-as-directory value)))
(defvar tategaki-restart--phase (getenv "TATEGAKI_RESTART_PHASE"))
(unless (member tategaki-restart--phase '("save" "restore"))
  (error "TATEGAKI_RESTART_PHASE must be save or restore"))

(setq user-emacs-directory (expand-file-name "userdata/" tategaki-restart--directory)
      server-name (concat "tategaki-isolated-restart-" tategaki-restart--phase)
      ;; Darwin limits UNIX socket paths; its default temp directory plus
      ;; the explicit session name would exceed that limit.
      server-socket-dir (make-temp-file "/tmp/tategaki-restart-sockets-" t)
      inhibit-startup-screen t)
(make-directory user-emacs-directory t)
(make-directory server-socket-dir t)
(set-file-modes server-socket-dir #o700)
(server-start)
(add-hook 'kill-emacs-hook
          (lambda () (ignore-errors (delete-directory server-socket-dir t))) t)
(set-frame-size (selected-frame) 150 48)
(require 'tategaki-studio)
(setq tategaki-session-file (expand-file-name "session.json" tategaki-restart--directory)
      tategaki-history-directory (expand-file-name "history/" tategaki-restart--directory)
      tategaki-project-default-file (expand-file-name "defaults.json" tategaki-restart--directory)
      tategaki-session-startup-action (and (equal tategaki-restart--phase "restore") 'resume))

(defun tategaki-restart--fixture (name)
  "Return the isolated fixture path for NAME."
  (expand-file-name name tategaki-restart--directory))

(defun tategaki-restart--save ()
  "Prepare a manuscript; final state is saved only by kill-emacs-hook."
  (let ((default-directory tategaki-restart--directory))
    (find-file (tategaki-restart--fixture "manuscript.txt"))
    (text-mode)
    (insert "第一章\n" (make-string 450 ?春) "。\n第二章\n"
            (make-string 700 ?夏) "。\n")
    (save-buffer)
    (tategaki-project-save
     '((title . "再起動する作品") (author . "検証著者")
       (language . "ja") (identifier . "urn:tategaki:restart")))
    (tategaki-studio-mode 1)
    ;; The explicit baseline deliberately differs from the final exit state.
    (goto-char 2)
    (tategaki-session-save)
    (setq-local tategaki-manuscript-size '(20 . 20)
                tategaki-manuscript-grid t
                tategaki-manuscript-spread t
                tategaki-typesetting t
                tategaki--text-scale-amount 1)
    (tategaki--text-scale-apply)
    (tategaki-studio-review)
    (goto-char 510)
    (set-mark 530)
    (setq mark-active t)
    (save-excursion (goto-char (point-max)) (insert "終了直前の未保存草稿。\n"))
    (tategaki-refresh)
    (tategaki-scroll-to-column 20)
    (redisplay t)
    (should (get-buffer-window tategaki-outline--buffer))
    (should (buffer-modified-p))
    (tategaki-history--write-json
     (tategaki-restart--fixture "expected.json")
     `((pid . ,(emacs-pid))
       (record . ,(tategaki-session--capture))
       (dirty_text . ,(buffer-string))
       (saved_text . ,(with-temp-buffer
                        (insert-file-contents (tategaki-restart--fixture "manuscript.txt"))
                        (buffer-string)))))
    (message "Restart SAVE ready pid=%d point=%d mark=%d state=%S page=%S scroll=%S dirty=%S"
             (emacs-pid) (point) (mark) tategaki-studio-state tategaki--page
             tategaki--scroll-start (buffer-modified-p))))

(ert-deftest tategaki-restart-process-restores-and-preserves-source ()
  (should (display-graphic-p))
  (let* ((expected (tategaki-history--read-json (tategaki-restart--fixture "expected.json")))
         (record (alist-get 'record expected))
         (saved (car (alist-get 'sessions (tategaki-session--read))))
         (source (get-file-buffer (tategaki-restart--fixture "manuscript.txt"))))
    (should-not (= (emacs-pid) (alist-get 'pid expected)))
    ;; This buffer must already have been resumed by emacs-startup-hook.
    (should (buffer-live-p source))
    (should (eq (window-buffer (selected-window)) source))
    (dolist (key '(point mark page scroll_start text_scale manuscript_size
                        spread grid typesetting studio state outline chapter))
      (should (equal (alist-get key saved) (alist-get key record))))
    (with-current-buffer source
      (should tategaki-studio-mode)
      (should tategaki-mode)
      (should (eq tategaki-studio-state 'review))
      (should (get-buffer-window tategaki-outline--buffer))
      (should (= (point) (alist-get 'point record)))
      (should (= (mark) (alist-get 'mark record)))
      (should (= tategaki-session-restored-page (alist-get 'page record)))
      (should (equal tategaki--scroll-start (alist-get 'scroll_start record)))
      (should (= tategaki--text-scale-amount 1))
      (should (equal tategaki-manuscript-size '(20 . 20)))
      (should tategaki-manuscript-grid)
      (should tategaki-manuscript-spread)
      (should tategaki-typesetting)
      (should (equal tategaki-session-active-chapter (alist-get 'chapter record)))
      (should (equal (plist-get (tategaki-project-metadata) :title) "再起動する作品"))
      (should (equal (plist-get (tategaki-project-metadata) :author) "検証著者"))
      (should (equal (buffer-string) (alist-get 'saved_text expected)))
      (should-not (buffer-modified-p))
      ;; The shutdown snapshot preserves every unsaved character separately.
      (let* ((snapshot (car (alist-get 'snapshots
                                      (tategaki-history--manifest (tategaki-history--id)))))
             (copy (tategaki-history-restore-as-copy snapshot)))
        (unwind-protect
            (with-current-buffer copy
              (should-not buffer-file-name)
              (should (buffer-modified-p))
              (should (equal (buffer-string) (alist-get 'dirty_text expected))))
          (when (buffer-live-p copy)
            (with-current-buffer copy (set-buffer-modified-p nil))
            (kill-buffer copy))))
      (select-window (get-buffer-window source))
      ;; A subsequent restore must reuse a buffer already containing edits.
      (save-excursion (goto-char (point-max)) (insert "再起動後の未保存追記。\n"))
      (let ((text (buffer-string)) (undo buffer-undo-list))
        (should (eq source (tategaki-session-restore record)))
        (should (equal text (buffer-string)))
        (should (eq undo buffer-undo-list))
        (should (buffer-modified-p)))
      (should (equal (alist-get 'saved_text expected)
                     (with-temp-buffer
                       (insert-file-contents (tategaki-restart--fixture "manuscript.txt"))
                       (buffer-string))))
      (tategaki-studio-write)
      (should (eq tategaki-studio-state 'write))
      (should (= 1 (length (window-list))))
      (tategaki-studio-review)
      (should (get-buffer-window tategaki-outline--buffer))
      (message "Restart RESTORE verified pid=%d previous-pid=%d point=%d dirty-copy-preserved=t"
               (emacs-pid) (alist-get 'pid expected) (point)))))

(defun tategaki-restart--run ()
  "Run this phase in its named isolated GUI process, then terminate it."
  (let ((status 2))
    (condition-case error-data
        (progn
          (unless (display-graphic-p) (error "A dedicated graphical Emacs is required"))
          (set-frame-size (selected-frame) 150 48)
          (set-frame-parameter nil 'name (concat "Tategaki isolated restart " tategaki-restart--phase))
          (if (equal tategaki-restart--phase "save")
              (progn (tategaki-restart--save) (setq status 0))
            (let ((stats (ert-run-tests-batch "^tategaki-restart-process-")))
              (setq status (if (and (= (ert-stats-completed-expected stats) 1)
                                    (zerop (ert-stats-completed-unexpected stats))
                                    (zerop (ert-stats-skipped stats))) 0 1)))))
      (error (message "Restart phase error: %S" error-data)))
    (with-current-buffer "*Messages*"
      (write-region (point-min) (point-max)
                    (tategaki-restart--fixture (concat tategaki-restart--phase ".log"))))
    ;; This intentionally exercises production kill-emacs-hook, not a
    ;; manually invoked save helper or simulated in-process reload.
    (kill-emacs status)))

(run-at-time 90 nil (lambda () (message "Isolated restart test timeout") (kill-emacs 2)))
(add-hook 'emacs-startup-hook
          (lambda () (run-at-time 1 nil #'tategaki-restart--run)) t)
;;; tategaki-session-restart-tests.el ends here
