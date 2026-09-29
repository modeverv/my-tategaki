;;; tategaki-voice.el --- Explicitly attributed character dialogue review -*- lexical-binding: t; -*-
;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'tategaki-world)
(require 'tategaki-proofread)
(defconst tategaki-voice-first-person '("私" "わたし" "あたし" "僕" "ぼく" "俺" "おれ" "わし" "自分"))
(defconst tategaki-voice-second-person '("あなた" "貴方" "君" "きみ" "お前" "あんた" "そなた"))
(defconst tategaki-voice--speech-verbs
  '("言った" "言う" "答えた" "答える" "尋ねた" "尋ねる" "聞いた" "叫んだ"
    "呟いた" "つぶやいた" "話した" "囁いた" "ささやいた" "返した")
  "Local reporting verbs used as evidence, never as confirmed attribution.")

(defun tategaki-voice--characters ()
  "Return accepted character names; inferred names cannot become speakers."
  (delete-dups (mapcar (lambda (record) (plist-get record :name)) (tategaki-world-query "Character"))))

(defun tategaki-voice--choose-character ()
  "Ask the author to choose a known speaker."
  (let ((characters (tategaki-voice--characters)))
    (unless characters (user-error "先に作品世界に人物を登録してください"))
    (completing-read "話者: " characters nil t)))

(defun tategaki-voice-register (character start end)
  "Register source START..END as author-attributed CHARACTER dialogue."
  (unless (member character (tategaki-voice--characters)) (user-error "未登録の人物です"))
  (with-current-buffer (tategaki-world--source)
    (unless (< start end) (user-error "台詞の範囲を選択してください"))
    (let* ((reference (tategaki-world-source-reference start end))
           (record (list :id (tategaki-world--id "voice") :character character :source reference))
           (records (tategaki-world--read-store "voice")))
      (tategaki-world--write-store "voice" (append records (list record)))
      record)))

(defun tategaki-voice-register-region ()
  "Add the selected source dialogue as an author-attributed sample."
  (interactive)
  (let ((character (tategaki-voice--choose-character))
        (region (tategaki-world-selection)))
    (with-current-buffer (tategaki-world--source)
      (unless region (user-error "原稿で台詞を選択してください"))
      (tategaki-voice-register character (car region) (cdr region)))
    (tategaki-voice)))

(defun tategaki-voice--counts (text words)
  "Count literal occurrences in TEXT for WORDS, keeping nonzero counts."
  (let (counts)
    (dolist (word words)
      (let ((position 0) (count 0))
        (while (string-match (regexp-quote word) text position)
          (cl-incf count) (setq position (match-end 0)))
        (when (> count 0) (push (cons word count) counts))))
    (sort counts (lambda (a b) (> (cdr a) (cdr b))))))

(defun tategaki-voice--frequent-expressions (text)
  "Extract repeated 3..12 character expressions from TEXT without a word list.
Count distinct punctuation-delimited clauses, not overlapping occurrences.
Prefer longer phrases over substrings with the same support.  This is literal
phrase discovery, not morphological or semantic analysis."
  (let ((counts (make-hash-table :test #'equal)) candidates kept)
    (dolist (clause (split-string text "[、。，．！？!?「」『』\n\t 　]+" t))
      (let ((seen (make-hash-table :test #'equal)))
        (dotimes (start (length clause))
          (cl-loop for size from 3 to (min 12 (- (length clause) start))
                   for phrase = (substring clause start (+ start size))
                   unless (or (gethash phrase seen)
                              (string-match-p "\\`[0-9０-９]+\\'" phrase))
                   do (progn (puthash phrase t seen)
                             (puthash phrase (1+ (gethash phrase counts 0)) counts))))))
    (maphash (lambda (phrase count)
               (when (and (>= count 2)
                          (not (member phrase tategaki-proofread-endings)))
                 (push (cons phrase count) candidates))) counts)
    (setq candidates
          (sort candidates (lambda (a b)
                             (if (= (cdr a) (cdr b))
                                 (if (= (length (car a)) (length (car b)))
                                     (string< (car a) (car b))
                                   (> (length (car a)) (length (car b))))
                               (> (cdr a) (cdr b))))))
    (dolist (candidate candidates)
      (unless (or (>= (length kept) 24)
                  (cl-some (lambda (longer)
                             (and (= (cdr longer) (cdr candidate))
                                  (string-match-p (regexp-quote (car candidate)) (car longer)))) kept))
        (push candidate kept)))
    (nreverse kept)))

(defun tategaki-voice--metrics (text)
  "Return deterministic descriptive metrics for author-attributed TEXT."
  (let* ((clean (replace-regexp-in-string "[「」『』]" "" text))
         (sentences (split-string clean "[。！？!?\n]+" t "[ 　\t]+"))
         (count (length sentences)) (polite 0) endings
         (words (make-hash-table :test #'equal)) (position 0))
    (dolist (sentence sentences)
      (let ((ending (cl-find-if (lambda (item) (string-suffix-p item sentence)) tategaki-proofread-endings)))
        (when ending (cl-incf (alist-get ending endings 0 nil #'equal))))
      (when (string-match-p "\\(?:です\\|ます\\|でした\\|ました\\)\\'" sentence) (cl-incf polite)))
    (while (string-match "[一-龯々]\\{2,\\}\\|[ァ-ヺー]\\{2,\\}\\|[A-Za-z]\\{2,\\}" clean position)
      (let ((word (match-string 0 clean))) (puthash word (1+ (gethash word words 0)) words))
      (setq position (match-end 0)))
    (let (vocabulary)
      (maphash (lambda (word n) (push (cons word n) vocabulary)) words)
      (list :sentences count :mean-length (if (> count 0) (/ (float (length clean)) count) 0)
            :first-person (tategaki-voice--counts clean tategaki-voice-first-person)
            :second-person (tategaki-voice--counts clean tategaki-voice-second-person)
            :endings (sort endings (lambda (a b) (> (cdr a) (cdr b))))
            :polite-ratio (if (> count 0) (/ (float polite) count) 0)
            :vocabulary (sort vocabulary (lambda (a b) (> (cdr a) (cdr b))))
            :expressions (tategaki-voice--frequent-expressions text)))))

(defun tategaki-voice-analyze (character)
  "Analyze saved, author-attributed samples for CHARACTER.
Samples keep their original wording after source edits; they are examples,
not assertions about the current manuscript."
  (let* ((samples (cl-remove-if-not (lambda (record) (equal character (plist-get record :character)))
                                   (tategaki-world--read-store "voice")))
         (text (mapconcat (lambda (record) (or (plist-get (plist-get record :source) :quote) "")) samples "\n")))
    (append (list :character character :sample-count (length samples)) (tategaki-voice--metrics text))))

(defun tategaki-voice-save-profile (profile)
  "Save the author's PROFILE constraints for a known character."
  (unless (member (plist-get profile :character) (tategaki-voice--characters)) (user-error "未登録の人物です"))
  (when (and (plist-get profile :max-length)
             (not (and (numberp (plist-get profile :max-length)) (> (plist-get profile :max-length) 0))))
    (user-error "文長は正の数で指定してください"))
  (unless (member (or (plist-get profile :politeness) "any") '("any" "polite" "plain"))
    (user-error "敬語設定を確認してください"))
  (dolist (key '(:first-person :second-person :endings :avoid-words))
    (when (plist-get profile key) (setq profile (plist-put profile key (vconcat (plist-get profile key))))))
  (tategaki-world--write-store
   "voice-profiles" (append (cl-remove (plist-get profile :character) (tategaki-world--read-store "voice-profiles")
                                         :key (lambda (item) (plist-get item :character)) :test #'equal) (list profile)))
  profile)

(defun tategaki-voice-configure ()
  "Set author-selected voice rules; empty word fields impose no restriction."
  (interactive)
  (let* ((character (tategaki-voice--choose-character))
         (old (cl-find character (tategaki-world--read-store "voice-profiles") :key (lambda (record) (plist-get record :character)) :test #'equal))
         (profile (list :character character)))
    (dolist (entry '((:first-person . "一人称") (:second-person . "二人称") (:endings . "語尾") (:avoid-words . "使わない語彙")))
      (setq profile (plist-put profile (car entry)
                               (vconcat (split-string
                                         (read-string (concat (cdr entry) "（カンマ区切り・空欄は制約なし）: ")
                                                      (mapconcat #'identity (plist-get old (car entry)) ","))
                                         "[,、]" t "[ 　]+")))))
    (setq profile (plist-put profile :max-length (read-number "文長目安（最大）: " (or (plist-get old :max-length) 120))))
    (setq profile (plist-put profile :politeness (completing-read "敬語: " '("any" "polite" "plain") nil t nil nil (or (plist-get old :politeness) "any"))))
    (tategaki-voice-save-profile profile)
    (tategaki-voice)))

(defun tategaki-voice--profile (character)
  "Return explicit rules, or conservative sample-derived hints for CHARACTER."
  (or (cl-find character (tategaki-world--read-store "voice-profiles")
               :key (lambda (record) (plist-get record :character)) :test #'equal)
      (let* ((metrics (tategaki-voice-analyze character))
             (first (car (plist-get metrics :first-person)))
             (endings (car (plist-get metrics :endings)))
             (fact (cl-find-if (lambda (record) (and (equal character (plist-get record :subject))
                                                    (equal "first-person" (plist-get record :attribute))))
                               (tategaki-world-query "Fact"))))
        (list :character character
              :first-person (cond (fact (vector (plist-get fact :value)))
                                  ((and first (>= (cdr first) 2)) (vector (car first))))
              :endings (when (and endings (>= (cdr endings) 3)
                                  (> (/ (float (cdr endings)) (max 1 (plist-get metrics :sentences))) 0.8))
                         (vector (car endings)))
              :max-length (when (>= (plist-get metrics :sample-count) 3) (* 2.5 (plist-get metrics :mean-length)))
              :politeness "any"))))

(defun tategaki-voice--compare (character reference &optional profile)
  "Return voice suggestions for CHARACTER's currently sourced REFERENCE."
  (let* ((profile (or profile (tategaki-voice--profile character)))
         (text (plist-get reference :quote))
         (metrics (tategaki-voice--metrics text)) results)
    (cl-labels ((report (code message)
                  (push (list :id (format "voice:%s:%s:%s" character (plist-get reference :start) code)
                              :source 'voice :severity 'info :start (plist-get reference :start)
                              :end (plist-get reference :end) :code code :message (concat character ": " message)) results)))
      (dolist (key '(:first-person :second-person))
        (let ((allowed (append (plist-get profile key) nil)))
          (when allowed
            (dolist (used (plist-get metrics key))
              (unless (member (car used) allowed)
                (report (if (eq key :first-person) "voice-first-person" "voice-second-person")
                        (format "%s が人物設定 (%s) と異なります" (car used) (string-join allowed ", "))))))))
      (let ((allowed (append (plist-get profile :endings) nil)))
        (when (and allowed (plist-get metrics :endings)
                   (cl-some (lambda (ending) (not (member (car ending) allowed))) (plist-get metrics :endings)))
          (report "voice-ending" "語尾が登録された傾向と異なります")))
      (when (and (plist-get profile :max-length) (> (plist-get metrics :mean-length) (plist-get profile :max-length)))
        (report "voice-length" "台詞の平均文長が人物の目安より長めです"))
      (when (or (and (equal (plist-get profile :politeness) "polite") (< (plist-get metrics :polite-ratio) 0.5))
                (and (equal (plist-get profile :politeness) "plain") (> (plist-get metrics :polite-ratio) 0.5)))
        (report "voice-politeness" "敬語の使い方が登録設定と異なります"))
      (dolist (word (append (plist-get profile :avoid-words) nil))
        (when (and (not (string-empty-p word)) (string-match-p (regexp-quote word) text))
          (report "voice-vocabulary" (format "使わない語彙に指定されています: %s" word)))))
    (nreverse results)))

(defun tategaki-voice--current-dialogues ()
  "Collect author-attributed current samples and explicitly name-prefixed quotes.
Unlabelled dialogue is never assigned a speaker by guesswork."
  (let ((tategaki-world--current-hash (tategaki-world--hash))
        (characters (tategaki-voice--characters))
        (seen (make-hash-table :test #'equal)) records)
    (dolist (record (tategaki-world--read-store "voice"))
      (when (and (member (plist-get record :character) characters)
                 (tategaki-world-source-current-p (plist-get record :source)))
        (push record records)
        (puthash (list (plist-get record :character) (plist-get (plist-get record :source) :start)) t seen)))
    (when characters
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (let ((regexp (concat "^ *\\(" (regexp-opt characters) "\\)[ 　\t]*[:：]?[ 　\t]*\\(「[^」\n]*」\\)")))
            (while (re-search-forward regexp nil t)
              (let* ((character (match-string-no-properties 1)) (start (match-beginning 2)) (end (match-end 2)))
                (unless (gethash (list character start) seen)
                  (push (list :character character :source (tategaki-world-source-reference start end)) records))))))))
    records))

(defun tategaki-voice--speaker-evidence (before after quote characters profiles)
  "Return unconfirmed speaker hints for QUOTE from BEFORE/AFTER and PROFILES.
CHARACTERS contains only accepted names.  Scores rank evidence; they are not
probabilities and do not establish who actually spoke."
  (let ((verbs (regexp-opt tategaki-voice--speech-verbs)) results)
    (dolist (character characters)
      (let ((names (list character)) (score 0) reasons)
        ;; Aliases are usable only after the world panel has accepted them.
        (when (fboundp 'tategaki-world-aliases)
          (dolist (alias (tategaki-world-aliases))
            (when (equal character (plist-get alias :subject))
              (push (plist-get alias :value) names))))
        (dolist (name (delete-dups names))
          (let ((escaped (regexp-quote name)))
            (when (string-match-p
                   (concat "\\(?:\\`\\|[。！？!?\n]\\)[ 　]*" escaped
                           "[はが][^。！？!?\n「」]\\{0,20\\}" verbs "[。:： 　]*\\'") before)
              (cl-incf score 4) (push (concat "直前の発話描写: " name) reasons))
            (when (string-match-p
                   (concat "\\`[ 　]*\\(?:と\\|って\\)[ 　]*" escaped
                           "[はが][^。！？!?\n「」]\\{0,20\\}" verbs) after)
              (cl-incf score 4) (push (concat "直後の発話描写: " name) reasons))))
        (let ((metrics (cdr (assoc character profiles))))
          (dolist (expression (plist-get metrics :expressions))
            (when (and (string-match-p (regexp-quote (car expression)) quote)
                       (not (cl-some
                             (lambda (other)
                               (and (not (equal character (car other)))
                                    (assoc (car expression) (plist-get (cdr other) :expressions)))) profiles)))
              (cl-incf score 2) (push (concat "見本の反復表現: " (car expression)) reasons)))
          (dolist (pronoun (plist-get metrics :first-person))
            (when (and (>= (cdr pronoun) 2)
                       (string-match-p (regexp-quote (car pronoun)) quote)
                       (not (cl-some
                             (lambda (other)
                               (and (not (equal character (car other)))
                                    (assoc (car pronoun) (plist-get (cdr other) :first-person)))) profiles)))
              (cl-incf score) (push (concat "見本の一人称: " (car pronoun)) reasons))))
        (when (> score 0)
          (push (list :character character :score score :reasons (nreverse reasons)) results))))
    (sort results (lambda (a b) (> (plist-get a :score) (plist-get b :score))))))

(defun tategaki-voice-speaker-candidates ()
  "Return hash-guarded, unconfirmed candidates for ordinary quoted dialogue.
No candidate is persisted, registered as a sample, or used by voice checks.
An empty candidate list explicitly represents unknown attribution."
  (with-current-buffer (tategaki-world--source)
    (save-excursion
      (save-restriction
        (widen)
        (let* ((tategaki-world--current-hash (tategaki-world--hash))
               (characters (tategaki-voice--characters))
               (profiles (mapcar (lambda (name) (cons name (tategaki-voice-analyze name))) characters))
               (attributed (tategaki-voice--current-dialogues)) records)
          (goto-char (point-min))
          (while (re-search-forward "「[^「」]*」" nil t)
            (let* ((start (match-beginning 0)) (end (match-end 0))
                   (reference (tategaki-world-source-reference start end)))
              (unless (cl-some
                       (lambda (record)
                         (let ((source (plist-get record :source)))
                           (and (< (plist-get source :start) end) (> (plist-get source :end) start)))) attributed)
                (push (list :state "inferred" :source reference
                            :candidates
                            (tategaki-voice--speaker-evidence
                             (buffer-substring-no-properties (max (point-min) (- start 120)) start)
                             (buffer-substring-no-properties end (min (point-max) (+ end 120)))
                             (plist-get reference :quote) characters profiles)) records))))
          (nreverse records))))))

(defun tategaki-voice-adopt-speaker (candidate character)
  "Adopt CHARACTER for CANDIDATE only on the author's explicit action."
  (with-current-buffer (tategaki-world--source)
    (let ((reference (plist-get candidate :source)))
      (unless (and (equal "inferred" (plist-get candidate :state))
                   (cl-find character (plist-get candidate :candidates)
                            :key (lambda (item) (plist-get item :character)) :test #'equal))
        (user-error "この台詞の候補にない人物です"))
      (unless (tategaki-world-source-current-p reference)
        (user-error "原稿が変わりました。話者候補を更新してください"))
      (tategaki-voice-register character (plist-get reference :start) (plist-get reference :end)))))

(defun tategaki-voice--insert-speaker-candidates (candidates)
  "Render source links and explicit adoption buttons for CANDIDATES."
  (insert "話者候補（未採用）\n発話描写・登録見本との文字列一致による候補です。根拠を読み、作者が採用してください。\n")
  (dolist (candidate candidates)
    (let ((reference (plist-get candidate :source)))
      (insert (format "\n%s\n" (truncate-string-to-width (plist-get reference :quote) 80 nil nil "…")))
      (tategaki-world-insert-reference reference "原稿を見る")
      (insert "\n")
      (dolist (hint (plist-get candidate :candidates))
        (let ((character (plist-get hint :character)))
          (insert (format "  候補 %s — %s  " character (string-join (plist-get hint :reasons) " / ")))
          (tategaki-world--button
           (concat character "として採用")
           (lambda () (tategaki-voice-adopt-speaker candidate character) (tategaki-voice)))
          (insert "\n")))
      (unless (plist-get candidate :candidates)
        (insert "  不明（根拠不足）。原稿の台詞を選択し、人物を指定して登録できます。\n"))))
  (unless candidates (insert "未登録の「台詞」はありません。\n")))

(defun tategaki-voice-check (&optional character start end)
  "Check attributed current dialogue or CHARACTER's source START..END selection."
  (interactive)
  (with-current-buffer (tategaki-world--source)
    (let ((dialogues (if character
                         (progn
                           (unless (member character (tategaki-voice--characters)) (user-error "未登録の人物です"))
                           (list (list :character character :source (tategaki-world-source-reference start end))))
                       (tategaki-voice--current-dialogues)))
          (profiles (make-hash-table :test #'equal)) results)
      (dolist (record dialogues)
        (let* ((name (plist-get record :character))
               (profile (or (gethash name profiles) (puthash name (tategaki-voice--profile name) profiles))))
          (dolist (item (tategaki-voice--compare name (plist-get record :source) profile))
            (push item results))))
      (setq results (nreverse results))
      (tategaki-diagnostics-set 'voice results (current-buffer))
      (when (called-interactively-p 'interactive) (message "人物の話し方: %d 件" (length results)))
      results)))

(defun tategaki-voice-check-region ()
  "Check selected dialogue against an explicitly chosen known character."
  (interactive)
  (let ((character (tategaki-voice--choose-character))
        (region (tategaki-world-selection)))
    (with-current-buffer (tategaki-world--source)
      (unless region (user-error "原稿で台詞を選択してください"))
      (tategaki-voice-check character (car region) (cdr region)))
    (tategaki-diagnostics-list 'voice)))

(defun tategaki-voice--format-counts (counts)
  "Format descriptive COUNTS for a character card."
  (mapconcat (lambda (pair) (format "%s(%d)" (car pair) (cdr pair))) (cl-subseq counts 0 (min 12 (length counts))) "、"))

;;;###autoload
(defun tategaki-voice ()
  "Show character speech analysis and author-controlled dialogue review."
  (interactive)
  (let ((characters (tategaki-voice--characters))
        (candidates (tategaki-voice-speaker-candidates)))
    (tategaki-world-panel
     "人物の話し方"
     (lambda ()
       (tategaki-world--button "選択台詞を見本に登録" #'tategaki-voice-register-region)
       (tategaki-world--button "話し方を設定" #'tategaki-voice-configure)
       (tategaki-world--button "選択台詞を検査" #'tategaki-voice-check-region)
       (tategaki-world--button "原稿を検査" (lambda () (tategaki-voice-check) (tategaki-diagnostics-list 'voice)))
       (tategaki-world--button "候補を更新" #'tategaki-voice)
       (insert "\n\n話者は作者が指定します。名前「台詞」の行は明示された話者で検査します。\n見本は登録時の文面を保持します。頻出表現は複数の句に現れる3〜12文字です。\n指摘は変更の提案です。\n\n")
       (dolist (character characters)
         (let ((metrics (tategaki-voice-analyze character)))
           (insert (format "%s — 見本 %d 件 / 平均文長 %.1f字 / 敬語 %.0f%%\n"
                           character (plist-get metrics :sample-count) (plist-get metrics :mean-length)
                           (* 100 (plist-get metrics :polite-ratio))))
           (dolist (field '((:first-person . "一人称") (:second-person . "二人称") (:endings . "語尾")
                            (:vocabulary . "語彙") (:expressions . "頻出表現")))
             (insert (format "  %s: %s\n" (cdr field) (tategaki-voice--format-counts (plist-get metrics (car field))))))
           (insert "\n")))
       (unless characters (insert "作品世界に人物を登録してから、台詞の見本や話し方を設定してください。\n"))
       (tategaki-voice--insert-speaker-candidates candidates)))))

(provide 'tategaki-voice)
;;; tategaki-voice.el ends here
