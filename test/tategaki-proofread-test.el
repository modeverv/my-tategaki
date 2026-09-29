;;; tategaki-proofread-test.el --- Diagnostics and rule tests -*- lexical-binding: t; -*-
;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'cl-lib)
(require 'tategaki-proofread)

(defun tategaki-proofread-test--codes (text)
  "Return rule codes for TEXT in a temporary source buffer."
  (with-temp-buffer
    (insert text)
    (mapcar (lambda (item) (plist-get item :code)) (tategaki-proofread-run))))

(ert-deftest tategaki-proofread-preserves-manuscript-state ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "「文章です。。文章です。をを。")
    (goto-char 4)
    (set-buffer-modified-p nil)
    (let ((text (buffer-string)) (undo buffer-undo-list) (tick (buffer-chars-modified-tick)))
      (should (tategaki-proofread-run))
      (should (equal text (buffer-string)))
      (should (equal undo buffer-undo-list))
      (should (= tick (buffer-chars-modified-tick)))
      (should (= 4 (point)))
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-proofread-brackets-handle-nesting-and-mismatch ()
  (should-not (member "unmatched-bracket"
                      (tategaki-proofread-test--codes "「『中』です」（[a]）【〈《中》〉】")))
  (dolist (text '("「未完" "閉じる」" "([)]" "【" "{" "]"))
    (should (member "unmatched-bracket" (tategaki-proofread-test--codes text)))))

(ert-deftest tategaki-proofread-punctuation-whitespace-and-particles ()
  (let ((codes (tategaki-proofread-test--codes "。。何！！？をを　　半角ｶﾅ…\n末尾 \n")))
    (dolist (code '("punctuation-run" "repeated-particle" "abnormal-whitespace"
                    "halfwidth-kana" "ellipsis-form"))
      (should (member code codes))))
  (should-not (member "ellipsis-form" (tategaki-proofread-test--codes "……"))))

(ert-deftest tategaki-proofread-configured-words-are-literal ()
  (let ((tategaki-proofread-banned-words '("a.b" ""))
        (tategaki-proofread-variants '(("出来る" . "できる") ("" . "ignore"))))
    (let ((codes (tategaki-proofread-test--codes "a.b 出来る")))
      (should (member "banned-word" codes))
      (should (member "spelling-variant" codes)))
    (should-not (member "banned-word" (tategaki-proofread-test--codes "axb")))))

(ert-deftest tategaki-proofread-mixed-forms-need-both-styles ()
  (let ((codes (tategaki-proofread-test--codes "ＡとA、１２と12、三人")))
    (should (member "mixed-width" codes))
    (should (member "mixed-number-form" codes)))
  (should-not (member "mixed-width" (tategaki-proofread-test--codes "１２３ ＡＢＣ")))
  (should-not (member "mixed-number-form" (tategaki-proofread-test--codes "唯一の12番"))))

(ert-deftest tategaki-proofread-length-and-repetition-rules ()
  (let* ((tategaki-proofread-max-sentence-length 3)
         (tategaki-proofread-max-paragraph-length 8)
         (codes (tategaki-proofread-test--codes "原稿です。原稿です。カメラとカメラ。")))
    (dolist (code '("long-sentence" "long-paragraph" "repeated-ending" "repeated-word"))
      (should (member code codes)))))

(ert-deftest tategaki-diagnostics-source-replacement-is-independent ()
  (with-temp-buffer
    (insert "0123456789")
    (let ((item '(:start 2 :end 4 :code "sample" :message "check" :severity warning)))
      (tategaki-diagnostics-set 'rule (list item))
      (tategaki-diagnostics-set 'world (list item))
      (tategaki-diagnostics-set 'rule nil)
      (should (= 1 (length (tategaki-diagnostics-get))))
      (should (eq 'world (plist-get (car (tategaki-diagnostics-get)) :source))))
    (tategaki-diagnostics-clear)
    (should-not (tategaki-diagnostics-get))))

(ert-deftest tategaki-diagnostics-invalid-replacement-preserves-old-items ()
  (with-temp-buffer
    (insert "0123456789")
    (tategaki-diagnostics-set 'rule '((:start 2 :end 4 :message "valid")))
    (should-error (tategaki-diagnostics-set 'rule '((:start 2 :end 100 :message "invalid"))))
    (should (equal "valid" (plist-get (car (tategaki-diagnostics-get)) :message)))))

(ert-deftest tategaki-diagnostics-positions-follow-source-edits ()
  (with-temp-buffer
    (insert "0123456789")
    (tategaki-diagnostics-set 'rule '((:start 2 :end 4 :message "check")))
    (goto-char 1)
    (insert "abc")
    (let ((item (car (tategaki-diagnostics-get))))
      (should (= 5 (plist-get item :start)))
      (should (= 7 (plist-get item :end))))))

(ert-deftest tategaki-diagnostics-project-through-highlight-and-hide ()
  (with-temp-buffer
    (insert "0123456789")
    (tategaki-diagnostics-set 'rule '((:start 2 :end 4 :message "check" :severity warning)))
    (should (memq 'tategaki-diagnostics-warning (tategaki-highlight-faces 2 3 nil)))
    (tategaki-diagnostics-set-visible nil)
    (should-not (tategaki-highlight-faces 2 3 nil))
    (should (= 1 (length (tategaki-diagnostics-get))))
    (tategaki-diagnostics-set-visible t)
    (should (memq 'tategaki-diagnostics-warning (tategaki-highlight-faces 2 3 nil)))))

(ert-deftest tategaki-proofread-idle-is-opt-in-and-cancelled-on-disable ()
  (with-temp-buffer
    (let ((tategaki-proofread-live nil))
      (tategaki-proofread-mode 1)
      (insert "。。")
      (should-not tategaki-proofread--timer))
    (let ((tategaki-proofread-live t))
      (insert "。。")
      (should (timerp tategaki-proofread--timer))
      (tategaki-proofread-mode -1)
      (should-not tategaki-proofread--timer))))

(ert-deftest tategaki-proofread-idle-retains-full-check-and-distant-results ()
  (with-temp-buffer
    (insert "「。。")
    (insert (make-string 1000 ?あ))
    (insert "。。")
    (tategaki-proofread-run)
    (let ((tategaki-proofread-live-radius 20)
          (tategaki-proofread--dirty-position (1- (point-max))))
      (tategaki-proofread-run t))
    (let ((items (tategaki-diagnostics-get 'rule)))
      (should (cl-find "unmatched-bracket" items :key (lambda (item) (plist-get item :code)) :test #'equal))
      (should (cl-find-if (lambda (item) (and (= 2 (plist-get item :start))
                                            (equal "punctuation-run" (plist-get item :code)))) items)))))

(ert-deftest tategaki-proofread-full-check-widens-without-altering-restriction ()
  (with-temp-buffer
    (insert "「前半。\n本文。\n後半をを。")
    (narrow-to-region 6 9)
    (let ((minimum (point-min)) (maximum (point-max)))
      (should (member "unmatched-bracket" (mapcar (lambda (item) (plist-get item :code)) (tategaki-proofread-run))))
      (should (= minimum (point-min)))
      (should (= maximum (point-max))))))

(ert-deftest tategaki-proofread-limit-is-explicit-and-bounded ()
  (with-temp-buffer
    (insert "。。文。をを。語　　語。")
    (let ((tategaki-proofread-max-diagnostics 1))
      (should (= 1 (length (tategaki-proofread-run))))
      (should tategaki-proofread-truncated))))

(ert-deftest tategaki-proofread-disabled-clears-only-rule-results ()
  (with-temp-buffer
    (insert "。。")
    (tategaki-proofread-run)
    (tategaki-diagnostics-set 'world '((:start 1 :end 2 :message "world")))
    (let ((tategaki-proofread-enabled nil)) (tategaki-proofread-reconfigure))
    (should-not (tategaki-diagnostics-get 'rule))
    (should (tategaki-diagnostics-get 'world))))

(ert-deftest tategaki-diagnostics-list-button-tracks-source-position ()
  (save-window-excursion
    (let ((source (generate-new-buffer " *diagnostic-test-source*")) output)
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (insert "原稿をを。")
            (setq output (tategaki-diagnostics-list))
            (should (eq major-mode 'tategaki-diagnostics-list-mode))
            (goto-char (point-min))
            (forward-button 1)
            (let ((button (button-at (point))))
              (should button)
              (with-current-buffer source (goto-char 1) (insert "前文。"))
              (button-activate button)
              (should (eq source (current-buffer)))
              (should (= 6 (point)))))
        (when (buffer-live-p output) (kill-buffer output))
        (when (buffer-live-p source) (kill-buffer source))))))

(provide 'tategaki-proofread-test)
