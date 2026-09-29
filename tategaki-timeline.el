;;; tategaki-timeline.el --- Manuscript order and story time -*- lexical-binding: t; -*-
;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'tategaki-world)
(defconst tategaki-timeline-states '("exact" "relative" "inferred" "unknown"))

(defun tategaki-timeline-records (&optional cutoff)
  "Return timeline entries, restricting current source references to CUTOFF."
  (with-current-buffer (tategaki-world--source)
    (let ((records (tategaki-world--read-store "timeline"))
          (tategaki-world--current-hash (tategaki-world--hash)))
      (if (null cutoff) records
        (cl-remove-if-not
         (lambda (record)
           (let ((source (plist-get record :source)))
             (and (tategaki-world-source-current-p source) (<= (plist-get source :end) cutoff)))) records)))))

(defun tategaki-timeline--parse-time (text)
  "Parse strict ISO TEXT without silently normalizing invalid dates."
  (when (and (stringp text)
             (string-match "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)\\(?:[ T]\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\)\\)?\\'" text))
    (let* ((year (string-to-number (match-string 1 text)))
           (month (string-to-number (match-string 2 text)))
           (day (string-to-number (match-string 3 text)))
           (hour (string-to-number (or (match-string 4 text) "0")))
           (minute (string-to-number (or (match-string 5 text) "0"))))
      (when (and (<= 1 year 9999) (<= 1 month 12)
                 (<= 1 day (calendar-last-day-of-month month year))
                 (<= 0 hour 23) (<= 0 minute 59))
        (encode-time 0 minute hour day month year t)))))

(defun tategaki-timeline-resolve (record &optional records seen)
  "Resolve RECORD to an Emacs time, or nil if unknown or cyclic.
RECORDS is the allowed anchor set; callers can supply cutoff-filtered entries.
SEEN tracks anchor IDs and prevents cyclic relative references."
  (let ((id (plist-get record :id)))
    (unless (member id seen)
      (pcase (plist-get record :time-status)
        ((or "exact" "inferred") (tategaki-timeline--parse-time (plist-get record :story-time)))
        ("relative"
         (let* ((entries (or records (tategaki-timeline-records)))
                (anchor (cl-find (plist-get record :anchor) entries :key (lambda (item) (plist-get item :id)) :test #'equal))
                (time (and anchor (tategaki-timeline-resolve anchor entries (cons id seen)))))
           (when (and time (numberp (plist-get record :offset-minutes)))
             (time-add time (seconds-to-time (* 60 (plist-get record :offset-minutes)))))))))))

(defun tategaki-timeline--validate (record)
  "Validate timeline RECORD without persisting it."
  (unless (and (stringp (plist-get record :label))
               (not (string-empty-p (plist-get record :label)))
               (member (plist-get record :time-status) tategaki-timeline-states))
    (user-error "場面名と日時状態を確認してください"))
  (when (and (member (plist-get record :time-status) '("exact" "inferred"))
             (not (tategaki-timeline--parse-time (plist-get record :story-time))))
    (user-error "日時は YYYY-MM-DD または YYYY-MM-DD HH:MM で入力してください"))
  (when (and (equal (plist-get record :time-status) "relative")
             (not (and (or (stringp (plist-get record :anchor))
                           (and (member (plist-get record :state) '("inferred" "rejected"))
                                (stringp (plist-get record :anchor-label))))
                       (numberp (plist-get record :offset-minutes)))))
    (user-error "相対日時には基準場面と分差が必要です"))
  record)

(defun tategaki-timeline-upsert (record)
  "Validate and persist a timeline RECORD."
  (setq record (copy-tree record))
  (unless (plist-get record :state) (setq record (plist-put record :state "author-confirmed")))
  (tategaki-timeline--validate record)
  (unless (plist-get record :id) (setq record (plist-put record :id (tategaki-world--id "time"))))
  (unless (plist-get record :source) (setq record (plist-put record :source (tategaki-world-source-reference))))
  (tategaki-world--write-store
   "timeline" (append (cl-remove (plist-get record :id) (tategaki-timeline-records)
                                  :key (lambda (item) (plist-get item :id)) :test #'equal) (list record)))
  record)

(defun tategaki-timeline-context (&optional cutoff)
  "Return story-time context derived only from entries through CUTOFF."
  (let ((records (cl-remove-if
                  (lambda (record) (member (plist-get record :state) '("inferred" "rejected")))
                  (tategaki-timeline-records cutoff))))
    (mapconcat
     (lambda (record)
       (let ((time (tategaki-timeline-resolve record records)))
         (format "%s [%s]: %s" (plist-get record :label) (plist-get record :time-status)
                 (if time (format-time-string "%Y-%m-%d %H:%M" time t) "不明")))) records "\n")))

(defun tategaki-timeline-add (&optional record)
  "Register or edit RECORD's scene time at the source point."
  (interactive)
  (let* ((label (read-string "場面名: " (plist-get record :label)))
         (status (completing-read "日時状態: " tategaki-timeline-states nil t nil nil (plist-get record :time-status)))
         (updated (list :id (plist-get record :id) :label label :time-status status
                        :state "author-confirmed" :source (or (plist-get record :source) (tategaki-world-source-reference)))))
    (pcase status
      ((or "exact" "inferred")
       (setq updated (plist-put updated :story-time (read-string "作品日時 (YYYY-MM-DD HH:MM): " (plist-get record :story-time)))))
      ("relative"
       (let* ((options (mapcar (lambda (item) (cons (concat (plist-get item :label) " / " (plist-get item :id)) (plist-get item :id)))
                              (cl-remove (plist-get record :id) (tategaki-timeline-records) :key (lambda (item) (plist-get item :id)) :test #'equal)))
              (anchor (and options (cdr (assoc (completing-read "基準場面: " options nil t) options)))))
         (unless anchor (user-error "先に基準となる場面を登録してください"))
         (setq updated (plist-put updated :anchor anchor))
         (setq updated (plist-put updated :offset-minutes (read-number "基準から何分後（前は負数）: " (or (plist-get record :offset-minutes) 0)))))))
    (when (and (equal (plist-get record :state) "inferred")
               (not (tategaki-world-reference-valid-p (plist-get record :source))))
      (user-error "原稿が変わったため再抽出してください"))
    (tategaki-timeline-upsert updated)
    (tategaki-timeline)))

(defun tategaki-timeline--import-candidates (items)
  "Store grounded time ITEMS as unadopted candidates in one write."
  (let ((records (tategaki-timeline-records)) candidates)
    (dolist (item items)
      (setq item (tategaki-world--normalize-model-item item))
      (let ((nested (plist-get item :story-time)))
        (when (and (listp nested) (keywordp (car nested)))
          (setq nested (tategaki-world--normalize-model-item nested))
          (when (and (stringp (plist-get nested :anchor-label))
                     (numberp (plist-get nested :offset-minutes)))
            (setq item (plist-put item :time-status "relative"))
            (setq item (plist-put item :anchor-label (plist-get nested :anchor-label)))
            (setq item (plist-put item :offset-minutes (plist-get nested :offset-minutes)))
            (setq item (plist-put item :story-time nil)))))
      (let ((record (append (list :id (tategaki-world--id "time") :state "inferred" :anchor nil)
                            (tategaki-world--copy-fields item
                             '(:label :time-status :story-time :offset-minutes :anchor-label
                               :source :chapter :scene :scene-id)))))
        (condition-case nil
            (progn (tategaki-timeline--validate record)
                   (unless (cl-find-if (lambda (old) (and (equal (plist-get old :label) (plist-get record :label))
                                                         (equal (plist-get old :source) (plist-get record :source))
                                                         (equal (tategaki-world--copy-fields old '(:time-status :story-time :offset-minutes :anchor-label))
                                                                (tategaki-world--copy-fields record '(:time-status :story-time :offset-minutes :anchor-label)))))
                                       (append records candidates))
                     (push record candidates)))
          (error nil))))
    (setq candidates (nreverse candidates))
    (dolist (record candidates)
      (when (equal (plist-get record :time-status) "relative")
        (let ((anchors (cl-remove-if-not
                        (lambda (entry) (and (not (eq entry record))
                                             (equal (plist-get entry :label) (plist-get record :anchor-label))
                                             (not (equal (plist-get entry :state) "rejected"))))
                        (append records candidates))))
          (when (= 1 (length anchors))
            (setf (plist-get record :anchor) (plist-get (car anchors) :id))))))
    (tategaki-world--write-store "timeline" (append records candidates))
    (length candidates)))

(defun tategaki-timeline--extraction-context (pending)
  "Return time labels for matching explicit relative anchors in PENDING."
  (vconcat
   (mapcar (lambda (item) (tategaki-world--copy-fields item '(:label :story-time :time-status)))
           (append (cl-remove-if (lambda (record) (equal (plist-get record :state) "rejected"))
                                 (tategaki-timeline-records)) pending))))

(defun tategaki-timeline-extract (&optional selection callback)
  "Extract date and relative-time candidates from all text or SELECTION."
  (interactive)
  (tategaki-world-extraction-start
   'timeline #'tategaki-timeline--import-candidates
   "日時候補の各要素はlabel（場面名）, evidence, time-status(exact/relative/inferred/unknown)。明示された年月日時のみstory-timeをYYYY-MM-DDまたはYYYY-MM-DD HH:MMで。相対日時はanchor-label（previousの既存場面名と正確に一致。未特定なら基準表現そのもの）とoffset-minutes（翌日=1440、前日=-1440）。基準の年が不明なら勝手に現在年を補わずunknown。回想・翌朝なども候補にし、確定済み場面を変更しない。形式はフラットなJSON: [{\"label\":\"出発\",\"evidence\":\"本文の正確な引用\",\"time-status\":\"exact\",\"story-time\":\"2026-09-29 08:00\"},{\"label\":\"帰宅\",\"evidence\":\"本文の正確な引用\",\"time-status\":\"relative\",\"anchor-label\":\"出発\",\"offset-minutes\":1440}]。story-timeにオブジェクトを入れない。例は形式のみ、本文にない内容は出力しない。"
   selection callback #'tategaki-timeline--extraction-context))

(defun tategaki-timeline-set-state (id state)
  "Apply the author's STATE decision to candidate ID after provenance checks."
  (unless (member state '("author-confirmed" "rejected")) (user-error "Unknown decision"))
  (let ((record (cl-find id (tategaki-timeline-records) :key (lambda (entry) (plist-get entry :id)) :test #'equal)))
    (unless record (user-error "日時候補が見つかりません"))
    (when (equal state "author-confirmed")
      (unless (tategaki-world-reference-valid-p (plist-get record :source))
        (user-error "候補の原稿が変わりました。再抽出してください"))
      (when (equal (plist-get record :time-status) "relative")
        (let ((anchor (cl-find (plist-get record :anchor) (tategaki-timeline-records)
                               :key (lambda (entry) (plist-get entry :id)) :test #'equal)))
          (unless (and anchor (not (member (plist-get anchor :state) '("inferred" "rejected")))
                       (tategaki-world-reference-valid-p (plist-get anchor :source)))
            (user-error "先に基準場面を採用するか、編集で基準を指定してください")))))
    (tategaki-timeline-upsert (plist-put record :state state))))

;;;###autoload
(defun tategaki-timeline (&optional chronological)
  "Show manuscript and story times; CHRONOLOGICAL sorts by resolved story time."
  (interactive "P")
  (let* ((records (tategaki-timeline-records))
         (ordered (sort (copy-sequence records)
                        (lambda (a b)
                          (if chronological
                              (let ((ta (tategaki-timeline-resolve a records)) (tb (tategaki-timeline-resolve b records)))
                                (and ta (or (null tb) (time-less-p ta tb))))
                            (< (or (plist-get (plist-get a :source) :start) 0)
                               (or (plist-get (plist-get b :source) :start) 0)))))))
    (tategaki-world-panel
     "時系列"
     (lambda ()
       (tategaki-world--button "場面を登録" #'tategaki-timeline-add)
       (tategaki-world--button "本文全文から日時候補" (lambda () (tategaki-timeline-extract) (tategaki-timeline)))
       (tategaki-world--button "選択範囲から日時候補" (lambda ()
                                                     (let ((selection (tategaki-world-selection)))
                                                       (unless selection (user-error "原稿で範囲を選択してください"))
                                                       (tategaki-timeline-extract selection) (tategaki-timeline))))
       (tategaki-world-insert-extraction-status #'tategaki-timeline)
       (tategaki-world--button "原稿順" #'tategaki-timeline)
       (tategaki-world--button "作品時間順" (lambda () (tategaki-timeline t)))
       (insert "\n\n場面 / 原稿位置 → 作品時間 [日時状態]\n\n")
       (dolist (record ordered)
         (let ((time (tategaki-timeline-resolve record records)))
           (insert (format "%s  " (plist-get record :label)))
           (tategaki-world-insert-reference (plist-get record :source))
           (insert (format " → %s [%s]  " (if time (format-time-string "%Y-%m-%d %H:%M" time t) "不明")
                           (plist-get record :time-status)))
           (insert (format "[%s] " (or (plist-get record :state) "author-confirmed")))
           (when (equal (plist-get record :state) "inferred")
             (tategaki-world--button "採用" (lambda () (tategaki-timeline-set-state (plist-get record :id) "author-confirmed") (tategaki-timeline)))
             (tategaki-world--button "却下" (lambda () (tategaki-timeline-set-state (plist-get record :id) "rejected") (tategaki-timeline))))
           (tategaki-world--button "編集" (lambda () (tategaki-timeline-add record)))
           (tategaki-world--button "位置更新" (lambda () (tategaki-timeline-upsert
                                                         (plist-put (copy-tree record) :source (tategaki-world-source-reference)))
                                                (tategaki-timeline)))
           (insert (format "\n  根拠: %s%s\n" (plist-get (plist-get record :source) :quote)
                           (if (plist-get record :anchor-label)
                               (format " / 基準候補: %s / 差: %s分" (plist-get record :anchor-label)
                                       (plist-get record :offset-minutes)) "")))))
       (unless ordered (insert "場面を登録すると、回想を含む作品時間と原稿順を比較できます。\n"))))))

(provide 'tategaki-timeline)
;;; tategaki-timeline.el ends here
