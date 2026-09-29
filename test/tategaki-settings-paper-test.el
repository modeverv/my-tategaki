;;; tategaki-settings-paper-test.el --- Custom paper draft transactions -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(unless (featurep 'tategaki-settings-test)
  (load (expand-file-name "tategaki-settings-test.el"
                          (file-name-directory (or load-file-name buffer-file-name))) nil nil t))

(defun tategaki-settings-paper-test--input (rows columns)
  "Enter ROWS and COLUMNS through the draft widgets, without applying them."
  (dolist (entry (list (cons 'rows rows) (cons 'columns columns)))
    (let ((widget (alist-get (car entry) tategaki-settings--paper-fields)))
      (widget-value-set widget (cdr entry))
      (widget-apply widget :notify widget))))

(ert-deftest tategaki-settings-paper-applies-dimensions-atomically-with-source-invariants ()
  (tategaki-settings-test--project
    (setq-local tategaki-manuscript-size '(20 . 20))
    (let ((text (buffer-string)) (undo buffer-undo-list) (position (point)))
      (setq settings (tategaki-settings source))
      (with-current-buffer settings
        (tategaki-settings-paper-test--input "25" "31")
        (should (tategaki-settings--paper-draft-p))
        (should (equal (alist-get 'manuscript-size tategaki-settings--values) '(20 . 20)))
        (should (equal (buffer-local-value 'tategaki-manuscript-size source) '(20 . 20)))
        (goto-char (point-min)) (search-forward "寸法を適用")
        (widget-apply (widget-at (1- (point))) :action)
        (should (equal (alist-get 'manuscript-size tategaki-settings--values) '(25 . 31)))
        (should (equal (widget-value (alist-get 'manuscript-size tategaki-settings--widgets)) '(25 . 31)))
        (should-not (tategaki-settings--paper-draft-p)))
      (with-current-buffer source
        (should (equal tategaki-manuscript-size '(25 . 31)))
        (should (equal text (buffer-string))) (should (eq undo buffer-undo-list))
        (should (= position (point))) (should-not (buffer-modified-p))))))

(ert-deftest tategaki-settings-paper-incomplete-and-invalid-input-never-changes-applied-size ()
  (tategaki-settings-test--project
    (setq-local tategaki-manuscript-size '(20 . 20))
    (setq settings (tategaki-settings source))
    (let ((session (buffer-local-value 'tategaki-project-session-settings source)))
      (with-current-buffer settings
        (dolist (invalid '("" "0" "201" "-1" "2.5" "二十" "20x20"))
          (tategaki-settings-paper-test--input "35" invalid)
          (should-error (tategaki-settings-apply-paper-size) :type 'user-error)
          (should (equal (alist-get 'manuscript-size tategaki-settings--values) '(20 . 20)))
          (should (equal (buffer-local-value 'tategaki-manuscript-size source) '(20 . 20)))
          (should (equal session (buffer-local-value 'tategaki-project-session-settings source)))
          (should (string-match-p "1〜200の整数" (buffer-string))))
        (dolist (pair '(("1" . "200") ("200" . "1")))
          (tategaki-settings-paper-test--input (car pair) (cdr pair))
          (tategaki-settings-apply-paper-size)
          (should (equal (alist-get 'manuscript-size tategaki-settings--values)
                         (cons (string-to-number (car pair)) (string-to-number (cdr pair))))))))))

(ert-deftest tategaki-settings-paper-draft-survives-rerender-but-preset-replaces-it ()
  (tategaki-settings-test--project
    (setq-local tategaki-manuscript-size '(20 . 20))
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (tategaki-settings-paper-test--input "" "33")
      (tategaki-settings--step 'character-spacing 1)
      (should (equal tategaki-settings--paper-draft '("" . "33")))
      (should (equal (widget-value (alist-get 'rows tategaki-settings--paper-fields)) ""))
      (let ((widget (alist-get 'manuscript-size tategaki-settings--widgets)))
        (widget-value-set widget '(40 . 30)) (widget-apply widget :notify widget))
      (should (equal tategaki-settings--paper-draft '("40" . "30")))
      (should (equal (widget-value (alist-get 'columns tategaki-settings--paper-fields)) "30"))
      (should-not (tategaki-settings--paper-draft-p)))))

(ert-deftest tategaki-settings-paper-saves-and-reloads-custom-and-free ()
  (tategaki-settings-test--project
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (tategaki-settings-paper-test--input "27" "43")
      (tategaki-settings-apply-paper-size)
      (setq tategaki-settings--scope 'project)
      (tategaki-settings-save))
    (with-temp-buffer
      (setq default-directory (file-name-as-directory directory))
      (tategaki-project-apply-settings)
      (should (equal tategaki-manuscript-size '(27 . 43))))
    (with-current-buffer settings
      (let ((widget (alist-get 'manuscript-size tategaki-settings--widgets)))
        (widget-value-set widget nil) (widget-apply widget :notify widget))
      (should (string-match-p "フリー（文字サイズ優先）" (buffer-string)))
      (should-not (alist-get 'manuscript-size tategaki-settings--values))
      (should (equal tategaki-settings--paper-draft '("" . "")))
      (should-not (tategaki-settings--paper-draft-p))
      (tategaki-settings-save)
      (tategaki-settings-close))
    (with-temp-buffer
      (setq default-directory (file-name-as-directory directory))
      (setq-local tategaki-manuscript-size '(20 . 20))
      (tategaki-project-apply-settings)
      (should-not tategaki-manuscript-size))))

(ert-deftest tategaki-settings-paper-close-asks-for-draft-save-guides-apply-and-discard ()
  (tategaki-settings-test--project
    (setq-local tategaki-manuscript-size '(20 . 20))
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (tategaki-settings-paper-test--input "" "30")
      (should-not (tategaki-settings--changes))
      (tategaki-settings-close)
      (should tategaki-settings--closing)
      (should (buffer-live-p settings))
      (should-error (tategaki-settings--save-and-close) :type 'user-error)
      (should-not tategaki-settings--closing)
      (should (string-match-p "原稿用紙の入力が未適用" (buffer-string)))
      (should (equal tategaki-settings--paper-draft '("" . "30")))
      (tategaki-settings-close)
      (should-not (tategaki-settings--kill-query))
      (tategaki-settings-discard))
    (should-not (buffer-live-p settings))
    (should (equal (buffer-local-value 'tategaki-manuscript-size source) '(20 . 20)))
    (should-not (file-exists-p (expand-file-name ".tategaki/project.json" directory)))))

(ert-deftest tategaki-settings-paper-revert-clears-draft-and-restores-opening-size ()
  (tategaki-settings-test--project
    (setq-local tategaki-manuscript-size '(20 . 20))
    (setq settings (tategaki-settings source))
    (with-current-buffer settings
      (tategaki-settings-paper-test--input "25" "35")
      (tategaki-settings-apply-paper-size)
      (tategaki-settings-paper-test--input "bad" "")
      (tategaki-settings-close)
      (tategaki-settings-revert)
      (should-not tategaki-settings--closing)
      (should (equal tategaki-settings--paper-draft '("20" . "20")))
      (should-not (tategaki-settings--paper-draft-p))
      (should (equal (buffer-local-value 'tategaki-manuscript-size source) '(20 . 20))))))

(provide 'tategaki-settings-paper-test)
;;; tategaki-settings-paper-test.el ends here
