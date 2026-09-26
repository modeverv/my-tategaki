;;; tategaki-typeset.el --- Source-preserving Japanese vertical typesetting -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; Optional layout model, independent of windows, fonts and editing commands.
;; Paragraphs keep relative source positions, so cached layouts survive changes
;; before them.  Public lookup functions translate only requested entries.
;; Segmentation covers combining marks, variation selectors, emoji modifiers,
;; pictographic ZWJ sequences, RI pairs and Hangul.  It is a documented subset,
;; not a claim of complete Unicode UAX #29 or JLReq conformance.

;;; Code:

(require 'cl-lib)
(require 'tategaki-layout)

(defgroup tategaki-typeset nil "Source-preserving vertical typesetting." :group 'text)

(defcustom tategaki-typesetting nil
  "Whether the editor uses typesetting instead of its literal character grid."
  :type 'boolean :group 'tategaki-typeset)
(make-variable-buffer-local 'tategaki-typesetting)

(defcustom tategaki-typeset-kinsoku t
  "Whether to avoid prohibited column starts and ends."
  :type 'boolean :group 'tategaki-typeset)
(defcustom tategaki-typeset-line-start-prohibited
  "、。，．・：；？！‼⁇⁈⁉）〕］｝〉》」』】〙〗〟’”»ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶー々〻ゝゞヽヾ…‥"
  "Characters normally prohibited at the top of a vertical column."
  :type 'string :group 'tategaki-typeset)
(defcustom tategaki-typeset-line-end-prohibited "（〔［｛〈《「『【〘〖〝‘“«"
  "Characters normally prohibited at the bottom of a vertical column."
  :type 'string :group 'tategaki-typeset)
(defcustom tategaki-typeset-hanging-punctuation t
  "Whether a final comma or full stop may hang half a cell below the column.
Hanging is tried before compression and pushing characters to the next column."
  :type 'boolean :group 'tategaki-typeset)
(defcustom tategaki-typeset-compression nil
  "Whether one extra prohibited-start cell may be squeezed into a column.
Otherwise move the preceding characters to the next column.  A pair that
cannot fit even an empty column is always compressed as an emergency fallback."
  :type 'boolean :group 'tategaki-typeset)
(defcustom tategaki-typeset-auto-tcy-digits t
  "Whether a standalone run of exactly two ASCII digits becomes tate-chu-yoko."
  :type 'boolean :group 'tategaki-typeset)
(defcustom tategaki-typeset-auto-tcy-punctuation t
  "Whether exactly two exclamation/question marks become tate-chu-yoko."
  :type 'boolean :group 'tategaki-typeset)
(defcustom tategaki-typeset-latin-orientation 'upright
  "Orientation of printable ASCII runs: upright characters or rotated words.
Rotated runs use one vertical cell per two ASCII characters.  Long words
and URLs are split to fit a column without changing the source."
  :type '(choice (const upright) (const rotate)) :group 'tategaki-typeset)
(defcustom tategaki-typeset-annotation-display 'rendered
  "Whether supported Aozora annotations are rendered or shown as raw notation.
Supported forms are ｜base《ruby》 (also ASCII |), implicit kanji ruby,
［＃傍点］body［＃傍点終わり］, the equivalent 傍線 and 縦中横 pairs,
and body［＃「body」に傍点］ or 傍線.  Incomplete/invalid notes stay literal."
  :type '(choice (const rendered) (const raw)) :group 'tategaki-typeset)

(defconst tategaki-typeset--position-keys
  '(:start :end :base-start :base-end :annotation-start :annotation-end
    :ruby-start :ruby-end)
  "Unit properties that hold source positions.")

(defconst tategaki-typeset--extra-vertical-forms
  '((?… . ?︙) (?‥ . ?︰) (?— . ?︱) (?― . ?︱) (?– . ?︲) (?ー . ?｜))
  "Additional display-only vertical forms, including a long-sound fallback.")

(defvar tategaki-typeset--fast-path t
  "Internal switch for comparing compact ordinary-text layout with token layout.")
(defvar tategaki-typeset--boundaries nil
  "Dynamically bound paragraph-relative boundaries that units must not cross.")

(defun tategaki-typeset-options-key (&optional boundaries)
  "Return a key for all parsing/layout options and optional BOUNDARIES."
  (list tategaki-typeset-kinsoku tategaki-typeset-line-start-prohibited
        tategaki-typeset-line-end-prohibited tategaki-typeset-hanging-punctuation
        tategaki-typeset-compression tategaki-typeset-auto-tcy-digits
        tategaki-typeset-auto-tcy-punctuation tategaki-typeset-latin-orientation
        tategaki-typeset-annotation-display tategaki-layout-use-vertical-forms
        tategaki-layout-newline-symbol tategaki-layout-tab-symbol
        tategaki-layout-eof-symbol tategaki-layout-zero-width-symbol
        tategaki-layout-control-symbol tategaki-typeset--fast-path boundaries))

(defun tategaki-typeset--crosses-boundary-p (start end)
  "Whether the half-open START/END range crosses a forced unit boundary."
  (cl-some (lambda (boundary) (and (< start boundary) (< boundary end)))
           tategaki-typeset--boundaries))

(defun tategaki-typeset--extend-p (char)
  "Whether CHAR extends a preceding grapheme in the supported profile."
  (or (memq (get-char-code-property char 'general-category) '(Mn Mc Me))
      (<= #xfe00 char #xfe0f) (<= #xe0100 char #xe01ef)
      (<= #x1f3fb char #x1f3ff) (<= #xe0020 char #xe007f)
      (= char #x200c)))

(defun tategaki-typeset--pictographic-p (char)
  "Whether CHAR falls in the pictographic ranges used for emoji joining."
  (or (<= #x1f000 char #x1faff) (<= #x2600 char #x27ff)
      (memq char '(#xa9 #xae #x203c #x2049 #x2122 #x2139 #x3030 #x303d #x3297 #x3299))))

(defun tategaki-typeset--hangul (char)
  "Return the Hangul grapheme category of CHAR, or nil."
  (cond ((or (<= #x1100 char #x115f) (<= #xa960 char #xa97c)) 'L)
        ((or (<= #x1160 char #x11a7) (<= #xd7b0 char #xd7c6)) 'V)
        ((or (<= #x11a8 char #x11ff) (<= #xd7cb char #xd7fb)) 'T)
        ((<= #xac00 char #xd7a3) (if (zerop (% (- char #xac00) 28)) 'LV 'LVT))))

(defun tategaki-typeset--cluster-end (text start)
  "Return the exclusive end of the grapheme at START in TEXT."
  (let* ((length (length text)) (first (aref text start)) (end (1+ start))
         (hangul (tategaki-typeset--hangul first))
         (pictographic (tategaki-typeset--pictographic-p first)))
    (cond
     ((and (= first ?\r) (< end length) (= (aref text end) ?\n)) (1+ end))
     ((or (< first 32) (= first 127)) end)
     ((<= #x1f1e6 first #x1f1ff)
      (if (and (< end length) (<= #x1f1e6 (aref text end) #x1f1ff)) (1+ end) end))
     (t
      (while
          (and (< end length)
               (let* ((next (aref text end)) (next-hangul (tategaki-typeset--hangul next)))
                 (cond
                  ((tategaki-typeset--extend-p next) (setq end (1+ end)) t)
                  ((and pictographic (= next #x200d) (< (1+ end) length)
                        (tategaki-typeset--pictographic-p (aref text (1+ end))))
                   (setq end (+ end 2)) t)
                  ((or (and (eq hangul 'L) (memq next-hangul '(L V LV LVT)))
                       (and (memq hangul '(LV V)) (memq next-hangul '(V T)))
                       (and (memq hangul '(LVT T)) (eq next-hangul 'T)))
                   (setq hangul next-hangul end (1+ end)) t)
                  (t nil)))))
      end))))

(defun tategaki-typeset--display (text)
  "Return a display glyph string for a nonempty source grapheme TEXT."
  (if (or (equal text "\n") (equal text "\r\n"))
      (tategaki-layout--glyph ?\n)
    (let ((vertical (and tategaki-layout-use-vertical-forms
                         (alist-get (aref text 0) tategaki-typeset--extra-vertical-forms))))
      (concat (if vertical (char-to-string vertical) (tategaki-layout--glyph (aref text 0)))
              (substring text 1)))))

(defun tategaki-typeset--unit (text start end &optional kind chars)
  "Make a unit for TEXT between START and END with optional KIND."
  ;; CHARS avoids backwards random access into a multibyte string, which
  ;; can repeatedly scan from its beginning when translating byte offsets.
  (let ((source (if (= end (1+ start)) (char-to-string (aref (or chars text) start))
                  (if chars (concat (cl-subseq chars start end))
                    (substring-no-properties text start end)))))
    (list :start start :end end :source-text source
          :text (tategaki-typeset--display source)
          :kind (or kind (if (member source '("\n" "\r\n")) 'newline 'glyph))
          :span 1)))

(defun tategaki-typeset--shift-unit (unit delta)
  "Copy UNIT, translating its source positions by DELTA."
  (let ((copy (copy-sequence unit)))
    (dolist (key tategaki-typeset--position-keys)
      (when (plist-member copy key)
        (setq copy (plist-put copy key (+ delta (plist-get copy key))))))
    copy))

(defun tategaki-typeset--put (unit key value)
  "Destructively set UNIT's KEY to VALUE, retaining UNIT's head cons."
  (if (plist-member unit key)
      (setf (plist-get unit key) value)
    (nconc unit (list key value)))
  unit)

(defun tategaki-typeset--han-p (char)
  "Whether CHAR can belong to an implicit Aozora ruby base."
  (or (<= #x3400 char #x9fff) (<= #x20000 char #x323af)
      (memq char '(?々 ?〆 ?〇 ?ヶ))))

(defun tategaki-typeset--ruby (text start &optional chars)
  "Parse ruby at START in TEXT, returning (END . UNITS), or nil."
  (let* ((chars (or chars (vconcat text)))
         (length (length text)) (first (aref chars start))
         (explicit (memq first '(?｜ ?|)))
         (base-start (+ start (if explicit 1 0)))
         (open base-start))
    (if explicit
        (while (and (< open length)
                    (not (memq (aref chars open) '(?《 ?》 ?｜ ?| ?\n ?［))))
          (setq open (1+ open)))
      (while (and (< open length) (tategaki-typeset--han-p (aref chars open)))
        (setq open (1+ open))))
    (when (and (> open base-start) (< open length) (= (aref chars open) ?《))
      (let ((close (string-match "[《》\n]" text (1+ open))))
        (when (and close (> close (1+ open)) (= (aref chars close) ?》))
          (let ((base-pos base-start) (reading-pos (1+ open)) bases readings units)
            (while (< base-pos open)
              (let ((end (min open (tategaki-typeset--cluster-end chars base-pos))))
                (push (tategaki-typeset--unit text base-pos end 'ruby chars) bases)
                (setq base-pos end)))
            (while (< reading-pos close)
              (let ((end (min close (tategaki-typeset--cluster-end chars reading-pos))))
                (push (concat (cl-subseq chars reading-pos end)) readings)
                (setq reading-pos end)))
            (setq bases (nreverse bases) readings (vconcat (nreverse readings)))
            (let ((count (length bases)) (r-count (length readings)) (index 0))
              (dolist (unit bases)
                (let ((ruby (append (cl-subseq readings (/ (* index r-count) count)
                                                   (/ (* (1+ index) r-count) count)) nil)))
                  (setq unit (plist-put unit :ruby (mapconcat #'identity ruby "")))
                  (setq unit (plist-put unit :ruby-graphemes ruby)))
                (setq unit (plist-put unit :base-start (plist-get unit :start)))
                (setq unit (plist-put unit :base-end (plist-get unit :end)))
                (setq unit (plist-put unit :annotation-start start))
                (setq unit (plist-put unit :annotation-end (1+ close)))
                (setq unit (plist-put unit :ruby-start (1+ open)))
                (setq unit (plist-put unit :ruby-end close))
                (when (zerop index) (setq unit (plist-put unit :start start)))
                (when (= index (1- count)) (setq unit (plist-put unit :end (1+ close))))
                (push unit units) (setq index (1+ index))))
            (cons (1+ close) (nreverse units))))))))

(defun tategaki-typeset--pair-note (text start depth)
  "Parse paired annotation at START, recursing no deeper than DEPTH permits."
  (when (and (< depth 8)
             (string-match "［＃\\(傍点\\|傍線\\|縦中横\\)］" text start)
             (= (match-beginning 0) start))
    (let* ((name (match-string 1 text)) (body-start (match-end 0))
           (closing (concat "［＃" name "終わり］"))
           (close (string-match (regexp-quote closing) text body-start)))
      (when (and close (> close body-start)
                 (not (tategaki-typeset--crosses-boundary-p start (+ close (length closing))))
                 (not (string-match-p "\n" (substring text body-start close))))
        (let ((end (+ close (length closing))) units)
          (if (equal name "縦中横")
              (when (<= (- close body-start) 8)
                (setq units (list (list :start start :end end :kind 'tcy :span 1
                                        :text (substring-no-properties text body-start close)
                                        :source-text (substring-no-properties text body-start close)
                                        :base-start body-start :base-end close))))
            (setq units (let ((tategaki-typeset--boundaries nil))
                          (mapcar (lambda (unit) (tategaki-typeset--shift-unit unit body-start))
                                  (tategaki-typeset--parse
                                   (substring-no-properties text body-start close) (1+ depth)))))
            (dolist (unit units)
              (tategaki-typeset--put unit :emphasis (if (equal name "傍点") 'dot 'line)))
            (setf (plist-get (car units) :start) start
                  (plist-get (car (last units)) :end) end))
          (when units
            (dolist (unit units)
              (unless (plist-member unit :annotation-start)
                (tategaki-typeset--put unit :annotation-start start)
                (tategaki-typeset--put unit :annotation-end end)))
            (cons end units)))))))

(defun tategaki-typeset--post-note (text start units)
  "Apply a postfix emphasis annotation at START to reverse-order UNITS.
Return its end position if the quoted body matches, otherwise nil."
  (when (and units
             (string-match "［＃「\\([^」\n]+\\)」に\\(傍点\\|傍線\\)］" text start)
             (= (match-beginning 0) start))
    (let ((label (match-string-no-properties 1 text))
          (kind (if (equal (match-string 2 text) "傍点") 'dot 'line))
          (end (match-end 0)) (body "") (tail units) selected)
      (while (and tail (< (length body) (length label)))
        (let ((unit (pop tail)))
          (setq body (concat (plist-get unit :source-text) body))
          (push unit selected)))
      (when (and (equal body label)
                 (not (tategaki-typeset--crosses-boundary-p (plist-get (car selected) :start) end)))
        (dolist (unit selected)
          (tategaki-typeset--put unit :emphasis kind)
          (unless (plist-member unit :annotation-start)
            (tategaki-typeset--put unit :annotation-start (plist-get (car selected) :start))
            (tategaki-typeset--put unit :annotation-end end)))
        (setf (plist-get (car units) :end) end)
        end))))

(defun tategaki-typeset--parse (text &optional depth)
  "Parse TEXT into source-ordered units; DEPTH limits annotation nesting."
  (let ((index 0) (length (length text)) (chars (vconcat text))
        (rendered (eq tategaki-typeset-annotation-display 'rendered)) units)
    (while (< index length)
      (let* ((char (aref chars index))
             (note (and rendered (= char ?［)
                        (tategaki-typeset--pair-note text index (or depth 0))))
             (post (and rendered (= char ?［) (not note)
                        (tategaki-typeset--post-note text index units)))
             (ruby (and rendered (not note) (not post)
                        (or (memq char '(?｜ ?|))
                            (and (tategaki-typeset--han-p char)
                                 (or (zerop index)
                                     (not (tategaki-typeset--han-p (aref chars (1- index)))))))
                        (let ((parsed (tategaki-typeset--ruby text index chars)))
                          (and parsed (not (tategaki-typeset--crosses-boundary-p index (car parsed))) parsed)))))
        (cond
         ((or note ruby)
          (let ((parsed (or note ruby)))
            (dolist (unit (cdr parsed)) (push unit units))
            (setq index (car parsed))))
         (post (setq index post))
         (t (let ((end (tategaki-typeset--cluster-end chars index)))
              (dolist (boundary tategaki-typeset--boundaries)
                (when (and (< index boundary) (< boundary end)) (setq end boundary)))
              (push (tategaki-typeset--unit text index end nil chars) units)
              (setq index end))))))
    (nreverse units)))

(defun tategaki-typeset--single-in (unit chars)
  "Whether UNIT is a single ordinary glyph in CHARS."
  (let ((text (plist-get unit :source-text)))
    (and (eq (plist-get unit :kind) 'glyph) (= (length text) 1)
         (cl-position (aref text 0) chars))))

(defun tategaki-typeset--latin-p (unit)
  "Whether UNIT is an ordinary printable ASCII word/URL character."
  (let ((text (plist-get unit :source-text)))
    (and (eq (plist-get unit :kind) 'glyph) (= (length text) 1)
         (string-match-p "\\`[A-Za-z0-9!#$%&*+,./:;=?@_~+-]\\'" text))))

(defun tategaki-typeset--merge (units kind)
  "Merge contiguous UNITS into a single KIND unit, preserving their source."
  (let ((unit (copy-sequence (car units))))
    (setf (plist-get unit :end) (plist-get (car (last units)) :end)
          (plist-get unit :text) (mapconcat (lambda (u) (plist-get u :source-text)) units "")
          (plist-get unit :source-text) (plist-get unit :text)
          (plist-get unit :kind) kind
          (plist-get unit :span) (if (eq kind 'latin)
                                   (max 1 (ceiling (string-width (plist-get unit :text)) 2)) 1))
    unit))

(defun tategaki-typeset--typography (units height)
  "Group TCY, Latin words and nonbreaking punctuation pairs in UNITS.
HEIGHT bounds each rotated Latin segment."
  (let (automatic result)
    (while units
      (let* ((unit (car units))
             (chars (cond ((and tategaki-typeset-auto-tcy-digits
                               (tategaki-typeset--single-in unit "0123456789")) "0123456789")
                          ((and tategaki-typeset-auto-tcy-punctuation
                                (tategaki-typeset--single-in unit "!?！？")) "!?！？")))
             run)
        (if chars
            (progn
              (while (and units (tategaki-typeset--single-in (car units) chars)
                          (or (null run) (not (memq (plist-get (car units) :start) tategaki-typeset--boundaries)))
                          (equal (plist-get (car units) :emphasis) (plist-get unit :emphasis)))
                (push (pop units) run))
              (setq run (nreverse run))
              (if (and (= (length run) 2)
                       (not (and (equal chars "0123456789")
                                 (or (and automatic (tategaki-typeset--latin-p (car automatic)))
                                     (and units (tategaki-typeset--latin-p (car units)))))))
                  (push (tategaki-typeset--merge run 'tcy) automatic)
                (dolist (item run) (push item automatic))))
          (push (pop units) automatic))))
    (setq units (nreverse automatic))
    (while units
      (let ((unit (pop units)))
        (if (and (eq tategaki-typeset-latin-orientation 'rotate)
                 (tategaki-typeset--latin-p unit))
            (let ((run (list unit)) (count 1))
              (while (and units (< count (* 2 height))
                          (not (memq (plist-get (car units) :start) tategaki-typeset--boundaries))
                          (tategaki-typeset--latin-p (car units))
                          (equal (plist-get (car units) :emphasis) (plist-get unit :emphasis)))
                (push (pop units) run) (setq count (1+ count)))
              (push (tategaki-typeset--merge (nreverse run) 'latin) result))
          (when (and units (tategaki-typeset--single-in unit "…‥―—")
                     (equal (plist-get unit :source-text) (plist-get (car units) :source-text)))
            ;; Consume pairs, rather than making an arbitrarily long run atomic.
            (setf (plist-get unit :no-break-after) t)
            (push unit result)
            (setq unit (pop units)))
          (push unit result))))
    (vconcat (nreverse result))))

(defun tategaki-typeset-plain-text (text &optional start end)
  "Return TEXT's body with supported, valid annotations removed.
Ruby readings and annotation delimiters do not contribute to the returned
text.  Whitespace/newlines and malformed notation remain unchanged.
Optional START and END are zero-based offsets selecting part of the original
TEXT.  Only annotations wholly contained in that range are stripped;
partially selected notation remains literal.  Supply surrounding complete
lines as TEXT when selection boundaries may fall inside an annotation.
This function neither normalizes characters nor mutates TEXT."
  (save-match-data
    (setq start (or start 0) end (or end (length text)))
    (unless (and (integerp start) (integerp end) (<= 0 start end (length text)))
      (signal 'args-out-of-range (list text start end)))
    (if (not (string-match-p "[《［]" text)) (substring-no-properties text start end)
      (tategaki-typeset--plain-spans text start end 0))))

(defun tategaki-typeset--plain-suffix (label parts)
  "Find LABEL at the end of reverse-order rendered PARTS.
Each part is [SOURCE-START SOURCE-END TEXT ANNOTATION].  Return the source
start of the matched label, or nil.  Only a label-sized suffix is inspected."
  (let ((remaining (length label)) (suffix "") begin)
    (while (and parts (> remaining 0))
      (let* ((part (pop parts)) (piece (aref part 2))
             (take (min remaining (length piece))))
        (when (> take 0)
          (setq suffix (concat (substring piece (- (length piece) take)) suffix)
                begin (if (aref part 3) (aref part 0) (- (aref part 1) take))
                remaining (- remaining take)))))
    (and (zerop remaining) (equal suffix label) begin)))

(defun tategaki-typeset--plain-spans (text range-start range-end depth)
  "Strip annotation spans in TEXT without building per-character units.
RANGE-START/RANGE-END specify selected source offsets; DEPTH bounds nesting."
  (let ((chars (vconcat text)) (length (length text)) (scan 0) (cursor 0) parts output)
    (cl-labels
        ((slice (from to) (concat (cl-subseq chars from to)))
         (raw-output (from to)
           (let ((begin (max from range-start)) (end (min to range-end)))
             (when (< begin end) (push (slice begin end) output))))
         (flush (to)
           (when (< cursor to)
             (push (vector cursor to (slice cursor to) nil) parts)
             (raw-output cursor to))
           (setq cursor to))
         (annotation (from to body)
           (flush from)
           (push (vector from to body t) parts)
           (if (and (<= range-start from) (<= to range-end)) (push body output)
             (raw-output from to))
           (setq cursor to scan to)))
      (while (and (< scan length) (setq scan (string-match "[《［]" text scan)))
        (let ((at scan))
          (setq scan (1+ scan))
          (if (= (aref chars at) ?《)
              (let ((base at) (bar (1- at)) (explicit nil)
                    (close (string-match "[《》\n]" text (1+ at))))
                ;; The explicit base is bounded by exactly the delimiters used
                ;; by the model parser.  Otherwise only a kanji run is implicit.
                (while (and (>= bar cursor)
                            (not (memq (aref chars bar) '(?《 ?》 ?｜ ?| ?\n ?［))))
                  (setq bar (1- bar)))
                (if (and (>= bar cursor) (memq (aref chars bar) '(?｜ ?|)))
                    (setq explicit t base (1+ bar))
                  (while (and (> base cursor) (tategaki-typeset--han-p (aref chars (1- base))))
                    (setq base (1- base))))
                (when (and (> at base) close (> close (1+ at)) (= (aref chars close) ?》))
                  (annotation (if explicit bar base) (1+ close) (slice base at))))
            (cond
             ((and (< depth 8)
                   (string-match "［＃\\(傍点\\|傍線\\|縦中横\\)］" text at)
                   (= (match-beginning 0) at))
              (let* ((name (match-string-no-properties 1 text)) (body-start (match-end 0))
                     (closing (concat "［＃" name "終わり］"))
                     (close (string-match (regexp-quote closing) text body-start)))
                (when (and close (> close body-start)
                           (not (cl-position ?\n chars :start body-start :end close))
                           (or (not (equal name "縦中横")) (<= (- close body-start) 8)))
                  (let ((body (slice body-start close)))
                    (annotation at (+ close (length closing))
                                (if (equal name "縦中横") body
                                  (tategaki-typeset--plain-spans body 0 (length body) (1+ depth))))))))
             ((and (string-match "［＃「\\([^」\n]+\\)」に\\(傍点\\|傍線\\)］" text at)
                   (= (match-beginning 0) at))
              (let ((label (match-string-no-properties 1 text)) (end (match-end 0)))
                (flush at)
                (let ((begin (tategaki-typeset--plain-suffix label parts)))
                  (when begin
                    ;; The preceding body is already emitted.  Hide only the
                    ;; suffix note, and only when its whole annotated range is
                    ;; selected.  A zero-text part preserves later suffix matches.
                    (push (vector at end "" t) parts)
                    (unless (and (<= range-start begin) (<= end range-end))
                      (raw-output at end))
                    (setq cursor end scan end)))))))))
      (flush length)
      (apply #'concat (nreverse output)))))

(defun tategaki-typeset--boundary-p (units index)
  "Whether breaking before INDEX in UNITS is allowed."
  (if (or (zerop index) (= index (length units))) t
    (let* ((left (aref units (1- index))) (right (aref units index))
           (ltext (plist-get left :source-text)) (rtext (plist-get right :source-text)))
      (or (memq (plist-get right :kind) '(newline eof))
          (and (not (plist-get left :no-break-after))
               (or (not tategaki-typeset-kinsoku)
                   (and (not (cl-position (aref ltext (1- (length ltext)))
                                          tategaki-typeset-line-end-prohibited))
                        (not (cl-position (aref rtext 0)
                                          tategaki-typeset-line-start-prohibited)))))))))

(defun tategaki-typeset--wrap (units height)
  "Place UNITS in columns of HEIGHT; return (:entries VECTOR :columns N ...)."
  (let ((index 0) (column 0) (length (length units)) entries (content-columns 0))
    (while (< index length)
      (let ((end index) (used 0) (scale 1) hanging forced)
        (while (and (< end length)
                    (<= (+ used (plist-get (aref units end) :span)) height)
                    (or (= end index) (not (eq (plist-get (aref units (1- end)) :kind) 'newline))))
          (setq used (+ used (plist-get (aref units end) :span)) end (1+ end)))
        (when (= end index)
          (setq end (1+ index) used (plist-get (aref units index) :span)
                scale (/ (float height) used) forced t))
        (when (and (< end length)
                   (not (eq (plist-get (aref units (1- end)) :kind) 'newline))
                   (not (tategaki-typeset--boundary-p units end)))
          (let* ((next (aref units end))
                 (next-text (plist-get next :source-text))
                 (next-span (plist-get next :span)))
            (cond
             ((and tategaki-typeset-hanging-punctuation (= next-span 1)
                   (= (length next-text) 1) (cl-position (aref next-text 0) "、。，．"))
              (setq end (1+ end) hanging t))
             ((and tategaki-typeset-compression (= next-span 1)
                   (not (memq (plist-get next :kind) '(newline eof))))
              (setq end (1+ end) scale (/ (float height) (+ used next-span))))
             (t
              (let ((candidate end))
                (while (and (> candidate index) (not (tategaki-typeset--boundary-p units candidate)))
                  (setq candidate (1- candidate)))
                (if (> candidate index) (setq end candidate)
                  ;; An indivisible pair must not be lost at height one.
                  (when (plist-get (aref units (1- end)) :no-break-after)
                    (setq end (1+ end) scale (/ (float height) (+ used next-span)) forced t))))))))
        (let ((row 0))
          (cl-loop for i from index below end do
                   (let* ((unit (copy-sequence (aref units i)))
                          (display-row (if (and hanging (= i (1- end))) height (* row scale))))
                     (when (< scale 1) (setf (plist-get unit :compression) scale))
                     (when forced (setf (plist-get unit :forced-break) t))
                     (setf (plist-get unit :advance) (* (plist-get unit :span) scale))
                     (when (and hanging (= i (1- end)))
                       (setf (plist-get unit :hanging) t
                             (plist-get unit :compression) 0.5
                             (plist-get unit :advance) 0.5))
                     (unless (eq (plist-get unit :kind) 'eof) (setq content-columns (1+ column)))
                     (push (vector (plist-get unit :start) nil display-row column unit) entries)
                     (setq row (+ row (plist-get unit :span))))))
        (setq index end column (1+ column))))
    (list :entries (vconcat (nreverse entries)) :columns column :content-columns content-columns)))

(defun tategaki-typeset--common-prefix (left right)
  "Return the length of the common prefix of LEFT and RIGHT, using C comparison."
  (let ((comparison (compare-strings left nil nil right nil nil)))
    (if (eq comparison t) (length left) (1- (abs comparison)))))

(defun tategaki-typeset--common-suffix (left right prefix)
  "Return common suffix length of LEFT and RIGHT without overlapping PREFIX."
  (let ((low 0) (high (- (min (length left) (length right)) prefix)))
    (while (< low high)
      (let ((middle (/ (+ low high 1) 2)))
        (if (eq t (compare-strings left (- (length left) middle) nil
                                  right (- (length right) middle) nil))
            (setq low middle) (setq high (1- middle)))))
    low))

(defun tategaki-typeset--find-entry (entries position)
  "Return index of the last entry in ENTRIES starting at/before POSITION."
  (let ((low 0) (high (length entries)))
    (while (< low high)
      (let ((mid (/ (+ low high) 2)))
        (if (<= (aref (aref entries mid) 0) position)
            (setq low (1+ mid)) (setq high mid))))
    (max 0 (1- low))))

(defun tategaki-typeset--incremental-parse (text previous)
  "Parse TEXT, reusing unchanged raw tokens from PREVIOUS paragraph data.
Annotation edits conservatively reparse the paragraph; ordinary edits
reparse the affected graphemes plus neighboring tokens.  Return (UNITS . N),
where N is the number of source characters reparsed."
  (let ((old (plist-get previous :source)) (tokens (plist-get previous :tokens)))
    (if (or tategaki-typeset--boundaries (not tokens) (zerop (length tokens))
            (string-match-p "[｜|《》［］🇦-🇿]" text)
            (and old (string-match-p "[｜|《》［］🇦-🇿]" old)))
        (cons (vconcat (tategaki-typeset--parse text)) (length text))
      (let* ((prefix (tategaki-typeset--common-prefix old text))
             (suffix (tategaki-typeset--common-suffix old text prefix))
             (delta (- (length text) (length old)))
             (first 0) (last (length tokens)))
        (while (and (< first (length tokens)) (<= (plist-get (aref tokens first) :end) prefix))
          (setq first (1+ first)))
        (setq first (max 0 (- first 2)))
        (while (and (> last first) (>= (plist-get (aref tokens (1- last)) :start) (- (length old) suffix)))
          (setq last (1- last)))
        (setq last (min (length tokens) (+ last 2)))
        (let* ((begin (if (< first (length tokens)) (plist-get (aref tokens first) :start) 0))
               (old-end (if (> last 0) (plist-get (aref tokens (1- last)) :end) (length old)))
               (end (+ old-end delta))
               (middle (mapcar (lambda (unit) (tategaki-typeset--shift-unit unit begin))
                               (tategaki-typeset--parse (substring-no-properties text begin end))))
               (after (cl-loop for i from last below (length tokens)
                               collect (tategaki-typeset--shift-unit (aref tokens i) delta))))
          (cons (vconcat (cl-subseq tokens 0 first) middle after) (- end begin)))))))

(defun tategaki-typeset--paragraph (text height eof previous)
  "Build relative layout data for TEXT, at HEIGHT, with EOF if final.
PREVIOUS may supply reusable lexical tokens."
  (if (tategaki-typeset--fast-eligible-p text)
      (tategaki-typeset--fast-paragraph text height eof)
    (let* ((parsed (tategaki-typeset--incremental-parse text previous))
         (tokens (car parsed))
         (units (tategaki-typeset--typography
                 (mapcar #'copy-sequence (append tokens nil)) height)))
    (when eof
      (setq units (vconcat units (vector (list :start (length text) :end (length text)
                                              :source-text "" :text (tategaki-layout--glyph nil)
                                              :kind 'eof :span 1)))))
    (append (tategaki-typeset--wrap units height)
            (list :source text :tokens tokens :eof eof :parsed-characters (cdr parsed))))))

(defun tategaki-typeset--fast-eligible-p (text)
  "Whether TEXT can be indexed directly without one token per character.
Only known single-codepoint graphemes are accepted.  Any annotation, joining
character, TCY candidate, rotated word or paired leader uses the general path."
  (and tategaki-typeset--fast-path
       (eq tategaki-typeset-latin-orientation 'upright)
       (not (string-match-p "[^ -~　-ヿ㐀-䶿一-鿿０-９\n]" text))
       (not (string-match-p "[゙゚]" text))
       (or (eq tategaki-typeset-annotation-display 'raw)
           (not (string-match-p "[｜|《［]" text)))
       (or (not tategaki-typeset-auto-tcy-digits)
           (not (string-match-p "[0-9][0-9]" text)))
       (or (not tategaki-typeset-auto-tcy-punctuation)
           (not (string-match-p "[!?！？][!?！？]" text)))))

(defun tategaki-typeset--fast-boundary-p (text index)
  "Whether the direct ordinary-text layout may break TEXT at INDEX."
  (or (not tategaki-typeset-kinsoku) (zerop index) (>= index (length text))
      (= (aref text index) ?\n)
      (and (not (cl-position (aref text (1- index)) tategaki-typeset-line-end-prohibited))
           (not (cl-position (aref text index) tategaki-typeset-line-start-prohibited)))))

(defun tategaki-typeset--fast-paragraph (text height eof)
  "Index ordinary TEXT by column breaks, constructing visible units lazily.
HEIGHT and EOF have the same meaning as in `tategaki-typeset--paragraph'.
Each descriptor is [START END COMPRESSION HANGING FORCED].  Its character
positions are sufficient because eligibility excludes multicharacter units."
  (let ((index 0) (total (+ (length text) (if eof 1 0))) (chars (vconcat text)) columns)
    (while (< index total)
      (let ((end (min total (+ index height))) (scale 1) hanging)
        (when (and (< end total) (not (tategaki-typeset--fast-boundary-p chars end)))
          (cond
           ((and tategaki-typeset-hanging-punctuation
                 (cl-position (aref chars end) "、。，．"))
            (setq end (1+ end) hanging t))
           (tategaki-typeset-compression (setq end (1+ end) scale (/ (float height) (1+ height))))
           (t
            (let ((candidate end))
              (while (and (> candidate index) (not (tategaki-typeset--fast-boundary-p chars candidate)))
                (setq candidate (1- candidate)))
              (when (> candidate index) (setq end candidate))))))
        (push (vector index end scale hanging nil) columns)
        (setq index end)))
    (setq columns (vconcat (nreverse columns)))
    (let ((count (length columns)))
      (list :fast-columns columns :height height :columns count
            :content-columns (if (and (> count 0) (= (aref (aref columns (1- count)) 0) (length text)))
                                 (1- count) count)
            :source text :chars chars :tokens nil :eof eof :parsed-characters 0))))

(defun tategaki-typeset--fast-entry (data position &optional column)
  "Return relative entry for POSITION in direct DATA, optionally in COLUMN."
  (let* ((columns (plist-get data :fast-columns))
         (low 0) (high (length columns)))
    (unless column
      (while (< low high)
        (let ((mid (/ (+ low high) 2)))
          (if (<= (aref (aref columns mid) 0) position)
              (setq low (1+ mid)) (setq high mid))))
      (setq column (max 0 (1- low))))
    (let* ((descriptor (aref columns column)) (scale (aref descriptor 2))
           (hanging (and (aref descriptor 3) (= position (1- (aref descriptor 1)))))
           (text (plist-get data :source))
           (unit (if (= position (length text))
                     (list :start position :end position :source-text ""
                           :text (tategaki-layout--glyph nil) :kind 'eof :span 1)
                   (tategaki-typeset--unit text position (1+ position) nil (plist-get data :chars))))
           (row (if hanging (plist-get data :height) (* (- position (aref descriptor 0)) scale))))
      (when (< scale 1) (setf (plist-get unit :compression) scale))
      (setf (plist-get unit :advance) scale)
      (when (aref descriptor 4) (setf (plist-get unit :forced-break) t))
      (when hanging
        (setf (plist-get unit :hanging) t (plist-get unit :advance) 0.5
              (plist-get unit :compression) 0.5))
      (vector position nil row column unit))))

(defun tategaki-typeset-layout (text height start &optional cache boundaries)
  "Return a compact source-preserving typeset layout for TEXT.
HEIGHT is a positive column height; START is TEXT's absolute source position.
CACHE may be an earlier returned layout.  Exact unchanged paragraphs reuse
their tokens and placements, including when their absolute positions shift.
Ordinary local edits reuse unaffected lexical tokens within a paragraph.
BOUNDARIES is a list of absolute source positions at which a display unit
must split, for example the start/end of transient IME or completion text.
Annotation groups crossing a boundary are exposed as source notation.

The result has :typeset, :height, :columns (including EOF), :content-columns
(excluding EOF-only columns), :start, :end, :blocks and :cache-stats.  It has
no rendered whole-document string or per-source-character position vector.
Use `tategaki-typeset-entry', `tategaki-typeset-visible' and
`tategaki-typeset-nearest' to access the compact index."
  (save-match-data
  (unless (stringp text) (signal 'wrong-type-argument (list 'stringp text)))
  (unless (and (integerp height) (> height 0))
    (signal 'wrong-type-argument (list 'positive-integer-p height)))
  (unless (and (integerp start) (> start 0))
    (signal 'wrong-type-argument (list 'positive-integer-p start)))
  (setq boundaries (sort (delete-dups
                          (cl-remove-if-not (lambda (position)
                                              (and (integerp position) (< start position)
                                                   (< position (+ start (length text)))))
                                            (copy-sequence boundaries))) #'<))
  (let* ((key (tategaki-typeset-options-key boundaries))
         (valid (and cache (= height (plist-get cache :height))
                     (equal key (plist-get cache :options))))
         (old-blocks (and valid (plist-get cache :blocks)))
         (reuse (make-hash-table :test #'equal))
         (index 0) (ordinal 0) (column 0) (content-columns 0)
         (reused 0) (rebuilt 0) (parsed-characters 0) blocks)
    (when old-blocks
      (mapc (lambda (block)
              (let ((data (plist-get block :data)))
                (puthash (list (plist-get data :eof) (plist-get data :source)
                               (plist-get data :boundaries)) data reuse)))
            old-blocks))
    ;; Always retain a final block, including after a trailing newline.
    (while (<= index (length text))
      (let* ((newline (string-match "\n" text index))
             (end (if newline (1+ newline) (length text)))
             (eof (null newline))
             (source (substring-no-properties text index end))
             (tategaki-typeset--boundaries
              (cl-loop for boundary in boundaries
                       when (and (< (+ start index) boundary) (< boundary (+ start end)))
                       collect (- boundary (+ start index))))
             (reuse-key (list eof source tategaki-typeset--boundaries))
             (data (gethash reuse-key reuse)))
        (if data (setq reused (1+ reused))
          (setq data (tategaki-typeset--paragraph
                      source height eof
                      (and old-blocks (< ordinal (length old-blocks))
                           (plist-get (aref old-blocks ordinal) :data))))
          (setq data (plist-put data :boundaries tategaki-typeset--boundaries))
          (setq rebuilt (1+ rebuilt)
                parsed-characters (+ parsed-characters (plist-get data :parsed-characters)))
          (puthash reuse-key data reuse))
        (push (list :start (+ start index) :end (+ start end) :column column :data data) blocks)
        (when (> (plist-get data :content-columns) 0)
          (setq content-columns (+ column (plist-get data :content-columns))))
        (setq column (+ column (plist-get data :columns)) ordinal (1+ ordinal)
              index (if eof (1+ (length text)) end))))
    (list :typeset t :height height :columns column :content-columns content-columns
          :start start :end (+ start (length text)) :blocks (vconcat (nreverse blocks))
          :options key :cache-stats (list :reused reused :rebuilt rebuilt
                                         :parsed-characters parsed-characters)))))

(defun tategaki-typeset--block-at (layout value key)
  "Return index of block in LAYOUT starting at/before VALUE using KEY."
  (let* ((blocks (plist-get layout :blocks)) (low 0) (high (length blocks)))
    (while (< low high)
      (let ((mid (/ (+ low high) 2)))
        (if (<= (plist-get (aref blocks mid) key) value)
            (setq low (1+ mid)) (setq high mid))))
    (max 0 (1- low))))

(defun tategaki-typeset--absolute-entry (entry block &optional position)
  "Translate relative ENTRY from BLOCK; preserve optional requested POSITION."
  (let* ((start (plist-get block :start))
         (unit (tategaki-typeset--shift-unit (aref entry 4) start)))
    (vector (or position (+ start (aref entry 0))) nil (aref entry 2)
            (+ (plist-get block :column) (aref entry 3)) unit)))

(defun tategaki-typeset-entry (layout position)
  "Return [POSITION nil ROW COLUMN UNIT] at source POSITION in LAYOUT.
Every insertion position from :start through :end is addressable.  Interior
grapheme and hidden annotation positions map to the same visible cell, while
POSITION itself is retained so logical editing never loses precision."
  (when (and (<= (plist-get layout :start) position) (<= position (plist-get layout :end)))
    (let* ((block (aref (plist-get layout :blocks) (tategaki-typeset--block-at layout position :start)))
           (data (plist-get block :data))
           (relative (- position (plist-get block :start))))
      (if (plist-member data :fast-columns)
          (tategaki-typeset--absolute-entry (tategaki-typeset--fast-entry data relative) block position)
        (let* ((entries (plist-get data :entries))
               (index (tategaki-typeset--find-entry entries relative)))
          (when (> (length entries) 0)
            (tategaki-typeset--absolute-entry (aref entries index) block position)))))))

(defun tategaki-typeset-visible (layout first-column column-count)
  "Return unique entries in LAYOUT's requested columns, in source order.
Entries are [START nil ROW COLUMN UNIT]; ROW may be fractional for hanging
punctuation or compression.  No document-wide position expansion is needed."
  (let* ((blocks (plist-get layout :blocks)) (end-column (+ first-column column-count))
         (index (tategaki-typeset--block-at layout first-column :column)) result)
    (when (> column-count 0)
      (while (and (< index (length blocks)) (< (plist-get (aref blocks index) :column) end-column))
        (let* ((block (aref blocks index)) (data (plist-get block :data))
               (entries (plist-get data :entries)) (fast (plist-get data :fast-columns))
               (base (plist-get block :column)) (low 0) (high (length entries)))
          (if fast
              (cl-loop for col from (max 0 (- first-column base))
                       below (min (length fast) (- end-column base)) do
                       (let ((descriptor (aref fast col)))
                         (cl-loop for pos from (aref descriptor 0) below (aref descriptor 1) do
                                  (push (tategaki-typeset--absolute-entry
                                         (tategaki-typeset--fast-entry data pos col) block) result))))
            (while (< low high)
              (let ((mid (/ (+ low high) 2)))
                (if (< (+ base (aref (aref entries mid) 3)) first-column)
                    (setq low (1+ mid)) (setq high mid))))
            (while (and (< low (length entries)) (< (+ base (aref (aref entries low) 3)) end-column))
              (push (tategaki-typeset--absolute-entry (aref entries low) block) result)
              (setq low (1+ low)))))
        (setq index (1+ index))))
    (nreverse result)))

(defun tategaki-typeset-nearest (layout column row)
  "Return the entry nearest ROW in COLUMN of LAYOUT, or nil for a missing column."
  (let (best (distance most-positive-fixnum))
    (dolist (entry (tategaki-typeset-visible layout column 1))
      (let* ((unit (aref entry 4)) (begin (aref entry 2))
             (end (+ begin (plist-get unit :advance)))
             (delta (cond ((< row begin) (- begin row)) ((>= row end) (+ 0.001 (- row end))) (t 0))))
        (when (< delta distance) (setq best entry distance delta))))
    best))

(provide 'tategaki-typeset)
;;; tategaki-typeset.el ends here
