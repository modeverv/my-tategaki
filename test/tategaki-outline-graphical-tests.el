;;; tategaki-outline-graphical-tests.el --- Outline GUI checks -*- lexical-binding: t; -*-

;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is part of my-tategaki.
;;
;; my-tategaki is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; my-tategaki is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with my-tategaki.  If not, see <https://www.gnu.org/licenses/>.

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

(defvar tategaki-outline-gui--idle-fixture nil)

(defun tategaki-outline-gui--prepare-idle-fixture ()
  "Type in a private source, then return to the real GUI event loop."
  (let ((source (generate-new-buffer " *Outline idle typing QA*")))
    (switch-to-buffer source)
    (delete-other-windows)
    (text-mode)
    (insert "#第一章\n本文\n")
    (setq-local tategaki-typesetting t
                tategaki-column-height 8
                tategaki-outline-update-delay 0.05)
    (buffer-enable-undo)
    (tategaki-mode 1)
    (tategaki-outline)
    (select-window (get-buffer-window source))
    (goto-char (point-max))
    (execute-kbd-macro (vconcat "##第一節\n新しい本文"))
    (should (timerp tategaki-outline--timer))
    (setq tategaki-outline-gui--idle-fixture
          (list source (buffer-string) (point) buffer-undo-list
                (buffer-chars-modified-tick)))))

(ert-deftest tategaki-outline-gui-automatic-idle-update-after-keyboard-input ()
  (pcase-let ((`(,source ,text ,position ,undo ,tick)
                tategaki-outline-gui--idle-fixture))
    (unwind-protect
        (with-current-buffer source
          (should (eq (window-buffer (selected-window)) source))
          ;; No manual refresh: the dedicated GUI's normal event loop fired
          ;; the idle timer between fixture preparation and this test.
          (should-not tategaki-outline--timer)
          (should (= (length tategaki-outline--entries) 2))
          (should (= (point) position))
          (should (= (buffer-chars-modified-tick) tick))
          (should (equal-including-properties (buffer-string) text))
          (should (equal buffer-undo-list undo))
          (with-current-buffer tategaki-outline--buffer
            (should (string-match-p "第一節" (buffer-string)))
            (should (equal (overlay-get tategaki-outline--highlight 'help-echo)
                           "執筆位置: 第一節"))))
      (when (buffer-live-p source)
        (with-current-buffer source
          (tategaki-outline-cleanup)
          (tategaki-mode -1)
          (set-buffer-modified-p nil))
        (kill-buffer source)))))

(defun tategaki-outline-gui--click-button (position)
  "Click the actual rendered text button at POSITION through its mouse path."
  (redisplay t)
  (let* ((where (posn-at-point position))
         (xy (and where (posn-x-y where)))
         (pixel (and xy (posn-at-x-y (1+ (car xy))
                                     (+ (cdr xy) (window-header-line-height) 2)
                                     (selected-window)))))
    (should pixel)
    (should (integerp (posn-point pixel)))
    (should (button-at (posn-point pixel)))
    ;; mouse-1's follow-link action dispatches the button's mouse-2 binding.
    (push-button (list 'mouse-2 pixel) t)
    (set-buffer (window-buffer (selected-window)))
    (redisplay t)))

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

(ert-deftest tategaki-outline-gui-mouse-disclosure-current-child-and-title-jump ()
  (tategaki-outline-gui--with-text
      "#第一章\n本文\n##第一節\n続き\n#第二章\n末尾\n"
    (forward-line 3)
    (let ((position (point)) (text (buffer-string))
          (tick (buffer-chars-modified-tick)))
      (tategaki-outline)
      (let ((sidebar (current-buffer)))
        (tategaki-outline-gui--click-button (point-min))
        (should (eq (current-buffer) sidebar))
        (should (equal (get-text-property (point-min) 'display) "▸"))
        (should (= (overlay-start tategaki-outline--highlight) (point-min)))
        (should (equal (overlay-get tategaki-outline--highlight 'help-echo)
                       "執筆位置: 第一節"))
        (let ((entries (buffer-local-value 'tategaki-outline--entries source)))
          (should (invisible-p (aref (aref entries 1) 3)))
          (with-current-buffer source (should (= (point) position)))
          ;; The title next to a folded triangle still jumps to the source.
          (tategaki-outline-gui--click-button (+ (aref (aref entries 0) 3) 2)))
        (should (eq (current-buffer) source))
        (should (looking-at "#第一章"))
        (tategaki-outline-gui--caret)
        (should (equal-including-properties (buffer-string) text))
        (should (= (buffer-chars-modified-tick) tick))
        (should-not buffer-undo-list)
        (should-not (buffer-modified-p))))))

(unless noninteractive
  (set-frame-parameter nil 'name "Tategaki Outline Writing QA")
  (set-frame-size (selected-frame) 100 36)
  (run-at-time 0.1 nil #'tategaki-outline-gui--prepare-idle-fixture)
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
               (setq status (if (and (= (ert-stats-completed-expected stats) 6)
                                    (= (ert-stats-completed-unexpected stats) 0)) 0 1))))
         (error (message "Outline GUI setup failed: %S" err)))
       (with-current-buffer "*Messages*"
         (write-region (point-min) (point-max)
                       (expand-file-name "tategaki-outline-gui-tests.log"
                                         temporary-file-directory)))
       (kill-emacs status)))))

;;; tategaki-outline-graphical-tests.el ends here
