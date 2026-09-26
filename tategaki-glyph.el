;;; tategaki-glyph.el --- Pixel sized cells for vertical typesetting -*- lexical-binding: t; -*-

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

;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; Render an immutable typesetting unit as a display string.  SVG gives
;; rotated runs, ruby and ornaments explicit pixel bounds; the original
;; document never acquires image or composition properties.  Without SVG,
;; all original characters remain visible as native text.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'image)
(require 'svg nil t)

(defgroup tategaki-glyph nil
  "Rendering of vertical typesetting cells."
  :group 'text)

(defcustom tategaki-glyph-cache-limit 2048
  "Maximum SVG images retained by the typesetting renderer.
Zero disables this cache.  Emacs also maintains its own image cache."
  :type 'natnum
  :group 'tategaki-glyph)

(defcustom tategaki-glyph-use-svg t
  "Use SVG images for typesetting when supported by this Emacs."
  :type 'boolean
  :group 'tategaki-glyph)

(defvar tategaki-glyph--cache (make-hash-table :test #'equal))
(defvar tategaki-glyph--cache-order nil)
(defvar tategaki-glyph--style-cache nil
  "Optional face-resolution cache, dynamically bound for a single repaint.")

;;;###autoload
(defun tategaki-glyph-clear-cache ()
  "Discard the renderer's cached images."
  (interactive)
  (maphash (lambda (_ image)
             (when (and (consp image) (fboundp 'image-flush))
               (ignore-errors (image-flush image))))
           tategaki-glyph--cache)
  (clrhash tategaki-glyph--cache)
  (setq tategaki-glyph--cache-order nil))

(defun tategaki-glyph--face-value (face attribute frame)
  "Resolve ATTRIBUTE from FACE on FRAME, falling back to the default face."
  (let ((faces (cond ((symbolp face) (list face))
                     ((keywordp (car-safe face)) (list face))
                     (t face)))
        value)
    (while (and faces (not value))
      (let* ((item (pop faces))
             (candidate (if (listp item) (plist-get item attribute)
                          (and (facep item)
                               (face-attribute item attribute frame t)))))
        (unless (memq candidate '(nil unspecified)) (setq value candidate))))
    (or value (face-attribute 'default attribute frame t))))

(defun tategaki-glyph--color (value fallback frame)
  "Convert Emacs color VALUE to SVG hexadecimal, or use FALLBACK."
  (let ((rgb (and (stringp value) (ignore-errors (color-values value frame)))))
    ;; A terminal frame quantizes even explicit hex colors to its palette.
    ;; Preserve their precise values in exported SVG irrespective of frame.
    (when (and (stringp value)
               (string-match "\\`#\\([[:xdigit:]]+\\)\\'" value)
               (memq (length (match-string 1 value)) '(3 6 9 12)))
      (let* ((digits (match-string 1 value))
             (count (/ (length digits) 3))
             (maximum (1- (expt 16 count))))
        (setq rgb
              (cl-loop for channel from 0 below 3
                       collect (round (* 65535.0
                                         (/ (float (string-to-number
                                                    (substring digits (* channel count)
                                                               (* (1+ channel) count)) 16))
                                            maximum)))))))
    (if rgb
        (apply #'format "#%02x%02x%02x"
               (mapcar (lambda (channel) (/ channel 257)) rgb))
      fallback)))

(defun tategaki-glyph--style (face frame)
  "Return resolved SVG styling from FACE on FRAME."
  (if (not tategaki-glyph--style-cache)
      (tategaki-glyph--resolve-style face frame)
    (let ((key (cons frame face)))
      (or (gethash key tategaki-glyph--style-cache)
          (puthash key (tategaki-glyph--resolve-style face frame)
                   tategaki-glyph--style-cache)))))

(defun tategaki-glyph--resolve-style (face frame)
  "Resolve FACE's SVG attributes on FRAME without a cache."
  (let ((style (list :foreground (tategaki-glyph--color
                     (tategaki-glyph--face-value face :foreground frame) "#000000" frame)
        :background (tategaki-glyph--color
                     (tategaki-glyph--face-value face :background frame) "#ffffff" frame)
        :family (let ((family (tategaki-glyph--face-value face :family frame)))
                  (if (stringp family) family "sans-serif"))
        :weight (tategaki-glyph--face-value face :weight frame)
        :slant (tategaki-glyph--face-value face :slant frame)
        :underline (tategaki-glyph--face-value face :underline frame))))
    (let* ((underline (plist-get style :underline))
           (color (cond ((stringp underline) underline)
                        ((listp underline) (plist-get underline :color)))))
      (when color
        (setq style (plist-put style :underline-color
                               (tategaki-glyph--color color (plist-get style :foreground) frame)))))
    (when (eq t (tategaki-glyph--face-value face :inverse-video frame))
      (let ((foreground (plist-get style :foreground)))
        (setq style (plist-put style :foreground (plist-get style :background)))
        (setq style (plist-put style :background foreground))))
    style))

(defun tategaki-glyph--emoji-p (text)
  "Whether TEXT needs a color emoji font for multi-character shaping."
  (and (stringp text)
       (cl-some (lambda (char)
                  (or (= char #x200d) (= char #xfe0f)
                      (<= #x1f000 char #x1faff)))
                (string-to-list text))))

(defun tategaki-glyph--emoji-family (frame)
  "Return an available color emoji font family for FRAME."
  (let ((families (font-family-list frame)))
    (cl-find-if (lambda (family) (member family families))
                '("Apple Color Emoji" "Noto Color Emoji" "Segoe UI Emoji"))))

(defun tategaki-glyph--svg-text (svg text x y size style &rest attributes)
  "Add TEXT to SVG at X,Y with SIZE and STYLE plus ATTRIBUTES."
  (apply #'svg-text svg text
         :x x :y y :font-size size
         :font-family (plist-get style :family)
         :font-weight (if (memq (plist-get style :weight)
                               '(bold semi-bold extra-bold ultra-bold)) "bold" "normal")
         :font-style (if (memq (plist-get style :slant) '(italic oblique))
                         "italic" "normal")
         :fill (plist-get style :foreground)
         :text-anchor "middle"
         attributes))

(defun tategaki-glyph--svg (unit width height style grid)
  "Build the SVG document for UNIT in WIDTH by HEIGHT pixel cells."
  (let* ((span (max 1 (or (plist-get unit :span) 1)))
         (full-height (round (* height span)))
         ;; A hanging mark occupies half a cell, but its type remains the
         ;; same size as the preceding body text.  Keep those two dimensions
         ;; separate instead of shrinking the punctuation to fit its advance.
         (font-height (or (plist-get unit :font-height) height))
         (kind (plist-get unit :kind))
         (text (or (plist-get unit :display-text) (plist-get unit :text) ""))
         (ruby (plist-get unit :ruby))
         (emphasis (plist-get unit :emphasis))
         (body-width (min width (or (plist-get unit :body-width)
                                    (- width
                                       (if (or (and ruby (not (equal ruby ""))) emphasis)
                                           (* width 0.35) 0)))))
         (gutter (min (- width body-width)
                      (or (plist-get unit :annotation-width) (- width body-width))))
         (compression (plist-get unit :compression))
         (factor (if (numberp compression) (max 0.5 (min 1.0 compression))
                   (if compression 0.9 1.0)))
         (size (* factor (min (* font-height 0.80) (* body-width 0.92))))
         (svg (svg-create width full-height)))
    (svg-rectangle svg 0 0 width full-height :fill (plist-get style :background))
    (cond
     ((eq kind 'latin)
      (let ((font-size (* factor (min (* body-width 0.78)
                                     (/ (* full-height 0.92)
                                        (max 1 (* 0.60 (length text))))))))
        (tategaki-glyph--svg-text
         svg text 0 (* font-size 0.34) font-size style
         :transform (format "translate(%s %s) rotate(90)"
                            (/ body-width 2.0) (/ full-height 2.0)))))
     ((eq kind 'tcy)
      (let ((font-size (* factor (min (* height 0.76)
                                     (/ (* body-width 0.90)
                                        (max 1 (* 0.60 (length text))))))))
        (tategaki-glyph--svg-text svg text (/ body-width 2.0)
                                (+ (/ height 2.0) (* font-size 0.34))
                                font-size style)))
     (t
      (tategaki-glyph--svg-text svg text (/ body-width 2.0)
                              (+ (/ font-height 2.0) (* size 0.34)
                                 ;; Vertical comma/full stop glyphs already
                                 ;; use the upper half of the em square.
                                 ;; Unsubstituted punctuation uses the lower
                                 ;; half; lift it so the half-cell does not
                                 ;; clip the original, full-sized mark.
                                 (if (and (plist-get unit :hanging)
                                          (not (member text '("︐" "︑" "︒"))))
                                     (- (/ font-height 2.0)) 0))
                              size style)))
    (when (and ruby (not (equal ruby "")))
      (let* ((characters (or (plist-get unit :ruby-graphemes)
                             (mapcar #'char-to-string (string-to-list ruby))))
             (step (/ (float full-height) (max 1 (length characters))))
             ;; Ruby and emphasis occupy distinct lanes when combined.
             (ruby-size (min (* gutter (if emphasis 0.58 0.88)) (* step 0.88)))
             (index 0))
        (dolist (char characters)
          (tategaki-glyph--svg-text
           svg char (+ body-width (* gutter (if emphasis 0.36 0.5)))
           (+ (* step (+ index 0.5)) (* ruby-size 0.34)) ruby-size style)
          (setq index (1+ index)))))
    (when (eq emphasis 'dot)
      (dotimes (row span)
        (svg-circle svg (+ body-width (* gutter 0.85)) (* height (+ row 0.5))
                    (max 1 (* width 0.035)) :fill (plist-get style :foreground))))
    (when (or (eq emphasis 'line) (plist-get style :underline))
      (let* ((underline (plist-get style :underline))
             (color (or (plist-get style :underline-color) (plist-get style :foreground)))
             (x (min (- width 1) (+ body-width (* gutter 0.9))))
             (top (* height 0.12)) (bottom (- full-height (* height 0.12))))
        (if (eq (and (listp underline) (plist-get underline :style)) 'wave)
            (svg-polyline svg
                          (cl-loop for y from (ceiling top) to (floor bottom) by 2
                                   for index from 0
                                   collect (cons (+ x (if (cl-evenp index) -1 0)) y))
                          :fill "none" :stroke color :stroke-width 1)
          (svg-line svg x top x bottom :stroke color :stroke-width 1))))
    (when grid
      (let ((color (if (stringp grid) grid "#cccccc")))
        (svg-rectangle svg 0.5 0.5 (max 0 (- body-width 1)) (max 0 (- full-height 1))
                       :fill "none" :stroke color :stroke-width 1)
        (dotimes (index (1- span))
          (svg-line svg 0 (round (* height (1+ index))) body-width (round (* height (1+ index)))
                    :stroke color :stroke-width 1))))
    svg))

(defun tategaki-glyph--remember (key image)
  "Store IMAGE under KEY, evicting the oldest entry as necessary."
  (when (> tategaki-glyph-cache-limit 0)
    (puthash key image tategaki-glyph--cache)
    (push key tategaki-glyph--cache-order)
    (while (> (hash-table-count tategaki-glyph--cache) tategaki-glyph-cache-limit)
      (let* ((old-key (car (last tategaki-glyph--cache-order)))
             (old-image (gethash old-key tategaki-glyph--cache)))
        (setq tategaki-glyph--cache-order (butlast tategaki-glyph--cache-order))
        (remhash old-key tategaki-glyph--cache)
        (when (fboundp 'image-flush) (ignore-errors (image-flush old-image))))))
  image)

(defun tategaki-glyph--trim-cache ()
  "Apply a reduced or disabled cache limit immediately."
  (while (> (hash-table-count tategaki-glyph--cache)
            (max 0 tategaki-glyph-cache-limit))
    (let* ((key (car (last tategaki-glyph--cache-order)))
           (image (gethash key tategaki-glyph--cache)))
      (setq tategaki-glyph--cache-order (butlast tategaki-glyph--cache-order))
      (remhash key tategaki-glyph--cache)
      (when (fboundp 'image-flush) (ignore-errors (image-flush image))))))

(defun tategaki-glyph--native (unit width height ascent face frame)
  "Render UNIT as native text, retaining all characters without SVG.
Shaping and emoji color depend on the host Emacs font backend.  Fallbacks
use horizontal text in a cell when rotation or ruby is unavailable."
  (let* ((body-width (min width (or (plist-get unit :body-width) width)))
         (text (or (plist-get unit :display-text) (plist-get unit :text) ""))
         (ruby (plist-get unit :ruby))
         (text (if (and ruby (not (equal ruby "")))
                   (concat text "(" ruby ")") text))
         (default-height (face-attribute 'default :height frame t))
         (font-height (if (numberp default-height) default-height 120))
         (face (list (list :height (max 10 (round (* font-height
                                                   (/ (float height)
                                                      (max 1 (frame-char-height frame))))))) face))
         (body (propertize (if (equal text "") " " text) 'face face))
         (pixels (if (and (display-graphic-p frame) (fboundp 'string-pixel-width))
                     (max 1 (string-pixel-width body))
                   (* (max 1 (string-width text)) (frame-char-width frame)))))
    (when (> pixels body-width)
      (setcar (cdr (car face))
              (max 10 (floor (* (cadr (car face)) (/ (float body-width) pixels)))))
      (setq pixels (if (and (display-graphic-p frame) (fboundp 'string-pixel-width))
                       (max 1 (string-pixel-width body)) width)))
    (let* ((left (max 0 (/ (- body-width pixels) 2)))
           (right (max 0 (- width pixels left)))
           (spacer (lambda (pixels)
                     (propertize " " 'display
                                 `(space :width (,pixels) :height (,height)
                                         :ascent (,ascent))))))
      (concat (funcall spacer left) body (funcall spacer right)))))

;;;###autoload
(defun tategaki-glyph-render (unit width height ascent face &optional frame grid)
  "Render UNIT as a display string within WIDTH by HEIGHT pixel cells.
UNIT is a plist with :text, :kind and positive integer :span.  Optional
:ruby and :emphasis (`dot' or `line') reserve a right gutter inside WIDTH.
For a half-cell hanging mark, :font-height retains the normal body cell
height and :hanging aligns its ink inside the shorter image.
Latin runs are rotated clockwise over :span cells.  FACE supplies colors
and font; ASCENT is the row ascent in pixels.  FRAME defaults to selected.
GRID is nil, t for gray, or a color string.

The SVG path returns a single-character string.  Its image occupies
WIDTH by (:span * HEIGHT) pixels.  Use `tategaki-glyph-slice-pixels' to
place the image across display rows.  Native fallback text is lossless."
  (unless (and (numberp width) (> width 0) (numberp height) (> height 0))
    (signal 'wrong-type-argument (list 'positive-pixel-dimensions width height)))
  (unless (and (integerp (or (plist-get unit :span) 1))
               (> (or (plist-get unit :span) 1) 0))
    (signal 'wrong-type-argument (list 'positive-integer-p (plist-get unit :span))))
  (tategaki-glyph--trim-cache)
  (setq frame (or frame (selected-frame))
        width (max 1 (round width)))
  (let* ((span (max 1 (or (plist-get unit :span) 1)))
         ;; Round the whole run once.  Rounding each row before multiplying
         ;; can lose a pixel at the last slice when character gaps compress.
         (full-height (max 1 (round (* height span))))
         (height (/ (float full-height) span))
         (ratio (max 0 (min 100 (round (* 100 (/ (float ascent) height))))))
         (style (tategaki-glyph--style face frame))
         (_emoji-font (when (tategaki-glyph--emoji-p (plist-get unit :text))
                        (when-let* ((family (tategaki-glyph--emoji-family frame)))
                          (setq style (plist-put (copy-sequence style) :family family)))))
         (svg-p (and tategaki-glyph-use-svg (fboundp 'svg-image)
                     (image-type-available-p 'svg)))
         (key (list (mapcar (lambda (property) (plist-get unit property))
                            '(:text :display-text :kind :span :ruby :ruby-graphemes :emphasis
                              :body-width :annotation-width :compression
                              :font-height :hanging))
                    width height ratio style grid))
         (image (and svg-p
                     (or (gethash key tategaki-glyph--cache)
                         (condition-case nil
                             (tategaki-glyph--remember
                              key (svg-image (tategaki-glyph--svg unit width height style grid)
                                             :ascent ratio :scale 1))
                           (error nil)))))
         (result (if image (propertize " " 'display (copy-tree image))
                   (tategaki-glyph--native unit width height ascent face frame))))
    (add-text-properties
     0 (length result)
     (list 'tategaki-glyph-width width 'tategaki-glyph-height full-height
           'tategaki-glyph-row-height height 'tategaki-glyph-ascent-ratio ratio
           'tategaki-glyph-image image 'tategaki-glyph-text (plist-get unit :text)
           'rear-nonsticky t) result)
    result))

(defun tategaki-glyph-slice-pixels (string y height)
  "Return the slice of rendered STRING starting at pixel Y, of HEIGHT.
SVG slices remain one-character display strings.  Native fallback returns
the text only for its first slice; later slices are exact-size spacers.
Fractional pixel boundaries are rounded to the nearest integer.  Emacs
interprets floating-point `slice' coordinates as proportions, not pixels."
  (let* ((width (get-text-property 0 'tategaki-glyph-width string))
         (full-height (get-text-property 0 'tategaki-glyph-height string))
         (ratio (or (get-text-property 0 'tategaki-glyph-ascent-ratio string) 80))
         (image (get-text-property 0 'tategaki-glyph-image string)))
    (unless (and width full-height (numberp y) (>= y 0)
                 (numberp height) (> height 0))
      (signal 'args-out-of-range (list y height full-height)))
    (let ((end (round (+ y height))))
      (setq y (round y) height (- end (round y))))
    (unless (and (> height 0) (<= (+ y height) full-height))
      (signal 'args-out-of-range (list y height full-height)))
    (let ((result
           (cond
            (image
             (let ((spec (copy-tree image)))
               (setcdr spec (plist-put (cdr spec) :ascent ratio))
               (propertize " " 'display (list (list 'slice 0 y width height) spec))))
            ((zerop y) (copy-sequence string))
            (t (propertize " " 'display
                           `(space :width (,width) :height (,height)
                                   :ascent ,ratio))))))
      (add-text-properties 0 (length result)
                           (list 'tategaki-glyph-width width
                                 'tategaki-glyph-height height
                                 'tategaki-glyph-text (get-text-property 0 'tategaki-glyph-text string)
                                 'rear-nonsticky t) result)
      result)))

(defun tategaki-glyph-slice (string row row-height)
  "Return ROW of rendered STRING, using ROW-HEIGHT pixels per row."
  (tategaki-glyph-slice-pixels string (* row row-height) row-height))

(provide 'tategaki-glyph)
;;; tategaki-glyph.el ends here
