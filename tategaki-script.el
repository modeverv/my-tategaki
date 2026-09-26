;;; tategaki-script.el --- Japanese screenplay editing mode -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; A text major mode for scene, speaker, dialogue and stage-direction
;; paragraphs.  Indentation is ordinary fullwidth spaces in the file.
;; Entering the mode never reformats existing source text.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'easymenu)
(require 'tategaki-writing)
(require 'tategaki-outline)

(defgroup tategaki-script nil
  "Write Japanese scripts as plain text." :group 'tategaki)

(defcustom tategaki-script-start-vertical t
  "Start composed vertical editing when entering `tategaki-script-mode'.
Nil leaves the script in horizontal display; all script commands still work."
  :type 'boolean :group 'tategaki-script)

(defcustom tategaki-script-auto-dialogue t
  "Insert an indented 「」 when RET follows a complete speaker paragraph."
  :type 'boolean :group 'tategaki-script)

(defcustom tategaki-script-scene-prefix "○ "
  "Prefix inserted before a new scene's title.
If changed to a different notation, also set `tategaki-script-scene-regexp'."
  :type 'string :group 'tategaki-script)

(defcustom tategaki-script-scene-regexp
  (concat "^[ \t　]*\\(?:[○◎]\\|"
          "第[0-9０-９一二三四五六七八九十百千万〇零]+[部章幕節場]\\|"
          "\\(?:\\*+\\|#+\\)[ \t]+\\)")
  "Regexp recognizing a scene or act at the beginning of a source line.
Scenes appear in both Imenu and the outline.  Only accessible text is used."
  :type 'regexp :group 'tategaki-script)

(defface tategaki-script-scene-face '((t (:inherit font-lock-keyword-face :weight bold)))
  "Scene and act headings." :group 'tategaki-script)
(defface tategaki-script-speaker-face '((t (:inherit font-lock-function-name-face :weight bold)))
  "Speaker paragraphs." :group 'tategaki-script)
(defface tategaki-script-dialogue-face '((t (:inherit default)))
  "Dialogue paragraphs." :group 'tategaki-script)
(defface tategaki-script-stage-direction-face '((t (:inherit font-lock-comment-face)))
  "Stage-direction paragraphs." :group 'tategaki-script)

(defvar tategaki-mode)
(defvar tategaki-typesetting)
(declare-function tategaki-mode "tategaki" (&optional arg))
(declare-function tategaki-refresh "tategaki" ())
(defvar-local tategaki-script--speaker-cache nil)
(defvar-local tategaki-script--speaker-key nil)
(defvar-local tategaki-script--dirty-start nil)
(defvar-local tategaki-script--dirty-end nil)
(defvar-local tategaki-script--settings-key nil)
(defvar tategaki-script--speaker-history nil)

(defun tategaki-script--line-role ()
  "Return the current paragraph's role without moving point."
  (save-match-data
    (save-excursion
      (beginning-of-line)
      (cond
       ((looking-at tategaki-script-scene-regexp) 'scene)
       (t
        (skip-chars-forward " \t　" (line-end-position))
        (cond ((eolp) 'blank)
              ((looking-at tategaki-script-stage-direction-regexp) 'stage-direction)
              ((looking-at tategaki-script-speaker-regexp) 'speaker)
              (t 'dialogue)))))))

(defun tategaki-script--match-line (limit)
  "Find a nonempty script paragraph before font-lock LIMIT."
  (re-search-forward "^[^\n]+" limit t))

(defun tategaki-script--matched-face ()
  "Return the semantic face for the current font-lock match."
  (save-excursion
    (goto-char (match-beginning 0))
    (pcase (tategaki-script--line-role)
      ('scene 'tategaki-script-scene-face)
      ('speaker 'tategaki-script-speaker-face)
      ('stage-direction 'tategaki-script-stage-direction-face)
      (_ 'tategaki-script-dialogue-face))))

(defconst tategaki-script--font-lock-keywords
  '((tategaki-script--match-line (0 (tategaki-script--matched-face) prepend))))

(defun tategaki-script--changed (beg end _old)
  "Remember source changes between BEG and END for explicit fontification."
  (unless tategaki-script--dirty-start
    (setq tategaki-script--dirty-start (copy-marker beg)
          tategaki-script--dirty-end (copy-marker end t)))
  (set-marker tategaki-script--dirty-start (min beg tategaki-script--dirty-start))
  (set-marker tategaki-script--dirty-end (max end tategaki-script--dirty-end)))

(defun tategaki-script--sync-settings ()
  "Keep role, outline and indentation rules aligned after settings change."
  (when (derived-mode-p 'tategaki-script-mode)
    (let ((key (list tategaki-script-scene-regexp tategaki-script-speaker-regexp
                     tategaki-script-stage-direction-regexp)))
      (unless (equal key tategaki-script--settings-key)
	(setq tategaki-script--settings-key key)
	(setq-local tategaki-outline-heading-regexp tategaki-script-scene-regexp)
	(setq-local outline-regexp tategaki-script-scene-regexp)
	(setq-local tategaki-writing-unindented-prefix-regexp
                    (concat "\\(?:[*#]+\\|"
                            (string-remove-prefix "^" tategaki-script-scene-regexp) "\\)"))
	(save-restriction
          (widen)
          (tategaki-script--changed (point-min) (point-max) 0))))))

(defun tategaki-script--fontify ()
  "Fontify changed source paragraphs before the vertical view paints them.
The hidden source overlay cannot rely on redisplay's lazy fontification."
  (tategaki-script--sync-settings)
  (when tategaki-script--dirty-start
    ;; A subsequent narrowing may exclude the changed source.  Fontify it
    ;; under a temporary widening instead of silently dropping that update.
    (save-restriction
      (widen)
      (let ((beg (max (point-min) (min (point-max) tategaki-script--dirty-start)))
            (end (max (point-min) (min (point-max) tategaki-script--dirty-end))))
	(set-marker tategaki-script--dirty-start nil)
	(set-marker tategaki-script--dirty-end nil)
	(setq tategaki-script--dirty-start nil tategaki-script--dirty-end nil)
	(save-match-data
          (save-excursion
            (goto-char beg) (setq beg (line-beginning-position))
            (goto-char end) (setq end (min (point-max) (1+ (line-end-position))))
            (font-lock-flush beg end)
            (font-lock-ensure beg end)))))))

(defun tategaki-script--refresh ()
  "Refresh changed script faces and the active vertical view."
  (tategaki-script--fontify)
  (when (bound-and-true-p tategaki-mode) (tategaki-refresh)))

(defun tategaki-script-speakers ()
  "Return unique speaker names in source order in the accessible script."
  (save-match-data
    (let ((key (list (buffer-chars-modified-tick) (point-min) (point-max)
                     tategaki-script-speaker-regexp tategaki-script-scene-regexp
                     tategaki-script-stage-direction-regexp)))
      (unless (equal key tategaki-script--speaker-key)
        (let ((seen (make-hash-table :test #'equal)) names)
          (save-excursion
            (goto-char (point-min))
            (while (< (point) (point-max))
              (when (eq (tategaki-script--line-role) 'speaker)
                (let ((name (string-trim
                             (replace-regexp-in-string
                              "[：:][ \t　]*$" ""
                              (buffer-substring-no-properties
                               (line-beginning-position) (line-end-position)))
                             "[ \t　]+" "[ \t　]+")))
                  (unless (gethash name seen)
                    (puthash name t seen) (push name names))))
              (forward-line 1)))
          (setq tategaki-script--speaker-key key
                tategaki-script--speaker-cache (nreverse names))))
      (copy-sequence tategaki-script--speaker-cache))))

(defun tategaki-script-completion-at-point ()
  "Offer source speaker names on a paragraph containing only a name prefix."
  (save-match-data
    (let* ((beg (save-excursion (beginning-of-line) (skip-chars-forward " \t　") (point)))
           (end (line-end-position))
           (text (buffer-substring-no-properties beg end)))
      (when (and (<= beg (point) end)
                 (eq (tategaki-script--line-role) (if (string-empty-p text) 'blank 'dialogue))
                 (not (string-match-p "[「」『』（）()：:\n \t　]" text)))
        (let ((names (mapcar (lambda (name) (concat name "："))
                             (tategaki-script-speakers))))
          (when names (list beg end names :exclusive 'no)))))))

(defun tategaki-script-dialogue (&optional speaker)
  "Insert a SPEAKER paragraph and an indented dialogue, completing known names."
  (interactive
   (list (completing-read "人物名: " (tategaki-script-speakers) nil nil nil
                          'tategaki-script--speaker-history)))
  (unless speaker (user-error "Specify a speaker name"))
  (tategaki-script-insert-dialogue speaker)
  (tategaki-script--refresh))

(defun tategaki-script-stage-direction (text)
  "Insert TEXT as a stage direction; empty TEXT leaves point inside （）."
  (interactive "sト書き（空欄なら括弧内で入力）: ")
  (tategaki-script-insert-stage-direction text)
  (tategaki-script--refresh))

(defun tategaki-script-scene (title)
  "Insert a new scene heading with TITLE, followed by a blank input paragraph."
  (interactive "sシーン（場所・時間など）: ")
  (when (or (string-empty-p (string-trim title))
            (string-match-p "[\n\r]" (concat title tategaki-script-scene-prefix)))
    (user-error "Use a nonempty, single-line scene title"))
  (barf-if-buffer-read-only)
  (let ((tategaki-writing--inhibit t))
    (atomic-change-group
      (tategaki-script--start-paragraph)
      (insert tategaki-script-scene-prefix title "\n")))
  (tategaki-script--refresh))

(defun tategaki-script-newline (&optional count)
  "Insert COUNT newlines; after a speaker, prepare a dialogue when COUNT is one."
  (interactive "p")
  (let ((dialogue (and tategaki-writing-auto-indent tategaki-script-auto-dialogue
                       (= (or count 1) 1)
                       (eolp) (eq (tategaki-script--line-role) 'speaker)))
        (tategaki-writing--inhibit t))
    (atomic-change-group
      (tategaki-writing-newline count)
      (when dialogue
        (tategaki-writing--indent-current-line tategaki-script-dialogue-indent)
        (insert "「」") (backward-char 1))))
  (tategaki-script--refresh))

(defun tategaki-script-indent-line ()
  "Align the current scene, speaker, dialogue or stage-direction paragraph."
  (interactive)
  (tategaki-script--sync-settings)
  (tategaki-writing-indent-line)
  (tategaki-script--refresh))

(defun tategaki-script-format (&optional beg end)
  "Format whole paragraphs in BEG..END, or the accessible script if omitted.
Interactively use the active region, otherwise the accessible buffer.
Only leading whitespace is changed; this is one ordinary undo operation."
  (interactive (when (use-region-p) (list (region-beginning) (region-end))))
  (tategaki-script--sync-settings)
  (tategaki-script-format-region (or beg (point-min)) (or end (point-max)))
  (tategaki-script--refresh))

(defun tategaki-script-next-scene (&optional count)
  "Visit the next COUNT scenes or acts without changing the script."
  (interactive "p")
  (let ((tategaki-outline-heading-regexp tategaki-script-scene-regexp))
    (tategaki-outline-next-heading count)))

(defun tategaki-script-previous-scene (&optional count)
  "Visit the previous COUNT scenes or acts."
  (interactive "p")
  (tategaki-script-next-scene (- (or count 1))))

(defun tategaki-script--outline-level ()
  "Return the hierarchy level of the current script heading."
  (save-match-data
    (save-excursion
      (beginning-of-line) (skip-chars-forward " \t　")
      (cond ((looking-at "\\([*#]+\\)[ \t]") (length (match-string 1)))
            ((looking-at "第[^\n部章幕]+[部章幕]") 1)
            (t 2)))))

(defun tategaki-script--imenu-index ()
  "Build an Imenu scene index, respecting the current narrowing."
  (let ((tategaki-outline-heading-regexp tategaki-script-scene-regexp))
    (mapcar (lambda (entry) (cons (aref entry 2) (marker-position (aref entry 0))))
            (append (tategaki-outline--headings) nil))))

(defun tategaki-script--cleanup ()
  "Release writing support and markers owned by this major mode."
  (when tategaki-writing-mode (tategaki-writing-mode -1))
  (dolist (marker (list tategaki-script--dirty-start tategaki-script--dirty-end))
    (when (markerp marker) (set-marker marker nil)))
  (setq tategaki-script--dirty-start nil tategaki-script--dirty-end nil)
  (tategaki-outline-cleanup))

(defvar tategaki-script-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "RET") #'tategaki-script-newline)
    (define-key map (kbd "TAB") #'tategaki-script-indent-line)
    (define-key map [remap indent-for-tab-command] #'tategaki-script-indent-line)
    (define-key map [remap newline] #'tategaki-script-newline)
    (define-key map [remap newline-and-indent] #'tategaki-script-newline)
    (define-key map (kbd "C-c C-s") #'tategaki-script-scene)
    (define-key map (kbd "C-c C-d") #'tategaki-script-dialogue)
    (define-key map (kbd "C-c C-t") #'tategaki-script-stage-direction)
    (define-key map (kbd "C-c C-f") #'tategaki-script-format)
    (define-key map (kbd "C-c C-o") #'tategaki-outline)
    (define-key map (kbd "M-n") #'tategaki-script-next-scene)
    (define-key map (kbd "M-p") #'tategaki-script-previous-scene)
    map))

(easy-menu-define tategaki-script-menu tategaki-script-mode-map
  "Script editing commands."
  '("台本"
    ["シーンを挿入" tategaki-script-scene t]
    ["人物名と台詞を挿入" tategaki-script-dialogue t]
    ["ト書きを挿入" tategaki-script-stage-direction t]
    "--"
    ["現在の段落を字下げ" tategaki-script-indent-line t]
    ["選択範囲／全文の字下げを揃える" tategaki-script-format t]
    "--"
    ["シーン一覧" tategaki-outline t]
    ["次のシーン" tategaki-script-next-scene t]
    ["前のシーン" tategaki-script-previous-scene t]))

;;;###autoload
(define-derived-mode tategaki-script-mode text-mode "台本"
  "Major mode for Japanese scene, speaker, dialogue and stage paragraphs.
Insert scenes with C-c C-s, speakers/dialogue with C-c C-d, and stage
directions with C-c C-t.  RET after a speaker prepares 「」; TAB aligns the
paragraph.  C-c C-o opens the scene outline; M-n and M-p move between scenes.
The mode preserves existing text on entry.  Formatting inserts ordinary
fullwidth spaces at paragraph starts; soft-wrapped columns are not indented."
  (setq-local tategaki-writing-style 'script)
  (setq-local tategaki-writing-unindented-prefix-regexp
              (concat "\\(?:[*#]+\\|"
                      (string-remove-prefix "^" tategaki-script-scene-regexp) "\\)"))
  (setq-local indent-line-function #'tategaki-script-indent-line)
  (setq-local font-lock-defaults '(tategaki-script--font-lock-keywords t))
  (setq-local tategaki-outline-heading-regexp tategaki-script-scene-regexp)
  (setq-local tategaki-outline-level-function #'tategaki-script--outline-level)
  (setq-local outline-regexp tategaki-script-scene-regexp)
  (setq-local outline-level #'tategaki-script--outline-level)
  (setq-local imenu-create-index-function #'tategaki-script--imenu-index)
  (setq-local comment-start "（" comment-end "）")
  (add-hook 'completion-at-point-functions #'tategaki-script-completion-at-point nil t)
  ;; Own writing support independently of the vertical view.  C-c C-c may
  ;; return to horizontal editing without leaving script mode.
  (tategaki-writing-mode 1)
  (let ((map (copy-keymap tategaki-writing-mode-map)))
    (define-key map (kbd "RET") #'tategaki-script-newline)
    (define-key map [remap newline] #'tategaki-script-newline)
    (define-key map [remap newline-and-indent] #'tategaki-script-newline)
    (setq-local minor-mode-overriding-map-alist
                (cons (cons 'tategaki-writing-mode map)
                      (assq-delete-all 'tategaki-writing-mode
                                       (copy-alist minor-mode-overriding-map-alist)))))
  (font-lock-mode 1)
  (tategaki-script--fontify)
  (add-hook 'after-change-functions #'tategaki-script--changed nil t)
  (add-hook 'post-command-hook #'tategaki-script--fontify -50 t)
  (add-hook 'change-major-mode-hook #'tategaki-script--cleanup nil t)
  (add-hook 'kill-buffer-hook #'tategaki-script--cleanup nil t)
  (when tategaki-script-start-vertical
    (require 'tategaki)
    (setq-local tategaki-typesetting t)
    (tategaki-mode 1)))

(provide 'tategaki-script)
;;; tategaki-script.el ends here
