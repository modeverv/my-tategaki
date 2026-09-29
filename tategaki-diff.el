;;; tategaki-diff.el --- Independent vertical manuscript comparisons -*- lexical-binding: t; -*-

;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; Compare independent source copies.  Ordinary overlays are projected by
;; tategaki-highlight into both vertical views; original buffers stay intact.

;;; Code:
(require 'tategaki-pane)

(require 'cl-lib)
(require 'tategaki-history)
(require 'tategaki-manuscript)
(require 'tategaki-typeset)

(defgroup tategaki-diff nil "Vertical manuscript comparisons." :group 'text)
(defface tategaki-diff-added '((t (:inherit diff-added)))
  "Face projected over added text." :group 'tategaki-diff)
(defface tategaki-diff-removed '((t (:inherit diff-removed)))
  "Face projected over removed text." :group 'tategaki-diff)
(defcustom tategaki-diff-program "diff"
  "Program used to find changed line ranges in manuscripts."
  :type 'string :group 'tategaki-diff)
(defvar-local tategaki-diff--context nil)
(defvar-local tategaki-diff--overlays nil)
(defvar-local tategaki-scene-branch-origin nil
  "Source buffer, range and history snapshot from which this branch began.")
(defvar tategaki-studio-source)
(declare-function tategaki-mode "tategaki" (&optional arg))
(declare-function tategaki-refresh "tategaki" ())

(defun tategaki-diff--text (buffer)
  "Return BUFFER's complete source text, ignoring narrowing."
  (with-current-buffer buffer
    (save-restriction (widen)
                      (buffer-substring-no-properties (point-min) (point-max)))))

(defun tategaki-diff--hunks (old-text new-text)
  "Return changed ranges as (OLD-LINE OLD-COUNT NEW-LINE NEW-COUNT).
Use zero-context unified diff so unchanged lines remain unhighlighted."
  (unless (executable-find tategaki-diff-program)
    (user-error "縦書き比較には diff コマンドが必要です"))
  (let ((old-file (make-temp-file "tategaki-diff-old-"))
        (new-file (make-temp-file "tategaki-diff-new-")))
    (unwind-protect
        (progn
          (tategaki-history--atomic-write old-file old-text)
          (tategaki-history--atomic-write new-file new-text)
          (with-temp-buffer
            (let ((status (call-process tategaki-diff-program nil t nil
                                        "-U0" "--" old-file new-file)) hunks)
              (unless (memq status '(0 1))
                (user-error "Diff failed: %s" (buffer-string)))
              (goto-char (point-min))
              (while (re-search-forward
                      "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? +\\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
                      nil t)
                (push (list (string-to-number (match-string 1))
                            (if (match-string 2) (string-to-number (match-string 2)) 1)
                            (string-to-number (match-string 3))
                            (if (match-string 4) (string-to-number (match-string 4)) 1))
                      hunks))
              (nreverse hunks))))
      (delete-file old-file) (delete-file new-file))))

(defun tategaki-diff--mark-lines (line count face)
  "Mark COUNT lines starting at LINE with FACE in this comparison copy."
  (when (> count 0)
    (save-excursion
      (goto-char (point-min))
      (forward-line (max 0 (1- line)))
      (let ((start (point)))
        (forward-line count)
        (when (< start (point))
          (let ((overlay (make-overlay start (point))))
            (overlay-put overlay 'face face)
            (overlay-put overlay 'tategaki-diff t)
            (overlay-put overlay 'priority 120)
            (push overlay tategaki-diff--overlays)))))))

(defun tategaki-diff--copy (source title text)
  "Create TITLE containing TEXT and SOURCE's main display settings."
  (let ((settings (with-current-buffer source
                    (cl-loop for symbol in
                             '(tategaki-manuscript-size tategaki-manuscript-spread
                               tategaki-manuscript-grid tategaki-typesetting
                               tategaki-column-spacing tategaki-character-spacing
                               tategaki--text-scale-amount)
                             when (boundp symbol)
                             collect (cons symbol (symbol-value symbol)))))
        (copy (generate-new-buffer title)))
    (with-current-buffer copy
      (insert text) (goto-char (point-min)) (text-mode)
      (dolist (setting settings) (set (make-local-variable (car setting)) (cdr setting)))
      (setq-local tategaki-studio-source source)
      (setq-local buffer-undo-list t)
      (set-buffer-modified-p nil)
      (setq buffer-read-only t))
    copy))

(defun tategaki-diff-quit ()
  "Close both comparison copies and restore the previous window layout."
  (interactive)
  (let ((context tategaki-diff--context))
    (when (and context (not (plist-get context :closing)))
      (setf (plist-get context :closing) t)
      (let ((configuration (plist-get context :windows)))
        (when (and configuration (frame-live-p (window-configuration-frame configuration)))
          (set-window-configuration configuration)))
      (dolist (buffer (plist-get context :buffers))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (setq tategaki-diff--context nil)
            (remove-hook 'kill-buffer-hook #'tategaki-diff-quit t))
          (kill-buffer buffer))))))

(defun tategaki-diff-next-change (&optional backwards)
  "Move to the next changed range, or previous with BACKWARDS."
  (interactive "P")
  (let* ((positions (sort (delq nil (mapcar #'overlay-start tategaki-diff--overlays)) #'<))
         (target (if backwards
                     (car (last (cl-remove-if-not (lambda (p) (< p (point))) positions)))
                   (cl-find-if (lambda (p) (> p (point))) positions))))
    (unless target (user-error "この方向には次の差分がありません"))
    (goto-char target)
    (when (bound-and-true-p tategaki-mode) (tategaki-refresh))))

(defvar tategaki-diff-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'tategaki-diff-quit)
    (define-key map (kbd "n") #'tategaki-diff-next-change)
    (define-key map (kbd "p") (lambda () (interactive) (tategaki-diff-next-change t)))
    map))

(define-minor-mode tategaki-diff-mode
  "Navigate a read-only manuscript comparison with n, p and q."
  :lighter " 比較" :keymap tategaki-diff-mode-map)

;;;###autoload
(defun tategaki-diff-buffers (old-buffer new-buffer)
  "Compare OLD-BUFFER and NEW-BUFFER in independent vertical copies.
Return the two comparison buffers.  No original text, undo or flags change."
  (interactive (list (read-buffer "旧稿: " (other-buffer) t)
                     (read-buffer "新稿: " (current-buffer) t)))
  (setq old-buffer (get-buffer old-buffer) new-buffer (get-buffer new-buffer))
  (unless (and old-buffer new-buffer) (user-error "比較する原稿バッファがありません"))
  (let* ((old-text (tategaki-diff--text old-buffer))
         (new-text (tategaki-diff--text new-buffer))
         (hunks (tategaki-diff--hunks old-text new-text))
         (old (tategaki-diff--copy old-buffer "*旧稿 縦書き比較*" old-text))
         (new (tategaki-diff--copy new-buffer "*新稿 縦書き比較*" new-text))
         (context (list :buffers (list old new) :windows (current-window-configuration)
                        :closing nil))
         success)
    (unwind-protect
        (progn
          (with-current-buffer old
            (dolist (hunk hunks) (tategaki-diff--mark-lines (nth 0 hunk) (nth 1 hunk)
                                                          'tategaki-diff-removed)))
          (with-current-buffer new
            (dolist (hunk hunks) (tategaki-diff--mark-lines (nth 2 hunk) (nth 3 hunk)
                                                          'tategaki-diff-added)))
          (pop-to-buffer old)
          (delete-other-windows)
          (let ((right (split-window-right)))
            (set-window-buffer right new)
            (dolist (window (list (selected-window) right))
              (with-selected-window window
                (when (and (display-graphic-p) (require 'tategaki nil t))
                  (tategaki-mode 1))
                (tategaki-diff-mode 1)
                (setq-local tategaki-diff--context context)
                (setq-local header-line-format
                            (format "%s   n/p: 差分移動   q: 戻る" (buffer-name)))
                (tategaki-pane-install new-buffer #'tategaki-diff-quit)
                (add-hook 'kill-buffer-hook #'tategaki-diff-quit nil t))))
          (setq success t)
          (list old new))
      (unless success
        (set-window-configuration (plist-get context :windows))
        (dolist (buffer (list old new))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (setq tategaki-diff--context nil))
            (kill-buffer buffer)))))))

;;;###autoload
(defun tategaki-scene-branch (&optional name)
  "Create an editable NAME copy of the region or whole manuscript.
Record the current source in history first.  The copy has no filename."
  (interactive (list (read-string "別案の名前: " "別案")))
  (let* ((source (current-buffer))
         (start (if (use-region-p) (region-beginning) (point-min)))
         (end (if (use-region-p) (region-end) (point-max)))
         (text (buffer-substring-no-properties start end))
         (record (tategaki-history-snapshot 'branch))
         (copy (generate-new-buffer (or name "原稿の別案"))))
    (with-current-buffer copy
      (insert text) (text-mode) (goto-char (point-min))
      (setq-local tategaki-scene-branch-origin
                  (list :source source :start start :end end :snapshot record))
      (buffer-enable-undo) (set-buffer-modified-p t))
    (with-current-buffer copy (tategaki-pane-install source nil "原稿の別案"))
    (pop-to-buffer copy)
    copy))

(provide 'tategaki-diff)
;;; tategaki-diff.el ends here
