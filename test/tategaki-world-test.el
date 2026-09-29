;;; tategaki-world-test.el --- World, chronology and voice integrity -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'cl-lib)
(require 'tategaki-world)
(require 'tategaki-timeline)
(require 'tategaki-foreshadow)
(require 'tategaki-voice)

(defmacro tategaki-world-test--with-source (&rest body)
  "Run BODY in a disposable manuscript with session-local stores."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (insert "第1章\n花子「私は元気です。」\n\n第2章\n太郎「俺は知らない。」\n")
     (goto-char 6)
     ,@body))

(defun tategaki-world-test--fact (attribute value &optional state context)
  "Create a sourced test fact with ATTRIBUTE VALUE STATE CONTEXT."
  (tategaki-world-upsert (list :type "Fact" :name (concat attribute value) :subject "花子"
                               :attribute attribute :value value :state (or state "author-confirmed")
                               :context (or context "day1") :known-by ["花子" "reader"])))

(ert-deftest tategaki-world-state-separation-and-source-invalidation ()
  (tategaki-world-test--with-source
    (tategaki-world-test--fact "age" "30" "observed")
    (tategaki-world-test--fact "age" "31" "inferred")
    (tategaki-world-test--fact "age" "32" "rejected")
    (tategaki-world-test--fact "color" "赤" "author-confirmed")
    (should (= 4 (length (tategaki-world-records))))
    (should (= 2 (length (tategaki-world-query))))
    (goto-char (point-max)) (insert "変更")
    (should (= 1 (length (tategaki-world-query))))
    (should-not (tategaki-world-query nil (point-max)))))

(ert-deftest tategaki-world-cutoff-and-explicit-character-knowledge ()
  (tategaki-world-test--with-source
    (goto-char 6) (tategaki-world-test--fact "knowledge:key" "知る")
    (goto-char 25) (tategaki-world-test--fact "knowledge:door" "知る")
    (should (= 1 (length (tategaki-world-query "Fact" 20 "花子"))))
    (should (= 1 (length (tategaki-world-query "Fact" 20 "reader"))))
    (should-not (tategaki-world-query "Fact" 20 "太郎"))
    (should-not (string-match-p "door" (tategaki-world-context 20 "花子")))))

(ert-deftest tategaki-world-canonical-attributes-check-all-comparable-categories ()
  (dolist (pair '(("年齢" . "age") ("日時" . "date") ("場所" . "location") ("左右" . "side")
                  ("色" . "color") ("所有物" . "possession") ("人間関係:太郎" . "relationship:太郎")
                  ("呼称:太郎" . "alias:太郎") ("生死" . "alive") ("知識:鍵" . "knowledge:鍵")))
    (tategaki-world-test--with-source
      (tategaki-world-test--fact (car pair) "a")
      (forward-char 2)
      (tategaki-world-test--fact (cdr pair) "b")
      (should (= 1 (length (tategaki-world-check)))))))

(ert-deftest tategaki-world-equivalent-values-different-context-and-inference-are-not-conflicts ()
  (tategaki-world-test--with-source
    (tategaki-world-test--fact "年齢" "３０歳")
    (tategaki-world-test--fact "age" "30")
    (tategaki-world-test--fact "age" "31" nil "next-year")
    (tategaki-world-test--fact "age" "32" "inferred")
    (should-not (tategaki-world-check))))

(ert-deftest tategaki-world-calendar-weekday-comparison ()
  (tategaki-world-test--with-source
    (tategaki-world-test--fact "日時" "2026-09-29")
    (tategaki-world-test--fact "曜日" "水曜日")
    (should (equal "weekday-mismatch" (plist-get (car (tategaki-world-check)) :code)))))

(ert-deftest tategaki-world-preserves-source-undo-and-modified-state ()
  (tategaki-world-test--with-source
    (buffer-enable-undo)
    (set-buffer-modified-p nil)
    (let ((text (buffer-string)) (undo buffer-undo-list))
      (tategaki-world-test--fact "age" "30")
      (tategaki-world-test--fact "age" "31")
      (tategaki-world-check)
      (should (equal text (buffer-string)))
      (should (equal undo buffer-undo-list))
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-world-project-json-roundtrip-and-corruption-preservation ()
  (let ((directory (make-temp-file "tategaki-world-test-" t)))
    (unwind-protect
        (tategaki-world-test--with-source
          (setq buffer-file-name (expand-file-name "novel.txt" directory))
          (let* ((record (tategaki-world-test--fact "age" "30"))
                 (file (expand-file-name ".tategaki/world.json" directory)))
            (should (file-exists-p file))
            (should (equal (plist-get record :name) (plist-get (car (tategaki-world-records)) :name)))
            (should (equal '("花子" "reader") (plist-get (car (tategaki-world-records)) :known-by)))
            (with-temp-file file (insert "broken-json"))
            (should-error (tategaki-world-test--fact "age" "31") :type 'user-error)
            (should (equal "broken-json" (with-temp-buffer (insert-file-contents file) (buffer-string))))))
      (delete-directory directory t))))

(ert-deftest tategaki-world-ai-candidates-cannot-self-confirm-or-smuggle-knowledge ()
  (tategaki-world-test--with-source
    (let* ((source (current-buffer)) (hash (tategaki-world--hash))
           (request (list 'request)) (tategaki-world--request request))
      (tategaki-world--extract-result
       '(:ok t :text "[{\"type\":\"Character\",\"name\":\"花子\",\"state\":\"author-confirmed\",\"evidence\":\"花子\",\"known-by\":[\"太郎\"]}]")
       source hash request 1 (point-max))
      (should (= 1 (length (tategaki-world-records))))
      (should (equal "inferred" (plist-get (car (tategaki-world-records)) :state)))
      (should-not (tategaki-world-query))
      (should-not (plist-get (car (tategaki-world-records)) :known-by)))))

(ert-deftest tategaki-world-ai-result-drops-changed-source-and-obsolete-request ()
  (tategaki-world-test--with-source
    (let ((source (current-buffer)) (hash (tategaki-world--hash))
          (request (list 'request)))
      (setq tategaki-world--request request)
      (insert "変更")
      (tategaki-world--extract-result '(:ok t :text "[]") source hash request 1 (point-max))
      (should-not (tategaki-world-records))
      (setq tategaki-world--request (list 'new))
      (tategaki-world--extract-result '(:ok t :text "bad") source (tategaki-world--hash) request 1 (point-max))
      (should tategaki-world--request))))

(ert-deftest tategaki-world-occurrences-and-citations-use-source-chapters ()
  (tategaki-world-test--with-source
    (let* ((references (tategaki-world-occurrences "花子")) (reference (car references)))
      (should (= 1 (length references)))
      (should (equal "第1章" (plist-get reference :chapter)))
      (should (tategaki-world-source-current-p reference))
      (insert "変更")
      (should-not (tategaki-world-source-current-p reference)))))

(ert-deftest tategaki-timeline-validated-dates-and-relative-time ()
  (tategaki-world-test--with-source
    (let* ((anchor (tategaki-timeline-upsert '(:label "朝" :time-status "exact" :story-time "2026-04-10 08:00")))
           (relative (tategaki-timeline-upsert (list :label "翌朝" :time-status "relative" :anchor (plist-get anchor :id) :offset-minutes 1440))))
      (should (equal "2026-04-11 08:00" (format-time-string "%Y-%m-%d %H:%M" (tategaki-timeline-resolve relative) t)))
      (should-error (tategaki-timeline-upsert '(:label "不正" :time-status "exact" :story-time "2026-02-30")) :type 'user-error))))

(ert-deftest tategaki-timeline-cycles-and-cutoff-do-not-resolve-future-anchors ()
  (tategaki-world-test--with-source
    (let* ((a '(:id "a" :label "a" :time-status "relative" :anchor "b" :offset-minutes 1))
           (b '(:id "b" :label "b" :time-status "relative" :anchor "a" :offset-minutes 1)))
      (should-not (tategaki-timeline-resolve a (list a b))))
    (goto-char 6)
    (tategaki-timeline-upsert '(:id "early" :label "早い記述" :time-status "relative" :anchor "late" :offset-minutes -10))
    (goto-char 25)
    (tategaki-timeline-upsert '(:id "late" :label "後の記述" :time-status "exact" :story-time "2026-04-10"))
    (should (string-match-p "不明" (tategaki-timeline-context 20)))
    (should-not (string-match-p "2026" (tategaki-timeline-context 20)))))

(ert-deftest tategaki-timeline-inferred-and-unknown-remain-labelled ()
  (tategaki-world-test--with-source
    (tategaki-timeline-upsert '(:label "推定" :time-status "inferred" :story-time "2026-04-10"))
    (tategaki-timeline-upsert '(:label "不明" :time-status "unknown"))
    (should (string-match-p "inferred" (tategaki-timeline-context)))
    (should (string-match-p "unknown" (tategaki-timeline-context)))))

(ert-deftest tategaki-foreshadow-author-adoption-and-resolution-lifecycle ()
  (tategaki-world-test--with-source
    (let* ((candidate (tategaki-foreshadow-propose "赤い傘")) (id (plist-get candidate :id)))
      (should (equal "candidate" (plist-get candidate :status)))
      (tategaki-foreshadow-set-status id "open")
      (goto-char 25)
      (tategaki-foreshadow-resolve id)
      (let ((resolved (car (tategaki-foreshadow-records))))
        (should (equal "resolved" (plist-get resolved :status)))
        (should (= 25 (plist-get (plist-get resolved :payoff) :start))))
      (tategaki-foreshadow-set-status id "open")
      (should-not (plist-get (car (tategaki-foreshadow-records)) :payoff)))))

(ert-deftest tategaki-voice-requires-known-speaker-and-analyzes-author-samples ()
  (tategaki-world-test--with-source
    (should-error (tategaki-voice-register "花子" 8 16) :type 'user-error)
    (tategaki-world-upsert '(:type "Character" :name "花子" :state "author-confirmed"))
    (tategaki-voice-register "花子" 8 16)
    (let ((metrics (tategaki-voice-analyze "花子")))
      (should (= 1 (plist-get metrics :sample-count)))
      (should (assoc "私" (plist-get metrics :first-person)))
      (should (> (plist-get metrics :mean-length) 0)))))

(ert-deftest tategaki-voice-explicit-rules-and-unlabelled-dialogue-safety ()
  (with-temp-buffer
    (insert "花子「俺は行く。ごめん。」\n「俺は行く。」\n")
    (goto-char 1)
    (tategaki-world-upsert '(:type "Character" :name "花子" :state "author-confirmed"))
    (tategaki-voice-save-profile '(:character "花子" :first-person ["私"] :politeness "polite" :avoid-words ["ごめん"] :max-length 3))
    (let* ((results (tategaki-voice-check)) (codes (mapcar (lambda (item) (plist-get item :code)) results)))
      (should (member "voice-first-person" codes))
      (should (member "voice-politeness" codes))
      (should (member "voice-vocabulary" codes))
      (should (member "voice-length" codes))
      (should (cl-every (lambda (item) (= 3 (plist-get item :start))) results)))))

(ert-deftest tategaki-world-tools-panels-work-with-ai-disabled ()
  (save-window-excursion
    (let ((source (generate-new-buffer " *world-ui-test*")) outputs)
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (insert "花子の話。")
            (goto-char 1)
            (tategaki-world-upsert '(:type "Character" :name "花子" :state "author-confirmed"))
            (let ((tategaki-ai-enabled nil))
              (dolist (command '(tategaki-world tategaki-timeline tategaki-foreshadow tategaki-voice))
                (with-current-buffer source (push (funcall command) outputs))
                (with-current-buffer (car outputs)
                  (should (eq tategaki-studio-source source))
                  (should (derived-mode-p 'special-mode))))))
        (dolist (buffer outputs) (when (buffer-live-p buffer) (kill-buffer buffer)))
        (when (buffer-live-p source) (kill-buffer source))))))

(ert-deftest tategaki-world-panel-selection-is-retained-only-for-unchanged-source ()
  (save-window-excursion
    (let ((source (generate-new-buffer " *world-selection-test*")) output)
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (insert "台詞の本文")
            (goto-char 2)
            (push-mark 5 t t)
            (let ((transient-mark-mode t))
              (setq output (tategaki-world-panel "選択テスト" (lambda () (insert "test")))))
            (with-current-buffer source (setq mark-active nil))
            (with-current-buffer output (should (equal '(2 . 5) (tategaki-world-selection))))
            (with-current-buffer source (goto-char (point-max)) (insert "変更"))
            (with-current-buffer output (should-not (tategaki-world-selection))))
        (when (buffer-live-p output) (kill-buffer output))
        (when (buffer-live-p source) (kill-buffer source))))))

(provide 'tategaki-world-test)
