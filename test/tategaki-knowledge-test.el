;;; tategaki-knowledge-test.el --- Viewpoint leakage regressions -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'tategaki-knowledge)
(require 'tategaki-rag)

(defmacro tategaki-knowledge-test--source (&rest body)
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (insert "第1章 真犯人は太郎\n花子は赤い傘を見た。太郎だけが鍵の隠し場所を知っていた。\n\n第2章\n花子は手紙を読んだ。\n")
     (goto-char (point-min))
     ,@body))

(defun tategaki-knowledge-test--ref (text)
  (save-excursion
    (goto-char (point-min)) (search-forward text)
    (tategaki-world-source-reference (- (point) (length text)) (point))))

(defun tategaki-knowledge-test--fact (text people &optional state)
  (tategaki-world-upsert
   (list :type "Fact" :name text :subject "出来事" :attribute "knowledge" :value text
         :known-by (vconcat people) :state (or state "author-confirmed")
         :source (tategaki-knowledge-test--ref text))))

(ert-deftest tategaki-knowledge-clips-shared-paragraph-and-hides-chapter-secret ()
  (tategaki-knowledge-test--source
    (tategaki-knowledge-test--fact "花子は赤い傘を見た。" '("花子" "reader"))
    (tategaki-knowledge-test--fact "太郎だけが鍵の隠し場所を知っていた。" '("太郎" "reader"))
    (tategaki-world-upsert '(:type "Character" :name "太郎" :state "author-confirmed"))
    (let* ((chunks (tategaki-knowledge-filter-chunks (tategaki-semantic-chunks) "花子" (point-max)))
           (text (mapconcat (lambda (c) (plist-get c :text)) chunks "\n")))
      (should (equal text "花子は赤い傘を見た。"))
      (should-not (string-match-p "太郎" (plist-get (car chunks) :chapter)))
      (should-not (plist-get (car chunks) :characters))
      (should-not (plist-get (car chunks) :pov))
      (should-not (plist-get (car chunks) :story-time))
      (should-not (tategaki-knowledge-filter-chunks (tategaki-semantic-chunks) "未知の人物" (point-max))))))

(ert-deftest tategaki-knowledge-rejects-inferred-future-and-stale-permissions ()
  (tategaki-knowledge-test--source
    (tategaki-knowledge-test--fact "花子は赤い傘を見た。" '("花子") "inferred")
    (let ((future (tategaki-knowledge-test--fact "花子は手紙を読んだ。" '("花子"))))
      (should-not (tategaki-knowledge-ranges "花子" (1- (plist-get (plist-get future :source) :end))))
      (should (tategaki-knowledge-ranges "花子" (point-max)))
      (goto-char (point-max)) (insert "追記")
      (should-not (tategaki-knowledge-ranges "花子" (point-max))))))

(ert-deftest tategaki-knowledge-presence-and-pov-do-not-grant-visibility ()
  (tategaki-knowledge-test--source
    (let* ((ref (tategaki-knowledge-test--ref "花子は赤い傘を見た。"))
           (scene (tategaki-world-upsert
                   (list :type "Scene" :name "玄関" :state "author-confirmed"
                         :pov "花子" :characters ["花子"] :source ref))))
      (should-not (tategaki-knowledge-ranges "花子" (point-max)))
      (tategaki-world-upsert (plist-put scene :visibility ["花子"]))
      (should (equal (tategaki-knowledge-ranges "花子" (point-max))
                     (list (cons (plist-get ref :start) (plist-get ref :end))))))))

(ert-deftest tategaki-knowledge-reader-difference-is-explicit-and-source-neutral ()
  (tategaki-knowledge-test--source
    (tategaki-knowledge-test--fact "花子は赤い傘を見た。" '("花子" "reader"))
    (tategaki-knowledge-test--fact "太郎だけが鍵の隠し場所を知っていた。" '("太郎" "reader"))
    (buffer-enable-undo) (setq buffer-undo-list nil) (set-buffer-modified-p nil)
    (let ((text (buffer-string)) (undo buffer-undo-list) (point (point))
          (data (tategaki-knowledge-difference "花子" (point-max))))
      (should (= 1 (length (plist-get data :reader-only))))
      (should (= 1 (length (plist-get data :shared))))
      (should-not (plist-get data :character-only))
      (should (equal text (buffer-string))) (should (eq undo buffer-undo-list))
      (should (= point (point))) (should-not (buffer-modified-p)))))

(ert-deftest tategaki-knowledge-rag-never-sends-unrestricted-search-or-timeline ()
  (tategaki-knowledge-test--source
    (tategaki-knowledge-test--fact "花子は赤い傘を見た。" '("花子" "reader"))
    (let ((source (current-buffer)) result)
      (goto-char (point-max))
      (cl-letf (((symbol-function 'tategaki-semantic-retrieve)
                 (lambda (&rest _) (ert-fail "Unrestricted retrieval is forbidden")))
                ((symbol-function 'tategaki-timeline-context)
                 (lambda (&rest _) (ert-fail "Unrestricted timeline is forbidden"))))
        (tategaki-rag-context "鍵の隠し場所は？" (lambda (r) (setq result r)) (point-max) nil "花子"))
      (should (plist-get result :ok))
      (should (eq 'character-scoped (plist-get result :method)))
      (should (string-match-p "赤い傘" (plist-get result :text)))
      (should-not (string-match-p "太郎\\|隠し場所\\|真犯人\\|手紙" (plist-get result :text)))
      (should (eq source (current-buffer))))))

(ert-deftest tategaki-semantic-annotations-use-reviewed-scene-not-inference ()
  (tategaki-knowledge-test--source
    (tategaki-world-upsert '(:type "Character" :name "花子" :state "author-confirmed"))
    (let* ((chunks (tategaki-semantic-chunks))
           (chunk (cadr chunks))
           (ref (tategaki-world-source-reference (plist-get chunk :start) (plist-get chunk :end)))
           (scene (tategaki-world-upsert
                   (list :type "Scene" :name "玄関" :state "inferred" :source ref
                         :pov "花子" :characters ["花子" "太郎"]))))
      (should-not (plist-get (cadr (tategaki-semantic-chunks)) :pov))
      (tategaki-world-upsert (plist-put scene :state "author-confirmed"))
      (let ((updated (cadr (tategaki-semantic-chunks))))
        (should (equal "花子" (plist-get updated :pov)))
        (should (member "太郎" (plist-get updated :characters)))))))

(ert-deftest tategaki-semantic-relative-time-cannot-use-unapproved-anchor ()
  (require 'tategaki-timeline)
  (tategaki-knowledge-test--source
    (let* ((ref (tategaki-knowledge-test--ref "花子は赤い傘を見た。"))
           (anchor (list :id "anchor" :state "inferred" :time-status "exact"
                         :story-time "2026-04-10 08:00" :source ref))
           (relative (list :id "relative" :state "author-confirmed"
                           :time-status "relative" :anchor "anchor"
                           :offset-minutes 60 :source ref)))
      (cl-letf (((symbol-function 'tategaki-timeline-records)
                 (lambda (&rest _) (list anchor relative))))
        (should-not (seq-some (lambda (chunk) (plist-get chunk :story-time))
                              (tategaki-semantic-chunks)))
        (setq anchor (plist-put anchor :state "author-confirmed"))
        (should (seq-some (lambda (chunk) (plist-get chunk :story-time))
                          (tategaki-semantic-chunks)))))))

(ert-deftest tategaki-semantic-relative-time-cannot-use-stale-anchor ()
  (require 'tategaki-timeline)
  (tategaki-knowledge-test--source
    (let* ((ref (tategaki-knowledge-test--ref "花子は赤い傘を見た。"))
           (stale (plist-put (copy-sequence ref) :hash "outdated"))
           (anchor (list :id "anchor" :state "author-confirmed" :time-status "exact"
                         :story-time "2026-04-10 08:00" :source stale))
           (relative (list :id "relative" :state "author-confirmed"
                           :time-status "relative" :anchor "anchor"
                           :offset-minutes 60 :source ref)))
      (cl-letf (((symbol-function 'tategaki-timeline-records)
                 (lambda (&rest _) (list anchor relative))))
        (should-not (seq-some (lambda (chunk) (plist-get chunk :story-time))
                              (tategaki-semantic-chunks)))))))

(ert-deftest tategaki-semantic-cutoff-clips-heading-metadata ()
  (tategaki-knowledge-test--source
    (goto-char (point-min)) (search-forward "第1章")
    (let ((chunks (tategaki-semantic-chunks nil (point))))
      (should (equal "第1章" (plist-get (car chunks) :chapter)))
      (should-not (string-match-p "真犯人\\|太郎" (prin1-to-string chunks))))))

(provide 'tategaki-knowledge-test)
