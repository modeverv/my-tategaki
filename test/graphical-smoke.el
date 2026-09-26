;;; graphical-smoke.el --- Isolated GUI regression check -*- lexical-binding: t; -*-

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

;; Run in a NEW Emacs process:
;; emacs -Q -L . -l test/graphical-smoke.el
;; This process exits after testing.  Do not load into your editing session.
(unless (display-graphic-p)
  (error "This test requires a graphical Emacs frame"))
(load (expand-file-name "../org-tategaki-preview.el"
                        (file-name-directory load-file-name)) nil t)
(load (expand-file-name "org-tategaki-preview-test.el"
                        (file-name-directory load-file-name)) nil t)
(set-face-attribute 'default nil :family "Helvetica" :height 220)
(run-at-time
 1 nil
 (lambda ()
   (let ((stats (ert-run-tests-batch "org-tategaki-preview-graphical-alignment")))
     (kill-emacs (if (and (= 1 (ert-stats-total stats))
                          (= 0 (ert-stats-completed-unexpected stats)))
                     0 1)))))
