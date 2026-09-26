;;; graphical-tests.el --- Run GUI checks in a dedicated Emacs -*- lexical-binding: t; -*-

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

;; Run: emacs -Q -l /absolute/path/to/test/graphical-tests.el
;; Exit status: 0 success, 1 failed test, 2 setup error or timeout.
(let* ((directory (file-name-directory (or load-file-name buffer-file-name)))
       (root (file-name-directory (directory-file-name directory))))
  (add-to-list 'load-path root)
  (load (expand-file-name "org-tategaki-preview.el" root) nil nil t)
  (load (expand-file-name "org-tategaki-preview-test.el" directory) nil nil t))

(run-at-time 60 nil (lambda () (kill-emacs 2)))
(run-at-time
 1 nil
 (lambda ()
   (let ((status 2))
     (condition-case err
         (progn
           (unless (display-graphic-p) (error "A graphical frame is required"))
           ;; A named selector errors if the test was not loaded.
           (let ((stats (ert-run-tests-batch
                         '(member org-tategaki-preview-frame-lifecycle
                                  org-tategaki-preview-frame-move-and-cleanup
                                  org-tategaki-preview-graphical-alignment
                                  org-tategaki-preview-cursor-scroll-sync
                                  org-tategaki-preview-sync-edit-and-narrowing
                                  org-tategaki-preview-sync-source-scroll
                                  org-tategaki-preview-text-modes-and-markup
                                  org-tategaki-preview-graphical-padding-and-row-height))))
             (setq status
                   (if (and (= (ert-stats-total stats) 8)
                            (= (ert-stats-completed-expected stats) 8)
                            (zerop (ert-stats-skipped stats)))
                       0 1))))
       (error (message "GUI test setup failed: %S" err)))
     (with-current-buffer "*Messages*"
       (write-region (point-min) (point-max)
                     (expand-file-name "org-tategaki-preview-gui-tests.log"
                                       temporary-file-directory)))
     (kill-emacs status))))

;;; graphical-tests.el ends here
