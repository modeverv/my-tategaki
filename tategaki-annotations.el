;;; tategaki-annotations.el --- Editable plain-text annotations -*- lexical-binding: t; -*-

;;; Commentary:
;; Author annotations in the source buffer using ordinary undoable edits.
;; Display-only composition never needs a second copy of the document.

;;; Code:
(require 'tategaki-typeset)
(require 'subr-x)

(defvar tategaki-mode)
(declare-function tategaki-refresh "tategaki" ())

(defun tategaki-annotations--refresh ()
  "Refresh a vertical layer after an annotation command."
  (when (bound-and-true-p tategaki-mode) (tategaki-refresh)))

(defun tategaki-annotations--region ()
  "Return a nonempty selected source interval."
  (unless (use-region-p) (user-error "Select the text to annotate first"))
  (list (region-beginning) (region-end)))

(defun tategaki-annotations--wrap (start end opening closing)
  "Wrap source START..END with OPENING and CLOSING as one undo operation."
  (barf-if-buffer-read-only)
  (unless (< start end) (user-error "Select at least one character"))
  (when (string-match-p "\n" (buffer-substring-no-properties start end))
    (user-error "Annotations cannot cross a paragraph boundary"))
  (atomic-change-group
    (save-excursion
      (goto-char end) (insert closing)
      (goto-char start) (insert opening)))
  (goto-char (+ start (length opening)))
  (deactivate-mark)
  (tategaki-annotations--refresh))

;;;###autoload
(defun tategaki-insert-ruby (start end reading)
  "Give source START..END the READING using ｜body《reading》 notation."
  (interactive (append (tategaki-annotations--region) (list (read-string "Ruby reading: "))))
  (when (or (string-empty-p reading) (string-match-p "[《》\n]" reading))
    (user-error "Ruby must be nonempty and contain no ruby delimiters or newlines"))
  (when (string-match-p "[｜|《》\n]" (buffer-substring-no-properties start end))
    (user-error "The ruby base cannot contain ruby notation"))
  (tategaki-annotations--wrap start end "｜" (concat "《" reading "》")))

;;;###autoload
(defun tategaki-edit-ruby (reading)
  "Replace the ruby READING at point, retaining its source body."
  (interactive (list (read-string "New ruby reading: ")))
  (barf-if-buffer-read-only)
  (when (or (string-empty-p reading) (string-match-p "[《》\n]" reading))
    (user-error "Ruby must be nonempty and contain no ruby delimiters or newlines"))
  (let* ((tategaki-typeset-annotation-display 'rendered)
         (layout (tategaki-typeset-layout (buffer-substring-no-properties (point-min) (point-max))
                                          30 (point-min)))
         (entry (tategaki-typeset-entry layout (point)))
         (unit (and entry (aref entry 4)))
         (start (plist-get unit :ruby-start)) (end (plist-get unit :ruby-end)))
    (unless (and start end) (user-error "Point is not in a supported ruby annotation"))
    (atomic-change-group
      (save-excursion (goto-char start) (delete-region start end) (insert reading)))
    (goto-char (plist-get unit :base-start))
    (tategaki-annotations--refresh)))

;;;###autoload
(defun tategaki-insert-tcy (start end)
  "Set source START..END horizontally inside one vertical cell."
  (interactive (tategaki-annotations--region))
  (tategaki-annotations--wrap start end "［＃縦中横］" "［＃縦中横終わり］"))

;;;###autoload
(defun tategaki-add-emphasis (start end kind)
  "Add dot or line emphasis of KIND to source START..END."
  (interactive (append (tategaki-annotations--region)
                       (list (intern (completing-read "Emphasis: " '("dot" "line") nil t)))))
  (unless (memq kind '(dot line)) (user-error "Emphasis must be dot or line"))
  (let ((name (if (eq kind 'dot) "傍点" "傍線")))
    (tategaki-annotations--wrap start end (concat "［＃" name "］")
                                (concat "［＃" name "終わり］"))))

;;;###autoload
(defun tategaki-toggle-annotations ()
  "Toggle rendered annotations and their editable source notation locally."
  (interactive)
  (setq-local tategaki-typeset-annotation-display
              (if (eq tategaki-typeset-annotation-display 'raw) 'rendered 'raw))
  (tategaki-annotations--refresh)
  (message "Vertical annotations: %s" tategaki-typeset-annotation-display))

(provide 'tategaki-annotations)
;;; tategaki-annotations.el ends here
