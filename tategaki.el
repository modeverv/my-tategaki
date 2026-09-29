;;; tategaki.el --- Write plain text in vertical columns -*- lexical-binding: t; -*-

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

;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/modeverv/my-tategaki
;; Keywords: text

;;; Commentary:
;; The file buffer remains the actual editing buffer.  A window-scoped
;; display overlay paints a vertical page over it.  Native commands, input
;; methods, undo and saving therefore operate on the original text.

;;; Code:

(require 'cl-lib)
(require 'face-remap)
(require 'tategaki-layout)
(require 'tategaki-ime)
(require 'tategaki-completion)
(require 'tategaki-corfu)
(require 'tategaki-navigation)
(require 'tategaki-highlight)
(require 'tategaki-typeset)
(require 'tategaki-typeset-view)
(require 'tategaki-manuscript)
(require 'tategaki-annotations)
(require 'tategaki-scrollbar)
(require 'tategaki-writing)
(require 'tategaki-outline)
(require 'tategaki-script)

;; Export dependencies are loaded only when explicitly requested.
(autoload 'tategaki-export "tategaki-export" nil t)
(autoload 'tategaki-export-all "tategaki-export" nil t)
(autoload 'tategaki-export-status "tategaki-export" nil t)
(autoload 'tategaki-export-cancel "tategaki-export" nil t)

;; The optional Novel IDE has no cost until a Studio command is requested.
(autoload 'tategaki-studio "tategaki-studio" nil t)
(autoload 'tategaki-studio-mode "tategaki-studio" nil t)
(autoload 'tategaki-settings "tategaki-settings" nil t)
(autoload 'tategaki-session-open-last "tategaki-session" nil t)

(defgroup tategaki nil
  "Edit text through a vertical display layer."
  :group 'text)

(defcustom tategaki-column-height nil
  "Maximum characters in a vertical column, or nil to fit the window."
  :type '(choice (const :tag "Fit window" nil) (integer :tag "Maximum rows"))
  :group 'tategaki)

(defcustom tategaki-column-spacing 1
  "Space between columns in frame character widths.
Used when `tategaki-line-spacing' is nil."
  :type 'natnum
  :group 'tategaki)

(defcustom tategaki-padding-top 0
  "Minimum space above editable text, in GUI pixels or terminal rows.
Padding is reduced in small windows to keep the insertion point visible."
  :type 'natnum :group 'tategaki)

(defcustom tategaki-padding-bottom 0
  "Minimum space below editable text, in GUI pixels or terminal rows.
Padding is reduced in small windows to keep the insertion point visible."
  :type 'natnum :group 'tategaki)

(defcustom tategaki-padding-left 0
  "Minimum space left of editable text, in GUI pixels or terminal cells.
Padding is reduced in small windows to keep the insertion point visible."
  :type 'natnum :group 'tategaki)

(defcustom tategaki-padding-right 0
  "Space right of editable text, in GUI pixels or terminal cells.
This is additional to the renderer's small right-edge safety margin.
Padding is reduced in small windows to keep the insertion point visible."
  :type 'natnum :group 'tategaki)

(defcustom tategaki-line-spacing nil
  "Horizontal gap between vertical columns, in GUI pixels or terminal cells.
Nil uses the existing `tategaki-column-spacing' setting."
  :type '(choice (const :tag "Use column-spacing" nil) natnum)
  :group 'tategaki)

(defcustom tategaki-character-spacing 0
  "Extra vertical gap between characters, in GUI pixels or terminal rows."
  :type 'natnum :group 'tategaki)

(defface tategaki-face '((t (:inherit fixed-pitch)))
  "Face for editable vertical text."
  :group 'tategaki)

(defface tategaki-cursor-face
  '((t (:inherit highlight :underline t)))
  "Face for the character immediately after the insertion point."
  :group 'tategaki)

(defface tategaki-preedit-face
  '((t (:underline t)))
  "Fallback emphasis for uncommitted IME text."
  :group 'tategaki)

(defvar-local tategaki--overlay nil)
(defvar-local tategaki--tail-overlay nil)
(defvar-local tategaki--display-string nil)
(defvar-local tategaki--window nil)
(defvar-local tategaki--window-state nil)
(defvar-local tategaki--saved-locals nil)
(defvar-local tategaki--original-highlight-region nil)
(defvar-local tategaki--layout nil)
(defvar-local tategaki--cache-key nil)
(defvar-local tategaki--metrics nil)
(defvar-local tategaki--font-key nil)
(defvar-local tategaki--font-metrics nil)
(defvar-local tategaki--text-scale-amount 0
  "Number of buffer-local zoom steps for the vertical display only.")
(defvar-local tategaki--text-scale-cookie nil
  "Face remapping owned by the vertical display's zoom commands.")
(defvar-local tategaki--source-key nil)
(defvar-local tategaki--source-text nil)
(defvar-local tategaki--typeset-cache nil)
(defvar-local tategaki--page 0)
(defvar-local tategaki--page-size 1)
(defvar-local tategaki--scroll-start nil
  "First visible column after a scrollbar move, or nil for page navigation.")
(defvar-local tategaki--goal-row nil)
(defvar-local tategaki--page-goal nil
  "Desired (PAGE-SIZE COLUMN-HEIGHT COLUMN-OFFSET) for consecutive page moves.")
(defvar-local tategaki--refreshing nil)
(defvar-local tategaki--preedit-text nil)
(defvar-local tategaki--preedit-start nil)
(defvar-local tategaki--preedit-length 0)
(defvar-local tategaki--preview-end nil)
(defvar-local tategaki--preview-kind nil)
(defvar-local tategaki--pixel-positions nil)
(defvar-local tategaki--caret-position nil
  "Cursor position in the virtual text, including uncommitted IME text.")
(defvar tategaki-mode)

(defcustom tategaki-render-gc-threshold (* 16 1024 1024)
  "Minimum garbage-collection allocation threshold during a vertical refresh.
This bounded, temporary allowance avoids collecting once per few display
cells.  The original threshold is restored after every refresh, including
errors.  Nil retains the caller's threshold."
  :type '(choice (const :tag "Unchanged" nil) natnum)
  :group 'tategaki)

(defun tategaki--save-local (variable value)
  "Set VARIABLE to VALUE locally, recording its original binding."
  (push (list variable (local-variable-p variable) (symbol-value variable))
        tategaki--saved-locals)
  (set (make-local-variable variable) value))

(defun tategaki--restore-window ()
  "Restore display parameters owned by the editing window."
  (when (and (window-live-p tategaki--window) tategaki--window-state)
    (set-window-hscroll tategaki--window (nth 0 tategaki--window-state))
    (set-window-vscroll tategaki--window (nth 1 tategaki--window-state) t))
  (setq tategaki--window-state nil))

(defun tategaki--attach-window (window)
  "Move the display layer to WINDOW, leaving other windows untouched."
  (unless (eq window tategaki--window)
    (tategaki--restore-window)
    (setq tategaki--window window
          tategaki--window-state
          (list (window-hscroll window) (window-vscroll window t))
          tategaki--cache-key nil))
  (overlay-put tategaki--overlay 'window window)
  (overlay-put tategaki--tail-overlay 'window window)
  (unless (eq window tategaki-ime--window)
    (tategaki-ime-sync-window window))
  (unless (eq window tategaki-completion--window)
    (tategaki-completion-sync-window window)))

(defun tategaki--font-signature (window)
  "Return the font configuration affecting cell metrics in WINDOW."
  (let ((frame (window-frame window)))
    (list frame (face-all-attributes 'default frame)
          (face-all-attributes 'fixed-pitch frame)
          (face-all-attributes 'tategaki-face frame) face-remapping-alist)))

(defun tategaki--text-scale-apply ()
  "Apply this buffer's vertical zoom without changing other face remappings."
  (when tategaki--text-scale-cookie
    (face-remap-remove-relative tategaki--text-scale-cookie)
    (setq tategaki--text-scale-cookie nil))
  (unless (zerop tategaki--text-scale-amount)
    (setq tategaki--text-scale-cookie
          (face-remap-add-relative
           'tategaki-face :height
           (expt text-scale-mode-step tategaki--text-scale-amount))))
  ;; Face-remap functions may mutate the lists retained in our cache keys.
  (setq tategaki--font-key nil tategaki--font-metrics nil
        tategaki--cache-key nil
        tategaki--goal-row nil tategaki--page-goal nil
        tategaki--scroll-start nil))

(defun tategaki-text-scale-increase (&optional steps)
  "Enlarge vertical text in this buffer by STEPS (default one).
Negative STEPS shrink the text; zero restores its original size.
Use `text-scale-mode-step' as the multiplier per step, independently of
ordinary `text-scale-mode'.  Fixed manuscript dimensions are preserved,
so display stops growing when the rows fill the window height.
With `tategaki-manuscript-fit-window', the whole page fits the width too."
  (interactive "p")
  (unless tategaki-mode (user-error "Vertical editing is not active"))
  (unless (display-graphic-p) (user-error "Vertical text zoom requires a graphical display"))
  (let* ((steps (or steps 1))
         (amount (if (zerop steps) 0 (+ tategaki--text-scale-amount steps)))
         (scale (expt text-scale-mode-step amount)))
    ;; Avoid requesting unusably tiny or enormous native fonts, including
    ;; accidental large numeric prefixes.  Reset always remains available.
    (unless (<= 0.1 scale 10.0)
      (user-error "Vertical text scale must stay between 10%% and 1000%%"))
    (setq tategaki--text-scale-amount amount)
    (tategaki--text-scale-apply)
    (tategaki-refresh)))

(defun tategaki-text-scale-decrease (&optional steps)
  "Shrink vertical text in this buffer by STEPS (default one)."
  (interactive "p")
  (tategaki-text-scale-increase (- (or steps 1))))

(defun tategaki-text-scale-reset ()
  "Restore this buffer's original vertical text size.
Leave ordinary `text-scale-mode' and user face remappings unchanged."
  (interactive)
  (tategaki-text-scale-increase 0))

(defun tategaki--measure (text window)
  "Return (WIDTHS CELL HEIGHT ASCENT) for TEXT in WINDOW.
Measure display strings without inserting anything into the source buffer."
  (let* ((key (tategaki--font-signature window))
         (cached (and (equal key tategaki--font-key) tategaki--font-metrics))
         (widths (or (car cached) (make-hash-table :test #'eql)))
         (cell (or (nth 1 cached) 1)) (ascent (or (nth 3 cached) 1))
         (descent (if cached (- (nth 2 cached) (nth 3 cached)) 0)))
    (dolist (char (append '(?あ ?\s) (string-to-list text) '(nil)))
      (let* ((glyph-string (propertize (tategaki-layout--glyph char)
                                     'face 'tategaki-face))
             (glyph-char (aref glyph-string 0)))
        (unless (gethash glyph-char widths)
          (let* ((font (font-at 0 window glyph-string))
                 (glyph (and font (aref (font-get-glyphs font 0 1 glyph-string) 0)))
                 (width (if glyph (max 1 (aref glyph 4))
                          (* (max 1 (string-width glyph-string))
                             (frame-char-width (window-frame window)))))
                 (info (and font (font-info font (window-frame window)))))
            (puthash glyph-char width widths)
            (setq cell (max cell width))
            (when info
              (setq ascent (max ascent (+ (aref info 8) (aref info 4)))
                    descent (max descent (- (aref info 9) (aref info 4)))))))))
    (setq tategaki--font-key key
          tategaki--font-metrics (list widths cell (max 1 (+ ascent descent)) ascent))))

(defun tategaki--preedit-index (position)
  "Return the preedit character index at virtual POSITION, or nil."
  (when (and tategaki--preedit-start
             (<= tategaki--preedit-start position)
             (< position (+ tategaki--preedit-start tategaki--preedit-length)))
    (- position tategaki--preedit-start)))

(defun tategaki--source-position (position)
  "Map virtual POSITION back to an original buffer position."
  (cond
   ((not tategaki--preedit-start) position)
   ((< position tategaki--preedit-start) position)
   ((< position (+ tategaki--preedit-start tategaki--preedit-length))
    (min tategaki--preview-end position))
   (t (+ position (- tategaki--preview-end tategaki--preedit-start)
         (- tategaki--preedit-length)))))

(defun tategaki--virtual-position (position)
  "Map a source POSITION through the displayed virtual replacement."
  (cond
   ((or (not tategaki--preedit-start) (< position tategaki--preedit-start)) position)
   ((< position tategaki--preview-end)
    (min position (+ tategaki--preedit-start tategaki--preedit-length)))
   (t (+ position tategaki--preedit-length
         (- tategaki--preedit-start tategaki--preview-end)))))

(defun tategaki--prepare-preedit ()
  "Snapshot virtual text; native IME takes precedence over completions."
  (let* ((ime (and (stringp tategaki-ime--text) (> (length tategaki-ime--text) 0)
                   (integerp tategaki-ime--position)
                   (<= (point-min) tategaki-ime--position (point-max))))
         (preview (unless ime (tategaki-completion-current))))
    (setq tategaki--preview-kind (if ime 'ime (plist-get preview :kind))
          tategaki--preedit-text (if ime tategaki-ime--text (plist-get preview :text))
          tategaki--preedit-start (if ime tategaki-ime--position (plist-get preview :start))
          tategaki--preview-end (if ime tategaki-ime--position (plist-get preview :end))
          tategaki--preedit-length (length tategaki--preedit-text)
          tategaki--caret-position
          (cond
           ((and ime (= (point) tategaki--preedit-start))
            (+ tategaki--preedit-start
               (min tategaki--preedit-length
                    (max 0 (if (consp tategaki-ime--selection)
                               (car tategaki-ime--selection) tategaki--preedit-length)))))
           (preview (+ tategaki--preedit-start (plist-get preview :caret-offset)))
           (t (tategaki--virtual-position (point)))))))

(defun tategaki--virtual-text ()
  "Return text with a display-only IME or completion replacement."
  (let ((key (list (buffer-chars-modified-tick) (point-min) (point-max))))
    (unless (equal key tategaki--source-key)
      (setq tategaki--source-key key
            tategaki--source-text (buffer-substring-no-properties (point-min) (point-max)))))
  (if (not tategaki--preedit-start)
      tategaki--source-text
    (concat (substring tategaki--source-text 0 (- tategaki--preedit-start (point-min)))
            tategaki--preedit-text
            (substring tategaki--source-text (- tategaki--preview-end (point-min))))))

(defun tategaki--preview-boundaries ()
  "Return virtual boundaries separating source, preview and IME clauses."
  (when (and tategaki--preedit-start (> tategaki--preedit-length 0))
    (let ((start tategaki--preedit-start)
          (end (+ tategaki--preedit-start tategaki--preedit-length)) boundaries)
      (setq boundaries (list start end))
      (when (eq tategaki--preview-kind 'ime)
        (let ((index 0))
          (while (< index tategaki--preedit-length)
            (push (+ start index) boundaries)
            (setq index (next-single-property-change
                         index 'face tategaki--preedit-text tategaki--preedit-length)))))
      boundaries)))

(defun tategaki-position-pixel (position &optional window)
  "Return visible POSITION's (:x :y :width :height) in WINDOW body pixels.
Coordinates exclude the header and tab lines, as `posn-x-y' does for text.
Return nil outside the vertical owner or visible page.  At point, use the
virtual insertion cursor, including completion and IME previews."
  (setq window (or window (selected-window)))
  (when (and tategaki-mode (eq window tategaki--window)
             (window-live-p window) (eq (window-buffer window) (current-buffer))
             (display-graphic-p (window-frame window)))
    (tategaki-refresh)
    (let* ((virtual (if (= position (point)) tategaki--caret-position
                      (tategaki--virtual-position position)))
           (unit (and (plist-get tategaki--layout :typeset)
                      (tategaki-typeset-entry tategaki--layout virtual)))
           (pixel (or (gethash virtual tategaki--pixel-positions)
                      (and unit (gethash (plist-get (aref unit 4) :start)
                                         tategaki--pixel-positions)))))
      (when pixel
        (redisplay t)
        ;; Read the rendered glyph, not hidden source posn-at-point.  Row
        ;; heights can grow due to fallback fonts or an underline, so using
        ;; row * nominal-font-height accumulates an error near the bottom.
        (cl-labels
            ((matches (object)
               (and object
                    (or (= virtual (or (get-text-property (cdr object)
                                          'tategaki-virtual-position (car object)) -1))
                        (let ((start (get-text-property (cdr object) 'tategaki-unit-start (car object)))
                              (end (get-text-property (cdr object) 'tategaki-unit-end (car object))))
                          (and start end (<= start virtual) (< virtual end)))))))
          (cl-loop with x = (+ (plist-get pixel :x) (/ (plist-get pixel :width) 2))
                   ;; posn-at-x-y's input includes header/tab lines although
                   ;; its returned text coordinates exclude them.  Scan the
                   ;; full body, including the final rows below tall headers.
                   with top = (+ (window-header-line-height window)
                                 (window-tab-line-height window))
                   for y from top below (+ top (window-body-height window t))
                   by (max 1 (min (/ (frame-char-height (window-frame window)) 2)
                                  (/ (plist-get pixel :height) 2)))
                   for posn = (posn-at-x-y x y window)
                   when (matches (and posn (posn-string posn)))
                   ;; A coarse hit can land in a later slice of a compressed
                   ;; cell.  Native line spacing separates slices, and image
                   ;; offsets already include the slice origin.  Locate the
                   ;; first slice instead of subtracting a nominal offset.
                   return
                   (let* ((first
                           (cl-loop for probe from y downto top
                                    for candidate = (posn-at-x-y x probe window)
                                    for object = (and candidate (posn-string candidate))
                                    when (and (matches object)
                                              (zerop (or (get-text-property
                                                          (cdr object) 'tategaki-slice-offset
                                                          (car object)) 0)))
                                    return candidate))
                          (object (and first (posn-string first))))
                     (when object
                       (list :x (- (car (posn-x-y first)) (car (posn-object-x-y first)))
                             :y (- (cdr (posn-x-y first)) (cdr (posn-object-x-y first)))
                             :width (car (posn-object-width-height first))
                             :height (or (get-text-property (cdr object) 'tategaki-unit-height
                                                             (car object))
                                         (cdr (posn-object-width-height first))))))))))))

(defun tategaki--entry (&optional position)
  "Return the layout entry for source POSITION, defaulting to point."
  (let ((virtual (if position (tategaki--virtual-position position)
                   (or tategaki--caret-position (point)))))
    (if (plist-get tategaki--layout :typeset)
        (tategaki-typeset-entry tategaki--layout virtual)
      (let* ((positions (plist-get tategaki--layout :positions))
             (index (- virtual (point-min))))
        (when (and positions (<= 0 index) (< index (length positions)))
          (aref positions index))))))

(defun tategaki--spacer (width height ascent)
  "Return a spacer of WIDTH pixels, with HEIGHT and ASCENT.
Relative widths remain stable across the two replacement strings."
  (propertize " " 'display `(space :width (,width) :height (,height)
                                    :ascent (,ascent))))

(defun tategaki--fit-padding (before after limit)
  "Return (BEFORE . AFTER) reduced proportionally to fit LIMIT."
  (setq before (max 0 before) after (max 0 after) limit (max 0 limit))
  (if (<= (+ before after) limit)
      (cons before after)
    (let ((first (/ (* before limit) (+ before after))))
      (cons first (- limit first)))))

(defun tategaki--geometry (window metrics)
  "Compute visible text geometry for WINDOW using font METRICS.
GUI values are logical pixels; terminal values are cells and rows."
  (if (and (or tategaki-typesetting tategaki-manuscript-size)
           (tategaki-typeset-view-available-p window))
      (tategaki-typeset-view-geometry window metrics)
    (let* ((graphic (display-graphic-p (window-frame window)))
         (unit (if graphic (frame-char-width (window-frame window)) 1))
         (cell (if graphic (nth 1 metrics) 2))
         (row-height (if graphic (nth 2 metrics) 1))
         ;; A fixed right-edge allowance keeps column spacing independent
         ;; of padding, and leaves room for the native cursor at EOF.
         (width (max cell (- (window-body-width window graphic) (* 2 unit))))
         (height (max 1 (- (window-body-height window graphic)
                           (tategaki-scrollbar-height window))))
         (horizontal (tategaki--fit-padding
                      tategaki-padding-left tategaki-padding-right (- width cell)))
         ;; Keep a spare row for font rounding and the native EOF cursor.
         (vertical (tategaki--fit-padding
                    tategaki-padding-top tategaki-padding-bottom
                    (- height (* 2 row-height))))
         (inner-width (- width (car horizontal) (cdr horizontal)))
         (inner-height (- height (car vertical) (cdr vertical)))
         (gap (min (max 0 (- inner-width cell))
                   (max 0 (or tategaki-line-spacing (* unit tategaki-column-spacing)))))
         (character-gap (min (max 0 (- inner-height row-height))
                             (max 0 tategaki-character-spacing)))
         (native-spacing (* (tategaki-scrollbar-line-spacing window)
                            (if (> character-gap 0) 2 1)))
         (pitch (+ cell gap))
         (capacity (max 1 (/ (+ inner-width gap) pitch))))
    (list :cell cell :gap gap :pitch pitch :capacity capacity
          :left (+ (car horizontal) (max 0 (- inner-width (- (* capacity pitch) gap))))
          :top (car vertical) :bottom (cdr vertical)
          :character-gap character-gap
          :rows (max 1 (1- (/ (+ inner-height character-gap)
                              (+ row-height character-gap native-spacing))))))))

(defun tategaki--vertical-space (size graphic)
  "Return display-only vertical space of SIZE pixels or terminal rows.
A space glyph defines the complete height; the newline adds no font height."
  (if (<= size 0) ""
    (if graphic
        (propertize (concat (tategaki--spacer 1 size 0) "\n")
                    'line-height t 'line-spacing 0)
      (make-string size ?\n))))

(defun tategaki--face-list (face)
  "Return FACE as a list of face names and attribute plists."
  (cond ((null face) nil)
        ((or (symbolp face) (keywordp (car-safe face))) (list face))
        (t face)))

(defun tategaki--page-start (column capacity)
  "Choose the first visible column for COLUMN with CAPACITY columns."
  (if (and tategaki--scroll-start
           (<= tategaki--scroll-start column)
           (< column (+ tategaki--scroll-start capacity)))
      (setq tategaki--scroll-start
            (min tategaki--scroll-start
                 (max 0 (- (plist-get tategaki--layout :columns) capacity))))
    (setq tategaki--scroll-start nil)
    (* (/ column capacity) capacity)))

(defun tategaki--install-display (display window &optional content-height)
  "Install DISPLAY around native point in WINDOW without source edits."
  (when content-height
    (setq display (tategaki-scrollbar-append display window content-height)))
  (let ((caret (text-property-any 0 (length display) 'cursor t display)))
    (unless caret (error "Vertical display lost the source cursor"))
    (setq tategaki--display-string display)
    (move-overlay tategaki--overlay (point-min) (point))
    (move-overlay tategaki--tail-overlay (point) (point-max))
    (dolist (overlay (list tategaki--overlay tategaki--tail-overlay))
      (dolist (property '(display before-string after-string))
        (overlay-put overlay property nil)))
    (if (= (point-min) (point-max))
        (overlay-put tategaki--overlay 'before-string display)
      (when (< (point-min) (point)) (overlay-put tategaki--overlay 'display ""))
      (when (< (point) (point-max)) (overlay-put tategaki--tail-overlay 'display ""))
      (overlay-put tategaki--overlay 'after-string (substring display 0 caret))
      (overlay-put tategaki--tail-overlay 'before-string (substring display caret))))
  (set-window-hscroll window 0)
  (set-window-vscroll window 0 t)
  (set-window-start window (point-min) t))

(defun tategaki--paint (window)
  "Paint the visible page in WINDOW using the active layout backend."
  (tategaki-highlight-consume)
  (let ((tategaki-glyph--style-cache (make-hash-table :test #'equal)))
    (if (plist-get tategaki--layout :typeset)
        (tategaki-typeset-view-paint window)
      (tategaki--paint-literal window))))

(defun tategaki--paint-literal (window)
  "Paint the visible page in WINDOW from the cached lossless layout."
  (let* ((graphic (display-graphic-p (window-frame window)))
         (geometry (tategaki--geometry window tategaki--metrics))
         (cell (plist-get geometry :cell))
         (line-height (if graphic (nth 2 tategaki--metrics) 1))
         (ascent (if graphic (nth 3 tategaki--metrics) 1))
         (pitch (plist-get geometry :pitch))
         (capacity (plist-get geometry :capacity))
         (top (plist-get geometry :top))
         (character-gap (plist-get geometry :character-gap))
         (entry (tategaki--entry))
         (column (if entry (aref entry 3) 0))
         (height (plist-get tategaki--layout :height))
         (positions (plist-get tategaki--layout :positions))
         (layout-text (plist-get tategaki--layout :text))
         (region-start (and (use-region-p) (region-beginning)))
         (region-end (and region-start (region-end)))
         (cells (make-hash-table :test #'equal))
         rows)
    (setq tategaki--pixel-positions (make-hash-table :test #'eql))
    (setq tategaki--page-size capacity
          tategaki--page (tategaki--page-start column capacity))
    (seq-doseq (item positions)
      (when (<= tategaki--page (aref item 3)
                (+ tategaki--page capacity -1))
        (puthash (cons (aref item 2) (aref item 3)) item cells)))
    (dotimes (row height)
      (let (parts)
        (dotimes (visual-column capacity)
          (let* ((logical-column (+ tategaki--page (- capacity visual-column 1)))
                 (item (gethash (cons row logical-column) cells))
                 (x (+ (plist-get geometry :left)
                       (* visual-column pitch))))
            (push (if graphic (tategaki--spacer
                               (if (zerop visual-column) x (- pitch cell))
                               line-height ascent)
                    (if (zerop visual-column)
                        (make-string (max 0 x) ?\s)
                      (make-string (- pitch cell) ?\s))) parts)
            (if (not item)
                (push (if graphic (tategaki--spacer cell line-height ascent)
                        (make-string cell ?\s)) parts)
              (let* ((position (aref item 0))
                     (source-position (tategaki--source-position position))
                     (preedit-index (tategaki--preedit-index position))
                     (glyph (substring layout-text (aref item 1) (1+ (aref item 1))))
                     (glyph-width (if graphic
                                      (gethash (aref glyph 0) (car tategaki--metrics) cell)
                                    (string-width glyph)))
                     (face (append
                            (cond
                             (preedit-index
                              (append
                               (tategaki--face-list
                                (get-text-property preedit-index 'face
                                                   tategaki--preedit-text))
                               (if (eq tategaki--preview-kind 'ime)
                                   '(tategaki-preedit-face) '(shadow))))
                             ((and region-start (<= region-start source-position)
                                   (< source-position region-end)) '(region)))
                            (unless preedit-index
                              (tategaki-highlight-faces source-position (1+ source-position) window))
                            (when (= position tategaki--caret-position)
                              '(tategaki-cursor-face))
                            (when (get-text-property 0 'face glyph)
                              (list (get-text-property 0 'face glyph)))
                            '(tategaki-face))))
                (when graphic
                  (puthash position
                           (list :x (+ x (/ (- cell glyph-width) 2))
                                 :y (+ top (* row (+ line-height character-gap)))
                                 :width glyph-width :height line-height)
                           tategaki--pixel-positions)
                  (push (tategaki--spacer (/ (- cell glyph-width) 2)
                                          line-height ascent) parts))
                (add-text-properties
                 0 1 (list 'face face 'tategaki-position source-position
                           'tategaki-virtual-position position
                           'tategaki-preedit-index (and (eq tategaki--preview-kind 'ime) preedit-index)
                           'tategaki-completion-index (and (not (eq tategaki--preview-kind 'ime)) preedit-index)
                           'tategaki-row row 'tategaki-column logical-column
                           'mouse-face 'highlight
                           'cursor (and (= position tategaki--caret-position) t)) glyph)
                (push glyph parts)
                (push (if graphic (tategaki--spacer
                                   (- cell glyph-width (/ (- cell glyph-width) 2))
                                   line-height ascent)
                        (make-string (max 0 (- cell glyph-width)) ?\s)) parts)))))
        (push (apply #'concat (nreverse parts)) rows)))
    (let ((display (propertize
                     (concat (tategaki--vertical-space top graphic)
                             (mapconcat #'identity (nreverse rows)
                                        (concat "\n" (tategaki--vertical-space
                                                      character-gap graphic))))
                     'line-height t 'line-spacing 0)))
      (tategaki--install-display display window
                                (+ top (* height line-height)
                                   (* (max 0 (1- height)) character-gap))))
    (when (and graphic (eq tategaki--preview-kind 'ime) (> tategaki--preedit-length 0))
      ;; NS already anchors to the physical cursor at the selected clause.
      ;; Put its horizontal candidate panel beside that vertical cell, and
      ;; undo the native extra line below it.  Use logical pixels, not Retina
      ;; pixels or frame/screen coordinates, and leave native text untouched.
      (tategaki-ime-set-panel-offset
       (+ cell 4) (- (frame-char-height (window-frame window)))))))

;;;###autoload
(defun tategaki-refresh ()
  "Refresh the vertical editing layer without changing source text."
  (interactive)
  (when (called-interactively-p 'interactive)
    (setq tategaki--cache-key nil))
  (save-match-data
  (when (and tategaki-mode (not tategaki--refreshing))
    (let ((tategaki--refreshing t)
          (gc-cons-threshold (max gc-cons-threshold (or tategaki-render-gc-threshold 0)))
          (window (if (eq (window-buffer (selected-window)) (current-buffer))
                      (selected-window)
                    (get-buffer-window (current-buffer) t))))
      (when (window-live-p window)
        (tategaki--attach-window window)
        (tategaki--prepare-preedit)
        (let* ((graphic (display-graphic-p (window-frame window)))
               (key (list (buffer-chars-modified-tick) (point-min) (point-max)
                          (window-body-width window t) (window-body-height window t)
                          tategaki-column-height tategaki-layout-use-vertical-forms
                          tategaki-padding-top tategaki-padding-bottom
                          tategaki-padding-left tategaki-padding-right
                          tategaki-line-spacing tategaki-column-spacing
                          tategaki-character-spacing
                          (tategaki-scrollbar-line-spacing window)
                          tategaki-scrollbar tategaki-scrollbar-pixel-height
                          tategaki-typesetting (tategaki-typeset-options-key)
                          tategaki-manuscript-size tategaki-manuscript-spread
                          tategaki-manuscript-fit-window
                          tategaki-manuscript-grid face-remapping-alist
                          tategaki-layout-newline-symbol tategaki-layout-tab-symbol
                          tategaki-layout-eof-symbol tategaki-layout-zero-width-symbol
                          tategaki-layout-control-symbol
                          tategaki--preedit-start tategaki--preedit-text
                          tategaki--preview-end tategaki--preview-kind
                          tategaki-ime--selection
                          (tategaki-typeset-view-available-p window)
                          (tategaki--font-signature window))))
          (unless (equal-including-properties key tategaki--cache-key)
            (let* ((text (tategaki--virtual-text))
                   (rich (and (or tategaki-typesetting tategaki-manuscript-size)
                              (tategaki-typeset-view-available-p window)))
                   (metrics (and graphic (tategaki--measure (if rich "あＡ□↵" text) window)))
                   (available (plist-get (tategaki--geometry window metrics) :rows))
                   (height (if (and rich tategaki-manuscript-size) (car tategaki-manuscript-size)
                             (min available (max 1 (or tategaki-column-height available))))))
              (setq tategaki--metrics metrics
                    tategaki--layout
                    (if rich
                        (setq tategaki--typeset-cache
                              (tategaki-typeset-layout text height (point-min) tategaki--typeset-cache
                                                       (tategaki--preview-boundaries)))
                      (tategaki-layout-render text height nil (point-min)))
                    tategaki--cache-key key)))
          (tategaki--paint window)))))))

(defun tategaki--ime-updated ()
  "Reflow after an IME update, including changes to marked clauses."
  (setq tategaki--cache-key nil)
  (tategaki-refresh))

(defun tategaki--post-command ()
  "Update the display after native editing and movement commands."
  ;; Command-loop startup (including keyboard macros) can run this hook
  ;; with no command.  Prefix input also prepares a move rather than ending
  ;; the previous one; neither should lose a clamped page's desired cell.
  (when (and this-command
             (not (memq this-command '(universal-argument universal-argument-more
                                      digit-argument negative-argument))))
    (unless (memq this-command '(tategaki-forward-page tategaki-backward-page))
      (setq tategaki--page-goal nil))
    (unless (memq this-command '(tategaki-forward-column tategaki-backward-column
                                tategaki-forward-page tategaki-backward-page))
      (setq tategaki--goal-row nil)))
  (tategaki-refresh))

(defun tategaki--changed (&rest _)
  "Invalidate layout following a source change."
  (setq tategaki--cache-key nil))

(defun tategaki--highlight-region (start end window overlay)
  "Use cell highlights in the editor, native highlights in other windows.
START, END, WINDOW and OVERLAY follow `redisplay-highlight-region-function'."
  (if (eq window tategaki--window)
      (progn (when (overlayp overlay) (delete-overlay overlay)) nil)
    (funcall tategaki--original-highlight-region start end window overlay)))

(defun tategaki--resized (frame)
  "Reflow active vertical buffers displayed on FRAME."
  (dolist (window (window-list frame 'no-minibuffer))
    (with-current-buffer (window-buffer window)
      (when (and tategaki-mode (eq window tategaki--window))
        (tategaki-refresh)))))

(defun tategaki-next-character (&optional count)
  "Move COUNT visible characters down in reading order.
Composed cells move as one unit; ordinary Emacs source commands remain native."
  (interactive "^p")
  (setq count (or count 1))
  (if (not (and (plist-get tategaki--layout :typeset)
                (not tategaki--preview-kind)))
      (forward-char count)
    (dotimes (_ (abs count))
      (let ((entry (tategaki--entry (if (< count 0) (1- (point)) (point)))))
        (unless (and entry (if (< count 0) (> (point) (point-min)) (< (point) (point-max))))
          (signal (if (< count 0) 'beginning-of-buffer 'end-of-buffer) nil))
        (goto-char (if (< count 0) (plist-get (aref entry 4) :start)
                     (plist-get (aref entry 4) :end)))))))

(defun tategaki-previous-character (&optional count)
  "Move COUNT characters up in reading order."
  (interactive "^p")
  (tategaki-next-character (- (or count 1))))

(defun tategaki--goto-cell (column row)
  "Move to COLUMN's nearest existing cell to ROW in the current layout."
  (if (plist-get tategaki--layout :typeset)
      (let ((entry (tategaki-typeset-nearest tategaki--layout column row)))
        (when entry (goto-char (tategaki--source-position (aref entry 0)))))
    (let (best)
    (seq-doseq (item (plist-get tategaki--layout :positions))
      (when (and (= (aref item 3) column)
                 (or (not best)
                     (< (abs (- (aref item 2) row))
                        (abs (- (aref best 2) row)))))
        (setq best item)))
    (when best (goto-char (tategaki--source-position (aref best 0)))))))

(defun tategaki-forward-column (&optional count)
  "Move COUNT columns left, preserving the desired row."
  (interactive "^p")
  (tategaki-refresh)
  (let ((entry (tategaki--entry)))
    (setq tategaki--goal-row (or tategaki--goal-row (aref entry 2)))
    (tategaki--goto-cell (+ (aref entry 3) (or count 1)) tategaki--goal-row)))

(defun tategaki-backward-column (&optional count)
  "Move COUNT columns right, preserving the desired row."
  (interactive "^p")
  (tategaki-forward-column (- (or count 1))))

(defun tategaki-forward-page (&optional count)
  "Move COUNT vertical pages forward (left), preserving the screen cell.
COUNT defaults to one; negative values move backward.  Short columns and
the final page use the nearest existing cell.  Moving beyond the first
or last page goes to the accessible buffer boundary."
  (interactive "^p")
  (unless tategaki-mode (user-error "Vertical editing is not active"))
  (setq count (or count 1))
  (unless (zerop count)
    (setq tategaki--scroll-start nil)
    (tategaki-refresh)
    ;; Copilot normally clears after motion.  Clear before computing a page
    ;; so unaccepted ghost columns cannot absorb the move at one source point.
    ;; Native IME composition and Corfu's candidate navigation stay native.
    (when (eq tategaki--preview-kind 'copilot)
      (tategaki-completion-dismiss-copilot)
      (tategaki-refresh))
    (let* ((entry (tategaki--entry))
           (height (plist-get tategaki--layout :height))
           (last-column (1- (plist-get tategaki--layout :columns)))
           (target-page (+ tategaki--page (* count tategaki--page-size))))
      (when (and tategaki--page-goal
                 (or (/= (car tategaki--page-goal) tategaki--page-size)
                     (/= (cadr tategaki--page-goal) height)))
        ;; Reflow changes point's visual cell.  Start from its new row as
        ;; well as its new column instead of restoring a pre-resize goal.
        (setq tategaki--page-goal nil tategaki--goal-row nil))
      (unless tategaki--page-goal
        (setq tategaki--page-goal
              (list tategaki--page-size height (- (aref entry 3) tategaki--page))))
      (setq tategaki--goal-row (or tategaki--goal-row (aref entry 2)))
      (cond
       ((< target-page 0) (goto-char (point-min)))
       ((> target-page last-column) (goto-char (point-max)))
       (t (tategaki--goto-cell
           (min last-column (+ target-page (nth 2 tategaki--page-goal)))
           tategaki--goal-row)))
      (tategaki-refresh))))

(defun tategaki-backward-page (&optional count)
  "Move COUNT vertical pages backward (right), preserving the screen cell."
  (interactive "^p")
  (tategaki-forward-page (- (or count 1))))

(defun tategaki--mouse-position (position)
  "Find the source position of a display cell at mouse POSITION."
  (let ((string-position (posn-string position)))
    (and string-position
         (get-text-property (cdr string-position) 'tategaki-position
                            (car string-position)))))

(defun tategaki-mouse-set-point (event)
  "Move source point to the vertical cell clicked in EVENT."
  (interactive "e")
  (let* ((position (event-start event))
         (window (posn-window position))
         (source-position (tategaki--mouse-position position)))
    (when (and (window-live-p window) source-position)
      (select-window window)
      (goto-char source-position)
      (deactivate-mark)
      (tategaki-refresh))))

(defun tategaki-mouse-set-region (event)
  "Select source text between the cells at either end of drag EVENT."
  (interactive "e")
  (let* ((start (event-start event))
         (end (event-end event))
         (window (posn-window start))
         (begin (tategaki--mouse-position start))
         (finish (tategaki--mouse-position end)))
    (when (and begin finish (eq window (posn-window end))
               (window-live-p window))
      (select-window window)
      (goto-char finish)
      (push-mark begin t t)
      (setq deactivate-mark nil)
      (tategaki-refresh))))

(defun tategaki--cleanup ()
  "Remove the layer and restore the original buffer settings."
  (when tategaki--text-scale-cookie
    (face-remap-remove-relative tategaki--text-scale-cookie)
    (setq tategaki--text-scale-cookie nil))
  (tategaki-ime-disable)
  (tategaki-corfu-disable)
  (tategaki-completion-disable)
  (tategaki-highlight-disable)
  (tategaki-manuscript-disable)
  (tategaki-writing-disable)
  (tategaki-outline-cleanup)
  (when (overlayp tategaki--overlay) (delete-overlay tategaki--overlay))
  (when (overlayp tategaki--tail-overlay) (delete-overlay tategaki--tail-overlay))
  (tategaki--restore-window)
  (dolist (binding tategaki--saved-locals)
    (if (nth 1 binding)
        (set (make-local-variable (car binding)) (nth 2 binding))
      (kill-local-variable (car binding))))
  (setq tategaki--overlay nil tategaki--tail-overlay nil
        tategaki--display-string nil tategaki--window nil tategaki--layout nil
        tategaki--original-highlight-region nil
        tategaki--preedit-text nil tategaki--preedit-start nil
        tategaki--preedit-length 0 tategaki--caret-position nil
        tategaki--preview-end nil tategaki--preview-kind nil tategaki--pixel-positions nil
        tategaki--cache-key nil tategaki--saved-locals nil)
  (setq tategaki--goal-row nil tategaki--page-goal nil
        tategaki--scroll-start nil
        tategaki--font-key nil tategaki--font-metrics nil
        tategaki--source-key nil tategaki--source-text nil tategaki--typeset-cache nil)
  (remove-hook 'post-command-hook #'tategaki--post-command t)
  (remove-hook 'after-change-functions #'tategaki--changed t)
  (remove-hook 'isearch-update-post-hook #'tategaki-refresh t)
  (remove-hook 'change-major-mode-hook #'tategaki-quit t)
  (remove-hook 'kill-buffer-hook #'tategaki--cleanup t)
  (unless (cl-some (lambda (buffer)
                     (and (not (eq buffer (current-buffer)))
                          (buffer-local-value 'tategaki-mode buffer)))
                   (buffer-list))
    (remove-hook 'window-size-change-functions #'tategaki--resized)))

(defvar tategaki-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<down>") #'tategaki-next-character)
    (define-key map (kbd "<up>") #'tategaki-previous-character)
    (define-key map (kbd "<left>") #'tategaki-forward-column)
    (define-key map (kbd "<right>") #'tategaki-backward-column)
    (define-key map (kbd "C-c C-c") #'tategaki-quit)
    (define-key map (kbd "C-c C-l") #'tategaki-refresh)
    (define-key map (kbd "C-c C-r") #'tategaki-insert-ruby)
    (define-key map (kbd "C-c C-a") #'tategaki-toggle-annotations)
    (define-key map (kbd "C-c C-p") #'tategaki-goto-page)
    (define-key map (kbd "C-c C-o") #'tategaki-outline)
    (define-key map (kbd "M-+") #'tategaki-text-scale-increase)
    (define-key map (kbd "M-=") #'tategaki-text-scale-increase)
    (define-key map (kbd "M--") #'tategaki-text-scale-decrease)
    (define-key map (kbd "M-0") #'tategaki-text-scale-reset)
    (define-key map [wheel-left] #'tategaki-scroll-left)
    (define-key map [wheel-right] #'tategaki-scroll-right)
    (define-key map [down-mouse-1] #'tategaki-mouse-set-point)
    (define-key map [mouse-1] #'ignore)
    (define-key map [drag-mouse-1] #'tategaki-mouse-set-region)
    map)
  "Keys for vertical editing; other keys retain their normal meanings.")

(tategaki-navigation-install tategaki-mode-map)

;;;###autoload
(define-minor-mode tategaki-mode
  "Edit text directly through a vertical display layer.
The actual source buffer stays selected.  Typing, input methods, undo,
regions and file saving retain their native semantics.  Arrow keys move
in vertical display coordinates.  `tategaki-physical-navigation' also
enables physical directions for C-f, C-b, C-n and C-p.
M-+ and M-- change vertical text size; M-0 restores it.
The mode applies to text-mode and derived modes.  `tategaki-typesetting'
enables composed typography and supported Aozora annotations on SVG displays."
  :lighter " 縦編集"
  :keymap tategaki-mode-map
  (if (not tategaki-mode)
      (tategaki--cleanup)
    (unless (derived-mode-p 'text-mode)
      (setq tategaki-mode nil)
      (user-error "Vertical editing requires text-mode or a derived mode"))
    (unless (overlayp tategaki--overlay)
      (condition-case error-data
          (progn
            (setq tategaki--overlay (make-overlay (point-min) (point-max) nil nil t))
            (setq tategaki--tail-overlay (make-overlay (point-min) (point-max) nil nil t))
            (overlay-put tategaki--overlay 'priority 1000)
            (overlay-put tategaki--tail-overlay 'priority 1000)
            (overlay-put tategaki--overlay 'tategaki-internal t)
            (overlay-put tategaki--tail-overlay 'tategaki-internal t)
            (tategaki--save-local 'global-disable-point-adjustment t)
            (setq tategaki--original-highlight-region redisplay-highlight-region-function)
            (tategaki--save-local 'redisplay-highlight-region-function
                                  #'tategaki--highlight-region)
            (add-hook 'post-command-hook #'tategaki--post-command nil t)
            (add-hook 'after-change-functions #'tategaki--changed nil t)
            (add-hook 'isearch-update-post-hook #'tategaki-refresh nil t)
            (add-hook 'change-major-mode-hook #'tategaki-quit nil t)
            (add-hook 'kill-buffer-hook #'tategaki--cleanup nil t)
            (add-hook 'window-size-change-functions #'tategaki--resized)
            (tategaki-ime-enable #'tategaki--ime-updated (selected-window))
            (tategaki-completion-enable #'tategaki--ime-updated (selected-window))
            (tategaki-corfu-enable)
            (tategaki-highlight-enable #'tategaki-refresh)
            (tategaki-manuscript-enable)
            (tategaki-writing-enable)
            (tategaki--text-scale-apply)
            (tategaki-refresh))
        (error
         (setq tategaki-mode nil)
         (tategaki--cleanup)
         (signal (car error-data) (cdr error-data)))))))

;;;###autoload
(defun tategaki-edit ()
  "Start vertical editing in the current text buffer."
  (interactive)
  (tategaki-mode 1))

;;;###autoload
(defun tategaki-typeset-edit ()
  "Start vertical editing with composed typography in this text buffer."
  (interactive)
  (setq-local tategaki-typesetting t)
  (tategaki-mode 1))

;;;###autoload
(defun tategaki-quit ()
  "Return to horizontal editing without changing the document."
  (interactive)
  (tategaki-mode -1))

(provide 'tategaki)
;;; tategaki.el ends here
