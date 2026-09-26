;;; tategaki-manuscript.el --- Manuscript pages and writing statistics -*- lexical-binding: t; -*-

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
;; Fixed paper dimensions are independent of the display window.  Navigation
;; uses the renderer's source-position map; statistics read source text only.
;; Whole-document and chapter counts are cached between text edits.  Installing
;; the status display never changes source properties, modified state, or undo.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tategaki-typeset)

(defgroup tategaki-manuscript nil
  "Paper dimensions and statistics for vertical writing."
  :group 'text)

(defcustom tategaki-manuscript-size nil
  "Fixed paper size as (ROWS . COLUMNS), or nil to fit the window.
Both dimensions must be positive integers.  Resizing a window changes the
display scale of a fixed page, not its logical number of rows or columns."
  :type '(choice (const :tag "Fit window" nil)
                 (cons :tag "Fixed paper" (integer :tag "Rows")
                       (integer :tag "Columns")))
  :group 'tategaki-manuscript)

(defcustom tategaki-manuscript-spread nil
  "Whether the renderer displays two paper pages side by side.
Page numbers and page counts continue to refer to individual paper pages."
  :type 'boolean
  :group 'tategaki-manuscript)

(defcustom tategaki-manuscript-grid nil
  "Whether the renderer draws manuscript cell guides."
  :type 'boolean
  :group 'tategaki-manuscript)

(defcustom tategaki-manuscript-status t
  "Whether the active vertical editor shows writing statistics in its mode line."
  :type 'boolean
  :group 'tategaki-manuscript)

(defcustom tategaki-manuscript-target-characters nil
  "Character-count goal for this document, or nil for no goal.
The remaining count follows the same counting rules as the document total."
  :type '(choice (const :tag "No goal" nil) natnum)
  :group 'tategaki-manuscript)

(defcustom tategaki-manuscript-count-whitespace t
  "Whether character counts include spaces, tabs and other horizontal whitespace.
Newlines are controlled separately by `tategaki-manuscript-count-newlines'."
  :type 'boolean
  :group 'tategaki-manuscript)

(defcustom tategaki-manuscript-count-newlines nil
  "Whether character counts include newline and carriage-return characters."
  :type 'boolean
  :group 'tategaki-manuscript)

(defcustom tategaki-manuscript-count-markup nil
  "Whether character counts include supported typesetting markup.
When nil, count the body of ruby, emphasis and tate-chu-yoko notation using
`tategaki-typeset-plain-text'.  Incomplete or unsupported notation remains
literal and is counted as written.  Counts use Emacs characters, not bytes."
  :type 'boolean
  :group 'tategaki-manuscript)

(defcustom tategaki-manuscript-chapter-regexp 'auto
  "How chapter boundaries are recognized for character counts.
`auto' recognizes Org headings in Org buffers; elsewhere it recognizes
Markdown ATX headings and Japanese headings such as 第三章 or 第12章.
`outline' uses the buffer's `outline-regexp'.  A string is an explicit
heading regexp.  Nil disables chapter counts.  Each matching heading starts
a chapter that ends before the next matching heading, including its own
heading text.  Text before the first heading is a separate preamble."
  :type '(choice (const :tag "Automatic headings" auto)
                 (const :tag "Use outline-regexp" outline)
                 (regexp :tag "Heading regexp")
                 (const :tag "Disable chapter counts" nil))
  :group 'tategaki-manuscript)

(dolist (variable '(tategaki-manuscript-size tategaki-manuscript-spread
                    tategaki-manuscript-grid tategaki-manuscript-status
                    tategaki-manuscript-target-characters
                    tategaki-manuscript-count-whitespace
                    tategaki-manuscript-count-newlines
                    tategaki-manuscript-count-markup
                    tategaki-manuscript-chapter-regexp))
  (make-variable-buffer-local variable))

(defvar tategaki-mode)
(defvar tategaki--layout)
(defvar tategaki--page-size)
(defvar tategaki--cache-key)
(defvar tategaki--scroll-start)
(defvar tategaki--page-goal)
(defvar tategaki--goal-row)
(defvar outline-regexp)
(declare-function tategaki-refresh "tategaki" ())
(declare-function tategaki--virtual-position "tategaki" (position))
(declare-function tategaki--source-position "tategaki" (position))

(defvar-local tategaki-manuscript--enabled nil)
(defvar-local tategaki-manuscript--saved-mode-line nil)
(defvar-local tategaki-manuscript--cache nil)
(defvar-local tategaki-manuscript--cache-key nil)
(defvar-local tategaki-manuscript--selection-cache nil)
(defvar-local tategaki-manuscript--dirty t)

(defun tategaki-manuscript-config ()
  "Return paper settings as :rows, :columns, :spread and :grid.
Rows and columns are nil for an adaptive page.  Reject invalid dimensions
before they can cause a division by zero or an unbounded layout."
  (let ((size tategaki-manuscript-size))
    (unless (or (null size)
                (and (consp size)
                     (integerp (car size)) (> (car size) 0)
                     (integerp (cdr size)) (> (cdr size) 0)))
      (user-error "Paper size must be nil or a positive (rows . columns) pair"))
    (list :rows (car size) :columns (cdr size)
          :spread (and tategaki-manuscript-spread t)
          :grid (and tategaki-manuscript-grid t))))

(defun tategaki-manuscript--entry (layout position)
  "Return the entry in LAYOUT corresponding to source POSITION."
  (if (plist-get layout :typeset)
      (tategaki-typeset-entry layout position)
    (let* ((positions (plist-get layout :positions))
           (start (or (plist-get layout :start)
                      (and (> (length positions) 0) (aref (aref positions 0) 0))))
           (index (and start (- position start))))
      (when (and index (<= 0 index) (< index (length positions)))
        (aref positions index)))))

(defun tategaki-manuscript--columns-per-page (&optional adaptive-columns)
  "Return fixed paper columns or the ADAPTIVE-COLUMNS fallback."
  (or (plist-get (tategaki-manuscript-config) :columns)
      (let ((columns (or adaptive-columns
                         (and (boundp 'tategaki--page-size) tategaki--page-size))))
        (if (and (integerp columns) (> columns 0)) columns 1))))

(defun tategaki-manuscript--content-columns (layout)
  "Return the number of LAYOUT columns containing actual source text.
An EOF-only column does not add a manuscript sheet.  Empty text uses zero."
  (or (plist-get layout :content-columns)
      (let* ((positions (plist-get layout :positions))
             (start (or (plist-get layout :start)
                        (and (> (length positions) 0) (aref (aref positions 0) 0))))
             (end (or (plist-get layout :end)
                      (and start (+ start (1- (length positions)))))))
        (if (and start end (> end start))
            (let ((entry (tategaki-manuscript--entry layout (1- end))))
              (if entry (1+ (aref entry 3)) 0))
          0))))

(defun tategaki-manuscript-page-info (layout position &optional adaptive-columns)
  "Return page information for POSITION in LAYOUT.
POSITION uses the layout's coordinate space (including any virtual preedit).
The result has :current, :total, :columns-per-page and :content-pages.
Navigation total includes an EOF-only page; content pages exclude it.
ADAPTIVE-COLUMNS overrides the window capacity when paper size is adaptive.
Literal fallback always uses adaptive columns, retaining but not applying
the stored fixed-paper setting."
  (let* ((columns-per-page
          (let ((tategaki-manuscript-size
                 (and (plist-get layout :typeset) tategaki-manuscript-size)))
            (tategaki-manuscript--columns-per-page adaptive-columns)))
         (entry (tategaki-manuscript--entry layout position))
         (column (if entry (aref entry 3) 0))
         (columns (max 1 (or (plist-get layout :columns) 1)))
         (total (max 1 (ceiling columns columns-per-page))))
    (list :current (min total (1+ (floor column columns-per-page)))
          :total total :columns-per-page columns-per-page
          :content-pages (ceiling (tategaki-manuscript--content-columns layout)
                                  columns-per-page))))

(defun tategaki-manuscript--refresh ()
  "Refresh the editor after a display-only manuscript setting changes."
  (when (boundp 'tategaki--cache-key) (setq tategaki--cache-key nil))
  (when (and (bound-and-true-p tategaki-mode) (fboundp 'tategaki-refresh))
    (tategaki-refresh))
  (force-mode-line-update))

;;;###autoload
(defun tategaki-manuscript-set-preset (preset)
  "Set this buffer's paper PRESET to 20x20, 40x30, or adaptive."
  (interactive
   (list (completing-read "Paper preset: " '("20x20" "40x30" "adaptive")
                          nil t nil nil "20x20")))
  (setq tategaki-manuscript-size
        (pcase preset
          ((or "20x20" '20x20) '(20 . 20))
          ((or "40x30" '40x30) '(40 . 30))
          ((or "adaptive" 'adaptive 'nil) nil)
          (_ (user-error "Unknown paper preset: %s" preset))))
  (tategaki-manuscript--refresh))

;;;###autoload
(defun tategaki-manuscript-toggle-spread (&optional arg)
  "Toggle two-page display, or enable it when prefix ARG is positive."
  (interactive "P")
  (setq tategaki-manuscript-spread
        (if arg (> (prefix-numeric-value arg) 0)
          (not tategaki-manuscript-spread)))
  (tategaki-manuscript--refresh))

;;;###autoload
(defun tategaki-manuscript-toggle-grid (&optional arg)
  "Toggle manuscript cell guides, or enable them for positive prefix ARG."
  (interactive "P")
  (setq tategaki-manuscript-grid
        (if arg (> (prefix-numeric-value arg) 0)
          (not tategaki-manuscript-grid)))
  (tategaki-manuscript--refresh))

;;;###autoload
(defun tategaki-manuscript-set-target (characters)
  "Set this buffer's writing goal to CHARACTERS; zero removes the goal."
  (interactive
   (list (read-number "Character goal (0 to clear): "
                       (or tategaki-manuscript-target-characters 0))))
  (unless (and (integerp characters) (>= characters 0))
    (user-error "Character goal must be a nonnegative integer"))
  (setq tategaki-manuscript-target-characters (and (> characters 0) characters))
  (force-mode-line-update))

;;;###autoload
(defun tategaki-goto-page (page)
  "Move point to the first editable position of document PAGE (one-based)."
  (interactive (list (read-number "Go to page: " 1)))
  (unless (bound-and-true-p tategaki-mode)
    (user-error "Enable tategaki-mode before moving to a vertical page"))
  (unless (and (integerp page) (> page 0))
    (user-error "Page number must be a positive integer"))
  (tategaki-refresh)
  (let* ((layout tategaki--layout)
         (start (or (plist-get layout :start) (point-min)))
         (info (tategaki-manuscript-page-info layout start))
         (column (* (1- page) (plist-get info :columns-per-page))))
    (when (> page (plist-get info :total))
      (user-error "Page %d exceeds the document's %d pages"
                  page (plist-get info :total)))
    (let ((entry
           (if (plist-get layout :typeset)
               (tategaki-typeset-nearest layout column 0)
             (cl-find-if (lambda (item) (= (aref item 3) column))
                         (plist-get layout :positions)))))
      (unless entry (user-error "No editable position on page %d" page))
      ;; Page navigation leaves any column-by-column scrollbar viewport.
      (setq tategaki--scroll-start nil tategaki--page-goal nil
            tategaki--goal-row nil)
      (goto-char (if (fboundp 'tategaki--source-position)
                     (tategaki--source-position (aref entry 0))
                   (aref entry 0)))
      (tategaki-refresh))))

(defun tategaki-manuscript-count-text (text)
  "Count TEXT using the current whitespace, newline and markup settings."
  (save-match-data
    ;; Ordinary prose needs no annotation parser, even in very large files.
    (when (and (not tategaki-manuscript-count-markup)
               (string-match-p "[《［]" text))
      (setq text (tategaki-typeset-plain-text text)))
    (unless tategaki-manuscript-count-newlines
      (setq text (replace-regexp-in-string "[\n\r]" "" text t t)))
    (unless tategaki-manuscript-count-whitespace
      (setq text (replace-regexp-in-string "[[:blank:]\f\v]" "" text t t)))
    (length text)))

(defun tategaki-manuscript--heading-regexp ()
  "Resolve the current chapter-detection setting to a heading regexp."
  (pcase tategaki-manuscript-chapter-regexp
    ('auto
     (if (derived-mode-p 'org-mode)
         "^\\*+[ \t]+"
       "^[ \t]*\\(?:#\\{1,6\\}[ \t]+\\|第[0-9０-９〇零一二三四五六七八九十百千万壱弐参]+章\\)"))
    ('outline (and (boundp 'outline-regexp) outline-regexp))
    ((pred stringp) tategaki-manuscript-chapter-regexp)
    (_ nil)))

(defun tategaki-manuscript--build-chapters (regexp)
  "Build cached [START END TITLE COUNT] chapter entries matching REGEXP."
  (when regexp
    (save-excursion
      (goto-char (point-min))
      (let (headings)
        (while (re-search-forward regexp nil t)
          (let ((start (line-beginning-position)))
            (unless (or (= start (point-max))
                        (and headings (= start (caar headings))))
              (push (cons start (string-trim
                                 (buffer-substring-no-properties
                                  start (line-end-position))))
                    headings))))
        (when headings
          (setq headings (nreverse headings))
          (when (> (caar headings) (point-min))
            (push (cons (point-min) "前文") headings))
          (let (chapters)
            (while headings
              (let* ((heading (pop headings))
                     (start (car heading))
                     (end (if headings (caar headings) (point-max))))
                (push (vector start end (cdr heading)
                              (tategaki-manuscript-count-text
                               (buffer-substring-no-properties start end)))
                      chapters)))
            (vconcat (nreverse chapters))))))))

(defun tategaki-manuscript--invalidate (&rest _ignored)
  "Invalidate text statistics after a source edit."
  (setq tategaki-manuscript--dirty t
        tategaki-manuscript--selection-cache nil)
  (force-mode-line-update))

(defun tategaki-manuscript--ensure-cache ()
  "Return cached whole-document and chapter statistics, refreshing if needed."
  (let* ((regexp (tategaki-manuscript--heading-regexp))
         (key (list (buffer-chars-modified-tick)
                    tategaki-manuscript-count-whitespace
                    tategaki-manuscript-count-newlines
                    tategaki-manuscript-count-markup regexp)))
    (when (or tategaki-manuscript--dirty
              (not (equal key tategaki-manuscript--cache-key)))
      (save-restriction
        (widen)
        (setq tategaki-manuscript--cache
              (list :characters
                    (tategaki-manuscript-count-text
                     (buffer-substring-no-properties (point-min) (point-max)))
                    :chapters (tategaki-manuscript--build-chapters regexp))))
      (setq tategaki-manuscript--cache-key key
            tategaki-manuscript--selection-cache nil
            tategaki-manuscript--dirty nil))
    tategaki-manuscript--cache))

(defun tategaki-manuscript--chapter-at (position)
  "Find cached chapter containing source POSITION with a binary search."
  (let* ((chapters (plist-get tategaki-manuscript--cache :chapters))
         (low 0) (high (1- (length chapters))) found)
    (while (<= low high)
      (let* ((middle (/ (+ low high) 2))
             (chapter (aref chapters middle)))
        (if (< position (aref chapter 0))
            (setq high (1- middle))
          (setq found chapter low (1+ middle)))))
    found))

(defun tategaki-manuscript--count-region (start end)
  "Count START..END, preserving annotations cut by either selection boundary.
Complete surrounding lines provide annotation context; supported notation
does not cross a newline.  Plain selections need no surrounding scan."
  (let ((text (buffer-substring-no-properties start end)))
    (if (or tategaki-manuscript-count-markup
            (not (string-match-p "[《［]" text)))
        (tategaki-manuscript-count-text text)
      (save-excursion
        (save-restriction
          (widen)
          (let* ((context-start (progn (goto-char start) (line-beginning-position)))
                 (context-end (progn (goto-char end) (line-end-position)))
                 (body (tategaki-typeset-plain-text
                        (buffer-substring-no-properties context-start context-end)
                        (- start context-start) (- end context-start)))
                 ;; The context-aware pass deliberately preserved partial
                 ;; notation.  Do not reinterpret that fragment in isolation.
                 (tategaki-manuscript-count-markup t))
            (tategaki-manuscript-count-text body)))))))

(defun tategaki-manuscript--selection-count ()
  "Return the active selection's count, reusing it while its bounds are stable."
  (when (use-region-p)
    (let* ((start (region-beginning)) (end (region-end))
           (key (list start end tategaki-manuscript--cache-key)))
      (unless (equal key (car tategaki-manuscript--selection-cache))
        (setq tategaki-manuscript--selection-cache
              (cons key (tategaki-manuscript--count-region start end))))
      (cdr tategaki-manuscript--selection-cache))))

(defun tategaki-manuscript-statistics (&optional layout)
  "Return document, chapter, selection, page and goal statistics.
Character counts cover the entire source buffer, even when it is narrowed.
Page counts describe LAYOUT, defaulting to the current editing layout; that
layout can cover a narrowed region.  Uncommitted IME text is excluded from
character counts.  :manuscript-pages is a ceiling of characters divided by
400, while :layout-pages counts sheets occupied by the actual layout."
  (save-match-data
    (let* ((cache (tategaki-manuscript--ensure-cache))
           (characters (plist-get cache :characters))
           (chapter (tategaki-manuscript--chapter-at (point)))
           (layout (or layout (and (boundp 'tategaki--layout) tategaki--layout)))
           (position (if (and layout (fboundp 'tategaki--virtual-position))
                         (tategaki--virtual-position (point)) (point)))
           (pages (tategaki-manuscript-page-info layout position))
           (target tategaki-manuscript-target-characters))
      (list :characters characters
            :selection (tategaki-manuscript--selection-count)
            :chapter (and chapter (aref chapter 3))
            :chapter-title (and chapter (aref chapter 2))
            :manuscript-pages (ceiling characters 400)
            :layout-pages (plist-get pages :content-pages)
            :current-page (plist-get pages :current)
            :total-pages (plist-get pages :total)
            :target target
            :remaining (and (integerp target) (>= target 0)
                            (max 0 (- target characters)))))))

(defun tategaki-manuscript-mode-line ()
  "Return this buffer's compact manuscript status, or nil when disabled."
  (when (and tategaki-manuscript--enabled tategaki-manuscript-status)
    (let* ((stats (tategaki-manuscript-statistics))
           (selection (plist-get stats :selection))
           (chapter (plist-get stats :chapter))
           (remaining (plist-get stats :remaining)))
      (propertize
       (concat
        (format " %d/%d頁 %d字" (plist-get stats :current-page)
                (plist-get stats :total-pages) (plist-get stats :characters))
        (format " 400字%d枚 配%d枚" (plist-get stats :manuscript-pages)
                (plist-get stats :layout-pages))
        (when remaining (format " 残%d" remaining))
        (when selection (format " 選%d" selection))
        (when chapter (format " 章%d" chapter)))
       'help-echo
       "現在/総ページ・全文字数・選択/章字数・400字換算枚数・本文配置枚数・目標残り"))))

(defun tategaki-manuscript-enable ()
  "Install buffer-local manuscript statistics without changing source text."
  (unless tategaki-manuscript--enabled
    (setq tategaki-manuscript--enabled t
          tategaki-manuscript--saved-mode-line
          (list (local-variable-p 'mode-line-format) mode-line-format))
    ;; A deliberately hidden mode line remains hidden.
    (when mode-line-format
      (let ((identity-tail (and (listp mode-line-format)
                                (memq 'mode-line-buffer-identification
                                      mode-line-format)))
            (status '(:eval (tategaki-manuscript-mode-line))))
        ;; Keep the buffer name and statistics ahead of position/minor modes.
        ;; An unfamiliar custom format is retained as one intact component.
        ;; All construction is non-destructive: global/shared lists are safe.
        (setq-local mode-line-format
                    (if identity-tail
                        (append (butlast mode-line-format
                                         (1- (length identity-tail)))
                                (list status) (cdr identity-tail))
                      (list status '(tategaki-manuscript-status " ")
                            mode-line-format)))))
    (add-hook 'after-change-functions #'tategaki-manuscript--invalidate nil t)
    (add-hook 'change-major-mode-hook #'tategaki-manuscript-disable nil t)
    (tategaki-manuscript--invalidate)))

(defun tategaki-manuscript-disable ()
  "Restore the original mode line and remove local statistics hooks."
  (when tategaki-manuscript--enabled
    (if (car tategaki-manuscript--saved-mode-line)
        (setq-local mode-line-format (cadr tategaki-manuscript--saved-mode-line))
      (kill-local-variable 'mode-line-format))
    (setq tategaki-manuscript--enabled nil
          tategaki-manuscript--saved-mode-line nil
          tategaki-manuscript--cache nil
          tategaki-manuscript--cache-key nil
          tategaki-manuscript--selection-cache nil
          tategaki-manuscript--dirty t)
    (remove-hook 'after-change-functions #'tategaki-manuscript--invalidate t)
    (remove-hook 'change-major-mode-hook #'tategaki-manuscript-disable t)
    (force-mode-line-update)))

(provide 'tategaki-manuscript)
;;; tategaki-manuscript.el ends here
