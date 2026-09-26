;;; tategaki-navigation.el --- Optional physical movement keys -*- lexical-binding: t; -*-

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

;;; Commentary:
;; Physical directions are an opt-in presentation choice.  Filtered bindings
;; fall through to the user's normal bindings whenever the option is nil.

;;; Code:

(defcustom tategaki-physical-navigation nil
  "Use physical directions for C-f, C-b, C-n and C-p in `tategaki-mode'.
When non-nil, C-f moves right, C-b left, C-n down and C-p up.  Numeric
prefix arguments retain their usual meaning.  When nil, these keys keep
their existing Emacs or user-defined bindings.
An active in-buffer completion map retains its normal navigation keys.

Changing this option with `setq' takes effect immediately.  Use
`setq-local' to choose a different value for an individual buffer."
  :type 'boolean
  :group 'tategaki)

(defun tategaki-navigation--page-filter (command)
  "Return COMMAND unless an active completion map needs its native keys."
  ;; Corfu remaps next/previous-line and scroll-up/down-command.  Directly
  ;; replacing their keys would bypass those candidate navigation remaps.
  (and (not (and (bound-and-true-p completion-in-region-mode)
                 (assq 'completion-in-region-mode minor-mode-overriding-map-alist)))
       command))

(defun tategaki-navigation--filter (command)
  "Return COMMAND only when physical navigation is requested."
  (and tategaki-physical-navigation (tategaki-navigation--page-filter command)))

(defun tategaki-navigation-install (map)
  "Install page and optional physical movement bindings in tategaki's MAP.
The bindings are resolved when a key is pressed, without global remaps."
  (dolist (binding '(("C-f" . tategaki-backward-column)
                     ("C-b" . tategaki-forward-column)
                     ("C-n" . tategaki-next-character)
                     ("C-p" . tategaki-previous-character)))
    (define-key map (kbd (car binding))
                `(menu-item "" ,(cdr binding)
                            :filter tategaki-navigation--filter)))
  (dolist (binding '(("C-v" . tategaki-forward-page)
                     ("M-v" . tategaki-backward-page)
                     ("<next>" . tategaki-forward-page)
                     ("<prior>" . tategaki-backward-page)))
    (define-key map (kbd (car binding))
                `(menu-item "" ,(cdr binding)
                            :filter tategaki-navigation--page-filter))))

(provide 'tategaki-navigation)
;;; tategaki-navigation.el ends here
