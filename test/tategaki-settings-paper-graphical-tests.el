;;; tategaki-settings-paper-graphical-tests.el --- Native paper fields -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run ONLY in a dedicated Emacs -Q -l /absolute/path/to/this-file.
;; This runner exits its Emacs and does not operate any existing editor.
(require 'ert)
(setq load-prefer-newer t)
(let* ((directory (file-name-directory (or load-file-name buffer-file-name)))
       (root (file-name-directory (directory-file-name directory))))
  (add-to-list 'load-path root)
  (load (expand-file-name "tategaki-settings-paper-test.el" directory) nil nil t))

(ert-deftest tategaki-settings-paper-gui-real-typing-apply-and-free ()
  (should (display-graphic-p))
  (tategaki-settings-test--project
    (setq-local tategaki-manuscript-size '(20 . 20))
    (let ((text (buffer-string)) (undo buffer-undo-list) (position (point)))
      (setq settings (tategaki-settings source))
      (with-selected-window (get-buffer-window settings)
        (dolist (entry '((rows . "27") (columns . "43")))
          (goto-char (widget-field-start (alist-get (car entry) tategaki-settings--paper-fields)))
          (execute-kbd-macro (kbd "C-a C-k"))
          (should (equal (buffer-local-value 'tategaki-manuscript-size source) '(20 . 20)))
          (execute-kbd-macro (cdr entry))
          (execute-kbd-macro (kbd "TAB")))
        (should (equal tategaki-settings--paper-draft '("27" . "43")))
        (should (equal (buffer-local-value 'tategaki-manuscript-size source) '(20 . 20)))
        (goto-char (point-min)) (search-forward "寸法を適用")
        (goto-char (1- (point)))
        (execute-kbd-macro (kbd "RET"))
        (should (equal (buffer-local-value 'tategaki-manuscript-size source) '(27 . 43)))
        (let ((widget (alist-get 'manuscript-size tategaki-settings--widgets)))
          (widget-value-set widget nil) (widget-apply widget :notify widget))
        (should-not (buffer-local-value 'tategaki-manuscript-size source))
        (should (string-match-p "フリー（文字サイズ優先）" (buffer-string))))
      (with-current-buffer source
        (should (equal text (buffer-string))) (should (eq undo buffer-undo-list))
        (should (= position (point))) (should-not (buffer-modified-p))))))

(run-with-timer
 1 nil
 (lambda ()
   (let* ((stats (ert-run-tests-batch "^tategaki-settings-paper-gui-"))
          (failed (ert-stats-completed-unexpected stats)))
     (with-current-buffer "*Messages*"
       (write-region (point-min) (point-max)
                     (expand-file-name "tategaki-settings-paper-gui-tests.log" temporary-file-directory) nil 'silent))
     (kill-emacs (if (zerop failed) 0 1)))))
;;; tategaki-settings-paper-graphical-tests.el ends here
