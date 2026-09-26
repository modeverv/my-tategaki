;;; tategaki-scrollbar-test.el --- Horizontal navigation tests -*- lexical-binding: t; -*-

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
(require 'tategaki)

(defmacro tategaki-scrollbar-test--with-text (&rest body)
  (declare (indent 0))
  `(save-window-excursion
     (let ((source (generate-new-buffer " *scroll test*"))
           (tategaki-column-height 3) (tategaki-line-spacing 25))
       (unwind-protect
           (progn
             (switch-to-buffer source) (text-mode)
             (insert (make-string 500 ?あ)) (goto-char 1)
             (buffer-enable-undo) (setq buffer-undo-list nil)
             (set-buffer-modified-p nil) (tategaki-mode 1)
             ,@body)
         (when (buffer-live-p source) (kill-buffer source))))))

(ert-deftest tategaki-scrollbar-reading-direction-and-endpoints ()
  (let* ((first (tategaki-scrollbar--geometry 500 100 10 0))
         (last (tategaki-scrollbar--geometry 500 100 10 90)))
    (should (> (plist-get first :x) (plist-get last :x)))
    (should (= 0 (tategaki-scrollbar--column-at (plist-get first :x) first 0)))
    (should (= 90 (tategaki-scrollbar--column-at (plist-get last :x) last 0)))
    (should (= 90 (tategaki-scrollbar--column-at -100 first 0)))
    (should (= 0 (tategaki-scrollbar--column-at 10000 first 0)))))

(ert-deftest tategaki-scrollbar-short-document-has-full-thumb ()
  (let ((geometry (tategaki-scrollbar--geometry 200 1 20 0)))
    (should (= (plist-get geometry :thumb) (plist-get geometry :track)))
    (should (= 0 (tategaki-scrollbar--column-at 15 geometry 0)))))

(ert-deftest tategaki-scrollbar-continuous-columns-keep-cursor-visible ()
  (tategaki-scrollbar-test--with-text
    (tategaki-scroll-to-column 1)
    (should (= tategaki--page 1))
    (should (= (aref (tategaki--entry) 3) 1))
    (let ((this-command 'tategaki-scroll-left)) (tategaki--post-command))
    (should (= tategaki--page 1))
    (tategaki-scroll-left 2)
    (should (= tategaki--page 3))
    (should (= (aref (tategaki--entry) 3) 3))
    (tategaki-scroll-right 2)
    (should (= tategaki--page 1))
    (should-not (buffer-modified-p))
    (should-not buffer-undo-list)))

(ert-deftest tategaki-scrollbar-page-commands-return-to-page-grid ()
  (tategaki-scrollbar-test--with-text
    (tategaki-scroll-to-column 1)
    (tategaki-forward-page)
    (should-not tategaki--scroll-start)
    (should (= (% tategaki--page tategaki--page-size) 0))))

(ert-deftest tategaki-scrollbar-endpoint-clamp-and-source-jump ()
  (tategaki-scrollbar-test--with-text
    (tategaki-scroll-to-column 10000)
    (should (= tategaki--page (- (plist-get tategaki--layout :columns) tategaki--page-size)))
    (goto-char 1) (tategaki-refresh)
    (should (= tategaki--page 0))
    (should-not tategaki--scroll-start)))

(ert-deftest tategaki-scrollbar-goto-page-resets-continuous-viewport ()
  (tategaki-scrollbar-test--with-text
    (tategaki-scroll-to-column 1)
    (tategaki-goto-page 2)
    (should-not tategaki--scroll-start)
    (should (= tategaki--page tategaki--page-size))))

(ert-deftest tategaki-scrollbar-is-display-only-and-can-be-disabled ()
  (tategaki-scrollbar-test--with-text
    (let* ((display tategaki--display-string)
           (index (text-property-not-all 0 (length display) 'tategaki-scrollbar nil display)))
      (should index)
      (should (keymapp (get-text-property index 'keymap display))))
    (setq-local tategaki-scrollbar nil) (tategaki-refresh)
    (should-not (text-property-not-all 0 (length tategaki--display-string)
                                       'tategaki-scrollbar nil tategaki--display-string))
    (should (= (buffer-size) 500))
    (tategaki-mode -1)
    (should-not tategaki--display-string)
    (should-not tategaki--scroll-start)))

(provide 'tategaki-scrollbar-test)
