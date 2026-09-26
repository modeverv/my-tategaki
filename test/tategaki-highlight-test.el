;;; tategaki-highlight-test.el --- Native highlight projection tests -*- lexical-binding: t; -*-

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

(require 'ert)
(require 'cl-lib)
(require 'isearch)
(require 'replace)
(require 'flymake)
(require 'tategaki-highlight)

(defmacro tategaki-highlight-test--with-source (&rest body)
  "Run BODY in a visible source buffer and clean up tracking."
  (declare (indent 0) (debug t))
  `(save-window-excursion
     (let ((source (generate-new-buffer " *tategaki-highlight-source*")))
       (unwind-protect
           (progn
             (switch-to-buffer source)
             (delete-other-windows)
             (text-mode)
             (insert "0123456789")
             (set-buffer-modified-p nil)
             ,@body)
         (when (buffer-live-p source)
           (with-current-buffer source (tategaki-highlight-disable))
           (kill-buffer source))))))

(defun tategaki-highlight-test--dispatch ()
  "Dispatch the actual scheduled idle timer deterministically in batch."
  (let ((timer tategaki-highlight--timer))
    (should (timerp timer))
    (timer-event-handler timer)))

(ert-deftest tategaki-highlight-face-precedes-font-lock-throughout-a-cell ()
  (tategaki-highlight-test--with-source
    (put-text-property 1 2 'font-lock-face 'font-lock-keyword-face)
    (put-text-property 2 3 'face 'warning)
    (should (equal (tategaki-highlight-faces 1 3 (selected-window))
                   '(warning font-lock-keyword-face)))))

(ert-deftest tategaki-highlight-partial-overlay-precedes-the-whole-cell-text-face ()
  (tategaki-highlight-test--with-source
    (put-text-property 1 2 'face 'font-lock-keyword-face)
    (let ((overlay (make-overlay 2 3)))
      (overlay-put overlay 'face 'isearch)
      (overlay-put overlay 'priority 1001)
      (should (equal (tategaki-highlight-faces 1 3 (selected-window))
                     '(isearch font-lock-keyword-face))))))

(ert-deftest tategaki-highlight-overlay-priority-matches-native-order ()
  (tategaki-highlight-test--with-source
    (dolist (spec '((1 10 100 error) (2 8 100 warning)
                    (3 7 (nil . 2000) success) (2 9 1001 isearch)))
      (let ((overlay (make-overlay (nth 0 spec) (nth 1 spec))))
        (overlay-put overlay 'priority (nth 2 spec))
        (overlay-put overlay 'face (nth 3 spec))))
    (let ((expected (mapcar (lambda (overlay) (overlay-get overlay 'face))
                            (overlays-at 4 t))))
      (should (equal (tategaki-highlight-faces 4 5 (selected-window)) expected)))))

(ert-deftest tategaki-highlight-disjoint-partial-overlays-use-global-priority ()
  (tategaki-highlight-test--with-source
    (let ((low (make-overlay 1 2)) (high (make-overlay 2 3)))
      (overlay-put low 'face 'lazy-highlight)
      (overlay-put low 'priority 1000)
      (overlay-put high 'face 'isearch)
      (overlay-put high 'priority 1001)
      (should (equal (tategaki-highlight-faces 1 3 (selected-window))
                     '(isearch lazy-highlight))))))

(ert-deftest tategaki-highlight-window-specific-and-internal-overlays ()
  (tategaki-highlight-test--with-source
    (let ((owner (selected-window))
          (other (split-window-right))
          (owner-overlay (make-overlay 1 4))
          (other-overlay (make-overlay 1 4))
          (internal (make-overlay 1 4)))
      (set-window-buffer other source)
      (overlay-put owner-overlay 'window owner)
      (overlay-put owner-overlay 'face 'isearch)
      (overlay-put other-overlay 'window other)
      (overlay-put other-overlay 'face 'warning)
      (overlay-put internal 'tategaki-internal t)
      (overlay-put internal 'face 'region)
      (should (equal (tategaki-highlight-faces 1 4 owner) '(isearch)))
      (should (equal (tategaki-highlight-faces 1 4 other) '(warning))))))

(ert-deftest tategaki-highlight-preserves-face-properties-text-and-undo ()
  (tategaki-highlight-test--with-source
    (put-text-property 1 4 'face '(warning (:underline t) warning))
    (put-text-property 1 4 'font-lock-face '(font-lock-keyword-face font-lock-keyword-face))
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (set-buffer-modified-p nil)
    (let ((original (buffer-string)) (undo-list buffer-undo-list))
      (tategaki-highlight-enable #'ignore)
      (dotimes (_ 3) (tategaki-highlight-faces 1 4 (selected-window)))
      (tategaki-highlight-disable)
      (should (equal-including-properties (buffer-string) original))
      (should (equal (get-text-property 1 'face) '(warning (:underline t) warning)))
      (should (equal (get-text-property 1 'font-lock-face)
                     '(font-lock-keyword-face font-lock-keyword-face)))
      (should (equal buffer-undo-list undo-list))
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-highlight-real-isearch-lazy-and-query-replace-overlays ()
  (tategaki-highlight-test--with-source
    (let ((search-highlight t) (isearch-overlay nil)
          (isearch-submatches-overlays nil) (isearch-regexp nil)
          (isearch-face 'isearch) (isearch-lazy-count nil)
          (isearch-lazy-highlight-overlays nil)
          (isearch-lazy-highlight t) (isearch-lazy-highlight-buffer nil)
          (query-replace-highlight t) (query-replace-lazy-highlight nil)
          (replace-overlay nil) (replace-submatches-overlays nil))
      (unwind-protect
          (progn
            (isearch-lazy-highlight-match 2 5)
            (isearch-highlight 2 5)
            (should (equal (tategaki-highlight-faces 2 5 (selected-window))
                           '(isearch lazy-highlight)))
            (isearch-dehighlight)
            (replace-highlight 2 5 1 11 "123" nil nil nil)
            (should (equal (tategaki-highlight-faces 2 5 (selected-window))
                           '(query-replace lazy-highlight)))
            (should (eq (overlay-get replace-overlay 'face) 'query-replace))
            (should-not (buffer-modified-p)))
        (isearch-dehighlight)
        (replace-dehighlight)
        (mapc #'delete-overlay isearch-lazy-highlight-overlays)))))

(ert-deftest tategaki-highlight-real-flymake-diagnostic-face ()
  (tategaki-highlight-test--with-source
    (let* ((diagnostic (flymake-make-diagnostic source 2 5 :error "Example error"))
           (backend (lambda (report &rest _) (funcall report (list diagnostic)))))
      (setq-local flymake-diagnostic-functions (list backend))
      (unwind-protect
          (progn
            (flymake-mode 1)
            (flymake-start)
            (should (memq 'flymake-error
                           (tategaki-highlight-faces 2 5 (selected-window))))
            (should (equal (buffer-string) "0123456789"))
            (should-not (buffer-modified-p)))
        (flymake-mode -1)))))

(ert-deftest tategaki-highlight-overlay-face-only-update-is-coalesced-and-dispatched ()
  (tategaki-highlight-test--with-source
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (let ((calls 0) callback-buffer
          (overlay (make-overlay 2 5))
          (original (buffer-string)))
      (tategaki-highlight-enable (lambda () (cl-incf calls)
                                   (setq callback-buffer (current-buffer))))
      (overlay-put overlay 'face 'warning)
      (let ((timer tategaki-highlight--timer))
        (overlay-put overlay 'face 'error)
        (overlay-put overlay 'priority 500)
        (should (eq timer tategaki-highlight--timer)))
      (tategaki-highlight-test--dispatch)
      (should (= calls 1))
      (should (eq callback-buffer source))
      (should-not tategaki-highlight--timer)
      (should (equal (tategaki-highlight-faces 2 5 (selected-window)) '(error)))
      (should (equal (buffer-string) original))
      (should-not buffer-undo-list)
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-highlight-consume-cancels-pending-work ()
  (tategaki-highlight-test--with-source
    (let ((overlay (make-overlay 2 5)) (calls 0))
      (tategaki-highlight-enable (lambda () (cl-incf calls)))
      (overlay-put overlay 'face 'warning)
      (let ((timer tategaki-highlight--timer))
        (should (timerp timer))
        (tategaki-highlight-consume)
        (should-not tategaki-highlight--timer)
        (should-not (memq timer timer-idle-list)))
      (should (zerop calls)))))

(ert-deftest tategaki-highlight-internal-and-untracked-buffers-do-not-notify ()
  (tategaki-highlight-test--with-source
    (let ((internal (make-overlay 1 4)) (calls 0))
      (overlay-put internal 'tategaki-internal t)
      (tategaki-highlight-enable (lambda () (cl-incf calls)))
      (overlay-put internal 'face 'region)
      (move-overlay internal 2 5)
      (delete-overlay internal)
      (with-temp-buffer
        (insert "別のバッファ")
        (let ((overlay (make-overlay 1 3)))
          (overlay-put overlay 'face 'error)
          (delete-overlay overlay)))
      (should-not tategaki-highlight--timer)
      (should (zerop calls)))))

(ert-deftest tategaki-highlight-overlay-move-notifies-both-buffer-owners ()
  (tategaki-highlight-test--with-source
    (let ((other (generate-new-buffer " *tategaki-highlight-other*"))
          (first-calls 0) (second-calls 0)
          (overlay (make-overlay 2 5)))
      (unwind-protect
          (progn
            (overlay-put overlay 'face 'error)
            (tategaki-highlight-enable (lambda () (cl-incf first-calls)))
            (with-current-buffer other
              (insert "abcdefghij")
              (tategaki-highlight-enable (lambda () (cl-incf second-calls))))
            (move-overlay overlay 3 6 other)
            (tategaki-highlight-test--dispatch)
            (with-current-buffer other (tategaki-highlight-test--dispatch))
            (should (= first-calls 1))
            (should (= second-calls 1))
            (tategaki-highlight-disable)
            (should (advice-member-p #'tategaki-highlight--overlay-put 'overlay-put))
            (with-current-buffer other
              (delete-overlay overlay)
              (tategaki-highlight-test--dispatch))
            (should (= second-calls 2)))
        (kill-buffer other)))))

(ert-deftest tategaki-highlight-disable-restores-hooks-and-keeps-source-overlays ()
  (tategaki-highlight-test--with-source
    (let ((overlay (make-overlay 2 5)))
      (overlay-put overlay 'face 'warning)
      (tategaki-highlight-enable #'ignore)
      (overlay-put overlay 'face 'error)
      (tategaki-highlight-disable)
      (should-not tategaki-highlight--callback)
      (should-not tategaki-highlight--timer)
      (should-not (memq source tategaki-highlight--buffers))
      (should-not (memq #'tategaki-highlight--changed after-change-functions))
      (should-not (memq #'tategaki-highlight-disable change-major-mode-hook))
      (should-not (advice-member-p #'tategaki-highlight--overlay-put 'overlay-put))
      (should (eq (overlay-buffer overlay) source))
      (should (eq (overlay-get overlay 'face) 'error)))))

(ert-deftest tategaki-highlight-major-mode-and-buffer-kill-cancel-tracking ()
  (tategaki-highlight-test--with-source
    (tategaki-highlight-enable #'ignore)
    (overlay-put (make-overlay 2 4) 'face 'warning)
    (fundamental-mode)
    (should-not tategaki-highlight--callback)
    (should-not (memq source tategaki-highlight--buffers))
    (tategaki-highlight-enable #'ignore)
    (kill-buffer source)
    (should-not (memq source tategaki-highlight--buffers))
    (should-not (advice-member-p #'tategaki-highlight--overlay-put 'overlay-put))))

(provide 'tategaki-highlight-test)
;;; tategaki-highlight-test.el ends here
