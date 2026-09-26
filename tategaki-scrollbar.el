;;; tategaki-scrollbar.el --- Horizontal document navigation -*- lexical-binding: t; -*-

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
;; The document is laid out right to left.  This window-local display track
;; scrolls logical columns, rather than Emacs's unrelated source hscroll.

;;; Code:
(require 'cl-lib)
(require 'svg)

(defgroup tategaki-scrollbar nil
  "Horizontal navigation in the vertical editor." :group 'tategaki)
(defcustom tategaki-scrollbar t
  "Show a draggable document scrollbar below the vertical text."
  :type 'boolean :group 'tategaki-scrollbar)
(defcustom tategaki-scrollbar-pixel-height 18
  "Scrollbar height in graphical displays, in logical pixels."
  :type 'natnum :group 'tategaki-scrollbar)
(defface tategaki-scrollbar-track '((t (:inherit shadow)))
  "Color of the scrollbar track." :group 'tategaki-scrollbar)
(defface tategaki-scrollbar-thumb '((t (:inherit font-lock-keyword-face)))
  "Color of the scrollbar thumb." :group 'tategaki-scrollbar)

(defvar tategaki-mode)
(defvar tategaki--layout)
(defvar tategaki--page)
(defvar tategaki--page-size)
(defvar tategaki--scroll-start)
(defvar tategaki--preview-kind)
(defvar tategaki--page-goal)
(defvar tategaki--goal-row)
(declare-function tategaki-refresh "tategaki" ())
(declare-function tategaki--entry "tategaki" (&optional position))
(declare-function tategaki--goto-cell "tategaki" (column row))
(declare-function tategaki--vertical-space "tategaki" (size graphic))
(declare-function tategaki-completion-dismiss-copilot "tategaki-completion" ())
(declare-function tategaki-glyph--color "tategaki-glyph" (value fallback frame))

(defun tategaki-scrollbar-height (window)
  "Return reserved height for the scrollbar in WINDOW, or zero."
  (if (not tategaki-scrollbar) 0
    (if (display-graphic-p (window-frame window))
        (+ 4 (max 12 tategaki-scrollbar-pixel-height
                  (frame-char-height (window-frame window))))
      1)))

(defun tategaki-scrollbar--geometry (width total visible first)
  "Return track/thumb geometry for WIDTH and TOTAL/VISIBLE/FIRST columns."
  (let* ((button (min 18 (/ width 5)))
         (track (max 1 (- width (* 2 button))))
         (total (max 1 total))
         (maximum (max 0 (- total visible)))
         (thumb (min track (max 10 (round (* track (/ (float visible) total))))))
         (travel (- track thumb))
         (x (+ button (if (zerop maximum) 0
                        (round (* travel (- 1 (/ (float (min first maximum)) maximum))))))))
    (list :width width :button button :track track :thumb thumb
          :travel travel :x x :maximum maximum)))

(defun tategaki-scroll-to-column (column)
  "Show COLUMN at the right edge, clamping point into the visible columns."
  (interactive "nRightmost column (from zero): ")
  (unless tategaki-mode (user-error "Vertical editing is not active"))
  (tategaki-refresh)
  (when (eq tategaki--preview-kind 'ime)
    (user-error "Finish the current IME conversion before scrolling"))
  (when (eq tategaki--preview-kind 'copilot)
    (tategaki-completion-dismiss-copilot)
    (tategaki-refresh))
  (let* ((total (plist-get tategaki--layout :columns))
         (entry (tategaki--entry))
         (start (max 0 (min column (max 0 (- total tategaki--page-size))))))
    (setq tategaki--scroll-start start tategaki--page-goal nil tategaki--goal-row nil)
    (tategaki--goto-cell (max start (min (aref entry 3) (+ start tategaki--page-size -1)))
                        (aref entry 2))
    (tategaki-refresh)))

(defun tategaki-scroll-left (&optional count)
  "Scroll COUNT columns toward the end of the document (left)."
  (interactive "p")
  (tategaki-refresh)
  (tategaki-scroll-to-column (+ tategaki--page (or count 1))))

(defun tategaki-scroll-right (&optional count)
  "Scroll COUNT columns toward the beginning of the document (right)."
  (interactive "p")
  (tategaki-scroll-left (- (or count 1))))

(defvar tategaki-scrollbar-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'tategaki-scrollbar-drag)
    (define-key map [mouse-1] #'ignore)
    (define-key map [drag-mouse-1] #'ignore)
    (define-key map [wheel-left] #'tategaki-scroll-left)
    (define-key map [wheel-right] #'tategaki-scroll-right)
    map))

(defun tategaki-scrollbar--column-at (x geometry offset)
  "Map pointer X to a start column using GEOMETRY and drag OFFSET."
  (let ((travel (plist-get geometry :travel)))
    (if (<= travel 0) 0
      (round (* (plist-get geometry :maximum)
                (- 1 (max 0.0 (min 1.0 (/ (- x (plist-get geometry :button) offset)
                                            (float travel))))))))))

(defun tategaki-scrollbar-drag (event)
  "Click or drag the bottom scrollbar in EVENT's window."
  (interactive "e")
  (let* ((position (event-start event)) (window (posn-window position)))
    (when (window-live-p window)
      (select-window window)
      (let* ((object (posn-string position))
             (geometry (and object (get-text-property (cdr object) 'tategaki-scrollbar
                                                     (car object))))
             (scale (or (plist-get geometry :coordinate-scale) 1))
             (x (/ (float (car (posn-x-y position))) scale))
             (thumb (plist-get geometry :thumb))
             (left (plist-get geometry :x)))
        (when geometry
          (cond
           ((< x (plist-get geometry :button)) (tategaki-scroll-left))
           ((>= x (- (plist-get geometry :width) (plist-get geometry :button)))
            (tategaki-scroll-right))
           (t
            (let ((offset (if (<= left x (+ left thumb)) (- x left) (/ thumb 2.0)))
                  next done)
              (tategaki-scroll-to-column (tategaki-scrollbar--column-at x geometry offset))
              (track-mouse
                (while (not done)
                  (setq next (read-event))
                  (cond
                   ((mouse-movement-p next)
                    (let ((end (event-end next)))
                      (when (eq (posn-window end) window)
                        (tategaki-scroll-to-column
                         (tategaki-scrollbar--column-at
                          (/ (float (car (posn-x-y end))) scale) geometry offset))
                        (redisplay))))
                   ((memq (car-safe next) '(mouse-1 drag-mouse-1)) (setq done t))
                   (t (setq done t unread-command-events
                            (cons next unread-command-events))))))))))))))

(defun tategaki-scrollbar-append (display window content-height)
  "Append a bottom-aligned track to DISPLAY in WINDOW after CONTENT-HEIGHT."
  (if (not tategaki-scrollbar) display
    (let* ((frame (window-frame window)) (graphic (display-graphic-p frame))
           (svg-p (and graphic (image-type-available-p 'svg)))
           (height (if graphic (max 12 tategaki-scrollbar-pixel-height
                                     (frame-char-height frame)) 1))
           (width (max 1 (- (window-body-width window svg-p)
                            (if svg-p (* 2 (frame-char-width frame)) 2))))
           (geometry (tategaki-scrollbar--geometry
                      width (plist-get tategaki--layout :columns)
                      tategaki--page-size tategaki--page))
           (padding (max 0 (- (window-body-height window graphic) content-height height
                               (if graphic 2 0))))
           (track-color (if svg-p (tategaki-glyph--color
                                   (face-foreground 'tategaki-scrollbar-track frame t) "#888888" frame)))
           (thumb-color (if svg-p (tategaki-glyph--color
                                   (face-foreground 'tategaki-scrollbar-thumb frame t) "#4488bb" frame)))
           (bar
            (if svg-p
                (let ((svg (svg-create width height)))
                  (svg-rectangle svg (plist-get geometry :button) (- (/ height 2.0) 2)
                                 (plist-get geometry :track) 4 :fill track-color :rx 2)
                  (svg-rectangle svg (plist-get geometry :x) 2 (plist-get geometry :thumb)
                                 (- height 4) :fill thumb-color :rx 4)
                  (svg-polygon svg `((2 . ,(/ height 2)) (10 . 3) (10 . ,(- height 3)))
                               :fill thumb-color)
                  (svg-polygon svg `((,(- width 2) . ,(/ height 2)) (,(- width 10) . 3)
                                    (,(- width 10) . ,(- height 3))) :fill thumb-color)
                  (propertize " " 'display (svg-image svg :ascent 0)))
              (let ((text (make-string width ?-)))
                (dotimes (i (plist-get geometry :thumb))
                  (aset text (min (1- width) (+ (plist-get geometry :x) i)) ?=))
                (aset text 0 ?<) (aset text (1- width) ?>) text))))
      ;; Native events use pixels even when a GUI without SVG paints the
      ;; track with character cells.  Keep the coordinate conversion explicit.
      (setq geometry (plist-put geometry :coordinate-scale
                                (if (and graphic (not svg-p)) (frame-char-width frame) 1)))
      (add-text-properties 0 (length bar)
                           (list 'keymap tategaki-scrollbar-map 'pointer 'hand
                                 'tategaki-scrollbar geometry 'mouse-face 'highlight
                                 'help-echo "横スクロール：左が文末・右が文頭。クリック／ドラッグで移動") bar)
      ;; The separator must share the image rows' explicit line height;
      ;; its default font ascent otherwise shifts the native cursor.
      (propertize (concat display "\n" (tategaki--vertical-space padding graphic) bar)
                  'line-height t 'line-spacing 0))))

(provide 'tategaki-scrollbar)
;;; tategaki-scrollbar.el ends here
