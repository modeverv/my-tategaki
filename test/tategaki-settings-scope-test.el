;;; tategaki-settings-scope-test.el --- Explicit scope promotion boundaries -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(eval-and-compile
  (unless (featurep 'tategaki-settings-paper-test)
    (load (expand-file-name "tategaki-settings-paper-test.el"
                            (file-name-directory
                             (or load-file-name (bound-and-true-p byte-compile-current-file)
                                 buffer-file-name))) nil nil t)))

(ert-deftest tategaki-settings-scope-promotes-only-edited-paper-to-project-and-default ()
  (tategaki-settings-test--project
    (tategaki-project-save '((title . "作品固有のタイトル") (author . "作品固有の著者")))
    (setq settings (tategaki-settings source))
    (let ((text (with-current-buffer source (buffer-string)))
          (undo (buffer-local-value 'buffer-undo-list source))
          (position (with-current-buffer source (point)))
          (tick (buffer-chars-modified-tick source)))
      (with-current-buffer settings
        (tategaki-settings-paper-test--input "27" "43")
        (tategaki-settings-apply-paper-size)
        (setq tategaki-settings--scope 'session)
        (tategaki-settings-save)
        (should-not (tategaki-settings--save-values))
        (setq tategaki-settings--scope 'project)
        (should (equal (mapcar #'car (tategaki-settings--save-values)) '(manuscript-size)))
        (tategaki-settings-save)
        (setq tategaki-settings--scope 'default)
        (tategaki-settings-save)
        (should-not (tategaki-settings--save-values)))
      (with-temp-buffer
        (setq default-directory (file-name-as-directory directory))
        (tategaki-project-apply-settings)
        (should (equal tategaki-manuscript-size '(27 . 43))))
      (let ((defaults (tategaki-project--read tategaki-project-default-file)))
        (should (equal (mapcar #'car (alist-get 'settings defaults)) '(manuscript-size)))
        (should-not (assq 'title defaults))
        (should-not (assq 'author defaults)))
      (with-current-buffer source
        (should (equal "作品固有のタイトル" (alist-get 'title (tategaki-project-load))))
        (should (equal text (buffer-string)))
        (should (eq undo buffer-undo-list))
        (should (= position (point)))
        (should (= tick (buffer-chars-modified-tick)))
        (should-not (buffer-modified-p))))))

(ert-deftest tategaki-settings-scope-explicit-equal-paper-can-be-saved ()
  (tategaki-settings-test--project
    (setq-local tategaki-manuscript-size '(27 . 43))
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (tategaki-settings-apply-paper-size)
      (should-not (tategaki-settings--changes))
      (should (assq 'manuscript-size (tategaki-settings--save-values)))
      (tategaki-settings-save))
    (with-temp-buffer
      (setq default-directory (file-name-as-directory directory))
      (tategaki-project-apply-settings)
      (should (equal tategaki-manuscript-size '(27 . 43))))))

(ert-deftest tategaki-settings-scope-explicit-equal-free-overrides-old-project-paper ()
  (tategaki-settings-test--project
    (tategaki-project-save '((settings . ((manuscript-size . (20 . 20))))))
    (tategaki-project-save '((settings . ((manuscript-size . nil)))) 'session)
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (let ((widget (alist-get 'manuscript-size tategaki-settings--widgets)))
        (widget-value-set widget nil)
        (widget-apply widget :notify widget))
      (should-not (tategaki-settings--changes))
      (should (equal (assq 'manuscript-size (tategaki-settings--save-values)) '(manuscript-size)))
      (tategaki-settings-close)
      (should tategaki-settings--closing)
      (tategaki-settings--save-and-close))
    (should-not (buffer-live-p settings))
    (with-temp-buffer
      (setq default-directory (file-name-as-directory directory))
      (setq-local tategaki-manuscript-size '(99 . 99))
      (tategaki-project-apply-settings)
      (should-not tategaki-manuscript-size))))

(ert-deftest tategaki-settings-scope-promotion-close-prompts-and-can-discard ()
  (tategaki-settings-test--project
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (tategaki-settings-paper-test--input "27" "43")
      (tategaki-settings-apply-paper-size)
      (setq tategaki-settings--scope 'session)
      (tategaki-settings-save)
      (setq tategaki-settings--scope 'project)
      (should-not (tategaki-settings--changes))
      (tategaki-settings-close)
      (should tategaki-settings--closing)
      (should-not (tategaki-settings--kill-query))
      (tategaki-settings-discard))
    (should-not (file-exists-p (expand-file-name ".tategaki/project.json" directory)))
    (should (equal (buffer-local-value 'tategaki-manuscript-size source) '(27 . 43)))))

(ert-deftest tategaki-settings-scope-failed-promotion-retains-intent-for-retry ()
  (tategaki-settings-test--project
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (tategaki-settings-paper-test--input "27" "43")
      (tategaki-settings-apply-paper-size)
      (setq tategaki-settings--scope 'session)
      (tategaki-settings-save)
      (setq tategaki-settings--scope 'project)
      (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (error "read-only destination"))))
        (should-error (tategaki-settings-save)))
      (should (eq tategaki-settings--saved-scope 'session))
      (should (assq 'manuscript-size (tategaki-settings--save-values)))
      (should (equal (buffer-local-value 'tategaki-manuscript-size source) '(27 . 43)))
      (tategaki-settings-save)
      (should (eq tategaki-settings--saved-scope 'project))
      (should-not (tategaki-settings--save-values)))
    (with-temp-buffer
      (setq default-directory (file-name-as-directory directory))
      (tategaki-project-apply-settings)
      (should (equal tategaki-manuscript-size '(27 . 43))))))

(ert-deftest tategaki-settings-scope-no-edits-or-reverted-edits-do-not-copy-metadata ()
  (tategaki-settings-test--project
    (tategaki-project-save '((title . "作品だけのタイトル")))
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (setq tategaki-settings--scope 'default)
      (tategaki-settings-save)
      (should-not (file-exists-p tategaki-project-default-file))
      (should (string-match-p "変更はありません" tategaki-settings--status))
      (tategaki-settings-paper-test--input "25" "35")
      (tategaki-settings-apply-paper-size)
      (tategaki-settings-set 'author "取り消す著者")
      (tategaki-settings-revert)
      (should-not (tategaki-settings--save-values))
      (tategaki-settings-save)
      (should-not (file-exists-p tategaki-project-default-file))
      (tategaki-settings-close))
    (should-not (buffer-live-p settings))
    (should-not (with-current-buffer source (assq 'author (tategaki-project-load))))))

(ert-deftest tategaki-settings-scope-repeated-save-does-not-overwrite-overridden-default ()
  (tategaki-settings-test--project
    (tategaki-project-save '((settings . ((manuscript-size . (20 . 20))))))
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (tategaki-settings-paper-test--input "27" "43")
      (tategaki-settings-apply-paper-size)
      (setq tategaki-settings--scope 'default)
      (tategaki-settings-save)
      ;; Project priority is visible again after saving the lower default scope.
      (should (equal (alist-get 'manuscript-size tategaki-settings--values) '(20 . 20)))
      (should-not (tategaki-settings--save-values))
      (tategaki-settings-save)
      (should (equal (alist-get 'manuscript-size
                               (alist-get 'settings (tategaki-project--read tategaki-project-default-file)))
                     [27 43])))))

(provide 'tategaki-settings-scope-test)
;;; tategaki-settings-scope-test.el ends here
