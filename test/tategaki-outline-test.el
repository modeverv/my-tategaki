;;; tategaki-outline-test.el --- Outline navigation tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'tategaki-outline)
(defvar tategaki-mode nil)

(defmacro tategaki-outline-test--with-source (text &rest body)
  "Evaluate BODY with TEXT in a displayed temporary source buffer."
  (declare (indent 1) (debug t))
  `(save-window-excursion
     (let ((source (generate-new-buffer " *tategaki-outline-test*")))
       (unwind-protect
           (progn
             (switch-to-buffer source)
             (text-mode)
             (insert ,text)
             (goto-char (point-min))
             (setq-local tategaki-outline-heading-regexp 'auto)
             (setq-local tategaki-outline-level-function nil)
             (setq-local tategaki-outline-follow-point t)
             (setq-local tategaki-outline-width 24)
             (setq-local tategaki-outline-side 'right)
             (buffer-enable-undo)
             (setq buffer-undo-list nil)
             (set-buffer-modified-p nil)
             ,@body)
         (when (buffer-live-p source)
           (with-current-buffer source (tategaki-outline-cleanup))
           (kill-buffer source))))))

(ert-deftest tategaki-outline-recognizes-mixed-headings-and-levels ()
  (tategaki-outline-test--with-source
      "前文\n* 第一章\n** 節\n本文\n# 次章\n### 小節\n第2章 続き\n第三節 その後\n第１幕\n第2場\n"
    (let ((entries (tategaki-outline--headings)))
      (should (equal (mapcar (lambda (entry) (aref entry 2)) entries)
                     '("第一章" "節" "次章" "小節" "第2章 続き"
                       "第三節 その後" "第１幕" "第2場")))
      (should (equal (mapcar (lambda (entry) (aref entry 1)) entries)
                     '(1 2 1 3 1 2 1 2)))
      (dolist (entry (append entries nil))
        (should (eq (marker-buffer (aref entry 0)) source))))))

(ert-deftest tategaki-outline-custom-regexp-and-level-function ()
  (tategaki-outline-test--with-source "SCENE 公園\n台詞\nSHOT ベンチ\n"
    (setq tategaki-outline-heading-regexp "^\\(?:SCENE\\|SHOT\\) "
          tategaki-outline-level-function
          (lambda () (if (looking-at "SHOT") 2 1)))
    (let ((entries (tategaki-outline--headings)))
      (should (= (length entries) 2))
      (should (equal (mapcar (lambda (entry) (aref entry 1)) entries) '(1 2))))))

(ert-deftest tategaki-outline-can-use-buffer-native-outline-rules ()
  (tategaki-outline-test--with-source ";; 一章\n;;; 小節\n# 無関係\n"
    (setq-local tategaki-outline-heading-regexp 'outline)
    (setq-local outline-regexp ";;+ ")
    (setq-local outline-level (lambda () (- (match-end 0) (match-beginning 0) 2)))
    (let ((entries (tategaki-outline--headings)))
      (should (= (length entries) 2))
      (should (equal (mapcar (lambda (entry) (aref entry 1)) entries) '(1 2))))))

(ert-deftest tategaki-outline-scan-preserves-source-state-and-match-data ()
  (tategaki-outline-test--with-source "前文\n# 一章\n本文\n# 二章\n後文"
    (put-text-property 9 11 'invisible 'outline)
    (setq buffer-undo-list nil)
    (set-buffer-modified-p nil)
    (let ((original (buffer-string))
          (tick (buffer-chars-modified-tick)))
      (narrow-to-region 4 12)
      (goto-char 9)
      (string-match "a\\(b\\)" "ab")
      (let ((match (match-data))
            (entries (tategaki-outline--headings)))
        (should (= (length entries) 1))
        (should (equal (aref (aref entries 0) 2) "一章"))
        (should (equal (match-data) match)))
      (should (= (point) 9))
      (should (= (point-min) 4))
      (should (= (point-max) 12))
      (widen)
      (should (equal-including-properties (buffer-string) original))
      (should (= tick (buffer-chars-modified-tick)))
      (should-not buffer-undo-list)
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-outline-cache-reuses-markers-until-text-or-options-change ()
  (tategaki-outline-test--with-source "# 一章\n本文\n# 二章\n"
    (let* ((entries (tategaki-outline--headings))
           (first-marker (aref (aref entries 0) 0)))
      (goto-char (point-max))
      (dotimes (_ 5) (should (eq entries (tategaki-outline--headings))))
      (insert "# 三章\n")
      (should (= (length (tategaki-outline--headings)) 3))
      (should-not (marker-buffer first-marker))
      (setq tategaki-outline-heading-regexp "^# 二")
      (should (= (length (tategaki-outline--headings)) 1)))))

(ert-deftest tategaki-outline-zero-width-custom-regexp-terminates ()
  (tategaki-outline-test--with-source "甲\n乙\n"
    (setq tategaki-outline-heading-regexp "^")
    (should (= (length (tategaki-outline--headings)) 2))
    (erase-buffer)
    (should (= (length (tategaki-outline--headings)) 0))))

(ert-deftest tategaki-outline-next-previous-counts-and-boundaries ()
  (tategaki-outline-test--with-source "前文\n# 一章\n本文\n# 二章\n本文\n# 三章\n"
    (tategaki-outline-next-heading)
    (should (looking-at "# 一章"))
    (let ((point (point)))
      (tategaki-outline-next-heading 0)
      (should (= point (point)))
      (should-error (tategaki-outline-previous-heading) :type 'user-error)
      (should (= point (point))))
    (tategaki-outline-next-heading 2)
    (should (looking-at "# 三章"))
    (should-error (tategaki-outline-next-heading) :type 'user-error)
    (tategaki-outline-previous-heading 2)
    (should (looking-at "# 一章"))
    (forward-line 1)
    (tategaki-outline-previous-heading)
    (should (looking-at "# 一章"))
    (tategaki-outline-previous-heading -1)
    (should (looking-at "# 二章"))))

(ert-deftest tategaki-outline-completion-disambiguates-duplicate-titles ()
  (tategaki-outline-test--with-source "# 同名\n甲\n# 同名\n乙\n"
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _)
                 (should (equal (mapcar #'car choices) '("1 同名" "2 同名")))
                 "2 同名")))
      (tategaki-outline-goto-heading)
      (should (= (line-number-at-pos) 3)))))

(ert-deftest tategaki-outline-sidebar-is-read-only-and-preserves-source ()
  (tategaki-outline-test--with-source "# 第一章\n本文\n## 第一節\n続き\n"
    (let ((original (buffer-string))
          (tick (buffer-chars-modified-tick)))
      (tategaki-outline)
      (should (derived-mode-p 'tategaki-outline-mode))
      (should buffer-read-only)
      (should (string-match-p "第一章" (buffer-string)))
      (should (string-match-p "  第一節" (buffer-string)))
      (should (eq tategaki-outline--source source))
      (should (eq (window-parameter (selected-window) 'window-side) 'right))
      (with-current-buffer source
        (should (equal (buffer-string) original))
        (should (= tick (buffer-chars-modified-tick)))
        (should-not buffer-undo-list)
        (should-not (buffer-modified-p))))))

(ert-deftest tategaki-outline-buttons-track-insertions-and-return-to-source ()
  (tategaki-outline-test--with-source "# 一章\n甲\n# 二章\n乙\n"
    (tategaki-outline)
    (let ((sidebar (current-buffer))
          (button (button-at (point-min))))
      (with-current-buffer source
        (goto-char (point-min))
        (insert "前書き\n"))
      ;; Click before the idle refresh; the source marker has already moved.
      (with-current-buffer sidebar
        (tategaki-outline--activate-button button))
      (should (eq (window-buffer (selected-window)) source))
      (with-current-buffer source
        (should (looking-at "# 一章"))
        (should (= (line-number-at-pos) 2))))))

(ert-deftest tategaki-outline-refresh-updates-titles-and-source-selection-highlight ()
  (tategaki-outline-test--with-source "# 一章\n甲\n# 二章\n乙\n"
    (tategaki-outline)
    (with-current-buffer source
      (goto-char (point-max))
      (insert "# 三章\n丙\n")
      (should (timerp tategaki-outline--timer))
      (tategaki-outline-refresh)
      (should-not tategaki-outline--timer)
      (let ((sidebar tategaki-outline--buffer))
        (with-current-buffer sidebar
          (should (string-match-p "三章" (buffer-string)))
          (should (overlay-buffer tategaki-outline--highlight))
          (should (equal (buffer-substring-no-properties
                          (overlay-start tategaki-outline--highlight)
                          (overlay-end tategaki-outline--highlight)) "三章\n")))))))

(ert-deftest tategaki-outline-button-follows-heading-level-edit-before-idle-refresh ()
  (tategaki-outline-test--with-source "# 章\n本文\n"
    (tategaki-outline)
    (let ((button (button-at (point-min))))
      (with-current-buffer source
        (goto-char (point-min))
        (insert "#"))
      (tategaki-outline--activate-button button)
      (should (eq (current-buffer) source))
      (should (looking-at "## 章")))))

(ert-deftest tategaki-outline-button-does-not-jump-to-removed-heading ()
  (tategaki-outline-test--with-source "# 章\n本文\n"
    (tategaki-outline)
    (let ((button (button-at (point-min))))
      (with-current-buffer source
        (goto-char (point-min))
        (delete-region (point-min) (progn (forward-line 1) (point))))
      (should-error (tategaki-outline--activate-button button) :type 'user-error)
      (with-current-buffer source
        (should (= (length tategaki-outline--entries) 0))))))

(ert-deftest tategaki-outline-follow-point-setting-only-changes-sidebar-highlight ()
  (tategaki-outline-test--with-source "# 章\n本文\n"
    (tategaki-outline)
    (with-current-buffer source
      (setq tategaki-outline-follow-point nil)
      (tategaki-outline--post-command)
      (with-current-buffer tategaki-outline--buffer
        (should-not (overlay-buffer tategaki-outline--highlight))))))

(ert-deftest tategaki-outline-navigation-refreshes-active-vertical-view ()
  (tategaki-outline-test--with-source "前文\n# 章\n本文\n"
    (let ((tategaki-mode t) (calls 0))
      (cl-letf (((symbol-function 'tategaki-refresh)
                 (lambda () (cl-incf calls))))
        (tategaki-outline-next-heading)
        (should (looking-at "# 章"))
        (should (= calls 1))))))

(ert-deftest tategaki-outline-post-command-follows-narrowing-without-widening ()
  (tategaki-outline-test--with-source "# 一章\n甲\n# 二章\n乙\n"
    (tategaki-outline)
    (with-current-buffer source
      (goto-char (point-min))
      (search-forward "# 二章")
      (beginning-of-line)
      (let ((start (point)))
        (narrow-to-region start (point-max))
        (tategaki-outline--post-command)
        (should (= (point-min) start))
        (with-current-buffer tategaki-outline--buffer
          (should-not (string-match-p "一章" (buffer-string)))
          (should (string-match-p "二章" (buffer-string))))))))

(ert-deftest tategaki-outline-closing-sidebar-removes-source-hooks-and-timer ()
  (tategaki-outline-test--with-source "# 一章\n本文\n"
    (tategaki-outline)
    (let ((sidebar (current-buffer)))
      (with-current-buffer source
        (insert "追記")
        (should (timerp tategaki-outline--timer))
        (should (memq #'tategaki-outline--after-change after-change-functions)))
      (kill-buffer sidebar)
      (with-current-buffer source
        (should-not tategaki-outline--timer)
        (should-not tategaki-outline--buffer)
        (should-not tategaki-outline--entries)
        (should-not (memq #'tategaki-outline--after-change after-change-functions))
        (should-not (memq #'tategaki-outline--post-command post-command-hook))))))

(ert-deftest tategaki-outline-source-kill-cleans-only-its-own-sidebar ()
  (tategaki-outline-test--with-source "# 一章\n本文\n"
    (tategaki-outline)
    (let ((sidebar (current-buffer))
          (other (generate-new-buffer " *other-writing-buffer*")))
      (unwind-protect
          (progn
            (with-current-buffer other
              (should-not (memq #'tategaki-outline--after-change after-change-functions)))
            (kill-buffer source)
            (should-not (buffer-live-p sidebar))
            (should (buffer-live-p other)))
        (kill-buffer other)))))

(ert-deftest tategaki-outline-explicit-cleanup-releases-markers-and-is-idempotent ()
  (tategaki-outline-test--with-source "# 一章\n本文\n"
    (let ((marker (aref (aref (tategaki-outline--headings) 0) 0)))
      (tategaki-outline)
      (with-current-buffer source
        (tategaki-outline-cleanup)
        (tategaki-outline-cleanup)
        (should-not (marker-buffer marker))
        (should-not tategaki-outline--entries)
        (should-not tategaki-outline--buffer)))))

(ert-deftest tategaki-outline-mode-change-closes-the-outline ()
  (tategaki-outline-test--with-source "# 一章\n本文\n"
    (tategaki-outline)
    (let ((sidebar (current-buffer)))
      (with-current-buffer source (fundamental-mode))
      (should-not (buffer-live-p sidebar)))))

(ert-deftest tategaki-outline-tab-folds-only-sidebar-and-survives-refresh ()
  (tategaki-outline-test--with-source "# 第一章\n本文\n## 一節\n続き\n### 小節\n# 第二章\n末尾\n"
    (let ((text (buffer-string))
          (tick (buffer-chars-modified-tick)))
      (tategaki-outline)
      (goto-char (point-min))
      (tategaki-outline-toggle-subtree)
      (let* ((entries (buffer-local-value 'tategaki-outline--entries source))
             (child-position (aref (aref entries 1) 3))
             (next-position (aref (aref entries 3) 3)))
        (should (invisible-p child-position))
        (should-not (invisible-p next-position))
        (tategaki-outline-refresh)
        (should (invisible-p child-position))
        (goto-char (point-min))
        (tategaki-outline-toggle-subtree)
        (should-not (invisible-p child-position)))
      (with-current-buffer source
        (should (= tick (buffer-chars-modified-tick)))
        (should (equal-including-properties text (buffer-string)))
        (should-not buffer-undo-list)))))

(ert-deftest tategaki-outline-folded-current-section-highlights-visible-ancestor ()
  (tategaki-outline-test--with-source "# 章\n本文\n## 節\n末尾\n"
    (tategaki-outline)
    (goto-char (point-min))
    (tategaki-outline-toggle-subtree)
    (with-current-buffer source
      (goto-char (point-max))
      (tategaki-outline--post-command)
      (with-current-buffer tategaki-outline--buffer
        (should (= (overlay-start tategaki-outline--highlight) (point-min)))))))

(provide 'tategaki-outline-test)
;;; tategaki-outline-test.el ends here
