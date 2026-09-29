;;; tategaki-knowledge.el --- Explicit character knowledge boundaries -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'tategaki-pane)
(require 'tategaki-world)
(require 'seq)
(declare-function tategaki-refresh "tategaki" ())

(declare-function tategaki-world-scenes "tategaki-world" (&optional cutoff include-candidates))
(declare-function tategaki-world-scene-range "tategaki-world" (record &optional cutoff))
(declare-function tategaki-world-reference-valid-p "tategaki-world" (reference &optional buffer))

(defun tategaki-knowledge-ranges (character &optional cutoff)
  "Return verified source ranges explicitly visible to CHARACTER at CUTOFF.
Being named or present in a scene never implies knowledge.  Only accepted
known-by facts and author-approved scene visibility permit source passages."
  (let (ranges)
    (dolist (fact (tategaki-world-query "Fact" cutoff character))
      (let ((ref (plist-get fact :source)))
        (when (and (tategaki-world-reference-valid-p ref)
                   (or (not cutoff) (<= (plist-get ref :end) cutoff)))
          (push (cons (plist-get ref :start) (plist-get ref :end)) ranges))))
    (when (fboundp 'tategaki-world-scenes)
      (dolist (scene (tategaki-world-scenes cutoff))
        (when (seq-contains-p (plist-get scene :visibility) character #'equal)
          (let ((range (tategaki-world-scene-range scene cutoff)))
            (when range (push range ranges))))))
    (let (merged)
      (dolist (range (sort ranges (lambda (a b) (< (car a) (car b)))))
        (when (< (car range) (cdr range))
          (if (and merged (<= (car range) (cdar merged)))
              (setcdr (car merged) (max (cdar merged) (cdr range)))
            (push (cons (car range) (cdr range)) merged))))
      (nreverse merged))))

(defun tategaki-knowledge-filter-chunks (chunks character &optional cutoff)
  "Clip CHUNKS to author-approved knowledge ranges for CHARACTER at CUTOFF.
No unannotated surrounding prose or chapter titles are included."
  (with-current-buffer (tategaki-semantic-source)
    (save-restriction
      (widen)
      (let ((ranges (tategaki-knowledge-ranges character cutoff)) result)
        (dolist (chunk chunks)
          (dolist (range ranges)
            (let ((start (max (car range) (plist-get chunk :start)))
                  (end (min (cdr range) (plist-get chunk :end))))
              (when (< start end)
                (let ((copy (copy-sequence chunk))
                      (text (buffer-substring-no-properties start end)))
                  (setq copy (plist-put copy :start start)
                        copy (plist-put copy :end end)
                        copy (plist-put copy :text text)
                        copy (plist-put copy :chapter "人物確認範囲")
                        copy (plist-put copy :characters nil)
                        copy (plist-put copy :pov nil)
                        copy (plist-put copy :story-time nil)
                        copy (plist-put copy :hash (secure-hash 'sha256 text)))
                  (push copy result))))))
        (nreverse result)))))

(defun tategaki-knowledge-difference (character &optional cutoff)
  "Compare registered reader and CHARACTER knowledge through CUTOFF.
Return :reader-only, :character-only and :shared lists of accepted facts."
  (let* ((reader (tategaki-world-query "Fact" cutoff "reader"))
         (person (tategaki-world-query "Fact" cutoff character))
         (ids (mapcar (lambda (r) (plist-get r :id)) person))
         (reader-ids (mapcar (lambda (r) (plist-get r :id)) reader)))
    (list :reader-only (seq-remove (lambda (r) (member (plist-get r :id) ids)) reader)
          :character-only (seq-remove (lambda (r) (member (plist-get r :id) reader-ids)) person)
          :shared (seq-filter (lambda (r) (member (plist-get r :id) ids)) reader))))

;;;###autoload
(defun tategaki-knowledge-compare (character)
  "Show the explicit reader/CHARACTER knowledge difference at source point."
  (interactive "s知識を比較する人物: ")
  (let* ((source (tategaki-semantic-source))
         (cutoff (with-current-buffer source (point)))
         (data (with-current-buffer source (tategaki-knowledge-difference character cutoff)))
         (buffer (get-buffer-create "*Tategaki Knowledge*")))
    (with-current-buffer buffer
      (special-mode)
      (setq-local tategaki-studio-source source)
      (tategaki-pane-install source nil "人物の知識")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "%s と読者の知識 — 原稿位置 %d まで\n\n" character cutoff))
        (insert "作者が確認した登録情報の比較です。未登録の情報は不明です。\n\n")
        (dolist (section '((:reader-only . "読者だけが知っている")
                           (:character-only . "人物だけが知っている")
                           (:shared . "両方が知っている")))
          (insert (cdr section) "\n")
          (if (not (plist-get data (car section))) (insert "  登録なし\n")
            (dolist (fact (plist-get data (car section)))
              (let ((ref (plist-get fact :source)))
                (insert-text-button
                 (format "  %s: %s = %s" (or (plist-get fact :subject) "")
                         (or (plist-get fact :attribute) "") (or (plist-get fact :value) ""))
                 'follow-link t
                 'action (lambda (_)
                           (unless (and (buffer-live-p source)
                                        (tategaki-world-reference-valid-p ref source))
                             (user-error "出典が変更されています。情報を確認し直してください"))
                           (pop-to-buffer source) (widen)
                           (goto-char (plist-get ref :start))
                           (when (bound-and-true-p tategaki-mode) (tategaki-refresh))))
                (insert "\n"))))
          (insert "\n"))
        (goto-char (point-min))))
    (display-buffer-in-side-window buffer '((side . right) (slot . 2) (window-width . 0.35)))))

(provide 'tategaki-knowledge)
;;; tategaki-knowledge.el ends here
