;;; org-tategaki-preview.el --- Vertical writing preview for text modes -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: text, outlines

;;; Commentary:
;; Run `tategaki-preview' in a text-mode-derived buffer.  The source stays editable
;; while a read-only window on its left displays a character-grid preview.
;; This is approximate typography, not a vertical text shaping engine.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'face-remap)

(defgroup org-tategaki-preview nil
  "Vertical writing previews for text modes."
  :group 'text)

(defcustom org-tategaki-preview-refresh-delay 0.2
  "Idle seconds before updating after an edit."
  :type 'number)

(defcustom org-tategaki-preview-use-vertical-forms t
  "Whether to substitute Unicode vertical punctuation in the preview."
  :type 'boolean)

(defcustom org-tategaki-preview-column-spacing 1
  "Number of display cells between vertical columns."
  :type 'natnum)

(defcustom org-tategaki-preview-window-margin 2
  "Blank display cells on each side of the preview window.
Margins stay visible during horizontal scrolling.  Refresh with g after
changing this value.  Narrow windows may use smaller margins."
  :type 'natnum)

(defcustom org-tategaki-preview-padding 1
  "Inner horizontal padding in display cells, in addition to window margins."
  :type 'natnum)

(defcustom org-tategaki-preview-vertical-padding 1
  "Blank character rows above and below the preview text.
The padding is included in the layout, reducing the number of characters
in each vertical column.  Short windows use less padding so text still fits.
Refresh with g after changing this value."
  :type 'natnum)

(defcustom org-tategaki-preview-sync-point t
  "Whether the preview follows the source cursor and scrolling."
  :type 'boolean)

(defface org-tategaki-preview-current-character
  '((((background dark)) (:background "#557a22" :foreground "#ffffff" :underline t))
    (t (:background "#c8e6a0" :underline t)))
  "Face for the character at the source cursor."
  :group 'org-tategaki-preview)

(defface org-tategaki-preview-current-column
  '((((background dark)) (:background "#164016"))
    (t (:background "#e4efdf")))
  "Face for the vertical column containing the source cursor."
  :group 'org-tategaki-preview)

(defface org-tategaki-preview-face
  '((t (:inherit default)))
  "Face used for preview text.  GUI columns use measured glyph widths."
  :group 'org-tategaki-preview)

(defconst org-tategaki-preview--vertical-forms
  '((?、 . ?︑) (?。 . ?︒) (?「 . ?﹁) (?」 . ?﹂)
    (?『 . ?﹃) (?』 . ?﹄) (?（ . ?︵) (?） . ?︶)
    (?［ . ?﹇) (?］ . ?﹈) (?｛ . ?︷) (?｝ . ?︸)
    (?〈 . ?︿) (?〉 . ?﹀) (?《 . ?︽) (?》 . ?︾)))

(defvar-local org-tategaki-preview--preview nil)
(defvar-local org-tategaki-preview--frame nil
  "Separate preview frame owned by this source buffer.")
(defvar org-tategaki-preview--open-in-frame nil
  "Non-nil while opening a preview in a separate frame.")
(defvar-local org-tategaki-preview--source nil)
(defvar-local org-tategaki-preview--timer nil)
(defvar-local org-tategaki-preview--size nil)
(defvar-local org-tategaki-preview--pixel-width 0)
(defvar-local org-tategaki-preview--position-index [])
(defvar-local org-tategaki-preview--cursor-overlay nil)
(defvar-local org-tategaki-preview--column-index nil)
(defvar-local org-tategaki-preview--column-overlays nil)
(defvar-local org-tategaki-preview--rendered-tick nil)
(defvar-local org-tategaki-preview--last-sync-position nil)
(defvar org-tategaki-preview--track-source nil)
(defvar org-tategaki-preview--org-source t
  "Whether to strip Org headings; bound from the source mode during refresh.
The default preserves the original internal rendering API.")
(defvar org-tategaki-preview-mode)

(defun org-tategaki-preview--source-text ()
  "Return the entire source buffer without properties, ignoring narrowing."
  (save-restriction
    (widen)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun org-tategaki-preview--normalize-text (text)
  "Normalize TEXT into paragraphs.
Single newlines join text; blank lines separate paragraphs.  When
`org-tategaki-preview--org-source' is non-nil, strip Org heading markers
and make headings separate paragraphs.  Otherwise preserve markup."
  (with-temp-buffer
    (insert (substring-no-properties text))
    (when org-tategaki-preview--track-source
      (dotimes (i (buffer-size))
        (put-text-property (1+ i) (+ i 2)
                           'org-tategaki-preview-source-position (1+ i))))
    (goto-char (point-min))
    (while (re-search-forward "\r\n?" nil t) (replace-match "\n" t t))
    (subst-char-in-region (point-min) (point-max) ?\t ?\s)
    (when org-tategaki-preview--org-source
      (goto-char (point-min))
      (while (re-search-forward "^\\*+ +\\(.*\\)$" nil t)
        (replace-match (concat "\n\n" (match-string 1) "\n\n") t t)))
    (goto-char (point-min))
    (while (re-search-forward "\n[ \t]*\n\\(?:[ \t]*\n\\)*" nil t)
      (replace-match "\n\n" t t))
    (mapconcat (lambda (paragraph)
                 (replace-regexp-in-string "\n" "" paragraph))
               (split-string (string-trim (buffer-string)) "\n\n" t) "\n\n")))

(defun org-tategaki-preview--vertical-form (char)
  "Return the preview form of CHAR."
  (if org-tategaki-preview-use-vertical-forms
      (or (alist-get char org-tategaki-preview--vertical-forms) char)
    char))

(defun org-tategaki-preview--columns (text height)
  "Return TEXT as right-to-left column vectors of HEIGHT characters."
  (let (columns)
    (dolist (paragraph (split-string (org-tategaki-preview--normalize-text text)
                                    "\n\n" t))
      (when columns (push [] columns))
      (let ((converted (apply #'string
                              (mapcar #'org-tategaki-preview--vertical-form paragraph))))
        (when org-tategaki-preview--track-source
          (dotimes (i (length paragraph))
            (set-text-properties i (1+ i) (text-properties-at i paragraph) converted)))
        (setq paragraph converted))
      (let ((start 0))
        (while (< start (length paragraph))
          (push (cl-subseq paragraph start (min (length paragraph) (+ start height)))
                columns)
          (setq start (+ start height)))))
    columns))

(defun org-tategaki-preview--annotate-cell (cell column row x width &optional column-x column-width)
  "Attach COLUMN's source position at ROW to CELL, with X and WIDTH.
COLUMN-X and COLUMN-WIDTH describe the full cell around a centered glyph."
  (let ((position (and (stringp column)
                       (get-text-property row 'org-tategaki-preview-source-position
                                          column))))
    (if (not position) cell
      (let ((result (copy-sequence cell)))
        (add-text-properties 0 1
                             (list 'org-tategaki-preview-location
                                   (vector position x width (or column-x x)
                                           (or column-width width))) result)
        result))))

(defun org-tategaki-preview--column-cell (text x)
  "Mark TEXT as the complete cell of column X, including blank space."
  (if org-tategaki-preview--track-source
      (propertize text 'org-tategaki-preview-column x)
    text))

(defun org-tategaki-preview--padding (width &optional unit)
  "Return inner padding for WIDTH, scaled by UNIT when using pixels."
  (min (* org-tategaki-preview-padding (or unit 1))
       (max 0 (/ (1- width) 4))))

(defun org-tategaki-preview--vertical-padding (rows)
  "Return padding rows per edge, keeping one text row within ROWS."
  (min org-tategaki-preview-vertical-padding (max 0 (/ (1- rows) 2))))

(defun org-tategaki-preview--pad-vertically (text padding blank)
  "Surround TEXT with PADDING rows of BLANK, without source annotations."
  (if (or (string-empty-p text) (zerop padding)) text
    (concat (apply #'concat (make-list padding (concat blank "\n")))
            text
            (apply #'concat (make-list padding (concat "\n" blank))))))

(defun org-tategaki-preview--render (text height &optional width)
  "Render TEXT top to bottom in HEIGHT-character columns, right to left.
WIDTH is the available display width in cells, used for right alignment.
Overflow is retained for horizontal scrolling.  Paragraphs start a new
column with a blank column between them.  Cells occupy at least two
display columns; characters, rather than grapheme clusters, are used."
  (unless (and (integerp height) (> height 0))
    (error "Column height must be a positive integer"))
  (let ((columns (org-tategaki-preview--columns text height))
        (cell-width 2)
        rows)
    (dolist (column columns)
      (seq-doseq (char column)
        (setq cell-width (max cell-width (char-width char)))))
    (if (null columns) ""
      (let* ((spacing (make-string org-tategaki-preview-column-spacing ?\s))
             (padding (org-tategaki-preview--padding (or width 0)))
             (render-width (+ (* (length columns) cell-width)
                              (* (1- (length columns)) (length spacing))))
             (margin (make-string (+ padding (max 0 (- (or width 0) render-width
                                                       (* 2 padding)))) ?\s))
             (blank (make-string cell-width ?\s))
             (cache (make-hash-table :test #'eql)))
        (dotimes (row height)
          (let ((x (length margin)) cells)
            (dolist (column columns)
              (push (org-tategaki-preview--column-cell
                     (if (>= row (length column)) blank
                      (let* ((char (aref column row))
                             (cell (gethash char cache)))
                        (org-tategaki-preview--annotate-cell
                         (or cell
                            (puthash char
                                     (concat (char-to-string char)
                                             (make-string
                                              (- cell-width (char-width char)) ?\s))
                                     cache))
                         column row x cell-width))) x)
                    cells)
              (setq x (+ x cell-width (length spacing))))
            (push (concat margin (mapconcat #'identity (nreverse cells) spacing)
                          (make-string padding ?\s))
                  rows)))
        (mapconcat #'identity (nreverse rows) "\n")))))

(defun org-tategaki-preview--render-terminal (text height width)
  "Render TEXT with vertical padding within HEIGHT rows and WIDTH cells.
Return (TEXT . WIDTH), retaining horizontal overflow."
  (let* ((padding (org-tategaki-preview--vertical-padding height))
         (body (org-tategaki-preview--render text (max 1 (- height (* 2 padding))) width))
         (extent (string-width (car (split-string body "\n")))))
    (cons (org-tategaki-preview--pad-vertically body padding " ") extent)))

(defun org-tategaki-preview--pixel-metrics (text window)
  "Measure TEXT's preview glyphs in WINDOW, using its actual font fallback.
The current preview buffer is used as scratch space.  Return widths,
cell width, row height and baseline.  The caller replaces the temporary text."
  (let ((widths (make-hash-table :test #'eql))
        (fonts (make-hash-table :test #'equal))
        (cell-width 1)
        (ascent 0)
        (descent 0)
        (org-tategaki-preview--track-source nil)
        chars positions)
    (dolist (char (append '(?あ ?\s)
                          (string-to-list (org-tategaki-preview--normalize-text text))))
      (setq char (org-tategaki-preview--vertical-form char))
      (unless (or (= char ?\n) (gethash char widths))
        (puthash char 0 widths)
        (push char chars)))
    (erase-buffer)
    ;; One sample line includes all ascenders/descenders and fallback fonts.
    (dolist (char chars)
      (push (cons char (point)) positions)
      (insert (propertize (char-to-string char) 'face 'org-tategaki-preview-face)))
    (let ((line-height (cdr (window-text-pixel-size
                             window (point-min) (point-max) t))))
      (dolist (entry positions)
        ;; Read the actual glyph advance from the chosen font.  The window
        ;; measurement API can return zero for a one-character range after
        ;; redisplay/scrolling, even though the glyph has a nonzero width.
        (let* ((font (font-at (cdr entry) window))
               (glyph (and font (aref (font-get-glyphs
                                      font (cdr entry) (1+ (cdr entry))) 0)))
               (width (if glyph (aref glyph 4)
                        (max 1 (car (window-text-pixel-size
                                     window (cdr entry) (1+ (cdr entry)) t))))))
          (puthash (car entry) width widths)
          (setq cell-width (max cell-width width))
          (when (and font (not (gethash font fonts)))
            (puthash font t fonts)
            ;; Reopening by name applies `face-font-rescale-alist' again.
            ;; Measure the font object actually used to display the glyph.
            (let ((info (font-info font (window-frame window))))
              (when info
                (setq ascent (max ascent (+ (aref info 8) (aref info 4)))
                      descent (max descent (- (aref info 9) (aref info 4)))))))))
      (let* ((height (max line-height (+ ascent descent) 1))
             (baseline (+ ascent (/ (- height (+ ascent descent)) 2))))
        (list widths cell-width height baseline)))))

(defun org-tategaki-preview--pixel-space (x &optional height ascent)
  "Return a spacer aligned to absolute pixel coordinate X."
  (propertize " " 'display `(space :align-to (,x)
                                  ,@(when height `(:height (,height) :ascent (,ascent))))))

(defun org-tategaki-preview--render-pixels (text window width &optional max-height)
  "Render TEXT in WINDOW within WIDTH, independently of horizontal scrolling.
MAX-HEIGHT optionally limits the row count.  Restore scrolling on exit."
  (let ((scroll (window-hscroll window)))
    (unwind-protect
        (progn
          (set-window-hscroll window 0)
          (org-tategaki-preview--render-pixels-unscrolled text window width max-height))
      (set-window-hscroll window scroll))))

(defun org-tategaki-preview--render-pixels-unscrolled (text window width &optional max-height)
  "Render TEXT for graphical WINDOW within WIDTH pixels.
Measure each glyph, center it in a fixed cell, and anchor every cell
independently so proportional fonts cannot accumulate alignment errors.
Return (TEXT . PIXEL-WIDTH), retaining overflow for horizontal scrolling.
MAX-HEIGHT limits rows when a measured layout needs a second pass."
  (pcase-let* ((`(,widths ,cell ,line-height ,ascent)
                (org-tategaki-preview--pixel-metrics text window))
               (capacity (max 1 (/ (1- (window-body-height window t)) line-height)))
               (vertical-padding (org-tategaki-preview--vertical-padding capacity))
               (height (min (or max-height most-positive-fixnum)
                            (- capacity (* 2 vertical-padding))))
               (columns (org-tategaki-preview--columns text height))
               (gap (* org-tategaki-preview-column-spacing
                       (frame-char-width (window-frame window))))
               (pitch (+ cell gap))
               (padding (org-tategaki-preview--padding
                         width (frame-char-width (window-frame window))))
               (extent (max width (+ (* 2 padding) (- (* (length columns) pitch) gap))))
               (margin (+ padding (max 0 (- width (* 2 padding)
                                            (- (* (length columns) pitch) gap)))))
               (rows nil))
    (if (null columns) (cons "" 0)
      (dotimes (row height)
        (let ((x margin) cells)
          (dolist (column columns)
            (let* ((char (and (< row (length column)) (aref column row)))
                   (offset (if char (/ (- cell (gethash char widths)) 2) 0))
                   (content (concat
                             (when char
                               (concat
                                (org-tategaki-preview--pixel-space (+ x offset) line-height ascent)
                                (org-tategaki-preview--annotate-cell
                                 (char-to-string char) column row
                                 (+ x offset) (gethash char widths) x cell)))
                             (org-tategaki-preview--pixel-space (+ x cell) line-height ascent))))
              (push (concat (org-tategaki-preview--pixel-space x line-height ascent)
                            (org-tategaki-preview--column-cell content x)) cells))
            (setq x (+ x pitch)))
          (push (concat (apply #'concat (nreverse cells))
                        (org-tategaki-preview--pixel-space extent line-height ascent)) rows)))
      (let ((rendered (propertize (org-tategaki-preview--pad-vertically
                                  (mapconcat #'identity (nreverse rows) "\n")
                                  vertical-padding
                                  (org-tategaki-preview--pixel-space extent line-height ascent))
                                 'face 'org-tategaki-preview-face
                                 ;; The spacers already set a uniform baseline
                                 ;; and height.  A numeric newline height adds
                                 ;; extra ascent and makes the grid too loose.
                                 'line-height t)))
        ;; Font backends can add baseline/descent space beyond the requested
        ;; line height.  Measure the finished layout before choosing capacity.
        (erase-buffer)
        (insert rendered)
        (let ((actual (cdr (window-text-pixel-size window nil nil t)))
              (available (1- (window-body-height window t))))
          (if (and (> height 1) (> actual available))
              (org-tategaki-preview--render-pixels
               text window width (max 1 (min (1- height)
                                             (/ (* height available) actual))))
            (cons rendered extent)))))))

(defvar org-tategaki-preview-buffer-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'org-tategaki-preview-close)
    (define-key map (kbd "g") #'org-tategaki-preview-refresh)
    map))

(define-derived-mode org-tategaki-preview-buffer-mode special-mode "Tategaki"
  "Read-only vertical preview.  Use q to close and g to refresh."
  (setq-local cursor-type nil)
  (setq-local truncate-lines t)
  (setq-local bidi-display-reordering nil)
  (setq-local auto-hscroll-mode nil)
  (setq-local show-trailing-whitespace nil)
  (setq-local line-spacing 0)
  (setq-local buffer-undo-list t)
  ;; Emacs 31 has a separate margin face, which can otherwise remain white
  ;; even when the default face has a black background.
  (when (facep 'margin)
    (face-remap-add-relative 'margin '(:background "#000000")))
  (face-remap-add-relative 'fringe '(:background "#000000"))
  (add-hook 'window-size-change-functions #'org-tategaki-preview--resized nil t)
  (add-hook 'kill-buffer-hook #'org-tategaki-preview--preview-killed nil t))

(defun org-tategaki-preview--cancel-timer ()
  "Cancel the current source buffer's pending refresh."
  (when (timerp org-tategaki-preview--timer)
    (cancel-timer org-tategaki-preview--timer))
  (setq org-tategaki-preview--timer nil))

(defun org-tategaki-preview--schedule-refresh (&rest _ignored)
  "Debounce a refresh of the current source buffer."
  (org-tategaki-preview--cancel-timer)
  (setq org-tategaki-preview--timer
        (run-with-idle-timer (max 0 org-tategaki-preview-refresh-delay) nil
                             #'org-tategaki-preview--refresh (current-buffer))))

(defun org-tategaki-preview--resized (window)
  "Schedule a refresh when preview WINDOW changes size."
  (let ((source org-tategaki-preview--source)
        (size (org-tategaki-preview--window-size window)))
    (when (and (buffer-live-p source)
               (not (equal size org-tategaki-preview--size)))
      (with-current-buffer source
        (when org-tategaki-preview-mode
          (org-tategaki-preview--schedule-refresh))))))

(defun org-tategaki-preview--window-width (window)
  "Return usable width of WINDOW, reserving a truncation-indicator cell."
  (max 1 (1- (window-body-width window))))

(defun org-tategaki-preview--set-margins (window)
  "Apply the preview's fixed side margins to WINDOW."
  (let ((margin (min org-tategaki-preview-window-margin
                     (max 0 (/ (- (window-total-width window) window-min-width) 2)))))
    (unless (equal (window-margins window)
                   (cons (and (> margin 0) margin) (and (> margin 0) margin)))
      (set-window-margins window margin margin))))

(defun org-tategaki-preview--window-size (window)
  "Return WINDOW's layout dimensions, in pixels on graphical frames."
  (let ((pixels (display-graphic-p (window-frame window))))
    (cons (window-body-height window pixels)
          (if pixels (window-body-width window t)
            (org-tategaki-preview--window-width window)))))

(defun org-tategaki-preview--index-positions ()
  "Index source positions and display coordinates in the current preview."
  (mapc #'delete-overlay org-tategaki-preview--column-overlays)
  (setq org-tategaki-preview--column-overlays nil
        org-tategaki-preview--column-index (make-hash-table :test #'eql))
  (let ((position (point-min)) entries)
    (while (< position (point-max))
      (let ((location (get-text-property position 'org-tategaki-preview-location)))
        (when location
          (let ((column (aref location 3)))
            (push (vector (aref location 0) position
                          (aref location 1) (aref location 2) column
                          (aref location 4)) entries))))
      (setq position (next-single-property-change
                      position 'org-tategaki-preview-location nil (point-max))))
    (setq org-tategaki-preview--position-index
          (vconcat (sort entries (lambda (a b) (< (aref a 0) (aref b 0))))))
    (setq position (point-min))
    (while (< position (point-max))
      (let ((column (get-text-property position 'org-tategaki-preview-column))
            (end (next-single-property-change
                  position 'org-tategaki-preview-column nil (point-max))))
        (when column
          (push (cons position end) (gethash column org-tategaki-preview--column-index)))
        (setq position end)))))

(defun org-tategaki-preview--sync-point (&optional force position)
  "Follow source POSITION or point without rebuilding the preview.
FORCE also updates when point has not moved.  Ignore stale render data."
  (when (and org-tategaki-preview-mode org-tategaki-preview-sync-point
             (buffer-live-p org-tategaki-preview--preview)
             (equal org-tategaki-preview--rendered-tick
                    (buffer-chars-modified-tick)))
    (let* ((target (or position (point)))
           (preview org-tategaki-preview--preview)
           (window (get-buffer-window preview t)))
      (when (and window
                 (or force (not (equal target org-tategaki-preview--last-sync-position))))
        (setq org-tategaki-preview--last-sync-position target)
        (with-current-buffer preview
          (let* ((index org-tategaki-preview--position-index)
                 (low 0) (high (length index)))
            ;; Removed markup and whitespace select the next displayed glyph;
            ;; end of buffer selects the last one.
            (while (< low high)
              (let ((middle (/ (+ low high) 2)))
                (if (< (aref (aref index middle) 0) target)
                    (setq low (1+ middle))
                  (setq high middle))))
            (if (zerop (length index))
                (when (overlayp org-tategaki-preview--cursor-overlay)
                  (delete-overlay org-tategaki-preview--cursor-overlay))
              (let* ((entry (aref index (min low (1- (length index)))))
                     (point (aref entry 1))
                     (x (aref entry 4))
                     (glyph-width (aref entry 5))
                     (pixels (display-graphic-p (window-frame window)))
                     (unit (if pixels (frame-char-width (window-frame window)) 1))
                     (width (if pixels (max 1 (- (window-body-width window t) unit))
                              (org-tategaki-preview--window-width window)))
                     (padding (org-tategaki-preview--padding width unit))
                     (left (* unit (window-hscroll window))))
                (unless (overlayp org-tategaki-preview--cursor-overlay)
                  (setq org-tategaki-preview--cursor-overlay (make-overlay point (1+ point)))
                  (overlay-put org-tategaki-preview--cursor-overlay
                               'face 'org-tategaki-preview-current-character)
                  (overlay-put org-tategaki-preview--cursor-overlay 'priority 2))
                (move-overlay org-tategaki-preview--cursor-overlay point (1+ point))
                (mapc #'delete-overlay org-tategaki-preview--column-overlays)
                (setq org-tategaki-preview--column-overlays nil)
                (dolist (range (gethash (aref entry 4) org-tategaki-preview--column-index))
                  (let ((overlay (make-overlay (car range) (cdr range))))
                    (overlay-put overlay 'face 'org-tategaki-preview-current-column)
                    (overlay-put overlay 'priority 1)
                    (push overlay org-tategaki-preview--column-overlays)))
                (cond
                 ((< x (+ left padding))
                  (set-window-hscroll window (max 0 (floor (- x padding) unit))))
                 ((> (+ x glyph-width) (- (+ left width) padding))
                  (set-window-hscroll window (max 0 (ceiling (- (+ x glyph-width padding) width) unit)))))
                (set-window-point window point)))))))))

(defun org-tategaki-preview--source-scrolled (window start)
  "Follow source WINDOW after scrolling to START without moving its cursor."
  (when (eq (window-buffer window) (current-buffer))
    (org-tategaki-preview--sync-point
     nil (if (pos-visible-in-window-p (window-point window) window)
             (window-point window) start))))

(defun org-tategaki-preview--refresh (source)
  "Refresh SOURCE's visible preview, if both buffers still exist."
  (when (buffer-live-p source)
    (with-current-buffer source
      (org-tategaki-preview--cancel-timer)
      (when (and org-tategaki-preview-mode
                 (buffer-live-p org-tategaki-preview--preview))
        (let* ((preview org-tategaki-preview--preview)
               (window (get-buffer-window preview t)))
          (when (window-live-p window)
            (org-tategaki-preview--set-margins window)
            (let ((text (org-tategaki-preview--source-text))
                  (org-tategaki-preview--track-source t)
                  (org-tategaki-preview--org-source (derived-mode-p 'org-mode))
                  (org-tategaki-preview-use-vertical-forms
                   org-tategaki-preview-use-vertical-forms)
                  (org-tategaki-preview-column-spacing
                   org-tategaki-preview-column-spacing))
              (with-selected-window window
                (let* ((inhibit-read-only t)
                       (pixels (display-graphic-p (window-frame window)))
                       (unit (if pixels (frame-char-width (window-frame window)) 1))
                       (size (org-tategaki-preview--window-size window))
                       (width (max 1 (- (cdr size) (if pixels unit 0))))
                       (old-width org-tategaki-preview--pixel-width)
                       (right-offset (max 0 (- old-width width
                                               (* unit (window-hscroll window)))))
                       (result (if pixels
                                   (org-tategaki-preview--render-pixels text window width)
                                 (org-tategaki-preview--render-terminal
                                  text (max 1 (car size)) width))))
                  (erase-buffer)
                  (insert (car result))
                  (add-text-properties (point-min) (point-max)
                                       '(face org-tategaki-preview-face))
                  (goto-char (point-min))
                  (setq org-tategaki-preview--size size
                        org-tategaki-preview--pixel-width (cdr result))
                  (org-tategaki-preview--index-positions)
                  (set-buffer-modified-p nil)
                  (set-window-start window (point-min))
                  (set-window-point window (point-min))
                  (set-window-hscroll
                   window (max 0 (ceiling (- (cdr result) width right-offset)
                                          unit))))))
            (setq org-tategaki-preview--rendered-tick (buffer-chars-modified-tick))
            (org-tategaki-preview--sync-point t)))))))

(defun org-tategaki-preview--source-buffer ()
  "Return the source associated with the current buffer."
  (if (derived-mode-p 'org-tategaki-preview-buffer-mode)
      org-tategaki-preview--source
    (and org-tategaki-preview-mode (current-buffer))))

;;;###autoload
(defun org-tategaki-preview-refresh ()
  "Manually redraw the preview from either the source or preview buffer."
  (interactive)
  (let ((source (org-tategaki-preview--source-buffer)))
    (unless (buffer-live-p source) (user-error "No active Tategaki preview"))
    (org-tategaki-preview--refresh source)))

(defun org-tategaki-preview--stop ()
  "Remove this source's hooks, timer, preview windows and preview buffer."
  (org-tategaki-preview--cancel-timer)
  (remove-hook 'after-change-functions #'org-tategaki-preview--schedule-refresh t)
  (remove-hook 'post-command-hook #'org-tategaki-preview--sync-point t)
  (remove-hook 'window-scroll-functions #'org-tategaki-preview--source-scrolled t)
  (setq org-tategaki-preview--rendered-tick nil
        org-tategaki-preview--last-sync-position nil)
  (remove-hook 'kill-buffer-hook #'org-tategaki-preview--source-killed t)
  (remove-hook 'change-major-mode-hook #'org-tategaki-preview--source-killed t)
  (let ((frame org-tategaki-preview--frame))
    (setq org-tategaki-preview--frame nil)
    (when (frame-live-p frame)
      (set-frame-parameter frame 'org-tategaki-preview-source nil)
      (delete-frame frame)))
  (let ((preview org-tategaki-preview--preview))
    (setq org-tategaki-preview--preview nil)
    (when (buffer-live-p preview)
      (with-current-buffer preview (setq org-tategaki-preview--source nil))
      (delete-windows-on preview)
      (kill-buffer preview))))

(defun org-tategaki-preview--source-killed ()
  "Clean up when the source dies or changes major mode."
  (org-tategaki-preview-mode -1))

(defun org-tategaki-preview--preview-killed ()
  "Detach the source when the preview is killed directly."
  (let ((source org-tategaki-preview--source))
    (when (buffer-live-p source)
      (with-current-buffer source
        (setq org-tategaki-preview--preview nil)
        (org-tategaki-preview-mode -1)))))

(defun org-tategaki-preview--frame-deleted (frame)
  "Detach the preview owned by FRAME when it is closed externally."
  (let ((source (frame-parameter frame 'org-tategaki-preview-source)))
    (when (buffer-live-p source)
      (with-current-buffer source
        (when (eq frame org-tategaki-preview--frame)
          (setq org-tategaki-preview--frame nil)
          (set-frame-parameter frame 'org-tategaki-preview-source nil)
          (org-tategaki-preview-mode -1))))))

(add-hook 'delete-frame-functions #'org-tategaki-preview--frame-deleted)

(defun org-tategaki-preview--open ()
  "Create or redisplay this source's preview window or separate frame."
  (unless (derived-mode-p 'text-mode)
    (user-error "Tategaki preview requires text-mode or a derived mode"))
  (let* ((source (current-buffer))
         (preview org-tategaki-preview--preview)
         (window (and (buffer-live-p preview) (get-buffer-window preview t))))
    (when org-tategaki-preview--open-in-frame
      (unless (frame-live-p org-tategaki-preview--frame)
        (setq org-tategaki-preview--frame
              (save-selected-window
                (make-frame
                 `((name . ,(format "Tategaki Preview: %s" (buffer-name source)))
                   (org-tategaki-preview-source . ,source)))))
        ;; Move an existing side preview instead of displaying two copies
        ;; with incompatible layout dimensions.
        (when (buffer-live-p preview)
          (delete-windows-on preview)))
      (make-frame-visible org-tategaki-preview--frame)
      (setq window (frame-selected-window org-tategaki-preview--frame)))
    (unless (window-live-p window)
      (let ((source-window (get-buffer-window source)))
        (unless source-window (user-error "Display the source buffer first"))
        (setq window (split-window source-window nil 'left))))
    (unless (buffer-live-p preview)
      (setq preview (generate-new-buffer
                     (format "*Tategaki Preview: %s*" (buffer-name source))))
      (setq org-tategaki-preview--preview preview)
      (with-current-buffer preview
        (org-tategaki-preview-buffer-mode)
        (setq org-tategaki-preview--source source)))
    (set-window-buffer window preview)
    (add-hook 'after-change-functions #'org-tategaki-preview--schedule-refresh nil t)
    (add-hook 'post-command-hook #'org-tategaki-preview--sync-point nil t)
    (add-hook 'window-scroll-functions #'org-tategaki-preview--source-scrolled nil t)
    (add-hook 'kill-buffer-hook #'org-tategaki-preview--source-killed nil t)
    (add-hook 'change-major-mode-hook #'org-tategaki-preview--source-killed nil t)
    (org-tategaki-preview--refresh source)))

;;;###autoload
(define-minor-mode org-tategaki-preview-mode
  "Display a live vertical preview of this text-mode-derived buffer."
  :lighter " 縦"
  (if org-tategaki-preview-mode
      (condition-case err
          (org-tategaki-preview--open)
        (error
         (setq org-tategaki-preview-mode nil)
         (org-tategaki-preview--stop)
         (signal (car err) (cdr err))))
    (org-tategaki-preview--stop)))

;;;###autoload
(defun org-tategaki-preview ()
  "Show or reuse a vertical preview to the left of the current text buffer."
  (interactive)
  (org-tategaki-preview-mode 1))

;;;###autoload
(defun org-tategaki-preview-frame ()
  "Show or reuse a separate vertical preview frame for the current text.
Keep the source window selected.  An existing side preview is moved to
the separate frame.  Closing that frame also stops the preview."
  (interactive)
  (let ((source (if (derived-mode-p 'org-tategaki-preview-buffer-mode)
                    org-tategaki-preview--source
                  (current-buffer)))
        (org-tategaki-preview--open-in-frame t))
    (unless (buffer-live-p source) (user-error "No live Tategaki source"))
    (with-current-buffer source
      (org-tategaki-preview-mode 1))))

;;;###autoload
(defun org-tategaki-preview-close ()
  "Close the preview and release its hooks and timer."
  (interactive)
  (let ((source (org-tategaki-preview--source-buffer)))
    (when (buffer-live-p source)
      (with-current-buffer source (org-tategaki-preview-mode -1)))))

;;;###autoload
(defalias 'tategaki-preview #'org-tategaki-preview
  "Show a vertical preview for text-mode and its derived modes.
Org buffers receive light heading formatting; other markup is preserved.")

;;;###autoload
(defalias 'tategaki-preview-refresh #'org-tategaki-preview-refresh)

;;;###autoload
(defalias 'tategaki-preview-frame #'org-tategaki-preview-frame)

;;;###autoload
(defalias 'tategaki-preview-close #'org-tategaki-preview-close)

;; Existing preview users can start the editor without changing their init.
(autoload 'tategaki-edit "tategaki" "Edit text in vertical columns." t)
(autoload 'tategaki-mode "tategaki" "Toggle vertical text editing." t)

(provide 'org-tategaki-preview)
;;; org-tategaki-preview.el ends here
