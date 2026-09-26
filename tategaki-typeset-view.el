;;; tategaki-typeset-view.el --- Visible-page compositor -*- lexical-binding: t; -*-

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
;; Only visible units become images.  Shared scanline boundaries let cells
;; span multiple rows, compress or hang without changing the source buffer.

;;; Code:
(require 'cl-lib)
(require 'tategaki-typeset)
(require 'tategaki-glyph)
(require 'tategaki-highlight)
(require 'tategaki-manuscript)

(defvar tategaki-padding-top)
(defvar tategaki-padding-bottom)
(defvar tategaki-padding-left)
(defvar tategaki-padding-right)
(defvar tategaki-column-height)
(defvar tategaki-column-spacing)
(defvar tategaki-line-spacing)
(defvar tategaki-character-spacing)
(defvar tategaki--metrics)
(defvar tategaki--layout)
(defvar tategaki--page)
(defvar tategaki--page-size)
(defvar tategaki--caret-position)
(defvar tategaki--pixel-positions)
(defvar tategaki--preedit-text)
(defvar tategaki--preedit-length)
(defvar tategaki--preview-kind)
(declare-function tategaki--entry "tategaki" (&optional position))
(declare-function tategaki--fit-padding "tategaki" (before after limit))
(declare-function tategaki--spacer "tategaki" (width height ascent))
(declare-function tategaki--vertical-space "tategaki" (size graphic))
(declare-function tategaki--install-display "tategaki" (display window &optional content-height))
(declare-function tategaki--page-start "tategaki" (column capacity))
(declare-function tategaki-scrollbar-height "tategaki-scrollbar" (window))
(declare-function tategaki--source-position "tategaki" (position))
(declare-function tategaki--preedit-index "tategaki" (position))
(declare-function tategaki--face-list "tategaki" (face))
(declare-function tategaki-ime-set-panel-offset "tategaki-ime" (x y))

(defun tategaki-typeset-view-available-p (window)
  "Whether WINDOW can show exact composed cells and image slices."
  (and (display-graphic-p (window-frame window)) tategaki-glyph-use-svg
       (image-type-available-p 'svg)))

(defun tategaki-typeset-view-geometry (window metrics)
  "Return fitted page dimensions for WINDOW and font METRICS.
Fixed manuscripts scale the display, never the number of cells per page."
  (let* ((frame (window-frame window))
         (unit (frame-char-width frame))
         (body (nth 1 metrics)) (row-height (nth 2 metrics))
         (gutter (ceiling (* 0.5 body)))
         (cell (+ body gutter))
         (width (max 1 (- (window-body-width window t) (* 2 unit))))
         (height (max 1 (- (window-body-height window t)
                           (tategaki-scrollbar-height window))))
         (hp (tategaki--fit-padding tategaki-padding-left tategaki-padding-right
                                   (- width cell)))
         (vp (tategaki--fit-padding tategaki-padding-top tategaki-padding-bottom
                                   (- height (* 2 row-height))))
         (inner-width (- width (car hp) (cdr hp)))
         (inner-height (- height (car vp) (cdr vp)))
         (gap (max 0 (or tategaki-line-spacing (* unit tategaki-column-spacing))))
         (character-gap (max 0 tategaki-character-spacing))
         (paper (tategaki-manuscript-config))
         (paper-columns (plist-get paper :columns))
         (spread (if (and paper-columns (plist-get paper :spread)) 2 1))
         (paper-gap (if (> spread 1) cell 0))
         (rows (or (plist-get paper :rows)
                   (min (or tategaki-column-height most-positive-fixnum)
                        (max 1 (1- (floor (/ (+ inner-height character-gap)
                                             (float (+ row-height character-gap)))))))))
         (capacity (if paper-columns (* paper-columns spread)
                     (max 1 (floor (/ (+ inner-width gap) (float (+ cell gap)))))))
         (scale (if paper-columns
                    (min 1.0 (/ (float inner-width)
                                (+ (* capacity cell) (* (1- capacity) gap) paper-gap))
                         (/ (float inner-height)
                            ;; Half a cell remains available for hanging marks.
                            (+ (* (+ rows 0.5) row-height) (* rows character-gap))))
                  1.0)))
    (setq body (max 1 (floor (* body scale)))
          gutter (max 1 (floor (* gutter scale)))
          cell (+ body gutter)
          row-height (max 1 (floor (* row-height scale)))
          gap (min (max 0 (- inner-width cell)) (floor (* gap scale)))
          character-gap (min (max 0 (- inner-height row-height))
                             (floor (* character-gap scale)))
          paper-gap (floor (* paper-gap scale)))
    (let ((used (+ (* capacity cell) (* (1- capacity) gap) paper-gap)))
      (list :cell cell :body body :gutter gutter :gap gap :pitch (+ cell gap)
            :row-height row-height :row-pitch (+ row-height character-gap)
            :ascent (max 1 (floor (* (nth 3 metrics) scale)))
            :character-gap character-gap :capacity capacity :rows rows
            :paper-columns paper-columns :paper-gap paper-gap :scale scale
            :left (+ (car hp) (max 0 (- inner-width used)))
            :top (car vp) :bottom (cdr vp)))))

(defun tategaki-typeset-view--face (unit window)
  "Resolve UNIT's preview, selection, search, cursor and source faces."
  (let* ((start (plist-get unit :start)) (end (plist-get unit :end))
         (source-start (tategaki--source-position start))
         (source-end (tategaki--source-position end))
         (preedit (tategaki--preedit-index start))
         (selected (and (use-region-p)
                        (< source-start (region-end)) (> source-end (region-beginning))))
         (caret (or (and (<= start tategaki--caret-position)
                         (< tategaki--caret-position end))
                    (and (= start end) (= start tategaki--caret-position)))))
    (append (cond (preedit
                   (append (tategaki--face-list
                            (get-text-property preedit 'face tategaki--preedit-text))
                           (if (eq tategaki--preview-kind 'ime)
                               '(tategaki-preedit-face) '(shadow))))
                  (selected '(region)))
            (unless preedit (tategaki-highlight-faces source-start source-end window))
            (when caret '(tategaki-cursor-face))
            (when (memq (plist-get unit :kind) '(newline eof)) '(tategaki-layout-control-face))
            '(tategaki-face))))

(defun tategaki-typeset-view--slice (picture offset height)
  "Slice PICTURE at OFFSET for HEIGHT with the scanline's common baseline."
  (let* ((piece (tategaki-glyph-slice-pixels picture offset height))
         (display (get-text-property 0 'display piece))
         (image (and (eq (car-safe (car-safe display)) 'slice) (cadr display))))
    ;; All spacers extend below the baseline.  Mixed image/spacer ascents
    ;; otherwise add together and double each physical row's height.
    (when (eq (car-safe image) 'image)
      (setcdr image (plist-put (cdr image) :ascent 0)))
    piece))

(defun tategaki-typeset-view-paint (window)
  "Compose the visible page's cells into exact scanlines in WINDOW."
  (let* ((geometry (tategaki-typeset-view-geometry window tategaki--metrics))
         (capacity (plist-get geometry :capacity))
         (entry (tategaki--entry))
         (column (aref entry 3))
         (cell (plist-get geometry :cell))
         (pitch (plist-get geometry :pitch))
         (row-pitch (plist-get geometry :row-pitch))
         (row-height (plist-get geometry :row-height))
         (ascent (plist-get geometry :ascent))
         (top (plist-get geometry :top))
         (paper-columns (plist-get geometry :paper-columns))
         (grid (and paper-columns tategaki-manuscript-grid))
         (columns (make-vector capacity nil))
         (boundaries (list 0))
         (right-edge 0) rows)
    (setq tategaki--page-size capacity
          tategaki--page (tategaki--page-start column capacity)
          tategaki--pixel-positions (make-hash-table :test #'eql))
    (dolist (item (tategaki-typeset-visible tategaki--layout tategaki--page capacity))
      (let* ((unit (copy-sequence (aref item 4)))
             (start (plist-get unit :start)) (end (plist-get unit :end))
             (span (max 1 (or (plist-get unit :span) 1)))
             (advance (or (plist-get unit :advance) span))
             (y (round (* (aref item 2) row-pitch)))
             (bottom (max (1+ y) (- (round (* (+ (aref item 2) advance) row-pitch))
                                    (round (* (/ (float advance) span)
                                              (plist-get geometry :character-gap))))))
             (visual (- capacity 1 (- (aref item 3) tategaki--page)))
             (x (+ (plist-get geometry :left) (* visual pitch)
                   (if paper-columns (* (/ visual paper-columns) (plist-get geometry :paper-gap)) 0)))
             (face (tategaki-typeset-view--face unit window))
             (caret (or (and (<= start tategaki--caret-position) (< tategaki--caret-position end))
                        (and (= start end) (= start tategaki--caret-position)))))
        (setq unit (plist-put unit :body-width (plist-get geometry :body))
              unit (plist-put unit :annotation-width (plist-get geometry :gutter))
              unit (plist-put unit :font-height
                              (and (plist-get unit :hanging) row-height))
              ;; Geometry already applies compression through :advance.
              ;; Do not shrink the font by that factor a second time.
              unit (plist-put unit :compression nil))
        (let ((picture (tategaki-glyph-render unit cell (/ (float (- bottom y)) span)
                                               ascent face (window-frame window) grid)))
          (push (list :unit unit :start start :end end :y y :bottom bottom
                      :x x :picture picture :caret caret :face face :row (aref item 2)
                      :column (aref item 3))
                (aref columns visual)))
        (puthash start (list :x x :y (+ top y) :width cell :height (- bottom y))
                 tategaki--pixel-positions)
        (when caret
          (puthash tategaki--caret-position (gethash start tategaki--pixel-positions)
                   tategaki--pixel-positions))
        (push y boundaries) (push bottom boundaries)
        (setq right-edge (max right-edge bottom))))
    ;; Paper includes empty cells, but an adaptive page paints only its text.
    (when paper-columns
      (dotimes (row (plist-get geometry :rows))
        (push (* row row-pitch) boundaries)
        (push (+ (* row row-pitch) row-height) boundaries))
      (setq right-edge (max right-edge (- (* (plist-get geometry :rows) row-pitch)
                                         (plist-get geometry :character-gap)))))
    (push right-edge boundaries)
    (setq boundaries (sort (delete-dups boundaries) #'<))
    (dotimes (index capacity)
      (aset columns index (sort (aref columns index)
                                (lambda (a b) (< (plist-get a :y) (plist-get b :y))))))
    (while (cdr boundaries)
      (let* ((y (pop boundaries)) (bottom (car boundaries)) (height (- bottom y)) parts)
        (dotimes (visual capacity)
          (let* ((items (aref columns visual))
                 (x (+ (plist-get geometry :left) (* visual pitch)
                       (if paper-columns (* (/ visual paper-columns) (plist-get geometry :paper-gap)) 0)))
                 (previous-x (if (zerop visual) 0
                               (+ (plist-get geometry :left) (* (1- visual) pitch) cell
                                  (if paper-columns (* (/ (1- visual) paper-columns)
                                                       (plist-get geometry :paper-gap)) 0)))))
            (while (and items (<= (plist-get (car items) :bottom) y)) (pop items))
            (aset columns visual items)
            (push (tategaki--spacer (- x previous-x) height 0) parts)
            (let* ((item (and items (<= (plist-get (car items) :y) y) (car items)))
                   (piece
                    (if item
                        (tategaki-typeset-view--slice (plist-get item :picture)
                                                     (- y (plist-get item :y)) height)
                      (let* ((grid-row (/ y row-pitch))
                             (offset (- y (* grid-row row-pitch))))
                        (if (and grid (< offset row-height) (< grid-row (plist-get geometry :rows)))
                            (tategaki-typeset-view--slice
                             (tategaki-glyph-render
                              (list :text "" :kind 'glyph :span 1
                                    :body-width (plist-get geometry :body)
                                    :annotation-width (plist-get geometry :gutter))
                              cell row-height ascent '(tategaki-face) (window-frame window) grid)
                             offset height)
                          (tategaki--spacer cell height 0))))))
              (when item
                (let* ((start (plist-get item :start)) (end (plist-get item :end))
                       (caret (and (plist-get item :caret) (= y (plist-get item :y))))
                       (position (if caret tategaki--caret-position start))
                       (preedit (tategaki--preedit-index position)))
                  (add-text-properties
                   0 (length piece)
                   (list 'tategaki-position (tategaki--source-position position)
                         'tategaki-virtual-position position 'tategaki-unit-start start 'tategaki-unit-end end
                         'tategaki-slice-offset (- y (plist-get item :y))
                         'tategaki-unit-height (- (plist-get item :bottom) (plist-get item :y))
                         'tategaki-preedit-index (and (eq tategaki--preview-kind 'ime) preedit)
                         'tategaki-completion-index (and (not (eq tategaki--preview-kind 'ime)) preedit)
                         'tategaki-row (plist-get item :row) 'tategaki-column (plist-get item :column)
                         'face (plist-get item :face) 'mouse-face 'highlight 'cursor caret) piece)))
              (push piece parts))))
        (push (apply #'concat (nreverse parts)) rows)))
    (tategaki--install-display
     (propertize (concat (tategaki--vertical-space top t)
                         (mapconcat #'identity (nreverse rows) "\n"))
                 'line-height t 'line-spacing 0)
     window (+ top right-edge))
    (when (and (eq tategaki--preview-kind 'ime) (> tategaki--preedit-length 0))
      (tategaki-ime-set-panel-offset (+ cell 4) (- (frame-char-height (window-frame window)))))))

(provide 'tategaki-typeset-view)
;;; tategaki-typeset-view.el ends here
