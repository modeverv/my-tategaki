;;; tategaki-ai-integration-test.el --- Async ownership and context regressions -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'tategaki-studio)
(require 'tategaki-assistant)
(require 'tategaki-review)
(require 'tategaki-world)
(require 'tategaki-timeline)

(defmacro tategaki-ai-integration--source (&rest body)
  "Run BODY in an isolated manuscript, cleaning its Assistant afterward."
  (declare (indent 0) (debug t))
  `(let ((source (generate-new-buffer " *AI integration manuscript*"))
         (directory (make-temp-file "tategaki-ai-integration-" t)))
     (unwind-protect
         (save-window-excursion
           (with-current-buffer source
             (text-mode)
             (setq default-directory (file-name-as-directory directory))
             (setq-local tategaki-ai-enabled t)
             (setq-local tategaki-ai-model "test-model")
             (setq-local tategaki-ai-endpoint "http://localhost:11434/v1")
             (insert "第1章\n母を待っていた。\n\n第2章\n鍵を見つけた。\n\n第3章\nその先の物語。")
             (goto-char 8)
             (switch-to-buffer source)
             ,@body))
       (when (buffer-live-p source)
         (with-current-buffer source
           (dolist (buffer (list tategaki-assistant--buffer tategaki-review--buffer))
             (when (buffer-live-p buffer) (kill-buffer buffer))))
         (kill-buffer source))
       (delete-directory directory t))))

(ert-deftest tategaki-ai-integration-busy-submit-keeps-typed-question ()
  (tategaki-ai-integration--source
    (tategaki-assistant)
    (setq tategaki-assistant--busy t)
    (goto-char (point-max))
    (insert "次に質問したい内容")
    (should-error (tategaki-assistant-submit) :type 'user-error)
    (should (equal (buffer-substring-no-properties tategaki-assistant--input (point-max))
                   "次に質問したい内容"))))

(ert-deftest tategaki-ai-integration-rag-respects-source-local-budget-after-yield ()
  (tategaki-ai-integration--source
    (setq-local tategaki-rag-context-limit 4)
    (let (pending result)
      (cl-letf (((symbol-function 'tategaki-semantic-retrieve)
                 (lambda (_query callback &rest _) (setq pending callback))))
        (tategaki-rag-context "母" (lambda (value) (setq result value))))
      ;; HTTP completions run in a transport buffer, not the manuscript.
      (with-temp-buffer
        (setq-local tategaki-rag-context-limit 1000)
        (funcall pending '(:ok t :method lexical :chunks nil)))
      (should result)
      (should (<= (length (cadr (split-string (plist-get result :text) "\n"))) 4)))))

(ert-deftest tategaki-ai-integration-heading-and-scene-boundaries-without-blank-lines ()
  (with-temp-buffer
    (insert "第1章\n前半です。\n***\n同じ章の別場面。\n第2章\n後半です。\n")
    (let* ((chunks (tategaki-semantic-chunks))
           (second-chapter (seq-find (lambda (chunk)
                                       (string-match-p "後半" (plist-get chunk :text))) chunks))
           (second-scene (seq-find (lambda (chunk)
                                     (string-match-p "別場面" (plist-get chunk :text))) chunks)))
      (should (equal (plist-get second-chapter :chapter) "第2章"))
      (should (= (plist-get second-scene :scene) 2)))))

(ert-deftest tategaki-ai-integration-cached-region-tracks-edits-or-refuses-stale-range ()
  (tategaki-ai-integration--source
    (let ((transient-mark-mode t) original panel received refused)
      (goto-char 5) (set-mark 13) (activate-mark)
      (setq original (buffer-substring-no-properties (region-beginning) (region-end)))
      (setq panel (tategaki-assistant))
      (with-current-buffer source
        (deactivate-mark)
        (goto-char 1) (insert "前書きを追記しました。\n"))
      (with-current-buffer panel
        (cl-letf (((symbol-function 'tategaki-ask)
                   (lambda (_question _cutoff region &rest _) (setq received region))))
          (condition-case nil (tategaki-ask-region "この範囲について")
            (user-error (setq refused t)))))
      (should (or refused
                  (and received
                       (with-current-buffer source
                         (equal original (buffer-substring-no-properties
                                          (car received) (cdr received))))))))))

(ert-deftest tategaki-ai-integration-cancel-during-retrieval-prevents-chat-dispatch ()
  (tategaki-ai-integration--source
    (let (pending calls panel)
      (cl-letf (((symbol-function 'tategaki-rag-context)
                 (lambda (_query callback &rest _) (setq pending callback)))
                ((symbol-function 'tategaki-ai-chat)
                 (lambda (&rest _) (cl-incf calls))))
        (setq calls 0)
        (tategaki-ask "母について")
        (setq panel (current-buffer))
        (tategaki-assistant-cancel)
        (with-temp-buffer
          (funcall pending '(:ok t :method lexical :chunks nil :text "本文")))
        (should (= calls 0))
        (with-current-buffer panel (should-not tategaki-assistant--busy))))))

(ert-deftest tategaki-ai-integration-late-cancelled-answer-cannot-overwrite-new-request ()
  (tategaki-ai-integration--source
    (let (callbacks panel)
      (cl-letf (((symbol-function 'tategaki-rag-context)
                 (lambda (_query callback &rest _)
                   (funcall callback '(:ok t :method lexical :chunks nil :text "本文"))))
                ((symbol-function 'tategaki-ai-chat)
                 (lambda (_messages callback &rest _) (push callback callbacks))))
        (tategaki-ask "一度目")
        (setq panel (current-buffer))
        (tategaki-assistant-cancel)
        (tategaki-ask "二度目")
        (with-temp-buffer
          (funcall (cadr callbacks) '(:ok t :text "OLD_CANCELLED_RESPONSE")))
        (with-current-buffer panel
          (should tategaki-assistant--busy)
          (should-not (string-match-p "OLD_CANCELLED_RESPONSE" (buffer-string))))
        (with-temp-buffer
          (funcall (car callbacks) '(:ok t :text "CURRENT_RESPONSE")))
        (with-current-buffer panel
          (should-not tategaki-assistant--busy)
          (should (string-match-p "CURRENT_RESPONSE" (buffer-string))))))))

(ert-deftest tategaki-ai-integration-provider-change-cancels-before-context-transmission ()
  (tategaki-ai-integration--source
    (let (pending panel (calls 0))
      (cl-letf (((symbol-function 'tategaki-rag-context)
                 (lambda (_query callback &rest _) (setq pending callback)))
                ((symbol-function 'tategaki-ai-chat)
                 (lambda (&rest _) (cl-incf calls))))
        (tategaki-ask "母について")
        (setq panel (current-buffer))
        (with-current-buffer source
          (setq-local tategaki-ai-endpoint "https://new.example.invalid/v1"))
        (with-temp-buffer
          (funcall pending '(:ok t :method lexical :chunks nil :text "本文")))
        (should (= calls 0))
        (with-current-buffer panel
          (should-not tategaki-assistant--busy)
          (should (string-match-p "設定が変更" (buffer-string))))))))

(ert-deftest tategaki-ai-integration-transport-cancel-closes-process-and-delivers-once ()
  (let* ((response (generate-new-buffer " *AI cancellable transport*"))
         (process (make-pipe-process :name "tategaki-ai-cancel-test"
                                     :buffer response :noquery t))
         callback delivered)
    (unwind-protect
        (cl-letf (((symbol-function 'url-retrieve)
                   (lambda (_url function &rest _) (setq callback function) response)))
          (let ((request (tategaki-ai--request "/models" nil
                                                (lambda (result) (push result delivered)) "GET")))
            (should (eq request response))
            (should (process-live-p process))
            (tategaki-ai-cancel request)
            (should-not (process-live-p process))
            (should-not (buffer-live-p response))
            (should (= (length delivered) 1))
            (should-not (plist-get (car delivered) :ok))
            ;; A late network sentinel must not deliver a second result.
            (with-temp-buffer
              (setq-local url-http-response-status 500)
              (funcall callback nil))
            (should (= (length delivered) 1))))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p response) (kill-buffer response)))))

(ert-deftest tategaki-ai-integration-retrieval-does-not-return-stale-semantic-results ()
  (tategaki-ai-integration--source
    (setq tategaki-semantic--index
          (list :hash (tategaki-semantic-hash) :model (tategaki-semantic--model-key)
                :chunks (mapcar (lambda (chunk) (plist-put chunk :vector '(1.0 0.0)))
                                (tategaki-semantic-chunks))))
    (let (pending result)
      (cl-letf (((symbol-function 'tategaki-ai-embed)
                 (lambda (_texts callback &rest _) (setq pending callback))))
        (tategaki-semantic-retrieve "母" (lambda (value) (setq result value))))
      (insert "検索待ちの編集")
      (with-temp-buffer (funcall pending '(:ok t :vectors ((1.0 0.0)))))
      (should result)
      (should (or (not (plist-get result :ok))
                  (cl-every (lambda (chunk)
                              (equal (plist-get chunk :source-hash)
                                     (tategaki-semantic-hash source)))
                            (plist-get result :chunks)))))))

(ert-deftest tategaki-ai-integration-review-counts-spelling-variant-rule-code ()
  (tategaki-ai-integration--source
    (tategaki-diagnostics-set 'rule
                             '((:id "variant" :start 1 :end 2 :severity warning
                                :code "spelling-variant" :message "test")))
    (tategaki-review)
    (should (string-match-p "表記揺れ 1 件" (buffer-string)))))

(ert-deftest tategaki-ai-integration-rag-world-and-timeline-cutoff-with-character-knowledge ()
  (tategaki-ai-integration--source
    (require 'tategaki-world)
    (require 'tategaki-timeline)
    (let* ((cutoff (save-excursion (goto-char (point-min))
                                   (search-forward "第2章") (match-beginning 0)))
           (early (tategaki-world-source-reference 6 7))
           (late (tategaki-world-source-reference (- (point-max) 2) (1- (point-max)))))
      (dolist (spec `(("人物だけが知る秘密" ["花子"] ,early "author-confirmed")
                      ("読者だけが知る秘密" ["reader"] ,early "author-confirmed")
                      ("未来で初めて知る秘密" ["花子" "reader"] ,late "author-confirmed")
                      ("採用していない推測" ["花子" "reader"] ,early "inferred")))
        (tategaki-world-upsert
         (list :type "Fact" :name (nth 0 spec) :subject "花子"
               :attribute "knowledge" :value (nth 0 spec) :known-by (nth 1 spec)
               :source (nth 2 spec) :state (nth 3 spec))))
      (tategaki-timeline-upsert (list :label "既出の朝" :time-status "exact"
                                     :story-time "2026-04-10 08:00" :source early))
      (tategaki-timeline-upsert (list :label "未来の夜" :time-status "exact"
                                     :story-time "2026-05-20 20:00" :source late))
      (dolist (person '("花子" "reader"))
        (let (result)
          (tategaki-rag-context "母" (lambda (value) (setq result value)) cutoff nil person)
          (should (plist-get result :ok))
          (let ((text (plist-get result :text)))
            (should (string-match-p (if (equal person "花子") "人物だけが知る秘密" "読者だけが知る秘密") text))
            (should-not (string-match-p (if (equal person "花子") "読者だけが知る秘密" "人物だけが知る秘密") text))
            ;; Chronology is not automatically known to a character merely
            ;; because its source occurs earlier in the manuscript.
            (should-not (string-match-p "既出の朝" text))
            (dolist (forbidden '("未来で初めて知る秘密" "未来の夜" "2026-05-20" "採用していない推測"))
              (should-not (string-match-p forbidden text))))
          (should (cl-every (lambda (chunk) (<= (plist-get chunk :end) cutoff))
                            (plist-get result :chunks))))))))

(ert-deftest tategaki-ai-integration-rag-extra-context-keeps-source-editing-state ()
  (tategaki-ai-integration--source
    (require 'tategaki-world)
    (require 'tategaki-timeline)
    (tategaki-world-upsert '(:type "Character" :name "花子" :state "author-confirmed"))
    (tategaki-timeline-upsert '(:label "朝" :time-status "exact" :story-time "2026-04-10"))
    (buffer-enable-undo)
    (set-buffer-modified-p nil)
    (set-mark 5)
    (narrow-to-region 2 13)
    (let ((text (buffer-string)) (undo buffer-undo-list) (position (point)) (mark (mark))
          (tick (buffer-chars-modified-tick)) (minimum (point-min)) (maximum (point-max)) result)
      (tategaki-rag-context "母" (lambda (value) (setq result value)))
      (should (plist-get result :ok))
      (should (string-match-p "作品設定" (plist-get result :text)))
      (should (string-match-p "作品時間" (plist-get result :text)))
      (should (equal text (buffer-string)))
      (should (equal undo buffer-undo-list))
      (should (= position (point)))
      (should (= mark (mark)))
      (should (= minimum (point-min)))
      (should (= maximum (point-max)))
      (should (= tick (buffer-chars-modified-tick)))
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-ai-integration-rag-reserved-context-includes-citation-overhead-in-budget ()
  (tategaki-ai-integration--source
    (require 'tategaki-world)
    (erase-buffer)
    (insert "第1章\n" (make-string 1000 ?母) "。\n")
    (goto-char 8)
    (tategaki-world-upsert (list :type "Fact" :name "予約する設定情報" :subject "花子"
                                 :attribute "knowledge" :value (make-string 100 ?秘)
                                 :state "author-confirmed"))
    (setq-local tategaki-rag-context-limit 150)
    (let (pending result)
      (cl-letf (((symbol-function 'tategaki-semantic-retrieve)
                 (lambda (_query callback &rest _) (setq pending callback))))
        (tategaki-rag-context "母" (lambda (value) (setq result value))))
      (with-temp-buffer
        (setq-local tategaki-rag-context-limit 12000)
        (funcall pending '(:ok t :method lexical :chunks nil)))
      (should (plist-get result :ok))
      (should (string-match-p "作品設定" (plist-get result :text)))
      (should (string-match-p "予約する設定情報" (plist-get result :text)))
      (should (plist-get result :chunks))
      (should (<= (length (plist-get result :text)) 150)))))

(provide 'tategaki-ai-integration-test)
;;; tategaki-ai-integration-test.el ends here
