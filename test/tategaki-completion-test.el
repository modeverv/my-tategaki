;;; tategaki-completion-test.el --- Completion integration tests -*- lexical-binding: t; -*-

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
(require 'tategaki)
(require 'package)
(unless (locate-library "copilot") (package-initialize))
(require 'copilot nil t)

(defmacro tategaki-completion-test--with-text (text &rest body)
  "Run BODY in a vertical TEXT buffer with real, offline Copilot display."
  (declare (indent 1))
  `(progn
     (skip-unless (featurep 'copilot))
     (save-window-excursion
       (let ((buffer (generate-new-buffer " *vertical completion test*"))
             (tategaki-column-height 3)
             (copilot--overlay nil) (copilot--keymap-overlay nil))
         (unwind-protect
             (cl-letf (((symbol-function 'copilot--notify) #'ignore)
                       ((symbol-function 'copilot--async-request) #'ignore)
                       ((symbol-function 'copilot--cancel-completion) #'ignore))
               (switch-to-buffer buffer)
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
               (tategaki-mode -1)
               (when (overlayp copilot--overlay) (delete-overlay copilot--overlay))
               (when (overlayp copilot--keymap-overlay) (delete-overlay copilot--keymap-overlay)))
             (kill-buffer buffer)))))))

(ert-deftest tategaki-completion-copilot-wraps-with-source-and-undo-untouched ()
  (tategaki-completion-test--with-text "前後"
    (goto-char 2)
    (let ((tick (buffer-chars-modified-tick)))
      (copilot--display-overlay-completion "日本語入力" nil "日本語入力" 2 2)
      (should (equal (tategaki--virtual-text) "前日本語入力後"))
      (should (eq tategaki--preview-kind 'copilot))
      (should (= tategaki--caret-position 2))
      (should (= (get-text-property
                  (text-property-any 0 (length tategaki--display-string)
                                     'tategaki-completion-index 2 tategaki--display-string)
                  'tategaki-row tategaki--display-string) 0))
      (should-not (overlay-get copilot--overlay 'after-string))
      (should-not (overlay-get copilot--overlay 'display))
      (should (copilot--overlay-visible))
      (should (keymapp (overlay-get copilot--keymap-overlay 'keymap)))
      (should (equal (buffer-string) "前後"))
      (should (= tick (buffer-chars-modified-tick)))
      (should-not (buffer-modified-p))
      (should-not buffer-undo-list))))

(ert-deftest tategaki-completion-copilot-replacement-retains-tail ()
  (tategaki-completion-test--with-text "前古い後"
    (goto-char 2)
    (copilot--display-overlay-completion "新しい" nil "新しい" 2 4)
    (should (equal (tategaki--virtual-text) "前新しい後"))
    (should (= (tategaki--source-position 5) 4))
    (copilot-accept-completion)
    (tategaki-refresh)
    (should (equal (buffer-string) "前新しい後"))
    (should-not (tategaki-completion-current))
    (undo-boundary)
    (undo-only 1)
    (tategaki-refresh)
    (should (equal (buffer-string) "前古い後"))))

(ert-deftest tategaki-completion-copilot-partial-acceptance-uses-native-tail ()
  (tategaki-completion-test--with-text "前古い後"
    (goto-char 2)
    (copilot--display-overlay-completion "新しい" nil "新しい" 2 4)
    (copilot-accept-completion (lambda (text) (substring text 0 1)))
    (tategaki-refresh)
    (should (equal (buffer-string) "前新古い後"))
    (should (equal (tategaki--virtual-text) "前新しい後"))
    (should (= tategaki--caret-position 3))
    (copilot-accept-completion)
    (tategaki-refresh)
    (should (equal (buffer-string) "前新しい後"))))

(ert-deftest tategaki-completion-copilot-cycle-and-dismiss ()
  (tategaki-completion-test--with-text "前後"
    (goto-char 2)
    (copilot--display-overlay-completion "最初" nil "最初" 2 2)
    (copilot--display-overlay-completion "次の候補\n次の行" nil "次の候補\n次の行" 2 2)
    (should (equal (tategaki--virtual-text) "前次の候補\n次の行後"))
    (copilot-clear-overlay)
    (should (equal (tategaki--virtual-text) "前後"))
    (should-not buffer-undo-list)))

(ert-deftest tategaki-completion-disable-restores-native-suggestion ()
  (tategaki-completion-test--with-text ""
    (copilot--display-overlay-completion "日本語" nil "日本語" 1 1)
    (let ((native copilot--overlay))
      (tategaki-mode -1)
      (should (eq copilot--overlay native))
      (should (equal (overlay-get native 'after-string) "日本語"))
      (should-not (buffer-modified-p))
      (should-not buffer-undo-list))))

(ert-deftest tategaki-completion-copilot-other-window-keeps-native-preview ()
  (tategaki-completion-test--with-text "前後"
    (goto-char 2)
    (let ((other (split-window-right)))
      (set-window-buffer other (current-buffer))
      (copilot--display-overlay-completion "日本語" nil "日本語" 2 2)
      (should (= (length tategaki-completion--mirrors) 1))
      (should (eq (overlay-get (car tategaki-completion--mirrors) 'window) other))
      (should (overlay-get (car tategaki-completion--mirrors) 'after-string))
      (copilot-clear-overlay)
      (should-not tategaki-completion--mirrors))))

(ert-deftest tategaki-completion-priority-and-corfu-replacement ()
  (tategaki-completion-test--with-text "前にほ後"
    (goto-char 4)
    (copilot--display-overlay-completion "Copilot" nil "Copilot" 4 4)
    (tategaki-completion-set 'corfu 2 4 (propertize "日本語" 'face 'shadow))
    (should (eq tategaki--preview-kind 'corfu))
    (should (equal (tategaki--virtual-text) "前日本語後"))
    (should (= tategaki--caret-position 4))
    (setq tategaki-ime--text "変換" tategaki-ime--position 4)
    (tategaki--ime-updated)
    (should (eq tategaki--preview-kind 'ime))
    (should (equal (tategaki--virtual-text) "前にほ変換後"))
    (setq tategaki-ime--text nil tategaki-ime--position nil)
    (tategaki--ime-updated)
    (should (eq tategaki--preview-kind 'corfu))
    (tategaki-completion-clear 'corfu)
    (should (eq tategaki--preview-kind 'copilot))))

(ert-deftest tategaki-completion-ordinary-buffer-keeps-native-copilot ()
  (tategaki-completion-test--with-text ""
    (with-temp-buffer
      (text-mode)
      (let ((copilot--overlay nil) (copilot--keymap-overlay nil))
        (copilot--display-overlay-completion "日本語" nil "日本語" 1 1)
        (should (equal (overlay-get copilot--overlay 'after-string) "日本語"))
        (should-not tategaki-completion--previews)
        (copilot-clear-overlay)))))

(provide 'tategaki-completion-test)
;;; tategaki-completion-test.el ends here
