;;; tategaki-proofread.el --- Local, source-preserving Japanese checks -*- lexical-binding: t; -*-

;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Explicit checks examine the whole manuscript.  Optional idle checks examine
;; a bounded neighborhood using only inexpensive local rules.  Suggestions do
;; not rewrite prose and never send manuscript contents to an external service.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'tategaki-diagnostics)

(defgroup tategaki-proofread nil "Rule-based Japanese proofreading." :group 'tategaki)
(defcustom tategaki-proofread-enabled t "Enable rule-based proofreading."
  :type 'boolean :group 'tategaki-proofread)
(defcustom tategaki-proofread-live nil "Run inexpensive local checks when idle."
  :type 'boolean :group 'tategaki-proofread)
(defcustom tategaki-proofread-max-sentence-length 120 "Suggest shortening sentences longer than this."
  :type 'integer :group 'tategaki-proofread)
(defcustom tategaki-proofread-max-paragraph-length 500 "Suggest splitting paragraphs longer than this."
  :type 'integer :group 'tategaki-proofread)
(defcustom tategaki-proofread-variants nil
  "Literal spelling preferences, as (VARIANT . PREFERRED) pairs."
  :type '(alist :key-type string :value-type string) :group 'tategaki-proofread)
(defcustom tategaki-proofread-banned-words nil "Literal words to flag for review."
  :type '(repeat string) :group 'tategaki-proofread)
(defcustom tategaki-proofread-repeated-word-distance 80
  "Flag repeated kanji, katakana and Latin words within this many characters."
  :type 'integer :group 'tategaki-proofread)
(defcustom tategaki-proofread-endings '("でした" "ました" "だった" "である" "です" "ます" "した" "ない")
  "Sentence endings whose consecutive use should be reviewed."
  :type '(repeat string) :group 'tategaki-proofread)
(defcustom tategaki-proofread-idle-delay 1.2 "Seconds of idle time before local checks."
  :type 'number :group 'tategaki-proofread)
(defcustom tategaki-proofread-live-radius 1500 "Maximum characters checked on each side of a changed point."
  :type 'integer :group 'tategaki-proofread)
(defcustom tategaki-proofread-max-diagnostics 500
  "Maximum diagnostics per check, bounding overlay and result-list overhead."
  :type 'integer :group 'tategaki-proofread)

(defvar-local tategaki-proofread--timer nil)
(defvar-local tategaki-proofread--dirty-position nil)
(defvar-local tategaki-proofread-truncated nil
  "Non-nil if the latest check reached the diagnostic limit.")
(defvar tategaki-proofread--results nil)
(defvar tategaki-proofread--count 0)
(defvar tategaki-proofread--scan-start nil)
(defvar tategaki-proofread--scan-end nil)
(defvar tategaki-proofread-mode)
(defconst tategaki-proofread--local-codes
  '("punctuation-run" "ellipsis-form" "repeated-particle" "abnormal-whitespace"
    "halfwidth-kana" "banned-word" "spelling-variant" "long-sentence"))

(defun tategaki-proofread--report (start end code message &optional severity details)
  "Record a suggestion for START..END with CODE, MESSAGE, SEVERITY and DETAILS."
  (if (>= tategaki-proofread--count (max 1 tategaki-proofread-max-diagnostics))
      (setq tategaki-proofread-truncated t)
    (cl-incf tategaki-proofread--count)
    (push (list :id (format "rule:%s:%d:%d" code start end)
                :source 'rule :severity (or severity 'warning)
                :start start :end end :code code :message message :details details)
          tategaki-proofread--results)))

(defun tategaki-proofread--matches (regexp callback)
  "Call CALLBACK at each REGEXP match in the current scan region."
  (save-excursion
    (goto-char tategaki-proofread--scan-start)
    (while (and (not tategaki-proofread-truncated)
                (re-search-forward regexp tategaki-proofread--scan-end t))
      (let ((begin (match-beginning 0)) (end (match-end 0))
            (text (match-string-no-properties 0)))
        (funcall callback begin end text)
        ;; User-defined values are literal; still guard against empty matches.
        (when (= begin end) (forward-char 1))))))

(defun tategaki-proofread--local-rules ()
  "Check punctuation, spacing, particles and configured literal words."
  (tategaki-proofread--matches
   "[、。，．]\\{2,\\}\\|[!！?？]\\{3,\\}\\|・\\{3,\\}"
   (lambda (begin end _text)
     (tategaki-proofread--report begin end "punctuation-run" "約物が連続しています")))
  (tategaki-proofread--matches
   "…+"
   (lambda (begin end text)
     (when (= (% (length text) 2) 1)
       (tategaki-proofread--report begin end "ellipsis-form" "三点リーダーの個数を確認してください" 'info))))
  (tategaki-proofread--matches
   "\\([はがをにへとでの]\\)\\1"
   (lambda (begin end _text)
     (tategaki-proofread--report begin end "repeated-particle" "同じ助詞が続いています")))
  (tategaki-proofread--matches
   "\t+\\|[ 　]\\{2,\\}\\|[ 　]+$"
   (lambda (begin end _text)
     (tategaki-proofread--report begin end "abnormal-whitespace" "タブ・連続空白・行末空白を確認してください" 'info)))
  (tategaki-proofread--matches
   "[ｦ-ﾟ]+"
   (lambda (begin end _text)
     (tategaki-proofread--report begin end "halfwidth-kana" "半角カタカナが含まれています" 'info)))
  (dolist (word tategaki-proofread-banned-words)
    (when (and (stringp word) (not (string-empty-p word)))
      (tategaki-proofread--matches
       (regexp-quote word)
       (lambda (begin end _text)
         (tategaki-proofread--report begin end "banned-word"
                                    (format "要確認語: %s" word))))))
  (dolist (pair tategaki-proofread-variants)
    (when (and (stringp (car pair)) (not (string-empty-p (car pair))))
      (tategaki-proofread--matches
       (regexp-quote (car pair))
       (lambda (begin end _text)
         (tategaki-proofread--report begin end "spelling-variant"
                                    (format "表記を確認: %s → %s" (car pair) (cdr pair))
                                    'info (list :preferred (cdr pair))))))))

(defun tategaki-proofread--brackets ()
  "Check bracket matching with a linear stack, including nested brackets."
  (let ((pairs '((?「 . ?」) (?『 . ?』) (?（ . ?）) (?\( . ?\))
                 (?［ . ?］) (?\[ . ?\]) (?｛ . ?｝) (?\{ . ?\})
                 (?【 . ?】) (?〈 . ?〉) (?《 . ?》)))
        stack)
    (tategaki-proofread--matches
     (regexp-opt '("「" "」" "『" "』" "（" "）" "(" ")" "［" "］"
                   "[" "]" "｛" "｝" "{" "}" "【" "】" "〈" "〉" "《" "》"))
     (lambda (begin end text)
       (let* ((character (aref text 0)) (opening (assq character pairs)))
         (if opening
             (push (cons character begin) stack)
           (if (and stack (= character (cdr (assq (caar stack) pairs))))
               (pop stack)
             (tategaki-proofread--report begin end "unmatched-bracket"
                                        "閉じ括弧に対応する開き括弧がありません" 'error))))))
    (dolist (entry stack)
      (tategaki-proofread--report (cdr entry) (1+ (cdr entry)) "unmatched-bracket"
                                 "開き括弧が閉じられていません" 'error))))

(defun tategaki-proofread--mixed-forms ()
  "Check mixed full/half width letters and Arabic/kanji numeral forms."
  (let (latin-full latin-half digit-full digit-half kanji)
    (tategaki-proofread--matches
     "[A-Za-z]+\\|[Ａ-Ｚａ-ｚ]+\\|[0-9]+\\|[０-９]+\\|[〇零一二三四五六七八九十百千万億]+[年月日時個人歳円章回]"
     (lambda (begin end text)
       (let ((entry (cons begin end)) (first (aref text 0)))
         (cond ((and (>= first ?Ａ) (<= first ?ｚ)) (push entry latin-full))
               ((or (and (>= first ?A) (<= first ?Z))
                    (and (>= first ?a) (<= first ?z))) (push entry latin-half))
               ((and (>= first ?０) (<= first ?９)) (push entry digit-full))
               ((and (>= first ?0) (<= first ?9)) (push entry digit-half))
               (t (push (cons begin (1- end)) kanji))))))
    (dolist (entry (append (and latin-half latin-full) (and digit-half digit-full)))
      (tategaki-proofread--report (car entry) (cdr entry) "mixed-width"
                                 "全角と半角の英数字が混在しています" 'info))
    (when (and kanji (or digit-full digit-half))
      (dolist (entry kanji)
        (tategaki-proofread--report (car entry) (cdr entry) "mixed-number-form"
                                   "算用数字と漢数字の表記を確認してください" 'info)))))

(defun tategaki-proofread--sentences (&optional lightweight)
  "Check sentence lengths and endings; LIGHTWEIGHT skips ending comparison."
  (save-excursion
    (goto-char tategaki-proofread--scan-start)
    (let ((begin (point)) previous-ending)
      (while (and (< begin tategaki-proofread--scan-end)
                  (not tategaki-proofread-truncated))
        (goto-char begin)
        (let* ((found (re-search-forward "[。！？!?\n]+" tategaki-proofread--scan-end t))
               (end (if found (match-beginning 0) tategaki-proofread--scan-end))
               (next (if found (match-end 0) tategaki-proofread--scan-end))
               (text (string-trim (buffer-substring-no-properties begin end)))
               ending)
          (when (> (length text) (max 0 tategaki-proofread-max-sentence-length))
            (tategaki-proofread--report begin end "long-sentence"
                                       (format "文が長めです（%d字）" (length text)) 'info))
          (unless lightweight
            (setq ending (cl-find-if (lambda (item)
                                      (and (not (string-empty-p item))
                                           (string-suffix-p item text)))
                                    tategaki-proofread-endings))
            (when (and ending (equal ending previous-ending))
              (tategaki-proofread--report (max begin (- end (length ending))) end
                                         "repeated-ending" (format "同じ語尾が続いています: %s" ending)
                                         'info))
            (unless (string-empty-p text) (setq previous-ending ending)))
          (setq begin next))))))

(defun tategaki-proofread--paragraphs ()
  "Check paragraph lengths, treating blank lines as paragraph separators."
  (save-excursion
    (goto-char tategaki-proofread--scan-start)
    (let ((begin (point)))
      (while (and (< begin tategaki-proofread--scan-end)
                  (not tategaki-proofread-truncated))
        (goto-char begin)
        (let* ((found (re-search-forward "\n[ \t　]*\n" tategaki-proofread--scan-end t))
               (end (if found (match-beginning 0) tategaki-proofread--scan-end))
               (next (if found (match-end 0) tategaki-proofread--scan-end)))
          (when (> (- end begin) (max 0 tategaki-proofread-max-paragraph-length))
            (tategaki-proofread--report begin end "long-paragraph"
                                       (format "段落が長めです（%d字）" (- end begin)) 'info))
          (setq begin next))))))

(defun tategaki-proofread--repeated-words ()
  "Find nearby repeated word-shaped runs without morphological dependencies."
  (let ((last-seen (make-hash-table :test #'equal)))
    (tategaki-proofread--matches
     "[一-龯々]\\{2,\\}\\|[ァ-ヺー]\\{2,\\}\\|[A-Za-z]\\{2,\\}"
     (lambda (begin end text)
       (let ((previous (gethash text last-seen)))
         (when (and previous (<= (- begin previous) tategaki-proofread-repeated-word-distance))
           (tategaki-proofread--report begin end "repeated-word"
                                      (format "同じ語が近接しています: %s" text) 'info))
         (puthash text end last-seen))))))

;;;###autoload
(defun tategaki-proofread-run (&optional lightweight)
  "Check the source manuscript and publish rule diagnostics.
When LIGHTWEIGHT is non-nil, check a bounded neighborhood with local rules.
An explicit interactive invocation always checks the whole manuscript."
  (interactive)
  (with-current-buffer (tategaki-diagnostics-source-buffer)
    (if (not tategaki-proofread-enabled)
        (progn (tategaki-diagnostics-clear 'rule (current-buffer)) nil)
      (save-excursion
        (save-restriction
          (widen)
          (let* ((position (or tategaki-proofread--dirty-position (point)))
                 (radius (max 1 tategaki-proofread-live-radius))
                 (tategaki-proofread--scan-start (if lightweight (max (point-min) (- position radius)) (point-min)))
                 (tategaki-proofread--scan-end (if lightweight (min (point-max) (+ position radius)) (point-max)))
                 (tategaki-proofread--results nil)
                 (tategaki-proofread--count 0)
                 (old (and lightweight (tategaki-diagnostics-get 'rule (current-buffer)))))
            (setq tategaki-proofread-truncated nil)
            (tategaki-proofread--local-rules)
            (tategaki-proofread--sentences lightweight)
            (unless lightweight
              (tategaki-proofread--brackets)
              (tategaki-proofread--mixed-forms)
              (tategaki-proofread--paragraphs)
              (tategaki-proofread--repeated-words))
            (let ((results (nreverse tategaki-proofread--results)))
              (when lightweight
                (setq results
                      (append (cl-remove-if
                               (lambda (item)
                                 (and (member (plist-get item :code) tategaki-proofread--local-codes)
                                      (< (plist-get item :start) tategaki-proofread--scan-end)
                                      (> (plist-get item :end) tategaki-proofread--scan-start)))
                              old)
                              results)))
              (when (> (length results) (max 1 tategaki-proofread-max-diagnostics))
                (setq tategaki-proofread-truncated t
                      results (cl-subseq results 0 (max 1 tategaki-proofread-max-diagnostics))))
              (tategaki-diagnostics-set 'rule results (current-buffer))
              (when (called-interactively-p 'interactive)
                (message "校正: %d 件%s" (length results)
                         (if tategaki-proofread-truncated "（上限に達しました）" "")))
              results)))))))

(defun tategaki-proofread--cancel ()
  "Cancel a pending local check."
  (when (timerp tategaki-proofread--timer) (cancel-timer tategaki-proofread--timer))
  (setq tategaki-proofread--timer nil))

(defun tategaki-proofread--idle (buffer)
  "Run a local check in live BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq tategaki-proofread--timer nil)
      (when (and tategaki-proofread-mode tategaki-proofread-enabled tategaki-proofread-live)
        (tategaki-proofread-run t)))))

(defun tategaki-proofread--changed (begin &rest _)
  "Schedule a local check around changed position BEGIN."
  (setq tategaki-proofread--dirty-position begin)
  (tategaki-proofread--cancel)
  (when (and tategaki-proofread-enabled tategaki-proofread-live)
    (setq tategaki-proofread--timer
          (run-with-idle-timer (max 0.1 tategaki-proofread-idle-delay) nil
                               #'tategaki-proofread--idle (current-buffer)))))

;;;###autoload
(define-minor-mode tategaki-proofread-mode
  "Maintain optional idle proofreading in the source buffer."
  :lighter " 校"
  (if tategaki-proofread-mode
      (progn
        (add-hook 'after-change-functions #'tategaki-proofread--changed nil t)
        (add-hook 'kill-buffer-hook #'tategaki-proofread--cancel nil t)
        (tategaki-proofread--changed (point)))
    (remove-hook 'after-change-functions #'tategaki-proofread--changed t)
    (remove-hook 'kill-buffer-hook #'tategaki-proofread--cancel t)
    (tategaki-proofread--cancel)))

(defun tategaki-proofread-reconfigure ()
  "Apply current enabled/live preferences to the source buffer."
  (with-current-buffer (tategaki-diagnostics-source-buffer)
    (tategaki-proofread-mode (if (and tategaki-proofread-enabled tategaki-proofread-live) 1 -1))
    (unless tategaki-proofread-enabled (tategaki-diagnostics-clear 'rule (current-buffer)))))

(provide 'tategaki-proofread)
;;; tategaki-proofread.el ends here
