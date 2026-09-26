;;; manual-screenshots.el --- Isolated manual illustration session -*- lexical-binding: t; -*-

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

;; Launch a separate GUI Emacs with -Q -l tools/manual-screenshots.el.
;; Never load this into the user's editing process.
(setq load-prefer-newer t inhibit-startup-screen t initial-scratch-message nil)
(defconst tategaki-manual-root
  (file-name-directory (directory-file-name (file-name-directory load-file-name))))
(add-to-list 'load-path tategaki-manual-root)
(require 'tategaki)
(require 'tategaki-script)
(require 'server)
(setq server-name "tategaki-manual")
(server-start)
(tool-bar-mode -1)
(menu-bar-mode -1)
(scroll-bar-mode -1)
(blink-cursor-mode -1)
(setq frame-title-format "my-tategaki — マニュアル撮影"
      use-dialog-box nil ring-bell-function #'ignore)
(set-frame-size nil 106 35)
(set-frame-position nil 30 50)
(set-face-attribute 'default nil :family "Menlo" :height 140
                    :foreground "#253c38" :background "#fcfbf6")
(set-fontset-font t 'japanese-jisx0208 "Hiragino Mincho ProN")
(set-face-attribute 'tategaki-face nil :family "Hiragino Mincho ProN" :height 200
                    :foreground "#253c38" :background "#fcfbf6")
(set-face-attribute 'tategaki-cursor-face nil :background "#d6e5d6")
(set-face-attribute 'mode-line nil :background "#e1e8df" :foreground "#253c38" :box nil)
(set-face-attribute 'mode-line-inactive nil :background "#f0efe8" :foreground "#5c6e65" :box nil)
(set-face-attribute 'header-line nil :background "#fcfbf6" :foreground "#53685d" :height 120 :box nil)
(setq-default cursor-type 'box)
(defvar tategaki-manual-buffers nil)
(defun tategaki-manual-show (kind)
  "Display a public sample in the isolated session for KIND."
  (interactive "sView (editing/typesetting/outline/script): ")
  (dolist (buffer tategaki-manual-buffers)
    (with-current-buffer buffer
      (when (bound-and-true-p tategaki-mode) (tategaki-mode -1))))
  (delete-other-windows)
  (let ((buffer (get-buffer-create (if (equal kind "script") "*manual 台本サンプル.txt*" "*manual 雨の書店.txt*"))))
    (cl-pushnew buffer tategaki-manual-buffers)
    (switch-to-buffer buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert-file-contents
       (expand-file-name (if (equal kind "script") "docs/examples/script.txt" "docs/examples/novel.txt")
                         tategaki-manual-root)))
    (text-mode)
    (setq-local tategaki-padding-top 22 tategaki-padding-bottom 22
                tategaki-padding-right 26 tategaki-padding-left 26
                tategaki-line-spacing 10 tategaki-character-spacing 2
                tategaki-typeset-latin-orientation 'rotate
                tategaki-manuscript-target-characters 4000
                tategaki-outline-width 28)
    (goto-char (point-min))
    (pcase kind
      ("editing" (tategaki-edit))
      ("script" (tategaki-script-mode))
      (_ (tategaki-typeset-edit)))
    (when (equal kind "typesetting")
      (setq-local tategaki-manuscript-size '(20 . 20)
                  tategaki-manuscript-grid t)
      (tategaki-refresh))
    (when (equal kind "outline")
      (let ((window (selected-window)))
        (tategaki-outline)
        (select-window window)
        (tategaki-refresh)))
    (setq-local header-line-format
                (concat "  " (pcase kind
                              ("editing" "原文を縦に編集   ·   ↓ ↑ 文字移動   /   ← → 列移動   /   C-c C-c 横書き")
                              ("typesetting" "組版と原稿用紙   ·   20字 × 20列   /   ルビ・縦中横・傍点")
                              ("outline" "章を選んで移動   ·   C-c C-o 一覧   /   RET 移動   /   TAB 階層の開閉")
                              ("script" "脚本・台本   ·   C-c C-s シーン   /   C-c C-d 人物・台詞   /   C-c C-t ト書き"))))
    (when (fboundp 'hl-line-mode) (hl-line-mode -1))
    (when (fboundp 'tab-line-mode) (tab-line-mode -1))
    (when (bound-and-true-p copilot-mode) (copilot-mode -1))
    (setq-local global-hl-line-mode nil cursor-type nil)
    (setq-local mode-line-format
                '("  " mode-line-buffer-identification "   "
                  (:eval (tategaki-manuscript-mode-line))))
    (set-buffer-modified-p nil)
    (redisplay t)))
(tategaki-manual-show "typesetting")
;;; manual-screenshots.el ends here
