;;; tategaki-corfu-graphical-tests.el --- Real Corfu GUI checks -*- lexical-binding: t; -*-

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

;; Run in a dedicated graphical Emacs, with Corfu and compat on load-path.
;; This runner exits after testing; no server or completion network is used.

(require 'ert)
(require 'cl-lib)
(require 'corfu)
(let* ((directory (file-name-directory (or load-file-name buffer-file-name)))
       (root (file-name-directory (directory-file-name directory))))
  (add-to-list 'load-path root)
  (setq load-prefer-newer t)
  (require 'tategaki))

(defmacro tategaki-corfu-gui--with-text (text &rest body)
  "Run BODY using real Corfu and the vertical renderer on TEXT."
  (declare (indent 1))
  `(save-window-excursion
     (let ((buffer (generate-new-buffer " *Tategaki Corfu graphical test*"))
           (tategaki-column-height 3)
           (corfu--preview-ov nil)
           (corfu--candidates nil)
           (corfu--base "")
           (corfu--index -1)
           (corfu--preselect -1)
           (corfu--frame nil)
           (corfu-auto nil)
           (corfu-preselect 'prompt)
           (corfu-preview-current t)
           (corfu-count 3))
       (unwind-protect
           (progn
             (switch-to-buffer buffer)
             (delete-other-windows)
             (text-mode)
             (insert ,text)
             (buffer-enable-undo)
             (setq buffer-undo-list nil)
             (set-buffer-modified-p nil)
             (tategaki-mode 1)
             (corfu-mode 1)
             ,@body)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when completion-in-region-mode (corfu-quit))
             (corfu--preview-delete)
             (tategaki-mode -1)
             (set-buffer-modified-p nil))
           (kill-buffer buffer))
         (when (frame-live-p corfu--frame) (delete-frame corfu--frame))))))

(defun tategaki-corfu-gui--cells ()
  "Return preview glyphs in source order, including their row and column."
  (let (cells)
    (dotimes (index (length tategaki--display-string))
      (let ((part (get-text-property index 'tategaki-completion-index
                                     tategaki--display-string)))
        (when part
          (push (list part (aref tategaki--display-string index)
                      (get-text-property index 'tategaki-row tategaki--display-string)
                      (get-text-property index 'tategaki-column tategaki--display-string))
                cells))))
    (sort cells (lambda (a b) (< (car a) (car b))))))

(ert-deftest tategaki-corfu-gui-preview-wraps-without-editing-source ()
  (tategaki-corfu-gui--with-text "前日本後"
    (goto-char 4)
    (setq corfu--candidates '("日本語入力候補") corfu--index 0)
    (let ((tick (buffer-chars-modified-tick)))
      (corfu--preview-current 2 4)
      (redisplay t)
      (let ((cells (tategaki-corfu-gui--cells)))
        (should (equal (apply #'string (mapcar #'cadr cells)) "日本語入力候補"))
        (should (equal (mapcar #'caddr cells) '(1 2 0 1 2 0 1)))
        (should (> (nth 3 (nth 2 cells)) (nth 3 (car cells)))))
      (should-not (overlay-get corfu--preview-ov 'display))
      (should (= tick (buffer-chars-modified-tick)))
      (should (equal (buffer-string) "前日本後"))
      (should-not buffer-undo-list)
      (should-not (buffer-modified-p))
      (corfu--preview-delete)
      (should-not (tategaki-corfu-gui--cells)))))

(ert-deftest tategaki-corfu-gui-popup-tracks-drawn-caret-through-wrap ()
  (tategaki-corfu-gui--with-text
      (concat (make-string 15 ?前) "日本語入力仮" (make-string 6 ?後))
    (setq corfu--candidates '("日本語入力候補確認") corfu--index 0)
    (let (positions)
      (dolist (point '(16 17 18 19))
        (goto-char point)
        (corfu--preview-current 16 22)
        (corfu--popup-show (posn-at-point) 7 12 '("日本語入力候補" "日本語入力確認") 0)
        (redisplay t)
        (let* ((cursor (window-cursor-info))
               (pixel (tategaki-position-pixel (point)))
               (geometry (frame-parameter corfu--frame 'corfu--geometry))
               (edges (window-inside-pixel-edges))
               (cell-height (max (default-line-height) (plist-get pixel :height)))
               (expected-y (+ (cadr edges) (plist-get pixel :y) cell-height))
               (object (posn-string (posn-at-x-y
                                     (+ (plist-get pixel :x) 1)
                                     (+ (plist-get pixel :y) 1)
                                     (selected-window)))))
          (should (frame-live-p corfu--frame))
          (should (frame-visible-p corfu--frame))
          (should object)
          (should (= tategaki--caret-position
                     (get-text-property (cdr object) 'tategaki-virtual-position (car object))))
          (should (= (aref cursor 1) (plist-get pixel :x)))
          (should (= (aref cursor 2) (plist-get pixel :y)))
          ;; This frame is tall enough that Corfu chooses below the glyph.
          (should (= (cadr geometry) expected-y))
          ;; Prefix-column offsets are horizontal completion artifacts: they
          ;; must not shift the list seven characters away from this caret.
          (should (< (abs (- (car geometry) (+ (car edges) (plist-get pixel :x)))) 25))
          (push geometry positions)))
      (setq positions (nreverse positions))
      (should (= (caar positions) (caadr positions)))
      (should (< (cadar positions) (cadadr positions)))
      (should (< (car (nth 3 positions)) (caar positions)))
      (should (= (cadr (nth 3 positions)) (cadar positions))))))

(ert-deftest tategaki-corfu-gui-popup-follows-lower-rows-with-font-remapping ()
  (tategaki-corfu-gui--with-text
      (concat (make-string 60 ?前) (make-string 18 ?日) (make-string 6 ?後))
    (setq tategaki-column-height 12
          corfu--candidates '("日本語入力候補確認日本語入力候補確認")
          corfu--index 0)
    (text-scale-set 1)
    (let (positions)
      (dolist (point '(61 62 69 70 72 73))
        (goto-char point)
        (corfu--preview-current 61 79)
        (corfu--popup-show (posn-at-point) 0 12 '("日本語入力候補" "日本語入力確認") 0)
        (let* ((pixel (tategaki-position-pixel (point)))
               (geometry (frame-parameter corfu--frame 'corfu--geometry))
               (edges (window-inside-pixel-edges))
               (object (posn-string (posn-at-x-y
                                     (+ (plist-get pixel :x) 1)
                                     (+ (plist-get pixel :y) 1)
                                     (selected-window)))))
          (should object)
          (should (= tategaki--caret-position
                     (get-text-property (cdr object) 'tategaki-virtual-position (car object))))
          (should (memq (cadr geometry)
                        (list (+ (cadr edges) (plist-get pixel :y)
                                 (max (default-line-height) (plist-get pixel :height)))
                              ;; Corfu moves above the caret near frame bottom.
                              (- (+ (cadr edges) (plist-get pixel :y))
                                 (nth 3 geometry) (* 2 corfu-border-width)))))
          (push geometry positions)))
      (setq positions (nreverse positions))
      (should (< (cadar positions) (cadr (nth 4 positions))))
      (should (< (car (nth 5 positions)) (caar positions)))
      (should (= (cadr (nth 5 positions)) (cadar positions))))))

(ert-deftest tategaki-corfu-gui-native-key-selection-accept-and-undo ()
  (tategaki-corfu-gui--with-text "前日後"
    (goto-char 3)
    (let ((completion-in-region-mode-predicate #'always))
      (corfu--setup 2 3 '("日本語入力" "日本語能力") nil))
    (corfu--exhibit)
    (should (eq (key-binding (kbd "<down>")) #'corfu-next))
    (should (eq (key-binding (kbd "<up>")) #'corfu-previous))
    (call-interactively (key-binding (kbd "<down>")))
    (corfu--exhibit)
    (should (equal (plist-get (tategaki-completion-current) :text) "日本語入力"))
    (let ((this-command #'corfu-insert)) (corfu--prepare))
    (corfu-insert)
    (should (equal (buffer-string) "前日本語入力後"))
    (should-not completion-in-region-mode)
    (should-not (tategaki-completion-current))
    (undo-boundary)
    (let ((inhibit-message t)) (undo 1))
    (should (equal (buffer-string) "前日後"))))

(run-at-time
 1 nil
 (lambda ()
   (let ((status 2))
     (condition-case err
         (progn
           (unless (display-graphic-p) (error "This test needs graphical Emacs"))
           (delete-other-windows)
           (set-frame-size (selected-frame) 90 35)
           (let ((stats (ert-run-tests-batch "^tategaki-corfu-gui-")))
             (setq status (if (and (= (ert-stats-completed-expected stats) 4)
                                   (zerop (ert-stats-completed-unexpected stats))
                                   (zerop (ert-stats-skipped stats))) 0 1))))
       (error (message "Corfu GUI test setup failed: %S" err)))
     (with-current-buffer "*Messages*"
       (write-region (point-min) (point-max)
                     (expand-file-name "tategaki-corfu-gui-tests.log" temporary-file-directory)))
     (kill-emacs status))))

;;; tategaki-corfu-graphical-tests.el ends here
