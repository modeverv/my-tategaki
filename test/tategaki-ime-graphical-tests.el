;;; tategaki-ime-graphical-tests.el --- NS preedit GUI checks -*- lexical-binding: t; -*-

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

;; Run in a dedicated NS Emacs; this runner exits after testing.
;; emacs -Q -l /absolute/path/to/test/tategaki-ime-graphical-tests.el

(require 'ert)
(require 'cl-lib)
(let* ((directory (file-name-directory (or load-file-name buffer-file-name)))
       (root (file-name-directory (directory-file-name directory))))
  (add-to-list 'load-path root)
  (dolist (file '("tategaki-layout.el" "tategaki-ime.el" "tategaki.el"))
    (load (expand-file-name file root) nil nil t)))

(defmacro tategaki-ime-gui--with-text (text &rest body)
  "Use an isolated native NS buffer containing TEXT for BODY."
  (declare (indent 1))
  `(save-window-excursion
     (let ((buffer (generate-new-buffer " *Tategaki native IME test*"))
           ;; Keep this native-source regression independent of optional
           ;; prose indentation (covered by writing GUI integration tests).
           (tategaki-writing-assistance nil)
           (tategaki-column-height 3)
           (ns-working-overlay nil)
           (ns-working-text "")
           (mac-ime-hide-cursor nil))
       (unwind-protect
           (progn
             (switch-to-buffer buffer)
             (delete-other-windows)
             (text-mode)
             (insert ,text)
             (goto-char (point-min))
             (buffer-enable-undo)
             (setq buffer-undo-list nil)
             (set-buffer-modified-p nil)
             (tategaki-mode 1)
             ,@body)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (ns-delete-working-text)
             (tategaki-mode -1)
             (set-buffer-modified-p nil))
           (kill-buffer buffer))))))

(defun tategaki-ime-gui--cursor ()
  "Return (CURSOR . STRING-POSITION) for the current actual screen cursor."
  (redisplay t)
  (let* ((cursor (window-cursor-info))
         (position (and cursor
                        (posn-at-x-y (+ (aref cursor 1) (/ (aref cursor 3) 2))
                                     (+ (aref cursor 2) (/ (aref cursor 4) 2))
                                     (selected-window))))
         (object (and position (posn-string position))))
    (should cursor)
    (should object)
    (should (= tategaki--caret-position
               (get-text-property (cdr object) 'tategaki-virtual-position
                                  (car object))))
    (cons cursor object)))

(ert-deftest tategaki-ime-gui-native-marked-text-wraps-and-highlights ()
  (tategaki-ime-gui--with-text "前後"
    (goto-char 2)
    (tategaki-refresh)
    (let ((text (buffer-string))
          (tick (buffer-chars-modified-tick))
          locations)
      (setq ns-working-text "日本語入力")
      (dotimes (index (length ns-working-text))
        ;; These are the installed NS functions, not mocks.  The full put
        ;; path also tests that our display layer does not route to echo.
        (ns-put-marked-text (list 'ns-put-marked-text index 1))
        (should (overlayp ns-working-overlay))
        (should-not mac-in-echo-area)
        (should-not (overlay-get ns-working-overlay 'before-string))
        (should-not (overlay-get ns-working-overlay 'after-string))
        (should (= (point) 2))
        (pcase-let* ((`(,cursor . ,object) (tategaki-ime-gui--cursor))
                     (props (text-properties-at (cdr object) (car object))))
          (should (= index (plist-get props 'tategaki-preedit-index)))
          (should (memq 'ns-marked-text-face (plist-get props 'face)))
          (push (cons (aref cursor 1) (aref cursor 2)) locations)))
      (setq locations (nreverse locations))
      ;; First two preedit characters descend in the same column.  The
      ;; third wraps to the top of the column on their left.
      (should (= (caar locations) (caadr locations)))
      (should (< (cdar locations) (cdadr locations)))
      (should (< (car (nth 2 locations)) (caar locations)))
      (should (< (cdr (nth 2 locations)) (cdar locations)))
      (should (equal text (buffer-string)))
      (should (= tick (buffer-chars-modified-tick)))
      (should-not (buffer-modified-p))
      (should-not buffer-undo-list))))

(ert-deftest tategaki-ime-gui-native-update-shrink-and-cancel ()
  (tategaki-ime-gui--with-text "前後"
    (goto-char 2)
    (setq ns-working-text "にほんご")
    (ns-put-working-text)
    (should (equal tategaki-ime--text "にほんご"))
    (should (= tategaki--caret-position 6))
    (tategaki-ime-gui--cursor)
    (setq ns-working-text "に")
    (ns-put-working-text)
    (should (= tategaki--caret-position 3))
    (should (= 4 (length (plist-get tategaki--layout :positions))))
    (tategaki-ime-gui--cursor)
    (ns-unput-working-text)
    (should-not tategaki-ime--text)
    (should-not ns-working-overlay)
    (should (= 3 (length (plist-get tategaki--layout :positions))))
    (should (equal "前後" (buffer-string)))
    (should (= (point) 2))
    (should-not (buffer-modified-p))
    (should-not buffer-undo-list)
    (tategaki-ime-gui--cursor)))

(ert-deftest tategaki-ime-gui-empty-eof-commit-and-undo ()
  (tategaki-ime-gui--with-text ""
    (setq ns-working-text "日本語")
    (ns-put-marked-text '(ns-put-marked-text 2 1))
    (should (zerop (buffer-size)))
    (tategaki-ime-gui--cursor)
    ;; Native composition teardown followed by ordinary committed input.
    (ns-unput-working-text)
    (execute-kbd-macro "日本語")
    (should (equal "日本語" (buffer-string)))
    (should-not tategaki-ime--text)
    (tategaki-ime-gui--cursor)
    (undo-boundary)
    (undo-only 1)
    (tategaki-refresh)
    (should (equal "" (buffer-string)))
    (tategaki-ime-gui--cursor)))

(ert-deftest tategaki-ime-gui-disable-restores-native-working-overlay ()
  (tategaki-ime-gui--with-text "原文"
    (goto-char (point-max))
    (setq ns-working-text "未確定")
    (ns-put-marked-text '(ns-put-marked-text 1 2))
    (let ((native ns-working-overlay))
      (tategaki-mode -1)
      (should (eq native ns-working-overlay))
      (should (equal (overlay-get native 'before-string) "未確定"))
      (should (eq 'ns-marked-text-face
                  (get-text-property 1 'face (overlay-get native 'before-string))))
      (should (equal "原文" (buffer-string)))
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-ime-gui-enable-adopts-existing-native-composition ()
  (tategaki-ime-gui--with-text "前後"
    ;; Simulate upgrading an already active editor that predates the adapter.
    (tategaki-ime-disable)
    (goto-char 2)
    (setq ns-working-text "変換途中")
    (ns-insert-marked-text 1 2)
    (let ((native ns-working-overlay)
          (tick (buffer-chars-modified-tick)))
      (tategaki-ime-enable #'tategaki--ime-updated (selected-window))
      (should (eq native ns-working-overlay))
      (should (equal "変換途中" tategaki-ime--text))
      (should (eq 'ns-marked-text-face
                  (get-text-property 1 'face tategaki-ime--text)))
      (should (= (point) 2))
      (should (= tick (buffer-chars-modified-tick)))
      (should-not buffer-undo-list)
      (should-not (buffer-modified-p))
      (tategaki-ime-gui--cursor)
      ;; The next native update retains the normal composition lifecycle.
      (ns-put-marked-text '(ns-put-marked-text 2 2))
      (should (= tategaki--caret-position 4))
      (tategaki-ime-gui--cursor)
      (ns-unput-working-text)
      (should (equal "前後" (buffer-string))))))

(ert-deftest tategaki-ime-gui-panel-anchor-follows-wrapped-clause ()
  (tategaki-ime-gui--with-text "前後"
    (skip-unless (and (boundp 'mac-ime-panel-offset-x)
                      (boundp 'mac-ime-panel-offset-y)))
    (setq-local mac-ime-panel-offset-x 7
                mac-ime-panel-offset-y 5)
    (goto-char 2)
    (setq ns-working-text "日本語入力")
    (let (anchors)
      (dotimes (index (length ns-working-text))
        (ns-put-marked-text (list 'ns-put-marked-text index 1))
        (let* ((cursor (car (tategaki-ime-gui--cursor)))
               ;; Same coordinates used by NS firstRectForCharacterRange,
               ;; before adding the common window/frame/screen origin.
               (x (+ (aref cursor 1) mac-ime-panel-offset-x))
               (y (+ (aref cursor 2) (frame-char-height)
                     mac-ime-panel-offset-y)))
          (should (= x (+ (aref cursor 1) (nth 1 tategaki--metrics) 4 7)))
          (should (= y (+ (aref cursor 2) 5)))
          (should (> x (+ (aref cursor 1) (aref cursor 3))))
          (push (cons x y) anchors)))
      (setq anchors (nreverse anchors))
      (should (= (caar anchors) (caadr anchors)))
      (should (< (cdar anchors) (cdadr anchors)))
      (should (< (car (nth 2 anchors)) (caar anchors)))
      (should (< (cdr (nth 2 anchors)) (cdar anchors))))
    ;; The native IME normally hides the cursor while selecting a clause;
    ;; placement must not depend on window-cursor-info being non-nil.
    (let ((mac-ime-hide-cursor t))
      (ns-put-marked-text '(ns-put-marked-text 2 1))
      (redisplay t)
      (should-not cursor-type)
      (should (= mac-ime-panel-offset-x (+ (nth 1 tategaki--metrics) 4 7)))
      (should (= mac-ime-panel-offset-y (- 5 (frame-char-height))))
      (ns-unput-working-text))
    (should (= mac-ime-panel-offset-x 7))
    (should (= mac-ime-panel-offset-y 5))
    (should (local-variable-p 'mac-ime-panel-offset-x))
    (should (equal "前後" (buffer-string)))
    (should-not (buffer-modified-p))
    (should-not buffer-undo-list)))

(run-at-time 60 nil (lambda () (kill-emacs 2)))
(run-at-time
 1 nil
 (lambda ()
   (let ((status 2))
     (condition-case err
         (progn
           (unless (and (eq window-system 'ns)
                        (fboundp 'window-cursor-info)
                        (fboundp 'ns-put-marked-text))
             (error "This test requires NS Emacs with native marked-text support"))
           (delete-other-windows)
           (set-frame-size (selected-frame) 72 28)
           (let ((stats (ert-run-tests-batch "^tategaki-ime-gui-")))
             (setq status
                   (if (and (= (ert-stats-total stats) 6)
                            (= (ert-stats-completed-expected stats) 6)
                            (zerop (ert-stats-skipped stats)))
                       0 1))))
       (error (message "Native preedit GUI setup failed: %S" err)))
     (with-current-buffer "*Messages*"
       (write-region (point-min) (point-max)
                     (expand-file-name "tategaki-ime-gui-tests.log"
                                       temporary-file-directory)))
     (kill-emacs status))))

;;; tategaki-ime-graphical-tests.el ends here
