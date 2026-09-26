;;; tategaki-glyph-graphical-tests.el --- SVG and native glyph GUI tests -*- lexical-binding: t; -*-

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
(setq load-prefer-newer t)
(let ((root (file-name-directory (directory-file-name
                                 (file-name-directory (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path root))
(require 'tategaki-glyph)

(ert-deftest tategaki-glyph-gui-image-dimensions ()
  :tags '(tategaki-glyph-gui)
  (should (display-graphic-p))
  (dolist (family '("Arial" "Hiragino Sans"))
    (dolist (unit '((:text "漢" :kind glyph :span 1)
                    (:text "12" :kind tcy :span 1)
                    (:text "Emacs" :kind latin :span 3)
                    (:text "漢" :kind ruby :span 1 :ruby "かん")))
      (let* ((rendered (tategaki-glyph-render unit 48 48 36 (list :family family)))
             (image (get-text-property 0 'tategaki-glyph-image rendered)))
        (should image)
        (should (equal (image-size image t) (cons 48 (* 48 (plist-get unit :span)))))))))

(ert-deftest tategaki-glyph-gui-grapheme-width ()
  :tags '(tategaki-glyph-gui)
  (should (display-graphic-p))
  (dolist (text '("👩‍👩‍👧‍👧" "❤️" "🇯🇵"))
    (let ((rendered (tategaki-glyph-render (list :text text :kind 'glyph :span 1)
                                         48 48 36 'default)))
      (should (= (string-pixel-width rendered) 48)))))

(ert-deftest tategaki-glyph-gui-slices-have-exact-row-height ()
  :tags '(tategaki-glyph-gui)
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *tategaki-glyph-slices*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (delete-other-windows)
            (setq-local line-spacing 0)
            (let ((rendered (tategaki-glyph-render '(:text "Emacs" :kind latin :span 3)
                                                  48 48 36 'default))
                  positions)
              (dotimes (row 3)
                (push (point) positions)
                (let ((slice (tategaki-glyph-slice rendered row 48)))
                  (should (= (string-pixel-width slice) 48))
                  (insert slice (propertize "\n" 'line-height t))))
              (goto-char (point-min))
              (redisplay t)
              (let* ((ys (mapcar (lambda (position) (cdr (posn-x-y (posn-at-point position))))
                                  (nreverse positions))))
                (should (= (- (nth 1 ys) (nth 0 ys)) 48))
                (should (= (- (nth 2 ys) (nth 1 ys)) 48)))))
        (kill-buffer buffer)))))

(defun tategaki-glyph-graphical-demo ()
  "Show cell examples in an isolated demo buffer."
  (interactive)
  (switch-to-buffer (get-buffer-create "*TATEGAKI GLYPH PROTOTYPE*"))
  (fundamental-mode)
  (erase-buffer)
  (setq-local line-spacing 0)
  (insert "字形・縦中横・ルビ・傍点・傍線・絵文字\n\n")
  (dolist (unit '((:text "漢" :kind glyph :span 1)
                  (:text "12" :kind tcy :span 1)
                  (:text "字" :ruby "じ" :kind ruby :span 1)
                  (:text "点" :emphasis dot :kind glyph :span 1)
                  (:text "線" :emphasis line :kind glyph :span 1)
                  (:text "👩‍👩‍👧‍👧" :kind glyph :span 1)))
    (insert (tategaki-glyph-render unit 64 64 48 'default nil t) "  "))
  (insert "\n\n時計回りの欧文を3行に分割\n")
  (let ((rendered (tategaki-glyph-render '(:text "Emacs" :kind latin :span 3)
                                        64 64 48 'default nil t)))
    (dotimes (row 3)
      (insert (tategaki-glyph-slice rendered row 64)
              (propertize "\n" 'line-height t))))
  (goto-char (point-min))
  (set-buffer-modified-p nil)
  (redisplay t))

(unless noninteractive
  (run-at-time 60 nil (lambda () (kill-emacs 2)))
  (run-at-time
   1 nil
   (lambda ()
     (let ((status 2))
       (condition-case err
           (let ((stats (ert-run-tests-batch "^tategaki-glyph-gui-")))
             (setq status (if (and (= (ert-stats-completed-expected stats) 3)
                                  (zerop (ert-stats-completed-unexpected stats))) 0 1)))
         (error (message "Glyph GUI setup failure: %S" err)))
       (with-current-buffer "*Messages*"
         (write-region (point-min) (point-max)
                       (expand-file-name "tategaki-glyph-gui-tests.log" temporary-file-directory)))
       (kill-emacs status)))))

(provide 'tategaki-glyph-graphical-tests)
;;; tategaki-glyph-graphical-tests.el ends here
