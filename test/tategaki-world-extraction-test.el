;;; tategaki-world-extraction-test.el --- Evidence-backed extraction -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'cl-lib)
(require 'tategaki-world)
(require 'tategaki-timeline)
(require 'tategaki-foreshadow)

(defmacro tategaki-extraction-test--source (text &rest body)
  "Run BODY in an unchanged disposable TEXT manuscript."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (goto-char 2)
     (buffer-enable-undo)
     (set-buffer-modified-p nil)
     (let ((tategaki-ai-enabled t)
           (tategaki-ai-model "fixture")
           (tategaki-world-extract-chunk-size 50))
       ,@body)))

(defun tategaki-extraction-test--json (items)
  "Encode model candidate ITEMS."
  (decode-coding-string (json-serialize (vconcat items)) 'utf-8))

(defun tategaki-extraction-test--next (job)
  "Run JOB's scheduled next step deterministically."
  (when (timerp (plist-get job :timer)) (cancel-timer (plist-get job :timer)))
  (tategaki-world--extraction-next (current-buffer) job))

(ert-deftest tategaki-extraction-whole-source-stages-atomic-grounded-candidates ()
  (tategaki-extraction-test--source "花子が鍵を見た。\n\n太郎は城にいる。\n"
    (let* ((confirmed (tategaki-world-upsert '(:type "Character" :name "花子" :state "author-confirmed")))
           (text (buffer-string)) (undo buffer-undo-list) (position (point)) pending requests completed)
      (cl-letf (((symbol-function 'tategaki-ai-authorize) #'ignore)
                ((symbol-function 'tategaki-ai-chat)
                 (lambda (messages callback &optional _authorized)
                   (push messages requests) (setq pending callback) nil)))
        (narrow-to-region 2 5)
        (let ((job (tategaki-world-extract t (lambda (result) (setq completed result)))))
          (should (= 2 (plist-get job :total)))
          (funcall pending (list :ok t :text (tategaki-extraction-test--json
                              (list (list :id (plist-get confirmed :id) :type "Fact" :name "鍵を知る"
                                          :subject "花子" :attribute "knowledge:鍵" :value "鍵を見た"
                                          :known-by ["花子"] :acquisition "seen" :state "author-confirmed"
                                          :evidence "花子が鍵を見た。")))))
          (should (= 1 (length (tategaki-world-records))))
          (tategaki-extraction-test--next job)
          (funcall pending '(:ok t :text "[{\"type\":\"Character\",\"name\":\"太郎\",\"evidence\":\"太郎\"},{\"type\":\"Character\",\"name\":\"捏造\",\"evidence\":\"本文にない\"}]"))
          (tategaki-extraction-test--next job)
          (should (plist-get completed :ok))
          (should (= 2 (plist-get completed :count)))
          (should (= 1 (length (tategaki-world-query))))
          (let ((fact (car (tategaki-world-records "Fact"))))
            (should (equal "inferred" (plist-get fact :state)))
            (should-not (equal (plist-get fact :id) (plist-get confirmed :id)))
            (should (equal ["花子"] (plist-get fact :known-by)))
            (tategaki-world-set-state (plist-get fact :id) "author-confirmed")
            (should (= 1 (length (tategaki-world-knowledge "花子" 10))))
            (should-not (tategaki-world-knowledge "太郎")))
          (should (= 2 (length requests)))
          (should (= 2 (point-min))) (should (= 5 (point-max)))
          (should (= position (point)))
          (widen)
          (should (equal text (buffer-string)))
          (should (equal undo buffer-undo-list))
          (should-not (buffer-modified-p)))))))

(ert-deftest tategaki-extraction-cancel-discards-staged-and-late-callback ()
  (tategaki-extraction-test--source "花子。\n\n太郎。\n"
    (let (pending completed)
      (cl-letf (((symbol-function 'tategaki-ai-authorize) #'ignore)
                ((symbol-function 'tategaki-ai-chat) (lambda (_messages callback &optional _authorized) (setq pending callback))))
        (let ((job (tategaki-world-extract t (lambda (result) (setq completed result)))))
          (funcall pending '(:ok t :text "[{\"type\":\"Character\",\"name\":\"花子\",\"evidence\":\"花子\"}]"))
          (should (= 1 (length (plist-get job :candidates))))
          (tategaki-extraction-test--next job)
          (tategaki-world-cancel-extraction)
          (funcall pending '(:ok t :text "[]"))
          (should (plist-get completed :cancelled))
          (should-not tategaki-world--job)
          (should-not (tategaki-world-records)))))))

(ert-deftest tategaki-extraction-invalidates-on-source-provider-and-failure ()
  (dolist (change '(source provider failure))
    (tategaki-extraction-test--source "花子。\n\n太郎。\n"
      (let (pending completed)
        (cl-letf (((symbol-function 'tategaki-ai-authorize) #'ignore)
                  ((symbol-function 'tategaki-ai-chat) (lambda (_messages callback &optional _authorized) (setq pending callback))))
          (let ((job (tategaki-world-extract t (lambda (result) (setq completed result)))))
            (funcall pending '(:ok t :text "[{\"type\":\"Character\",\"name\":\"花子\",\"evidence\":\"花子\"}]"))
            (tategaki-extraction-test--next job)
            (pcase change ('source (insert "変更")) ('provider (setq tategaki-ai-model "new")))
            (funcall pending (if (eq change 'failure) '(:ok nil :message "Fixture failure") '(:ok t :text "[]")))
            (should-not (plist-get completed :ok))
            (should-not tategaki-world--job)
            (should-not (tategaki-world-records))))))))

(ert-deftest tategaki-extraction-source-quote-and-scene-range-permission ()
  (tategaki-extraction-test--source "花子は鍵を見た。秘密を悟る。\n\n太郎の内面。\n"
    (let* ((chunk (car (tategaki-semantic-chunks)))
           (items (tategaki-world--ground-items
                   "[{\"type\":\"Scene\",\"name\":\"花子視点\",\"pov\":\"花子\",\"characters\":[\"花子\",\"太郎\"],\"visibility\":[\"花子\"],\"evidence\":\"鍵を見た\",\"range_quote\":\"花子は鍵を見た。秘密を悟る。\"}]" chunk)))
      (tategaki-world--import-candidates items)
      (let* ((record (car (tategaki-world-records "Scene")))
             (source (plist-get record :source)))
        (should-not (tategaki-world-scenes))
        (should-not (tategaki-world-scene-range record))
        (tategaki-world-set-state (plist-get record :id) "author-confirmed")
        (setq record (car (tategaki-world-scenes)))
        (should (equal '(1 . 9) (tategaki-world-scene-range record 9)))
        (should-not (tategaki-world-scene-range record 7))
        (should-not (tategaki-world-query "Scene" nil "太郎"))
        (should (tategaki-world-reference-valid-p source))
        (should-not (tategaki-world-reference-valid-p (plist-put (copy-tree source) :quote "嘘")))
        (should-not (tategaki-world-scene-range (plist-put (copy-tree record) :range-end 24)))
        (insert "変更")
        (should-not (tategaki-world-scenes))
        (should-not (tategaki-world-scene-range record))))))

(ert-deftest tategaki-extraction-scene-default-scope-is-exact-evidence ()
  (tategaki-extraction-test--source "花子は知る。太郎の秘密。\n\n別場面。\n"
    (let* ((chunk (car (tategaki-semantic-chunks)))
           (items (tategaki-world--ground-items
                   "[{\"type\":\"Scene\",\"name\":\"場面\",\"evidence\":\"花子は知る。\",\"range_quote\":\"花子は知る。太郎の秘密。\\n\\n別場面。\"}]" chunk)))
      (should (equal (plist-get (car items) :source) (plist-get (car items) :range-source)))
      (should (= 7 (plist-get (car items) :range-end))))))

(ert-deftest tategaki-world-alias-first-appearance-requires-author-adoption ()
  (tategaki-extraction-test--source "ハナが来た。\n\n花子が言う。\n"
    (let ((record (tategaki-world-upsert (list :type "Relationship" :name "花子別名" :attribute "alias"
                                               :subject "花子" :value "ハナ" :state "inferred"
                                               :source (tategaki-world-source-reference 1 3)))))
      (should (> (plist-get (tategaki-world-first-appearance "花子") :start) 1))
      (should-not (tategaki-world-aliases))
      (tategaki-world-set-state (plist-get record :id) "author-confirmed")
      (should (= 1 (plist-get (tategaki-world-first-appearance "花子") :start))))))

(ert-deftest tategaki-timeline-ai-relative-candidates-explicit-anchor-adoption ()
  (tategaki-extraction-test--source "2026年9月29日の出発。\n\n翌日に帰る。\n"
    (let* ((chunks (tategaki-semantic-chunks))
           (items (append (tategaki-world--ground-items
                           "[{\"label\":\"出発\",\"time-status\":\"exact\",\"story-time\":\"2026-09-29\",\"evidence\":\"2026年9月29日の出発。\"}]" (car chunks))
                          (tategaki-world--ground-items
                           "[{\"label\":\"帰宅\",\"time-status\":\"relative\",\"anchor-label\":\"出発\",\"offset-minutes\":1440,\"evidence\":\"翌日に帰る。\"}]" (cadr chunks)))))
      (should (= 2 (tategaki-timeline--import-candidates items)))
      (should (equal "" (tategaki-timeline-context)))
      (let* ((records (tategaki-timeline-records)) (departure (car records)) (arrival (cadr records)))
        (should (equal (plist-get departure :id) (plist-get arrival :anchor)))
        (should-error (tategaki-timeline-set-state (plist-get arrival :id) "author-confirmed") :type 'user-error)
        (tategaki-timeline-set-state (plist-get departure :id) "author-confirmed")
        (tategaki-timeline-set-state (plist-get arrival :id) "author-confirmed")
        (should (string-match-p "2026-09-30" (tategaki-timeline-context)))
        (should-not (string-match-p "帰宅" (tategaki-timeline-context 16)))
        (should-not (buffer-modified-p))))))

(ert-deftest tategaki-timeline-unknown-anchor-cannot-self-confirm ()
  (tategaki-extraction-test--source "翌朝、花子は帰った。\n"
    (let ((items (tategaki-world--ground-items
                  "[{\"label\":\"帰宅\",\"state\":\"author-confirmed\",\"time-status\":\"relative\",\"anchor-label\":\"不明な前日\",\"offset-minutes\":1440,\"evidence\":\"翌朝、花子は帰った。\"}]"
                  (car (tategaki-semantic-chunks)))))
      (tategaki-timeline--import-candidates items)
      (let ((record (car (tategaki-timeline-records))))
        (should (equal "inferred" (plist-get record :state)))
        (should-not (tategaki-timeline-resolve record))
        (should-error (tategaki-timeline-set-state (plist-get record :id) "author-confirmed") :type 'user-error)
        (tategaki-timeline-set-state (plist-get record :id) "rejected")
        (should (equal "rejected" (plist-get (car (tategaki-timeline-records)) :state)))))))

(ert-deftest tategaki-foreshadow-extraction-pairing-is-author-only ()
  (tategaki-extraction-test--source "箱の鍵はどこだ。\n\n花子が鍵を見つけた。\n"
    (let* ((text (buffer-string)) (undo buffer-undo-list)
           (chunks (tategaki-semantic-chunks))
           (items (append (tategaki-world--ground-items
                           "[{\"kind\":\"setup\",\"name\":\"消えた鍵\",\"evidence\":\"箱の鍵はどこだ。\"}]" (car chunks))
                          (tategaki-world--ground-items
                           "[{\"kind\":\"payoff\",\"name\":\"鍵の発見\",\"target-name\":\"消えた鍵\",\"status\":\"resolved\",\"evidence\":\"花子が鍵を見つけた。\"}]" (cadr chunks)))))
      (should (= 2 (tategaki-foreshadow--import-candidates items)))
      (let* ((records (tategaki-foreshadow-records)) (setup (car records)) (payoff (cadr records)))
        (should (cl-every (lambda (record) (equal (plist-get record :status) "candidate")) records))
        (should-error (tategaki-foreshadow-adopt (plist-get payoff :id) (plist-get setup :id)) :type 'user-error)
        (tategaki-foreshadow-adopt (plist-get setup :id))
        (should (equal "open" (plist-get (cl-find (plist-get setup :id) (tategaki-foreshadow-records)
                                                 :key (lambda (entry) (plist-get entry :id)) :test #'equal) :status)))
        (tategaki-foreshadow-adopt (plist-get payoff :id) (plist-get setup :id))
        (let ((resolved (cl-find (plist-get setup :id) (tategaki-foreshadow-records) :key (lambda (record) (plist-get record :id)) :test #'equal)))
          (should (equal "resolved" (plist-get resolved :status)))
          (should (equal (plist-get payoff :source) (plist-get resolved :payoff)))))
      (should (equal text (buffer-string)))
      (should (equal undo buffer-undo-list))
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-foreshadow-stale-payoff-cannot-apply ()
  (tategaki-extraction-test--source "鍵がない。\n\n鍵があった。\n"
    (let* ((setup (tategaki-foreshadow-upsert (list :name "鍵" :status "open" :source (tategaki-world-source-reference 1 6))))
           (payoff (tategaki-foreshadow-upsert (list :name "発見" :status "candidate" :candidate-kind "payoff"
                                                   :source (tategaki-world-source-reference 8 14)))))
      (insert "変更")
      (should-error (tategaki-foreshadow-adopt (plist-get payoff :id) (plist-get setup :id)) :type 'user-error)
      (should (equal "open" (plist-get (car (tategaki-foreshadow-records)) :status))))))

(ert-deftest tategaki-extraction-malformed-second-batch-is-atomic ()
  (tategaki-extraction-test--source "花子。\n\n太郎。\n"
    (let (pending completed)
      (cl-letf (((symbol-function 'tategaki-ai-authorize) #'ignore)
                ((symbol-function 'tategaki-ai-chat) (lambda (_messages callback &optional _authorized) (setq pending callback))))
        (let ((job (tategaki-world-extract t (lambda (result) (setq completed result)))))
          (funcall pending '(:ok t :text "[{\"type\":\"Character\",\"name\":\"花子\",\"evidence\":\"花子\"}]"))
          (tategaki-extraction-test--next job)
          (funcall pending '(:ok t :text "not JSON"))
          (should-not (plist-get completed :ok))
          (should-not (tategaki-world-records)))))))

(ert-deftest tategaki-foreshadow-full-extraction-uses-prior-setup-context ()
  (tategaki-extraction-test--source "箱の鍵はどこだ。\n\n鍵を見つけた。\n"
    (let (pending messages completed)
      (cl-letf (((symbol-function 'tategaki-ai-authorize) #'ignore)
                ((symbol-function 'tategaki-ai-chat)
                 (lambda (input callback &optional _authorized) (setq pending callback messages input))))
        (let ((job (tategaki-foreshadow-extract nil (lambda (result) (setq completed result)))))
          (should (string-match-p (regexp-quote "kind(setup/payoff)") (alist-get 'content (car messages))))
          (funcall pending '(:ok t :text "[{\"kind\":\"setup\",\"name\":\"鍵の謎\",\"evidence\":\"箱の鍵はどこだ。\"}]"))
          (tategaki-extraction-test--next job)
          (should (string-match-p "鍵の謎" (alist-get 'content (cadr messages))))
          (funcall pending '(:ok t :text "[{\"kind\":\"payoff\",\"name\":\"鍵の回収\",\"target-name\":\"鍵の謎\",\"evidence\":\"鍵を見つけた。\"}]"))
          (tategaki-extraction-test--next job)
          (should (= 2 (plist-get completed :count)))
          (let ((records (tategaki-foreshadow-records)))
            (should (equal (plist-get (car records) :id) (plist-get (cadr records) :target-id)))))))))

(ert-deftest tategaki-scene-range-cannot-cross-explicit-boundary ()
  (tategaki-extraction-test--source "花子の内面。\n***\n太郎の内面。\n"
    (let ((record (list :type "Scene" :state "author-confirmed" :name "場面"
                        :source (tategaki-world-source-reference 1 8)
                        :range-source (tategaki-world-source-reference 1 (point-max))
                        :range-start 1 :range-end (point-max))))
      (should-not (tategaki-world-scene-range record)))))

(ert-deftest tategaki-extraction-candidate-json-roundtrip-retains-evidence-and-deduplicates ()
  (let ((directory (make-temp-file "tategaki-extraction-project-" t)))
    (unwind-protect
        (tategaki-extraction-test--source "花子が鍵を見る。\n"
          (setq buffer-file-name (expand-file-name "novel.txt" directory))
          (let ((items (tategaki-world--ground-items
                        "[{\"type\":\"Fact\",\"name\":\"鍵を知る\",\"subject\":\"花子\",\"attribute\":\"knowledge:鍵\",\"value\":\"存在\",\"known-by\":[\"花子\"],\"evidence\":\"花子が鍵を見る。\"},{\"type\":\"Scene\",\"name\":\"花子視点\",\"pov\":\"花子\",\"visibility\":[\"花子\"],\"characters\":[\"花子\"],\"evidence\":\"花子が鍵を見る。\"}]"
                        (car (tategaki-semantic-chunks)))))
            (should (= 2 (tategaki-world--import-candidates items)))
            (should (= 0 (tategaki-world--import-candidates items)))
            (let ((scene (car (tategaki-world-records "Scene"))))
              (tategaki-world-set-state (plist-get scene :id) "author-confirmed")
              (should (equal '(1 . 9) (tategaki-world-scene-range (car (tategaki-world-scenes)))))
              (should (= 0 (tategaki-world--import-candidates items))))
            (should (= 2 (length (tategaki-world-records))))
            (should-not (buffer-modified-p))))
      (delete-directory directory t))))

(ert-deftest tategaki-extraction-real-model-key-variants-still-require-evidence ()
  (tategaki-extraction-test--source "花子は鍵の場所を聞いた。\n"
    (let ((items (tategaki-world--ground-items
                  "[{\"type\":\"Fact\",\"subject\":\"花子\",\"attribute\":\"knowledge:鍵\",\"value\":\"箱\",\"known_by\":[\"花子\"],\"evidence\":\"花子は鍵の場所を聞いた。\"},{\"type\":\"Fact\",\"subject\":\"花子\",\"attribute\":\"age\",\"value\":\"30\"}]"
                  (car (tategaki-semantic-chunks)))))
      (should (= 1 (tategaki-world--import-candidates items)))
      (let ((record (car (tategaki-world-records))))
        (should (equal ["花子"] (plist-get record :known-by)))
        (should (equal "花子 / knowledge:鍵" (plist-get record :name)))
        (should (equal "inferred" (plist-get record :state)))))))

(ert-deftest tategaki-timeline-real-model-nested-relative-keys ()
  (tategaki-extraction-test--source "2026年9月29日の出発。\n\n翌日に帰る。\n"
    (let* ((chunks (tategaki-semantic-chunks))
           (items (append (tategaki-world--ground-items
                           "[{\"label\":\"出発\",\"time_status\":\"exact\",\"story-time\":\"2026-09-29 08:00\",\"evidence\":\"2026年9月29日の出発。\"}]" (car chunks))
                          (tategaki-world--ground-items
                           "[{\"label\":\"帰宅\",\"time_status\":\"exact\",\"story-time\":{\"anchor_label\":\"出発\",\"offset_minutes\":1440,\"base_time\":\"2026-09-29 08:00\"},\"evidence\":\"翌日に帰る。\"}]" (cadr chunks)))))
      (should (= 2 (tategaki-timeline--import-candidates items)))
      (let* ((records (tategaki-timeline-records)) (relative (cadr records)))
        (should (equal "relative" (plist-get relative :time-status)))
        (should (equal "inferred" (plist-get relative :state)))
        (should (equal "2026-09-30 08:00" (format-time-string "%Y-%m-%d %H:%M" (tategaki-timeline-resolve relative records) t)))))))

(ert-deftest tategaki-foreshadow-real-model-missing-target-only-links-earlier-setup ()
  (tategaki-extraction-test--source "鍵がない。\n\n鍵を発見。\n"
    (let* ((chunks (tategaki-semantic-chunks))
           (items (append (tategaki-world--ground-items
                           "[{\"kind\":\"setup\",\"name\":\"鍵\",\"evidence\":\"鍵がない。\"}]" (car chunks))
                          (tategaki-world--ground-items
                           "[{\"kind\":\"setup\",\"name\":\"鍵\",\"evidence\":\"鍵を発見。\"},{\"kind\":\"payoff\",\"name\":\"鍵\",\"evidence\":\"鍵を発見。\"}]" (cadr chunks)))))
      (tategaki-foreshadow--import-candidates items)
      (let ((records (tategaki-foreshadow-records)))
        (should (equal (plist-get (car records) :id) (plist-get (nth 2 records) :target-id)))
        (should (cl-every (lambda (record) (equal "candidate" (plist-get record :status))) records))))))

(provide 'tategaki-world-extraction-test)
;;; tategaki-world-extraction-test.el ends here
