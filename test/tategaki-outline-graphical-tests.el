;;; tategaki-outline-graphical-tests.el --- Outline GUI checks -*- lexical-binding: t; -*-

;; Run in a dedicated GUI: emacs -Q -l /absolute/path/to/this-file.el
(require 'ert)
(require 'cl-lib)
(let ((root (file-name-directory
             (directory-file-name
              (file-name-directory (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path root))
(setq load-prefer-newer t)
(require 'tategaki)
(require 'tategaki-outline)

(defmacro tategaki-outline-gui--with-text (text &rest body)
  "Run BODY in an isolated graphical vertical source containing TEXT."
  (declare (indent 1) (debug t))
  `(save-window-excursion
     (let ((source (generate-new-buffer " *Outline GUI source*")))
       (unwind-protect
           (progn
             (switch-to-buffer source)
             (delete-other-windows)
             (text-mode)
             (insert ,text)
             (goto-char (point-min))
             (setq-local tategaki-typesetting t
                         tategaki-column-height 8
                         tategaki-outline-width 25
                         tategaki-outline-heading-regexp 'auto
                         tategaki-outline-follow-point t)
             (buffer-enable-undo)
             (setq buffer-undo-list nil)
             (set-buffer-modified-p nil)
             (tategaki-mode 1)
             (should (plist-get tategaki--layout :typeset))
             (redisplay t)
             ,@body)
         (when (buffer-live-p source)
           (with-current-buffer source
             (tategaki-outline-cleanup)
             (tategaki-mode -1)
             (set-buffer-modified-p nil))
           (kill-buffer source))))))

(defun tategaki-outline-gui--caret ()
  "Verify that the native caret is on the current vertical source position."
  (tategaki-refresh)
  (redisplay t)
  (let ((pixel (tategaki-position-pixel (point)))
        (cursor (window-cursor-info)))
    (should pixel)
    (should cursor)
    (should (= (plist-get pixel :x) (aref cursor 1)))
    (should (= (plist-get pixel :y) (aref cursor 2)))
    (should (<= (+ (plist-get pixel :y) (plist-get pixel :height))
                (window-body-height nil t)))
    pixel))

(ert-deftest tategaki-outline-gui-sidebar-resizes-vertical-page-and-ret-visits-heading ()
  (tategaki-outline-gui--with-text
      (concat "# 第一章\n" (make-string 1000 ?文) "\n# 第二章\n本文\n")
    (let ((source-window (selected-window))
          (width (window-body-width nil t))
          (page-size tategaki--page-size)
          (text (buffer-string)))
      (execute-kbd-macro (kbd "C-c C-o"))
      (should (derived-mode-p 'tategaki-outline-mode))
      (should (< (window-body-width source-window t) width))
      (with-selected-window source-window
        (tategaki-outline-gui--caret)
        (should (< tategaki--page-size page-size)))
      (goto-char (aref (aref (buffer-local-value 'tategaki-outline--entries source) 1) 3))
      (execute-kbd-macro (kbd "RET"))
      (should (eq (current-buffer) source))
      (should (looking-at "# 第二章"))
      (tategaki-outline-gui--caret)
      (should (equal (buffer-string) text))
      (should-not buffer-undo-list)
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-outline-gui-renaming-refreshes-sidebar-without-extra-source-edits ()
  (tategaki-outline-gui--with-text "# 第一章\n本文\n# 第二章\n末尾\n"
    (tategaki-outline)
    (let ((sidebar (current-buffer)))
      (select-window (get-buffer-window source))
      (goto-char (point-min))
      (search-forward "第一章")
      (replace-match "新しい章" t t)
      (let ((text (buffer-string))
            (tick (buffer-chars-modified-tick))
            (undo buffer-undo-list))
        (should (timerp tategaki-outline--timer))
        (sit-for 0.4)
        (tategaki-outline-refresh)
        (should-not tategaki-outline--timer)
        (tategaki-outline-gui--caret)
        (with-current-buffer sidebar
          (should (string-match-p "新しい章" (buffer-string)))
          (should-not (string-match-p "第一章" (buffer-string))))
        (should (equal (buffer-string) text))
        (should (= tick (buffer-chars-modified-tick)))
        (should (eq undo buffer-undo-list))))))

(ert-deftest tategaki-outline-gui-tab-folds-sidebar-with-source-caret-preserved ()
  (tategaki-outline-gui--with-text "# 第一章\n本文\n## 一節\n続き\n### 小節\n# 第二章\n末尾\n"
    (let ((text (buffer-string))
          (tick (buffer-chars-modified-tick)))
      (tategaki-outline)
      (goto-char (point-min))
      (execute-kbd-macro (kbd "TAB"))
      (let* ((entries (buffer-local-value 'tategaki-outline--entries source))
             (child (aref (aref entries 1) 3)))
        (should (invisible-p child))
        (execute-kbd-macro (kbd "TAB"))
        (should-not (invisible-p child)))
      (select-window (get-buffer-window source))
      (tategaki-outline-gui--caret)
      (should (equal-including-properties text (buffer-string)))
      (should (= tick (buffer-chars-modified-tick)))
      (should-not buffer-undo-list))))

(ert-deftest tategaki-outline-gui-mode-disable-closes-sidebar-and-restores-window ()
  (tategaki-outline-gui--with-text "# 第一章\n本文\n## 第一節\n続き\n"
    (let ((width (window-body-width nil t))
          (text (buffer-string)))
      (tategaki-outline)
      (let ((sidebar (current-buffer)))
        (select-window (get-buffer-window source))
        (tategaki-mode -1)
        (redisplay t)
        (should-not (buffer-live-p sidebar))
        (should (= (window-body-width nil t) width))
        (should (equal (buffer-string) text))
        (should-not buffer-undo-list)
        (should-not (memq #'tategaki-outline--after-change after-change-functions))))))

(unless noninteractive
  (run-at-time 60 nil (lambda () (kill-emacs 2)))
  (run-at-time
   1 nil
   (lambda ()
     (let ((status 2))
       (condition-case err
           (progn
             (unless (and (display-graphic-p) (image-type-available-p 'svg)
                          (fboundp 'window-cursor-info))
               (error "A graphical Emacs with SVG and window-cursor-info is required"))
             (set-frame-size (selected-frame) 100 36)
             (let ((stats (ert-run-tests-batch "^tategaki-outline-gui-")))
               (setq status (if (and (= (ert-stats-completed-expected stats) 4)
                                    (= (ert-stats-completed-unexpected stats) 0)) 0 1))))
         (error (message "Outline GUI setup failed: %S" err)))
       (with-current-buffer "*Messages*"
         (write-region (point-min) (point-max)
                       (expand-file-name "tategaki-outline-gui-tests.log"
                                         temporary-file-directory)))
       (kill-emacs status)))))

;;; tategaki-outline-graphical-tests.el ends here
