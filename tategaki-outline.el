;;; tategaki-outline.el --- Outline navigation for vertical writing -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; Headings are ordinary source text.  A separate, read-only side window
;; follows their markers without hiding, indenting or rewriting the source.
;; The outline is scanned lazily and only when the source or settings change.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'outline)

(defgroup tategaki-outline nil
  "Outline navigation for vertical writing."
  :group 'text)

(defcustom tategaki-outline-heading-regexp 'auto
  "Headings shown in the vertical editor's outline.
`auto' recognizes Org stars, Markdown ATX headings and Japanese numbered
parts, chapters, sections, acts and scenes.  `outline' uses `outline-regexp'
and `outline-level' from the source buffer.  A regexp selects custom heading
lines; `tategaki-outline-level-function' can supply their hierarchy.
Only headings inside the current narrowing are listed."
  :type '(choice (const auto) (const outline) regexp)
  :group 'tategaki-outline)

(defcustom tategaki-outline-level-function nil
  "Optional function returning a positive heading level at source point.
Called without arguments at the beginning of each matching heading line.
Nil uses the heading syntax, or `outline-level' for the `outline' preset."
  :type '(choice (const nil) function)
  :group 'tategaki-outline)

(defcustom tategaki-outline-width 30
  "Preferred width, in columns, of the outline side window."
  :type 'natnum
  :group 'tategaki-outline)

(defcustom tategaki-outline-side 'right
  "Side on which to show the outline."
  :type '(choice (const left) (const right))
  :group 'tategaki-outline)

(defcustom tategaki-outline-follow-point t
  "Whether to highlight the current heading in the outline side window."
  :type 'boolean
  :group 'tategaki-outline)

(defcustom tategaki-outline-update-delay 0.25
  "Idle seconds before refreshing an open outline after source edits."
  :type 'number
  :group 'tategaki-outline)

(defconst tategaki-outline--auto-regexp
  (concat "^\\(?:\\*+[ \t]+\\|#\\{1,6\\}[ \t]+\\|"
          "[ 　]*第[0-9０-９一二三四五六七八九十百千万〇零]+[部章節幕場]"
          "\\)")
  "Heading prefixes understood by the automatic outline.")

(defvar-local tategaki-outline--entries nil
  "Cached vector of [MARKER LEVEL TITLE SIDEBAR-POSITION] entries.")
(defvar-local tategaki-outline--cache-key nil)
(defvar-local tategaki-outline--buffer nil)
(defvar-local tategaki-outline--timer nil)
(defvar-local tategaki-outline--source nil)
(defvar-local tategaki-outline--highlight nil)
(defvar-local tategaki-outline--folded nil
  "Independent source markers for collapsed sidebar headings.")
(defvar-local tategaki-outline--fold-overlays nil)

(defvar tategaki-mode)
(declare-function tategaki-refresh "tategaki")

(defvar tategaki-outline-button-map
  (let ((map (copy-keymap button-map)))
    ;; Text buttons take precedence over the major-mode keymap.
    (define-key map (kbd "TAB") #'tategaki-outline-toggle-subtree)
    (define-key map (kbd "<tab>") #'tategaki-outline-toggle-subtree)
    map)
  "Button bindings for outline navigation and sidebar subtree folding.")

(defun tategaki-outline--regexp ()
  "Return the heading regexp for the current source buffer."
  (pcase tategaki-outline-heading-regexp
    ('auto tategaki-outline--auto-regexp)
    ('outline outline-regexp)
    ((pred stringp) tategaki-outline-heading-regexp)
    (_ (user-error "Invalid tategaki-outline-heading-regexp"))))

(defun tategaki-outline--level ()
  "Return the heading level at the beginning of the current source line."
  (max 1
       (truncate
        (cond
         (tategaki-outline-level-function
          (funcall tategaki-outline-level-function))
         ((eq tategaki-outline-heading-regexp 'outline)
          (funcall outline-level))
         ((looking-at "\\(\\*+\\|#+\\)[ \t]")
          (length (match-string-no-properties 1)))
         ((looking-at "[ 　]*第[^\n部章節幕場]+[節場]") 2)
         (t 1)))))

(defun tategaki-outline--release-entries ()
  "Release markers in the current source buffer's outline cache."
  (mapc (lambda (entry) (set-marker (aref entry 0) nil))
        tategaki-outline--entries)
  (setq tategaki-outline--entries nil
        tategaki-outline--cache-key nil))

(defun tategaki-outline--headings ()
  "Return cached heading entries for the accessible source text.
Preserve point, narrowing, match data, source properties and undo."
  (save-match-data
    (let* ((regexp (tategaki-outline--regexp))
           (key (list (buffer-chars-modified-tick) (point-min) (point-max)
                      regexp tategaki-outline-level-function
                      (and (eq tategaki-outline-heading-regexp 'outline)
                           outline-level))))
      (unless (equal key tategaki-outline--cache-key)
        (let (entries)
          (save-excursion
            (goto-char (point-min))
            (while (and (< (point) (point-max))
                        (re-search-forward regexp nil t))
              (let ((start (line-beginning-position)))
                ;; A custom regexp may match several times on one line, or
                ;; match the empty final line.  Advancing a line handles both.
                (unless (= start (point-max))
                  (goto-char start)
                  (let ((level (save-excursion
                                 (save-match-data (tategaki-outline--level))))
                        (title (string-trim
                                (buffer-substring-no-properties
                                 start (line-end-position)))))
                    (when (eq tategaki-outline-heading-regexp 'auto)
                      (setq title (replace-regexp-in-string
                                   "\\`\\(?:\\*+\\|#+\\)[ \t]+" "" title)))
                    (push (vector (copy-marker start t) level title nil)
                          entries)))
                (goto-char start)
                (if (= (forward-line 1) 1)
                    (goto-char (point-max))))))
          (tategaki-outline--release-entries)
          (setq tategaki-outline--entries (vconcat (nreverse entries))
                tategaki-outline--cache-key key)))
      tategaki-outline--entries)))

(defun tategaki-outline--current-index (entries position)
  "Return the heading index at POSITION within sorted ENTRIES, or nil."
  (let ((low 0) (high (length entries)))
    (while (< low high)
      (let ((middle (/ (+ low high) 2)))
        (if (<= (marker-position (aref (aref entries middle) 0)) position)
            (setq low (1+ middle))
          (setq high middle))))
    (and (> low 0) (1- low))))

(defun tategaki-outline--source-buffer ()
  "Return the source buffer for an outline or source command."
  (let ((source (or tategaki-outline--source (current-buffer))))
    (unless (buffer-live-p source)
      (user-error "The outline's source buffer is no longer available"))
    source))

(defun tategaki-outline--visit (marker)
  "Visit MARKER in its source buffer and refresh the vertical viewport."
  (unless (and (markerp marker) (marker-buffer marker))
    (user-error "Heading has changed; refresh the outline"))
  (let* ((source (marker-buffer marker))
         (window (get-buffer-window source)))
    (if (window-live-p window) (select-window window)
      (pop-to-buffer source))
    (unless (<= (point-min) marker (point-max))
      (user-error "Heading is outside the current narrowing"))
    (goto-char marker)
    (when (and (bound-and-true-p tategaki-mode)
               (fboundp 'tategaki-refresh))
      (tategaki-refresh))
    (tategaki-outline--follow)))

(defun tategaki-outline--activate-button (button)
  "Visit the source heading represented by BUTTON."
  (let* ((marker (button-get button 'tategaki-outline-marker))
         (source (and (markerp marker) (marker-buffer marker)))
         (position (and source (marker-position marker))))
    (unless source (user-error "Heading has changed; refresh the outline"))
    (setq marker
          (with-current-buffer source
            ;; Inserting an extra Org star or Markdown hash at the heading's
            ;; start moves its marker into the prefix, but it is still the
            ;; same heading line.
            (setq position (save-excursion
                             (goto-char position) (line-beginning-position)))
            (let ((entry (cl-find position (tategaki-outline--headings)
                                  :key (lambda (item) (marker-position (aref item 0))))))
              (tategaki-outline--render)
              (unless entry (user-error "Heading has been removed"))
              (aref entry 0))))
    (tategaki-outline--visit marker)))

(defun tategaki-outline--render ()
  "Render the current source buffer's headings in its outline buffer."
  (when (buffer-live-p tategaki-outline--buffer)
    (let ((entries (tategaki-outline--headings))
          (sidebar tategaki-outline--buffer)
          (name (buffer-name)))
      (with-current-buffer sidebar
        (let ((inhibit-read-only t))
          (erase-buffer)
          (setq header-line-format (format " %s  |  RET 移動  TAB 開閉  g 更新  q 閉じる" name))
          (if (= (length entries) 0)
              (insert "見出しがありません。\n\n# 第一章\n## 第一節\n第1章 始まり\n\nなどの見出しを本文に書くと\nここに表示されます。\n")
            (mapc
             (lambda (entry)
               (insert (make-string (* 2 (min 8 (1- (aref entry 1)))) ?\s))
               (aset entry 3 (point))
               (insert-text-button
                (aref entry 2)
                'follow-link t 'help-echo "RET / mouse-1: 本文の見出しへ移動"
                'keymap tategaki-outline-button-map
                'face (if (= (aref entry 1) 1) 'bold 'default)
                'tategaki-outline-marker (aref entry 0)
                'action #'tategaki-outline--activate-button)
               (insert "\n"))
             entries))
          (tategaki-outline--apply-folds entries)
          (goto-char (point-min))
          (set-buffer-modified-p nil)))
      (tategaki-outline--follow))))

(defun tategaki-outline--subtree-end (entries index)
  "Return the first index after INDEX's subtree in ENTRIES."
  (let ((level (aref (aref entries index) 1))
        (end (1+ index)))
    (while (and (< end (length entries))
                (> (aref (aref entries end) 1) level))
      (setq end (1+ end)))
    end))

(defun tategaki-outline--apply-folds (entries)
  "Apply this sidebar's collapsed headings to ENTRIES.
All invisible properties belong to sidebar overlays, never the source."
  (mapc #'delete-overlay tategaki-outline--fold-overlays)
  (setq tategaki-outline--fold-overlays nil)
  (let (retained)
    (dolist (marker tategaki-outline--folded)
      (let* ((position
              (when (marker-buffer marker)
                (with-current-buffer (marker-buffer marker)
                  (save-excursion
                    (goto-char marker) (line-beginning-position)))))
             (index (and position
                         (cl-position position entries
                                      :key (lambda (entry)
                                             (marker-position (aref entry 0))))))
             (end (and index (tategaki-outline--subtree-end entries index))))
        (if (not (and end (> end (1+ index))))
            (set-marker marker nil)
          (push marker retained)
          (let* ((parent (aref (aref entries index) 3))
                 (start (save-excursion
                          (goto-char (aref (aref entries (1+ index)) 3))
                          (line-beginning-position)))
                 (finish (if (= end (length entries)) (point-max)
                           (save-excursion
                             (goto-char (aref (aref entries end) 3))
                             (line-beginning-position))))
                 (overlay (make-overlay start finish))
                 (badge (save-excursion
                          (goto-char parent)
                          (make-overlay (line-end-position) (line-end-position)))))
            (overlay-put overlay 'invisible 'tategaki-outline)
            (overlay-put overlay 'tategaki-outline-parent parent)
            (overlay-put badge 'after-string (propertize " …" 'face 'shadow))
            (push overlay tategaki-outline--fold-overlays)
            (push badge tategaki-outline--fold-overlays)))))
    (setq tategaki-outline--folded (nreverse retained))))

(defun tategaki-outline-toggle-subtree ()
  "Expand or collapse this heading's children in the sidebar only."
  (interactive)
  (unless (derived-mode-p 'tategaki-outline-mode)
    (user-error "Run this command in the outline sidebar"))
  (let* ((button (button-at (save-excursion (back-to-indentation) (point))))
         (marker (and button (button-get button 'tategaki-outline-marker)))
         (source tategaki-outline--source)
         (position (and marker (marker-position marker)))
         (sidebar (current-buffer)))
    (unless position (user-error "No heading on this line"))
    (with-current-buffer source (tategaki-outline--render))
    (let* ((entries (buffer-local-value 'tategaki-outline--entries source))
           (index (cl-position position entries
                               :key (lambda (entry) (marker-position (aref entry 0)))))
           (collapsed (cl-find position tategaki-outline--folded
                               :key #'marker-position)))
      (unless (and index (> (tategaki-outline--subtree-end entries index) (1+ index)))
        (user-error "This heading has no child headings"))
      (if collapsed
          (progn (setq tategaki-outline--folded (delq collapsed tategaki-outline--folded))
                 (set-marker collapsed nil))
        (push (copy-marker (aref (aref entries index) 0) t) tategaki-outline--folded))
      (tategaki-outline--apply-folds entries)
      (goto-char (aref (aref entries index) 3))
      (with-current-buffer source (tategaki-outline--follow))
      (set-buffer sidebar))))

(defun tategaki-outline--follow ()
  "Highlight the current source heading without changing source point."
  (when (buffer-live-p tategaki-outline--buffer)
    (let* ((index (and tategaki-outline-follow-point
                       (tategaki-outline--current-index
                        tategaki-outline--entries (point))))
           (entry (and index (aref tategaki-outline--entries index)))
           (position (and entry (aref entry 3))))
      (with-current-buffer tategaki-outline--buffer
        (when position
          ;; If the current section is folded, highlight its visible ancestor.
          (let (parent)
            (while (setq parent (get-char-property position 'tategaki-outline-parent))
              (setq position parent))))
        (if (not position)
            (when (overlayp tategaki-outline--highlight)
              (delete-overlay tategaki-outline--highlight))
          (save-excursion
            (goto-char position)
            (unless (overlayp tategaki-outline--highlight)
              (setq tategaki-outline--highlight (make-overlay position position)))
            (move-overlay tategaki-outline--highlight
                          (line-beginning-position) (1+ (line-end-position)))
            (overlay-put tategaki-outline--highlight 'face 'highlight)
            ;; Keep the active section visible, but do not steal the user's
            ;; selection while they are navigating inside the outline itself.
            (dolist (window (get-buffer-window-list (current-buffer) nil t))
              (unless (eq window (selected-window))
                (set-window-point window position)))))))))

(defun tategaki-outline--post-command ()
  "Follow source point and changes to narrowing or heading settings."
  (when (buffer-live-p tategaki-outline--buffer)
    ;; Source edits are debounced.  Point movement needs only binary lookup.
    (if (and tategaki-outline--cache-key
             (equal (cdr tategaki-outline--cache-key)
                    (list (point-min) (point-max) (tategaki-outline--regexp)
                          tategaki-outline-level-function
                          (and (eq tategaki-outline-heading-regexp 'outline)
                               outline-level))))
        (tategaki-outline--follow)
      (tategaki-outline--render))))

(defun tategaki-outline--idle-refresh (source)
  "Refresh SOURCE after coalescing pending source edits."
  (when (buffer-live-p source)
    (with-current-buffer source
      (setq tategaki-outline--timer nil)
      (tategaki-outline--render))))

(defun tategaki-outline--after-change (&rest _)
  "Schedule an outline refresh after a source change."
  (when (buffer-live-p tategaki-outline--buffer)
    (when (timerp tategaki-outline--timer)
      (cancel-timer tategaki-outline--timer))
    (setq tategaki-outline--timer
          (run-with-idle-timer (max 0 tategaki-outline-update-delay) nil
                              #'tategaki-outline--idle-refresh (current-buffer)))))

(defun tategaki-outline-refresh ()
  "Refresh the open outline from its source text."
  (interactive)
  (with-current-buffer (tategaki-outline--source-buffer)
    (when (timerp tategaki-outline--timer)
      (cancel-timer tategaki-outline--timer)
      (setq tategaki-outline--timer nil))
    (tategaki-outline--render)))

(defun tategaki-outline--sidebar-killed ()
  "Detach source hooks when the outline buffer is killed."
  (mapc (lambda (marker) (set-marker marker nil)) tategaki-outline--folded)
  (when (buffer-live-p tategaki-outline--source)
    (let ((sidebar (current-buffer)))
      (with-current-buffer tategaki-outline--source
        (when (eq tategaki-outline--buffer sidebar)
          (setq tategaki-outline--buffer nil)
          (tategaki-outline-cleanup)))))
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (when (window-parent window) (delete-window window))))

(defun tategaki-outline-cleanup ()
  "Close this source buffer's outline and remove only its own local hooks."
  (when (timerp tategaki-outline--timer)
    (cancel-timer tategaki-outline--timer))
  (setq tategaki-outline--timer nil)
  (remove-hook 'after-change-functions #'tategaki-outline--after-change t)
  (remove-hook 'post-command-hook #'tategaki-outline--post-command t)
  (remove-hook 'kill-buffer-hook #'tategaki-outline-cleanup t)
  (remove-hook 'change-major-mode-hook #'tategaki-outline-cleanup t)
  (let ((sidebar tategaki-outline--buffer))
    (setq tategaki-outline--buffer nil)
    (when (buffer-live-p sidebar) (kill-buffer sidebar)))
  (tategaki-outline--release-entries))

(defvar tategaki-outline-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'push-button)
    (define-key map (kbd "TAB") #'tategaki-outline-toggle-subtree)
    (define-key map (kbd "<tab>") #'tategaki-outline-toggle-subtree)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "g") #'tategaki-outline-refresh)
    (define-key map (kbd "q") #'kill-current-buffer)
    map))

(define-derived-mode tategaki-outline-mode special-mode "縦書き目次"
  "Major mode for a vertical editor's heading list."
  (setq-local truncate-lines t)
  (setq-local cursor-type nil)
  (add-to-invisibility-spec 'tategaki-outline)
  (add-hook 'kill-buffer-hook #'tategaki-outline--sidebar-killed nil t))

;;;###autoload
(defun tategaki-outline (&optional close)
  "Show and select the current document's outline side window.
With prefix argument CLOSE, close it.  This never folds or changes source text."
  (interactive "P")
  (let ((window
         (with-current-buffer (tategaki-outline--source-buffer)
           (if close (tategaki-outline-cleanup)
             (unless (buffer-live-p tategaki-outline--buffer)
               (let ((source (current-buffer)))
                 (setq tategaki-outline--buffer
                       (generate-new-buffer (format "*縦書き目次: %s*" (buffer-name))))
                 (with-current-buffer tategaki-outline--buffer
                   (tategaki-outline-mode)
                   (setq-local tategaki-outline--source source)))
               (add-hook 'after-change-functions #'tategaki-outline--after-change nil t)
               (add-hook 'post-command-hook #'tategaki-outline--post-command nil t)
               (add-hook 'kill-buffer-hook #'tategaki-outline-cleanup nil t)
               (add-hook 'change-major-mode-hook #'tategaki-outline-cleanup nil t))
             (tategaki-outline--render)
             (display-buffer-in-side-window
              tategaki-outline--buffer
              `((side . ,tategaki-outline-side)
                (slot . 1) (window-width . ,(max 12 tategaki-outline-width))
                (window-parameters . ((no-delete-other-windows . t)))))))))
    (when (window-live-p window) (select-window window))))

;;;###autoload
(defun tategaki-outline-goto-heading ()
  "Choose a heading with completion and visit its source position."
  (interactive)
  (let ((marker
         (with-current-buffer (tategaki-outline--source-buffer)
           (let ((entries (tategaki-outline--headings)) choices)
             (when (= (length entries) 0)
               (user-error "No headings in the accessible text"))
             (dotimes (index (length entries))
               (let ((entry (aref entries index)))
                 (push (cons (format "%d %s" (1+ index) (aref entry 2)) (aref entry 0))
                       choices)))
             (setq choices (nreverse choices))
             (tategaki-outline--render)
             (let ((choice (completing-read "見出し: " choices nil t)))
               (cdr (assoc choice choices)))))))
    (tategaki-outline--visit marker)))

;;;###autoload
(defun tategaki-outline-next-heading (&optional count)
  "Move to the next COUNT headings in accessible source text.
A negative COUNT moves backwards.  Zero keeps the current position."
  (interactive "p")
  (let ((source (tategaki-outline--source-buffer))
        (count (or count 1)))
    (unless (zerop count)
      (let ((marker
             (with-current-buffer source
               (let* ((entries (tategaki-outline--headings))
                      (index (tategaki-outline--current-index entries (point)))
                      (exact (and index (= (point) (aref (aref entries index) 0))))
                      (target (if (> count 0)
                                  (+ (or index -1) count)
                                (+ (or index -1) count (if exact 0 1)))))
                 (unless (< -1 target (length entries))
                   (user-error "No %s heading" (if (> count 0) "next" "previous")))
                 (tategaki-outline--render)
                 (aref (aref entries target) 0)))))
        (tategaki-outline--visit marker)))))

;;;###autoload
(defun tategaki-outline-previous-heading (&optional count)
  "Move to the previous COUNT headings in accessible source text."
  (interactive "p")
  (tategaki-outline-next-heading (- (or count 1))))

(provide 'tategaki-outline)
;;; tategaki-outline.el ends here
