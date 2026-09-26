;;; tategaki-layout.el --- Lossless character layout for vertical editing -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; A vertical editor must retain every insertion position, including newlines,
;; whitespace, combining characters, and the position at end of buffer.  This
;; module builds an independent display string; it never changes source text.

;;; Code:

(require 'cl-lib)
(require 'org-tategaki-preview)

(defgroup tategaki-layout nil
  "Literal vertical text layout."
  :group 'text)

(defcustom tategaki-layout-use-vertical-forms t
  "Whether punctuation uses Unicode vertical forms in the display."
  :type 'boolean
  :group 'tategaki-layout)

(defcustom tategaki-layout-newline-symbol "↵"
  "Single-character symbol for a newline; one or two display cells wide."
  :type 'string
  :group 'tategaki-layout)

(defcustom tategaki-layout-tab-symbol "⇥"
  "Single-character symbol for a tab; one or two display cells wide."
  :type 'string
  :group 'tategaki-layout)

(defcustom tategaki-layout-eof-symbol "□"
  "Single-character symbol for the insertion position at end of buffer."
  :type 'string
  :group 'tategaki-layout)

(defcustom tategaki-layout-zero-width-symbol "◌"
  "Single-character symbol for a character without its own visible width.
Each source character has a separate cell so that it can be selected or
deleted individually, even when it belongs to a combining sequence."
  :type 'string
  :group 'tategaki-layout)

(defcustom tategaki-layout-control-symbol "�"
  "Single-character symbol for a control without a Unicode control picture."
  :type 'string
  :group 'tategaki-layout)

(defface tategaki-layout-control-face
  '((t (:inherit shadow)))
  "Face for newline, tab, end-of-buffer and other display-only markers."
  :group 'tategaki-layout)

(defconst tategaki-layout-cell-width 2
  "Number of character display cells occupied by each vertical cell.")

(defun tategaki-layout--symbol (symbol fallback)
  "Return SYMBOL when it is one character fitting one cell, else FALLBACK.
Display markers cannot introduce a real newline or tab into the grid."
  (if (and (stringp symbol)
           (= (length symbol) 1)
           (> (string-width symbol) 0)
           (<= (string-width symbol) tategaki-layout-cell-width)
           (not (string-match-p "[\n\r\t]" symbol)))
      (substring-no-properties symbol)
    fallback))

(defun tategaki-layout--glyph (char)
  "Return the display string for source CHAR, or the EOF marker for nil."
  (let* ((category (and char (get-char-code-property char 'general-category)))
         (marker t)
         (glyph
          (cond
           ((null char)
            (tategaki-layout--symbol tategaki-layout-eof-symbol "□"))
           ((eq char ?\n)
            (tategaki-layout--symbol tategaki-layout-newline-symbol "↵"))
           ((eq char ?\t)
            (tategaki-layout--symbol tategaki-layout-tab-symbol "⇥"))
           ((< char 32) (char-to-string (+ #x2400 char)))
           ((eq char 127) "␡")
           ((zerop (char-width char))
            (tategaki-layout--symbol tategaki-layout-zero-width-symbol "◌"))
           ((memq category '(Cc Cf Zl Zp))
            (tategaki-layout--symbol tategaki-layout-control-symbol "�"))
           (t
            (setq marker nil)
            (char-to-string
             (if tategaki-layout-use-vertical-forms
                 (or (alist-get char org-tategaki-preview--vertical-forms) char)
               char))))))
    (when marker
      (put-text-property 0 (length glyph) 'face
                         'tategaki-layout-control-face glyph))
    glyph))

(defun tategaki-layout-render (text height &optional width start)
  "Return a literal vertical layout of TEXT as a property list.
HEIGHT is a positive number of rows.  Characters run from top to bottom,
and columns from right to left.  Each newline occupies one visible cell
then starts a new column.  Every source character, including whitespace,
has its own cell; the final insertion position gets an additional EOF cell.

WIDTH, when non-nil, is a minimum overall width in character display cells.
Short layouts are padded on the left to align their first column at the
right edge.  Longer layouts are never cropped.  START is the position of
the first character in the source buffer, defaulting to 1 for a full buffer.

The result contains :text, the display string; :positions, a vector in
source order with entries [SOURCE-POS STRING-OFFSET ROW COLUMN]; :height;
and :columns.  Rows and columns are zero-based; column zero is rightmost.
String offsets are zero-based character offsets, suitable for adding to a
display buffer's `point-min'.  Glyphs and their padding carry the properties
`tategaki-position', `tategaki-row' and `tategaki-column'.  Empty grid cells
and row separators have no source position.  :padding is the left padding
width and :cell-width is the width of each vertical cell.

This function does not mutate TEXT or copy any of its text properties."
  (unless (stringp text)
    (signal 'wrong-type-argument (list 'stringp text)))
  (unless (and (integerp height) (> height 0))
    (signal 'wrong-type-argument (list 'positive-integer-p height)))
  (unless (or (null width) (and (integerp width) (>= width 0)))
    (signal 'wrong-type-argument (list 'natnump width)))
  (setq start (or start 1))
  (unless (and (integerp start) (> start 0))
    (signal 'wrong-type-argument (list 'positive-integer-p start)))
  (let* ((length (length text))
         (positions (make-vector (1+ length) nil))
         (column 0)
         (row 0)
         (cells (make-vector height nil))
         (columns (list cells)))
    (dotimes (index (1+ length))
      (let ((char (and (< index length) (aref text index))))
        (aset cells row (vector (tategaki-layout--glyph char) index))
        (aset positions index (vector (+ start index) nil row column))
        (when (< index length)
          (setq row (if (eq char ?\n) height (1+ row)))
          (when (= row height)
            (setq row 0
                  column (1+ column)
                  cells (make-vector height nil))
            (push cells columns)))))
    (let* ((count (length columns))
           (padding (max 0 (- (or width 0)
                              (* count tategaki-layout-cell-width))))
           (blank (make-string tategaki-layout-cell-width ?\s))
           (rendered
            (with-temp-buffer
              (dotimes (display-row height)
                (insert (make-string padding ?\s))
                (dolist (display-column columns)
                  (let ((cell (aref display-column display-row)))
                    (if (null cell)
                        (insert blank)
                      (let* ((glyph (aref cell 0))
                             (entry (aref positions (aref cell 1)))
                             (begin (point)))
                        (aset entry 1 (1- begin))
                        (insert glyph)
                        (insert (make-string
                                 (max 0 (- tategaki-layout-cell-width
                                           (string-width glyph))) ?\s))
                        (add-text-properties
                         begin (point)
                         (list 'tategaki-position (aref entry 0)
                               'tategaki-row (aref entry 2)
                               'tategaki-column (aref entry 3)
                               'rear-nonsticky t))))))
                (when (< display-row (1- height)) (insert "\n")))
              (buffer-string))))
      (list :text rendered :positions positions :height height :columns count
            :padding padding :cell-width tategaki-layout-cell-width))))

(provide 'tategaki-layout)
;;; tategaki-layout.el ends here
