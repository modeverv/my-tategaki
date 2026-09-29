;;; tategaki-review.el --- Unified novel review dashboard -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'tategaki-pane)
(require 'cl-lib)
(require 'button)
(require 'tategaki-diagnostics)
(require 'tategaki-proofread)
(autoload 'tategaki-world "tategaki-world" nil t)
(autoload 'tategaki-world-check "tategaki-world" nil t)
(autoload 'tategaki-timeline "tategaki-timeline" nil t)
(autoload 'tategaki-foreshadow "tategaki-foreshadow" nil t)
(autoload 'tategaki-voice "tategaki-voice" nil t)
(autoload 'tategaki-voice-check "tategaki-voice" nil t)
(autoload 'tategaki-assistant "tategaki-assistant" nil t)
(autoload 'tategaki-tts-play "tategaki-tts" nil t)
(autoload 'tategaki-export-status "tategaki-export" nil t)
(defvar-local tategaki-studio-source nil)
(defvar-local tategaki-review--buffer nil)
(defvar-local tategaki-review--checked-tick nil)
(defvar-local tategaki-review--running nil)
(defvar-local tategaki-review--message nil)
(declare-function tategaki-studio-source-buffer "tategaki-studio" (&optional buffer))
(declare-function tategaki-studio-command "tategaki-studio" (command &optional source))

(defun tategaki-review--source ()
  "Return this dashboard's associated manuscript."
  (if (fboundp 'tategaki-studio-source-buffer) (tategaki-studio-source-buffer)
    (or tategaki-studio-source (current-buffer))))

(defun tategaki-review--action (label command source)
  "Insert LABEL invoking COMMAND in SOURCE."
  (insert-text-button
   label 'follow-link t
   'action (lambda (_)
             (if (fboundp 'tategaki-studio-command) (tategaki-studio-command command source)
               (pop-to-buffer source) (call-interactively command))))
  (insert "\n\n"))

(defun tategaki-review--render (source buffer)
  "Render current verified review state for SOURCE into BUFFER."
  (let* ((items (with-current-buffer source (tategaki-diagnostics-get)))
         (count (lambda (kind) (cl-count kind items :key (lambda (d) (plist-get d :source)))))
         (variant-count (cl-count "spelling-variant" items :key (lambda (d) (plist-get d :code)) :test #'equal))
         (status (with-current-buffer source
                   (cond (tategaki-review--running "検査中…")
                         ((null tategaki-review--checked-tick) "未実行")
                         ((/= tategaki-review--checked-tick (buffer-chars-modified-tick)) "原稿変更あり — 再検査してください")
                         (t "検査済み"))))
         (note (buffer-local-value 'tategaki-review--message source)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "レビュー — %s\n%s\n%s\n\n" (buffer-name source) status (or note "")))
        (tategaki-review--action "原稿を検査" #'tategaki-review-run source)
        (tategaki-review--action (format "校正: %d 件（表記揺れ %d 件）" (funcall count 'rule) variant-count)
                                #'tategaki-diagnostics-list source)
        (tategaki-review--action (format "設定整合性: %d 件" (funcall count 'world)) #'tategaki-world source)
        (tategaki-review--action "時系列を確認" #'tategaki-timeline source)
        (tategaki-review--action "伏線・回収を確認" #'tategaki-foreshadow source)
        (tategaki-review--action (format "人物の話し方: %d 件" (funcall count 'voice)) #'tategaki-voice source)
        (tategaki-review--action "AI review: 相談画面で明示的に質問" #'tategaki-assistant source)
        (tategaki-review--action "音読: 再生" #'tategaki-tts-play source)
        (tategaki-review--action "出力: ジョブの結果を確認" #'tategaki-export-status source)
        (insert "自動検査は候補の提示です。指摘をクリックして本文を確認してください。\n")
        (goto-char (point-min))))))

;;;###autoload
(defun tategaki-review ()
  "Open the unified review dashboard without invoking AI or playing audio."
  (interactive)
  (let* ((source (tategaki-review--source))
         (buffer (with-current-buffer source
                   (unless (buffer-live-p tategaki-review--buffer)
                     (setq tategaki-review--buffer
                           (generate-new-buffer (format "*Tategaki Review: %s*" (buffer-name))))
                     (with-current-buffer tategaki-review--buffer
                       (special-mode)
                       (setq-local tategaki-studio-source source)
                       (local-set-key (kbd "g") #'tategaki-review)))
                   tategaki-review--buffer)))
    (tategaki-review--render source buffer)
    (with-current-buffer buffer (tategaki-pane-install source nil "レビュー"))
    (select-window (display-buffer-in-side-window buffer '((side . right) (slot . 2) (window-width . 0.32))))))

(defun tategaki-review-run ()
  "Schedule local proofreading, consistency and voice checks for this source."
  (interactive)
  (let* ((source (tategaki-review--source))
         (tick (buffer-chars-modified-tick source)))
    (with-current-buffer source
      (when tategaki-review--running (user-error "検査中です"))
      (setq tategaki-review--running t tategaki-review--message nil))
    (tategaki-review)
    (run-at-time
     0 nil
     (lambda ()
       (when (buffer-live-p source)
         (with-current-buffer source
           (unwind-protect
               (condition-case err
                   (when (= tick (buffer-chars-modified-tick))
                     (tategaki-proofread-run)
                     (tategaki-world-check)
                     (tategaki-voice-check)
                     (setq tategaki-review--checked-tick tick))
                 (error (setq tategaki-review--message (error-message-string err))))
             (setq tategaki-review--running nil)
             (when (buffer-live-p tategaki-review--buffer)
               (tategaki-review--render source tategaki-review--buffer)))))))))

(provide 'tategaki-review)
;;; tategaki-review.el ends here
