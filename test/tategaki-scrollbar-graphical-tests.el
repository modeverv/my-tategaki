;;; tategaki-scrollbar-graphical-tests.el --- Scrollbar pixels and input -*- lexical-binding: t; -*-

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
(let* ((directory (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (file-name-directory (directory-file-name directory))))
(setq load-prefer-newer t)
(require 'tategaki)

(defmacro tategaki-scroll-gui--with-text (rich &rest body)
  (declare (indent 1))
  `(save-window-excursion
     (let ((source (generate-new-buffer " *scroll GUI*")))
       (unwind-protect
           (progn
             (switch-to-buffer source) (delete-other-windows) (text-mode)
             (insert (make-string 1000 ?字)) (goto-char 1)
             (setq-local tategaki-typesetting ,rich tategaki-column-height 10)
             (buffer-enable-undo) (setq buffer-undo-list nil)
             (set-buffer-modified-p nil) (tategaki-mode 1)
             ,@body)
         (when (buffer-live-p source) (kill-buffer source))))))

(defmacro tategaki-scroll-gui--with-fixed-paper (text spacing &rest body)
  "Run BODY with TEXT on unruled fixed paper and buffer line SPACING."
  (declare (indent 2))
  `(save-window-excursion
     (let ((source (generate-new-buffer " *fixed scroll GUI*"))
           (frame (selected-frame))
           (original-height (face-attribute 'default :height (selected-frame))))
       (unwind-protect
           (progn
             ;; An enlarged portable default font reproduces the geometry
             ;; without requiring the user's particular installed family.
             (set-face-attribute 'default frame :height 220)
             (switch-to-buffer source) (delete-other-windows) (text-mode)
             (insert ,text) (goto-char (point-min))
             (setq-local tategaki-typesetting t
                         tategaki-manuscript-size '(20 . 20)
                         tategaki-manuscript-grid nil
                         tategaki-padding-top 0 tategaki-padding-bottom 0
                         tategaki-padding-left 0 tategaki-padding-right 0
                         tategaki-line-spacing nil tategaki-character-spacing 0
                         line-spacing ,spacing)
             (buffer-enable-undo) (setq buffer-undo-list nil)
             (set-buffer-modified-p nil) (tategaki-mode 1)
             ,@body)
         (when (buffer-live-p source) (kill-buffer source))
         (set-face-attribute 'default frame :height original-height)))))

(defun tategaki-scroll-gui--bar-position (&optional x)
  "Find the real scrollbar glyph at X in the rendered bottom area."
  (redisplay t)
  (let* ((height (window-body-height nil t))
         (x (or x (/ (window-body-width nil t) 2)))
         found)
    (cl-loop for y from (max 0 (- height (max 45 (tategaki-scrollbar-height
                                                  (selected-window)))))
             below height
             for position = (posn-at-x-y x y)
             for object = (and position (posn-string position))
             when (and object (get-text-property (cdr object) 'tategaki-scrollbar (car object)))
             do (setq found position) and return nil)
    (should found)
    found))

(defun tategaki-scroll-gui--assert-bar-bounds ()
  "Check the actual scrollbar image's full bounds and return its position."
  (let* ((position (tategaki-scroll-gui--bar-position))
         (object (posn-string position))
         (string (car object)) (index (cdr object))
         (geometry (get-text-property index 'tategaki-scrollbar string))
         (image (get-text-property index 'display string))
         (size (image-size image t (selected-frame)))
         (offset (posn-object-x-y position))
         (origin (posn-x-y position))
         (left (- (car origin) (car offset)))
         (top (- (cdr origin) (cdr offset)))
         (expected-height (max 12 tategaki-scrollbar-pixel-height
                               (frame-char-height (selected-frame)))))
    ;; Automatic image scaling must not enlarge the track beyond the logical
    ;; coordinates used both for fitting it and for handling pointer events.
    (should (= (car size) (plist-get geometry :width)))
    (should (= (cdr size) expected-height))
    (should (>= left 0))
    (should (>= top 0))
    (should (<= (+ left (car size)) (window-body-width nil t)))
    (should (<= (+ top (cdr size)) (window-body-height nil t)))
    position))

(defun tategaki-scroll-gui--assert-native-caret ()
  "Check that the native cursor matches the source insertion cell."
  (let ((pixel (tategaki-position-pixel (point)))
        (cursor (window-cursor-info)))
    (should pixel)
    (should (= (aref cursor 2) (plist-get pixel :y)))
    (should (= (window-vscroll nil t) 0))))

(ert-deftest tategaki-scroll-gui-bottom-track-and-caret ()
  (dolist (rich '(nil t))
    (tategaki-scroll-gui--with-text rich
      (goto-char 8) (tategaki-refresh) (redisplay t)
      (let* ((bar (tategaki-scroll-gui--bar-position))
             (y (cdr (posn-x-y bar)))
             (pixel (tategaki-position-pixel (point)))
             (cursor (window-cursor-info)))
        (should (> y (- (window-body-height nil t) 45)))
        (should (= (aref cursor 2) (plist-get pixel :y)))
        (should (= (window-vscroll nil t) 0))))))

(ert-deftest tategaki-scroll-gui-click-drag-and-undo ()
  (tategaki-scroll-gui--with-text t
    (let* ((width (window-body-width nil t))
           (start (tategaki-scroll-gui--bar-position (/ width 2)))
           (finish (tategaki-scroll-gui--bar-position 30))
           (events (list (list 'mouse-movement finish) (list 'mouse-1 finish))))
      (cl-letf (((symbol-function 'read-event) (lambda (&rest _) (pop events))))
        (tategaki-scrollbar-drag (list 'down-mouse-1 start)))
      (should (> tategaki--page 50))
      (should (<= tategaki--page (aref (tategaki--entry) 3)
                  (+ tategaki--page tategaki--page-size -1)))
      (should-not (buffer-modified-p)) (should-not buffer-undo-list)
      (tategaki-scroll-gui--bar-position)
      (should (= (window-vscroll nil t) 0)))))

(ert-deftest tategaki-scroll-gui-resize-and-fixed-paper ()
  (tategaki-scroll-gui--with-text t
    (setq-local tategaki-manuscript-size '(20 . 20) tategaki-manuscript-grid t)
    (dolist (width '(65 90))
      (set-frame-size nil width 28)
      (tategaki-refresh) (redisplay t)
      (tategaki-scroll-to-column 3)
      (tategaki-scroll-gui--bar-position)
      (should (= tategaki--page 3))
      (should (= (window-vscroll nil t) 0)))))

(ert-deftest tategaki-scroll-gui-text-fallback-uses-pixel-event-coordinates ()
  (let ((available (symbol-function 'image-type-available-p)))
    (cl-letf (((symbol-function 'image-type-available-p)
               (lambda (type) (and (not (eq type 'svg)) (funcall available type)))))
      (tategaki-scroll-gui--with-text nil
        (let* ((start (tategaki-scroll-gui--bar-position (/ (window-body-width nil t) 2)))
               (events (list (list 'mouse-1 start))))
          (cl-letf (((symbol-function 'read-event) (lambda (&rest _) (pop events))))
            (tategaki-scrollbar-drag (list 'down-mouse-1 start)))
          (should (> tategaki--page 20))
          (should (< tategaki--page 80))
          (should-not (buffer-modified-p)))))))

(ert-deftest tategaki-scroll-gui-scaled-images-keep-logical-track-size ()
  (dolist (settings '((1.5 . 0.1) (2.0 . 3)))
    (let ((image-scaling-factor (car settings)))
      (tategaki-scroll-gui--with-fixed-paper "短い原稿の途中にカーソルを置く。" (cdr settings)
        (goto-char 6) (tategaki-refresh) (redisplay t)
        (tategaki-scroll-gui--assert-bar-bounds)
        (tategaki-scroll-gui--assert-native-caret)
        (should-not (buffer-modified-p))
        (should-not buffer-undo-list)))))

(ert-deftest tategaki-scroll-gui-unruled-paper-empty-rows-and-line-spacing ()
  (let ((image-scaling-factor 2.0))
    (dolist (spacing '(0.1 3))
      (dolist (fixture '(("" . 1) ("短い原稿。" . 1)
                         ("最初の段落。\n次の段落の途中。" . 13)))
        (tategaki-scroll-gui--with-fixed-paper (car fixture) spacing
          (goto-char (cdr fixture)) (tategaki-refresh) (redisplay t)
          (tategaki-scroll-gui--assert-bar-bounds)
          (tategaki-scroll-gui--assert-native-caret)
          (should (equal (buffer-string) (car fixture)))
          (should-not (buffer-modified-p))
          (should-not buffer-undo-list))))))

(ert-deftest tategaki-scroll-gui-scaled-fixed-paper-drag-preserves-source ()
  (let ((image-scaling-factor 2.0))
    (tategaki-scroll-gui--with-fixed-paper (make-string 1200 ?字) 0.1
      (goto-char 12) (tategaki-refresh) (redisplay t)
      (let* ((before (buffer-string))
             (start (tategaki-scroll-gui--assert-bar-bounds))
             (finish (tategaki-scroll-gui--bar-position 30))
             (events (list (list 'mouse-movement finish) (list 'mouse-1 finish))))
        (cl-letf (((symbol-function 'read-event) (lambda (&rest _) (pop events))))
          (tategaki-scrollbar-drag (list 'down-mouse-1 start)))
        (should (> tategaki--page 0))
        (should (<= tategaki--page (aref (tategaki--entry) 3)
                    (+ tategaki--page tategaki--page-size -1)))
        (tategaki-scroll-gui--assert-bar-bounds)
        (tategaki-scroll-gui--assert-native-caret)
        (should (equal (buffer-string) before))
        (should-not (buffer-modified-p))
        (should-not buffer-undo-list)))))

(ert-deftest tategaki-scroll-gui-compressed-columns-reserve-all-scanlines ()
  (let ((frame (selected-frame))
        (original-width (frame-pixel-width))
        (original-height (frame-pixel-height))
        (image-scaling-factor 2.0))
    (unwind-protect
        (dolist (character-gap '(0 2))
          (tategaki-scroll-gui--with-fixed-paper
              (concat (make-string 20 ?あ) "）" (make-string 379 ?あ)) 3
            ;; The first column must squeeze its closing parenthesis into
            ;; 20 cells.  Its fractional rows interleave with the fixed paper
            ;; boundaries, producing more scanlines than 20 ordinary cells.
            (set-frame-size frame 1120 450 t)
            (setq-local tategaki-typeset-compression t
                        tategaki-character-spacing character-gap)
            (goto-char 10) (tategaki-refresh) (redisplay t)
            (should (<= (window-body-height nil t) 500))
            (should
             (cl-some (lambda (entry)
                        (let ((compression (plist-get (aref entry 4) :compression)))
                          (and compression (< compression 1))))
                      (tategaki-typeset-visible tategaki--layout
                                               tategaki--page tategaki--page-size)))
            (let* ((geometry (tategaki-typeset-view-geometry (selected-window)
                                                           tategaki--metrics))
                   (ordinary-lines (* (plist-get geometry :rows)
                                      (if (> (plist-get geometry :character-gap) 0) 2 1)))
                   (newlines (cl-count ?\n tategaki--display-string)))
              ;; Leave room for the padding/bar separators in this comparison:
              ;; the additional rows must come from actual composition slices.
              (should (> newlines (+ ordinary-lines 5))))
            (tategaki-scroll-gui--assert-bar-bounds)
            (tategaki-scroll-gui--assert-native-caret)
            (should-not (buffer-modified-p))
            (should-not buffer-undo-list)))
      (set-frame-size frame original-width original-height t))))

(run-at-time 50 nil (lambda () (kill-emacs 2)))
(run-at-time
 1 nil
 (lambda ()
   (let ((status 2))
     (condition-case err
         (progn
           (set-frame-size nil 80 30)
           (let ((stats (ert-run-tests-batch "^tategaki-scroll-gui-")))
             (setq status (if (= (ert-stats-completed-expected stats) 8) 0 1))))
       (error (message "Scrollbar GUI setup failed: %S" err)))
     (with-current-buffer "*Messages*"
       (write-region (point-min) (point-max)
                     (expand-file-name "tategaki-scrollbar-gui-tests.log" temporary-file-directory)))
     (kill-emacs status))))
