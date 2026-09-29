;;; tategaki-foreshadow.el --- Author-confirmed foreshadowing ledger -*- lexical-binding: t; -*-
;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'tategaki-world)

(defun tategaki-foreshadow-records ()
  "Return the stored candidate, open, resolved and rejected foreshadow records."
  (tategaki-world--read-store "foreshadow"))

(defun tategaki-foreshadow-upsert (record)
  "Validate and save a foreshadow RECORD without changing author decisions."
  (setq record (copy-tree record))
  (unless (and (stringp (plist-get record :name)) (not (string-empty-p (plist-get record :name)))
               (member (plist-get record :status) '("candidate" "open" "resolved" "rejected" "adopted")))
    (user-error "伏線の名前と状態を確認してください"))
  (when (and (equal (plist-get record :status) "resolved") (null (plist-get record :payoff)))
    (user-error "回収箇所が必要です"))
  (unless (plist-get record :id) (setq record (plist-put record :id (tategaki-world--id "foreshadow"))))
  (unless (plist-get record :source) (setq record (plist-put record :source (tategaki-world-source-reference))))
  (tategaki-world--write-store
   "foreshadow" (append (cl-remove (plist-get record :id) (tategaki-foreshadow-records)
                                    :key (lambda (item) (plist-get item :id)) :test #'equal) (list record)))
  record)

(defun tategaki-foreshadow-propose (name &optional reference)
  "Store NAME with REFERENCE as a candidate requiring explicit author adoption."
  (tategaki-foreshadow-upsert (list :name name :status "candidate" :source reference)))

(defun tategaki-foreshadow-register (name)
  "Explicitly register author-confirmed NAME at the source point."
  (interactive "s伏線の名前: ")
  (prog1 (tategaki-foreshadow-upsert (list :name name :status "open"))
    (when (called-interactively-p 'interactive) (tategaki-foreshadow))))

(defun tategaki-foreshadow-set-status (id status &optional payoff)
  "Apply the author's STATUS decision to ID, using PAYOFF for resolution."
  (let ((record (cl-find id (tategaki-foreshadow-records) :key (lambda (item) (plist-get item :id)) :test #'equal)))
    (unless record (user-error "伏線が見つかりません"))
    (when (and (equal status "open") (equal (plist-get record :status) "candidate"))
      (when (equal (plist-get record :candidate-kind) "payoff")
        (user-error "回収候補は採用操作で配置先を選択してください"))
      (unless (tategaki-world-reference-valid-p (plist-get record :source))
        (user-error "候補の原稿が変わりました。再抽出してください")))
    (setq record (plist-put record :status status))
    (setq record (plist-put record :payoff (and (equal status "resolved")
                                               (or payoff (tategaki-world-source-reference)))))
    (tategaki-foreshadow-upsert record)))

(defun tategaki-foreshadow-resolve (id)
  "Mark ID resolved at the current source position."
  (interactive
   (let ((options (mapcar (lambda (item) (cons (plist-get item :name) (plist-get item :id)))
                          (cl-remove-if-not (lambda (item) (equal (plist-get item :status) "open")) (tategaki-foreshadow-records)))))
     (list (cdr (assoc (completing-read "回収する伏線: " options nil t) options)))))
  (tategaki-foreshadow-set-status id "resolved")
  (when (called-interactively-p 'interactive) (tategaki-foreshadow)))

(defun tategaki-foreshadow--import-candidates (items)
  "Append grounded setup/payoff ITEMS without changing any existing thread."
  (let ((records (tategaki-foreshadow-records)) candidates)
    (dolist (item items)
      (setq item (tategaki-world--normalize-model-item item))
      (when (and (equal (plist-get item :kind) "payoff") (not (plist-get item :target-name)))
        (setq item (plist-put item :target-name (plist-get item :name))))
      (when (and (member (plist-get item :kind) '("setup" "payoff"))
                 (stringp (plist-get item :name)) (not (string-empty-p (plist-get item :name))))
        (let ((record (append (list :id (tategaki-world--id "foreshadow") :status "candidate"
                                    :candidate-kind (plist-get item :kind) :target-id nil)
                              (tategaki-world--copy-fields item '(:name :target-name :reason :source :chapter :scene)))))
          (unless (cl-find-if (lambda (old) (and (equal (plist-get old :source) (plist-get record :source))
                                                (equal (plist-get old :candidate-kind) (plist-get record :candidate-kind))
                                                (equal (plist-get old :name) (plist-get record :name))
                                                (equal (plist-get old :target-name) (plist-get record :target-name))))
                              (append records candidates))
            (push record candidates)))))
    (setq candidates (nreverse candidates))
    (dolist (record candidates)
      (when (equal (plist-get record :candidate-kind) "payoff")
        (let ((matches (cl-remove-if-not
                        (lambda (entry) (and (not (equal (plist-get entry :candidate-kind) "payoff"))
                                             (member (plist-get entry :status) '("open" "candidate"))
                                             (equal (plist-get entry :name) (plist-get record :target-name))
                                             (equal (plist-get (plist-get entry :source) :document)
                                                    (plist-get (plist-get record :source) :document))
                                             (<= (plist-get (plist-get entry :source) :end)
                                                 (plist-get (plist-get record :source) :start))))
                        (append records candidates))))
          (when (= 1 (length matches)) (setf (plist-get record :target-id) (plist-get (car matches) :id))))))
    (tategaki-world--write-store "foreshadow" (append records candidates))
    (length candidates)))

(defun tategaki-foreshadow--extraction-context (pending)
  "Return open setup names and staged PENDING setup names for payoff matching."
  (vconcat
   (mapcar (lambda (item) (tategaki-world--copy-fields item '(:name :evidence :reason)))
           (append (cl-remove-if-not (lambda (record) (equal (plist-get record :status) "open"))
                                    (tategaki-foreshadow-records))
                   (cl-remove-if-not (lambda (item) (equal (plist-get item :kind) "setup")) pending)))))

(defun tategaki-foreshadow-extract (&optional selection callback)
  "Extract foreshadow setups and payoff proposals from all text or SELECTION."
  (interactive)
  (tategaki-world-extraction-start
   'foreshadow #'tategaki-foreshadow--import-candidates
   "伏線の配置候補と回収候補を抽出。各要素はkind(setup/payoff), name, evidence, reason。setupは未解決の示唆・謎・約束の配置。payoffは以前の示唆が明らかになる箇所でtarget-nameに対応するpreviousの配置名を正確に記す。previousに無ければ対応する本文中の配置候補もsetupとして挙げる。作者意図や回収完了を断定しない。previousの候補を新しいsetupとして繰り返さない。payoffにはtarget-nameを必ず付ける。形式例: [{\"kind\":\"payoff\",\"name\":\"鍵の発見\",\"target-name\":\"previousにある配置名\",\"evidence\":\"このtextにある正確な引用\",\"reason\":\"配置と結びつく根拠\"}]。"
   selection callback #'tategaki-foreshadow--extraction-context))

(defun tategaki-foreshadow-adopt (id &optional target-id)
  "Adopt candidate ID; payoff candidates explicitly pair with open TARGET-ID.
A payoff proposal never resolves its target until this author action."
  (let* ((records (tategaki-foreshadow-records))
         (record (cl-find id records :key (lambda (item) (plist-get item :id)) :test #'equal)))
    (unless (and record (equal (plist-get record :status) "candidate"))
      (user-error "未採用の候補を選択してください"))
    (unless (tategaki-world-reference-valid-p (plist-get record :source))
      (user-error "候補の原稿が変わりました。再抽出してください"))
    (if (not (equal (plist-get record :candidate-kind) "payoff"))
        (tategaki-foreshadow-set-status id "open")
      (let* ((options (mapcar (lambda (item) (cons (format "%s / %s" (plist-get item :name) (plist-get item :id))
                                                  (plist-get item :id)))
                              (cl-remove-if-not (lambda (item) (equal (plist-get item :status) "open")) records)))
             (preferred (car (rassoc (plist-get record :target-id) options)))
             (target-id (or target-id
                            (and options (cdr (assoc (completing-read "回収先の配置（先に配置候補を採用）: " options nil t nil nil preferred) options)))))
             (target (cl-find target-id records :key (lambda (item) (plist-get item :id)) :test #'equal)))
        (unless (and target (equal (plist-get target :status) "open"))
          (user-error "先に配置候補を採用し、未回収の伏線を選択してください"))
        (unless (tategaki-world-reference-valid-p (plist-get target :source))
          (user-error "配置元の原稿が変わっています。出典を確認してください"))
        (unless (<= (plist-get (plist-get target :source) :end)
                    (plist-get (plist-get record :source) :start))
          (user-error "回収候補は配置箇所より後の原稿位置を指定してください"))
        (setf (plist-get target :status) "resolved"
              (plist-get target :payoff) (plist-get record :source)
              (plist-get record :status) "adopted"
              (plist-get record :target-id) target-id)
        (tategaki-world--write-store
         "foreshadow" (mapcar (lambda (entry)
                                (cond ((equal (plist-get entry :id) id) record)
                                      ((equal (plist-get entry :id) target-id) target)
                                      (t entry))) records))
        target))))

;;;###autoload
(defun tategaki-foreshadow ()
  "Show author-confirmed open/resolved threads and unadopted candidates."
  (interactive)
  (let ((records (tategaki-foreshadow-records)))
    (tategaki-world-panel
     "伏線"
     (lambda ()
       (tategaki-world--button "伏線を登録" (lambda () (call-interactively #'tategaki-foreshadow-register)))
       (tategaki-world--button "候補を記録" (lambda () (tategaki-foreshadow-propose (read-string "候補名: ")) (tategaki-foreshadow)))
       (tategaki-world--button "本文全文から配置・回収候補" (lambda () (tategaki-foreshadow-extract) (tategaki-foreshadow)))
       (tategaki-world--button "選択範囲から候補" (lambda ()
                                                  (let ((selection (tategaki-world-selection)))
                                                    (unless selection (user-error "原稿で範囲を選択してください"))
                                                    (tategaki-foreshadow-extract selection) (tategaki-foreshadow))))
       (tategaki-world--button "更新" #'tategaki-foreshadow)
       (tategaki-world-insert-extraction-status #'tategaki-foreshadow)
       (insert "\n\n回収操作は、原稿の現在位置を回収箇所として記録します。\n")
       (dolist (group '(("open" . "未回収") ("resolved" . "回収済") ("candidate" . "候補（未採用）") ("rejected" . "却下") ("adopted" . "対応付け済み回収候補")))
         (insert (format "\n%s\n" (cdr group)))
         (dolist (record records)
           (when (equal (car group) (plist-get record :status))
             (let ((id (plist-get record :id)))
               (insert (format "  %s  " (plist-get record :name)))
               (tategaki-world-insert-reference (plist-get record :source)
                                                 (if (equal (plist-get record :candidate-kind) "payoff") "回収候補箇所" "配置箇所"))
               (when (plist-get record :payoff)
                 (insert " → ") (tategaki-world-insert-reference (plist-get record :payoff) "回収箇所"))
               (insert "  ")
               (pcase (plist-get record :status)
                 ("candidate" (tategaki-world--button "採用" (lambda () (tategaki-foreshadow-adopt id) (tategaki-foreshadow)))
                  (tategaki-world--button "却下" (lambda () (tategaki-foreshadow-set-status id "rejected") (tategaki-foreshadow))))
                 ("open" (tategaki-world--button "現在位置で回収" (lambda () (tategaki-foreshadow-resolve id) (tategaki-foreshadow))))
                 ("resolved" (tategaki-world--button "未回収に戻す" (lambda () (tategaki-foreshadow-set-status id "open") (tategaki-foreshadow)))))
               (insert (format "\n    根拠: %s\n" (plist-get (plist-get record :source) :quote)))
               (when (plist-get record :reason) (insert (format "    候補理由: %s\n" (plist-get record :reason))))
               (when (plist-get record :target-name)
                 (insert (format "    対応先候補: %s（採用時に作者が選択）\n" (plist-get record :target-name))))))))))))

(provide 'tategaki-foreshadow)
;;; tategaki-foreshadow.el ends here
