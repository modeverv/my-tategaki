;;; tategaki-writing.el --- Prose and script input helpers -*- lexical-binding: t; -*-

;; These helpers edit ordinary source text.  Enabling the mode never reformats
;; an existing paragraph; formatting a region is always an explicit command.

;;; Code:

(require 'cl-lib)
(require 'elec-pair)
(require 'subr-x)

(defgroup tategaki-writing nil
  "Prose and script input in vertical text buffers."
  :group 'tategaki)

(defcustom tategaki-writing-assistance t
  "Whether entering tategaki enables `tategaki-writing-mode'."
  :type 'boolean :group 'tategaki-writing)

(defcustom tategaki-writing-auto-indent t
  "Insert paragraph indentation on RET and adjust newly typed dialogue.
Only newly entered text is adjusted automatically.  Pasting or loading a
document does not reformat it.  Use `tategaki-writing-indent-line' or
`tategaki-script-format-region' to format existing text explicitly."
  :type 'boolean :group 'tategaki-writing)

(defcustom tategaki-writing-paragraph-indent 1
  "Number of fullwidth spaces at the start of prose paragraphs."
  :type 'natnum :group 'tategaki-writing)

(defcustom tategaki-writing-dialogue-indent 0
  "Number of fullwidth spaces before dialogue in prose."
  :type 'natnum :group 'tategaki-writing)

(defcustom tategaki-writing-dialogue-openers "「『“‘"
  "Characters starting a prose dialogue paragraph."
  :type 'string :group 'tategaki-writing)

(defcustom tategaki-writing-unindented-prefix-regexp
  "\\(?:[*#]+\\|第[[:digit:]一二三四五六七八九十百千万〇零]+[章節部]\\)"
  "Paragraph prefixes that should remain unindented while typing.
The default preserves Org/Markdown heading markers even before their first
space is typed, and Japanese numbered chapter headings once 章/節/部 is
entered.  Set nil to disable this exception.  Matches start after any
leading whitespace and do not add an indentation to existing headings."
  :type '(choice (const nil) regexp) :group 'tategaki-writing)

(defcustom tategaki-writing-electric-pair t
  "Use native buffer-local Electric Pair mode while writing assistance is on.
Existing Electric Pair configuration is preserved and restored on exit.
Set this to nil when another package, such as Smartparens, supplies pairing."
  :type 'boolean :group 'tategaki-writing)

(defcustom tategaki-writing-bracket-pairs
  '((?「 . ?」) (?『 . ?』) (?（ . ?）) (?［ . ?］) (?【 . ?】)
    (?〈 . ?〉) (?《 . ?》))
  "Additional native Electric Pair pairs, local to the writing buffer."
  :type '(repeat (cons character character)) :group 'tategaki-writing)

(defcustom tategaki-writing-style 'prose
  "Indentation convention used by the writing commands.
`prose' indents paragraphs and lets dialogue start at the column head.
`script' uses separate speaker, dialogue and stage-direction paragraphs.
Changing this option does not rewrite existing text."
  :type '(choice (const prose) (const script)) :group 'tategaki-writing)
(make-variable-buffer-local 'tategaki-writing-style)

(defcustom tategaki-script-speaker-indent 0
  "Fullwidth spaces before a speaker paragraph in script style."
  :type 'natnum :group 'tategaki-writing)

(defcustom tategaki-script-dialogue-indent 2
  "Fullwidth spaces before dialogue paragraphs in script style."
  :type 'natnum :group 'tategaki-writing)

(defcustom tategaki-script-stage-direction-indent 1
  "Fullwidth spaces before parenthesized stage directions in script style."
  :type 'natnum :group 'tategaki-writing)

(defcustom tategaki-script-speaker-regexp "[^：:\n]+[：:][ \t　]*$"
  "Regexp recognizing a script speaker paragraph after leading whitespace.
The default recognizes a name followed by a fullwidth or ASCII colon.
Dialogue is a separate paragraph, usually enclosed by 「 and 」."
  :type 'regexp :group 'tategaki-writing)

(defcustom tategaki-script-stage-direction-regexp "[（(]"
  "Regexp recognizing a stage direction after leading whitespace."
  :type 'regexp :group 'tategaki-writing)

(defvar-local tategaki-writing--saved-settings nil)
(defvar-local tategaki-writing--active nil)
(defvar-local tategaki-writing--pair-local-was-listed nil)
(defvar-local tategaki-writing--pending-indent nil)
(defvar tategaki-writing--inhibit nil)
(defvar-local tategaki-writing--managed nil)

(defconst tategaki-writing--input-commands
  '(self-insert-command ns-insert-text ns-insert-working-text)
  "Commands whose newly entered paragraph prefix may be adjusted.")

(defun tategaki-writing--save-setting (symbol)
  "Save SYMBOL once, including whether its old binding was local."
  (unless (assq symbol tategaki-writing--saved-settings)
    (push (list symbol (local-variable-p symbol) (symbol-value symbol))
          tategaki-writing--saved-settings)))

(defun tategaki-writing--restore-settings ()
  "Restore saved local settings without affecting any other buffer."
  (dolist (entry tategaki-writing--saved-settings)
    (if (nth 1 entry)
        (set (make-local-variable (car entry)) (nth 2 entry))
      (kill-local-variable (car entry))))
  (setq tategaki-writing--saved-settings nil))

(defun tategaki-writing--desired-indent ()
  "Return the fullwidth indentation for the current paragraph."
  (save-match-data
    (save-excursion
      (beginning-of-line)
      (skip-chars-forward " \t　" (line-end-position))
      (max 0
           (cond
            ((and tategaki-writing-unindented-prefix-regexp
                  (looking-at tategaki-writing-unindented-prefix-regexp)) 0)
            ((eq tategaki-writing-style 'script)
             (cond
              ((looking-at tategaki-script-speaker-regexp)
               tategaki-script-speaker-indent)
              ((looking-at tategaki-script-stage-direction-regexp)
               tategaki-script-stage-direction-indent)
              (t tategaki-script-dialogue-indent)))
            ((and (char-after)
                  (cl-find (char-after) tategaki-writing-dialogue-openers))
             tategaki-writing-dialogue-indent)
            (t tategaki-writing-paragraph-indent))))))

(defun tategaki-writing--indent-current-line (count)
  "Set current paragraph indentation to COUNT fullwidth spaces.
Retain point relative to the text, or move it to the end of indentation."
  (let* ((tategaki-writing--inhibit t)
         (origin (point))
         (start (line-beginning-position))
         (end (save-excursion
                (goto-char start)
                (skip-chars-forward " \t　" (line-end-position))
                (point)))
         (indent (make-string (max 0 count) ?　)))
    (unless (equal indent (buffer-substring-no-properties start end))
      (save-excursion
        (goto-char start)
        (delete-region start end)
        (insert indent))
      (goto-char (+ start (length indent) (max 0 (- origin end)))))))

(defun tategaki-writing-indent-line ()
  "Indent the current prose or script paragraph using fullwidth spaces."
  (interactive)
  (barf-if-buffer-read-only)
  (atomic-change-group
    (tategaki-writing--indent-current-line
     (tategaki-writing--desired-indent))))

(defun tategaki-writing--clear-pending ()
  "Discard any pending automatic indentation marker."
  (when (markerp tategaki-writing--pending-indent)
    (set-marker tategaki-writing--pending-indent nil))
  (setq tategaki-writing--pending-indent nil))

(defun tategaki-writing--structural-prefix-input-p (position)
  "Whether insertion at POSITION finishes a heading or script speaker prefix."
  (save-match-data
    (save-excursion
      (goto-char position)
      (beginning-of-line)
      (skip-chars-forward " \t　" (line-end-position))
      (or (and tategaki-writing-unindented-prefix-regexp
               (looking-at tategaki-writing-unindented-prefix-regexp)
               (< position (match-end 0)))
          (and (eq tategaki-writing-style 'script)
               (looking-at tategaki-script-speaker-regexp)
               (< position (match-end 0)))))))

(defun tategaki-writing--after-change (beg end old-length)
  "Remember a newly typed paragraph prefix from BEG to END.
OLD-LENGTH is the replaced text length.  Undo, paste, source loading and
multi-paragraph insertions are deliberately excluded."
  (when (and tategaki-writing-auto-indent
             (not tategaki-writing--inhibit)
             (not undo-in-progress)
             (zerop old-length) (< beg end)
             (memq this-command tategaki-writing--input-commands)
             (string-match-p "[^ \t　]"
                             (buffer-substring-no-properties beg end))
             (save-excursion
               (goto-char beg)
               (and (<= end (line-end-position))
                    (or (string-match-p
                         "\\`[ \t　]*\\'"
                         (buffer-substring-no-properties
                          (line-beginning-position) beg))
                        (tategaki-writing--structural-prefix-input-p beg)))))
    (tategaki-writing--clear-pending)
    (setq tategaki-writing--pending-indent
          (copy-marker (save-excursion (goto-char beg)
                                      (line-beginning-position))))))

(defun tategaki-writing--finish-input ()
  "Adjust a newly entered paragraph prefix, including committed IME text."
  (when tategaki-writing--pending-indent
    (let ((marker tategaki-writing--pending-indent))
      (setq tategaki-writing--pending-indent nil)
      (unwind-protect
          (when (and tategaki-writing-auto-indent
                     (not buffer-read-only) (not undo-in-progress)
                     (marker-buffer marker))
            (save-excursion
              (goto-char marker)
              ;; In prose, this handles the first character of the first
              ;; paragraph as well as removing the provisional RET indent
              ;; when a dialogue opening bracket is typed next.
              (unless (= (line-beginning-position) (line-end-position))
                (tategaki-writing-indent-line))))
        (set-marker marker nil)))))

(defun tategaki-writing--inside-dialogue-p ()
  "Whether point follows an unclosed dialogue opener on the current line."
  (let* ((prefix (string-trim-left
                  (buffer-substring-no-properties
                   (line-beginning-position) (point)) "[ \t　]+"))
         (opening (and (> (length prefix) 0) (aref prefix 0)))
         (closing (or (cdr (assq opening tategaki-writing-bracket-pairs))
                      (cdr (assq opening '((?“ . ?”) (?‘ . ?’)))))))
    (and opening closing
         (cl-find opening tategaki-writing-dialogue-openers)
         (> (cl-count opening prefix) (cl-count closing prefix)))))

(defun tategaki-writing-newline (&optional count)
  "Insert COUNT newlines, then indent the resulting prose or script paragraph.
Blank separator paragraphs remain blank.  With automatic indentation off,
delegate to ordinary `newline'.  C-u 2 RET inserts one empty separator line."
  (interactive "p")
  (barf-if-buffer-read-only)
  (let ((continue-dialogue (and (eq tategaki-writing-style 'prose)
                               (tategaki-writing--inside-dialogue-p)))
        (tategaki-writing--inhibit t)
        (electric-indent-inhibit t)
        (electric-pair-open-newline-between-pairs nil))
    (atomic-change-group
      (tategaki-writing--clear-pending)
      ;; A second RET on an indentation-only paragraph leaves an empty line.
      (when (and tategaki-writing-auto-indent
                 (string-match-p
                  "\\`[ \t　]+\\'"
                  (buffer-substring-no-properties
                   (line-beginning-position) (line-end-position))))
        (delete-region (line-beginning-position) (line-end-position)))
      (newline count)
      (when tategaki-writing-auto-indent
        (if continue-dialogue
            (tategaki-writing--indent-current-line
             tategaki-writing-dialogue-indent)
          (tategaki-writing-indent-line))))))

(defun tategaki-writing-set-style (style)
  "Select STYLE for subsequent input, without reformatting existing text."
  (interactive
   (list (intern (completing-read "Writing style: " '("prose" "script")
                                   nil t nil nil
                                   (symbol-name tategaki-writing-style)))))
  (unless (memq style '(prose script))
    (user-error "Unknown writing style: %s" style))
  (setq-local tategaki-writing-style style)
  (message "Tategaki writing style: %s" style))

(defun tategaki-script-format-region (beg end)
  "Apply script indentation to complete paragraphs intersecting BEG and END.
Names ending with ： or : are speakers; paragraphs beginning with （ or (
are stage directions; other nonempty paragraphs are dialogue.  Only leading
spaces are changed.  The entire operation is one ordinary undo step."
  (interactive "r")
  (barf-if-buffer-read-only)
  (unless (<= (point-min) beg end (point-max))
    (user-error "Invalid region"))
  (let ((limit (copy-marker end))
        (tategaki-writing-style 'script)
        (tategaki-writing--inhibit t))
    (unwind-protect
        (atomic-change-group
          (save-excursion
            (goto-char beg)
            (beginning-of-line)
            (while (and (< beg end) (< (point) limit))
              (unless (looking-at "[ \t　]*$")
                (tategaki-writing-indent-line))
              (forward-line 1))))
      (set-marker limit nil))))

(defun tategaki-script--start-paragraph ()
  "Start a fresh script paragraph, reusing the current one if it is blank."
  (unless (string-match-p
           "\\`[ \t　]*\\'"
           (buffer-substring-no-properties
            (line-beginning-position) (line-end-position)))
    (end-of-line)
    (insert "\n"))
  (delete-region (line-beginning-position) (line-end-position)))

(defun tategaki-script-insert-dialogue (speaker)
  "Insert SPEAKER on its own paragraph and an indented 「」 dialogue below it.
Leave point inside the brackets.  Subsequent input uses script indentation."
  (interactive "sSpeaker: ")
  (setq speaker (string-trim speaker "[ \t　]+" "[ \t　]+"))
  (when (or (string-empty-p speaker) (string-match-p "[\n\r：:]" speaker))
    (user-error "Use a nonempty speaker name without a newline or colon"))
  (barf-if-buffer-read-only)
  (let ((tategaki-writing--inhibit t))
    (atomic-change-group
      (tategaki-script--start-paragraph)
      (insert (make-string (max 0 tategaki-script-speaker-indent) ?　)
              speaker "：\n"
              (make-string (max 0 tategaki-script-dialogue-indent) ?　)
              "「」")
      (backward-char 1)))
  (setq-local tategaki-writing-style 'script))

(defun tategaki-script-insert-stage-direction (text)
  "Insert TEXT as an indented, parenthesized stage direction.
With empty TEXT leave point between the parentheses for further writing."
  (interactive "sStage direction (empty to write at point): ")
  (when (string-match-p "[\n\r]" text)
    (user-error "A stage direction must fit in one source paragraph"))
  (barf-if-buffer-read-only)
  (let ((tategaki-writing--inhibit t))
    (atomic-change-group
      (tategaki-script--start-paragraph)
      (insert (make-string (max 0 tategaki-script-stage-direction-indent) ?　)
              "（" text "）")
      (when (string-empty-p text) (backward-char 1))))
  (setq-local tategaki-writing-style 'script))

(defvar tategaki-writing-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'tategaki-writing-newline)
    (define-key map [remap newline] #'tategaki-writing-newline)
    (define-key map [remap newline-and-indent] #'tategaki-writing-newline)
    map)
  "Keys active only in buffers using writing assistance.")

;;;###autoload
(define-minor-mode tategaki-writing-mode
  "Help enter prose and scripts using ordinary Emacs source editing.
RET inserts a fullwidth paragraph indent.  A newly entered dialogue opening
bracket adjusts the paragraph to `tategaki-writing-dialogue-indent'.
Japanese pairing uses native Electric Pair mode, only in this buffer.
Enabling or disabling this mode does not alter document contents."
  :lighter " 執筆" :keymap tategaki-writing-mode-map
  (if tategaki-writing-mode
      (unless tategaki-writing--active
        (setq tategaki-writing--active t)
        (when tategaki-writing-electric-pair
          (setq tategaki-writing--pair-local-was-listed
                (memq 'electric-pair-local-mode local-minor-modes))
          (dolist (symbol '(electric-pair-mode electric-pair-pairs
                                              electric-pair-text-pairs))
            (tategaki-writing--save-setting symbol))
          (setq-local electric-pair-pairs
                      (append tategaki-writing-bracket-pairs electric-pair-pairs))
          (setq-local electric-pair-text-pairs
                      (append tategaki-writing-bracket-pairs
                              electric-pair-text-pairs))
          (electric-pair-local-mode 1))
        (add-hook 'after-change-functions #'tategaki-writing--after-change nil t)
        (add-hook 'post-self-insert-hook #'tategaki-writing--finish-input 90 t)
        ;; Commit-time source indentation must precede the view's ordinary
        ;; post-command refresh, otherwise IME commits show one stale frame.
        (add-hook 'post-command-hook #'tategaki-writing--finish-input -90 t)
        (add-hook 'change-major-mode-hook #'tategaki-writing-disable nil t))
    (tategaki-writing--clear-pending)
    (remove-hook 'after-change-functions #'tategaki-writing--after-change t)
    (remove-hook 'post-self-insert-hook #'tategaki-writing--finish-input t)
    (remove-hook 'post-command-hook #'tategaki-writing--finish-input t)
    (remove-hook 'change-major-mode-hook #'tategaki-writing-disable t)
    (when (assq 'electric-pair-mode tategaki-writing--saved-settings)
      (electric-pair-local-mode
       (if (nth 2 (assq 'electric-pair-mode tategaki-writing--saved-settings))
           1 -1))
      (unless tategaki-writing--pair-local-was-listed
        (setq local-minor-modes
              (delq 'electric-pair-local-mode local-minor-modes))))
    (tategaki-writing--restore-settings)
    (setq tategaki-writing--active nil
          tategaki-writing--pair-local-was-listed nil)))

(defun tategaki-writing-enable ()
  "Enable configured writing support when entering tategaki.
Remember whether this integration enabled the mode, so an independently
enabled writing mode is retained when tategaki exits."
  (when (and tategaki-writing-assistance (not tategaki-writing-mode))
    (setq tategaki-writing--managed t)
    (tategaki-writing-mode 1)))

(defun tategaki-writing-disable ()
  "Remove writing support enabled by tategaki integration."
  (when tategaki-writing--managed
    (setq tategaki-writing--managed nil)
    (tategaki-writing-mode -1)))

(provide 'tategaki-writing)
;;; tategaki-writing.el ends here
