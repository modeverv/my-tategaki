;;; tategaki-studio.el --- Optional novel writing workspace -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Studio owns UI and lifecycle only.  Every action delegates to a command;
;; the ordinary manuscript buffer remains the source of truth.

;;; Code:
(require 'cl-lib)
(require 'button)
(require 'tategaki-pane)
(require 'tategaki)
(require 'tategaki-project)
(require 'tategaki-history)
(require 'tategaki-session)
(require 'tategaki-proofread)

(autoload 'tategaki-settings "tategaki-settings" nil t)
(autoload 'tategaki-lookup-word "tategaki-lookup" nil t)
(autoload 'tategaki-assistant "tategaki-assistant" nil t)
(autoload 'tategaki-world "tategaki-world" nil t)
(autoload 'tategaki-timeline "tategaki-timeline" nil t)
(autoload 'tategaki-foreshadow "tategaki-foreshadow" nil t)
(autoload 'tategaki-voice "tategaki-voice" nil t)
(autoload 'tategaki-knowledge-compare "tategaki-knowledge" nil t)
(autoload 'tategaki-corpus "tategaki-corpus" nil t)
(autoload 'tategaki-semantic-search "tategaki-semantic" nil t)
(autoload 'tategaki-scene-branch "tategaki-diff" nil t)
(autoload 'tategaki-review "tategaki-review" nil t)
(autoload 'tategaki-reader-mode "tategaki-reader" nil t)
(declare-function tategaki-reader-quit "tategaki-reader" ())
(autoload 'tategaki-tts-play "tategaki-tts" nil t)
(autoload 'tategaki-tts-pause "tategaki-tts" nil t)
(autoload 'tategaki-tts-resume "tategaki-tts" nil t)
(autoload 'tategaki-tts-read-region "tategaki-tts" nil t)
(autoload 'tategaki-tts-stop "tategaki-tts" nil t)

(defvar-local tategaki-studio-source nil
  "Manuscript buffer associated with a Studio tool buffer.")
(defvar-local tategaki-studio-state 'write)
(defvar-local tategaki-studio--saved nil)
(defvar-local tategaki-studio--windows nil)
(defvar-local tategaki-studio--review-windows nil)
(defvar-local tategaki-studio--starting nil)
(defvar tategaki-studio-mode)

(defun tategaki-studio-source-buffer (&optional buffer)
  "Return the manuscript associated with BUFFER or the current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (let ((source (or tategaki-studio-source
                      (and (boundp 'tategaki-outline--source)
                           tategaki-outline--source)
                      (and (not (derived-mode-p 'special-mode)) (current-buffer)))))
      (unless (buffer-live-p source) (user-error "原稿を開いてください"))
      source)))

(defun tategaki-studio-command (command &optional source)
  "Run COMMAND interactively in SOURCE's manuscript window."
  (let* ((buffer (tategaki-studio-source-buffer source))
         (window (or (get-buffer-window buffer) (display-buffer buffer))))
    (select-window window)
    (call-interactively command)))

(defun tategaki-studio--button (label command)
  "Make a header-line LABEL delegating to COMMAND in its source window."
  (let ((source (current-buffer)) (map (make-sparse-keymap)))
    (define-key map [header-line mouse-1]
                (lambda (event)
                  (interactive "e")
                  (when (windowp (posn-window (event-start event)))
                    (select-window (posn-window (event-start event))))
                  (tategaki-studio-command command source)))
    (propertize (concat " " label " ") 'local-map map
                'mouse-face 'highlight 'help-echo (symbol-name command)
                'face 'mode-line-emphasis)))

(defun tategaki-studio--toolbar ()
  "Return the clickable toolbar for the current Studio state."
  (let ((items (if (eq tategaki-studio-state 'write)
                   '(("原稿" . tategaki-studio-menu)
                     ("目次" . tategaki-studio-toggle-outline)
                     ("Review" . tategaki-studio-review)
                     ("⚙設定" . tategaki-settings))
                 '(("原稿" . tategaki-studio-menu)
                   ("目次" . tategaki-studio-toggle-outline)
                   ("検索" . tategaki-studio-search)
                   ("辞書" . tategaki-lookup-word)
                   ("校正" . tategaki-diagnostics-list)
                   ("人物" . tategaki-world)
                   ("履歴" . tategaki-history)
                   ("AI" . tategaki-assistant)
                   ("音読" . tategaki-tts-play)
                   ("出力" . tategaki-export)
                   ("⚙設定" . tategaki-settings)
                   ("Write" . tategaki-studio-write)))))
    ;; Keep settings and returning to Write reachable even in narrow Review
    ;; windows.  The manuscript menu always exposes the complete action list.
    (when (and (eq tategaki-studio-state 'review)
               (< (window-body-width) 85))
      (setq items '(("原稿" . tategaki-studio-menu)
                    ("目次" . tategaki-studio-toggle-outline)
                    ("校正" . tategaki-diagnostics-list)
                    ("AI" . tategaki-assistant)
                    ("⚙設定" . tategaki-settings)
                    ("Write" . tategaki-studio-write))))
    (mapconcat (lambda (entry) (tategaki-studio--button (car entry) (cdr entry)))
               items " ")))

(defun tategaki-studio--status ()
  "Return manuscript statistics using the renderer's cached document model."
  (let ((stats (tategaki-manuscript-statistics)))
    (format " %s字%s   %s   %s/%s頁 "
            (plist-get stats :characters)
            (if (plist-get stats :target)
                (format " / %s" (plist-get stats :target)) "")
            (or (plist-get stats :chapter-title) "")
            (or (plist-get stats :current-page) 1)
            (or (plist-get stats :total-pages) 1))))

(defun tategaki-studio-set-state (state)
  "Switch the current manuscript to STATE, either `write' or `review'."
  (unless (memq state '(write review)) (user-error "Unknown Studio state: %s" state))
  (let* ((source (tategaki-studio-source-buffer))
         (window (or (get-buffer-window source) (display-buffer source))))
    (select-window window)
    (with-current-buffer source
      (unless tategaki-studio-mode (tategaki-studio-mode 1))
      (cond
       ((eq state 'write)
        (when (eq tategaki-studio-state 'review)
          (setq tategaki-studio--review-windows (current-window-configuration)))
        (dolist (side (window-list))
          (when (and (window-parameter side 'window-side)
                     (not (eq (window-buffer side) tategaki-outline--buffer)))
            (delete-window side)))
        (delete-other-windows window))
       ((not (eq tategaki-studio-state 'review))
        (if (and tategaki-studio--review-windows
                 (eq (window-configuration-frame tategaki-studio--review-windows)
                     (selected-frame)))
            (set-window-configuration tategaki-studio--review-windows)
          (tategaki-outline)
          (select-window window))))
      (setq tategaki-studio-state state)
      (force-mode-line-update)
      (tategaki-refresh))))

;;;###autoload
(defun tategaki-studio-write ()
  "Focus the manuscript, retaining its visible outline and hiding review tools."
  (interactive) (tategaki-studio-set-state 'write))

;;;###autoload
(defun tategaki-studio-toggle-outline ()
  "Show or close this manuscript's outline without interrupting writing."
  (interactive)
  (let* ((source (tategaki-studio-source-buffer))
         (window (or (get-buffer-window source) (display-buffer source))))
    (with-current-buffer source
      (if (and (buffer-live-p tategaki-outline--buffer)
               (get-buffer-window tategaki-outline--buffer (selected-frame)))
          (tategaki-outline-cleanup)
        (save-selected-window (tategaki-outline))))
    (when (window-live-p window) (select-window window))
    (force-mode-line-update)))

;;;###autoload
(defun tategaki-studio-review ()
  "Show the manuscript with its review tools."
  (interactive) (tategaki-studio-set-state 'review))

(defun tategaki-studio-toggle-review ()
  "Toggle writing and reviewing layouts."
  (interactive)
  (with-current-buffer (tategaki-studio-source-buffer)
    (tategaki-studio-set-state (if (eq tategaki-studio-state 'write) 'review 'write))))

(defun tategaki-studio-search ()
  "Search the ordinary source buffer using Emacs search."
  (interactive) (isearch-forward))

(defun tategaki-studio--save-session ()
  "Save position at a lifecycle boundary without disrupting editing."
  (when (and tategaki-studio-mode buffer-file-name (not tategaki-studio--starting))
    (condition-case err (tategaki-session-save)
      (error (message "Studio: セッション保存失敗: %s" (error-message-string err))))))

(defun tategaki-studio--exit ()
  "Release Studio when the source buffer changes mode or closes."
  (when tategaki-studio-mode (tategaki-studio-mode -1)))

(defvar tategaki-studio-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c s w") #'tategaki-studio-write)
    (define-key map (kbd "C-c s r") #'tategaki-studio-review)
    (define-key map (kbd "C-c s o") #'tategaki-studio-toggle-outline)
    (define-key map (kbd "C-c s s") #'tategaki-settings)
    (define-key map (kbd "C-c s h") #'tategaki-history)
    (define-key map (kbd "C-c s d") #'tategaki-lookup-word)
    (define-key map (kbd "C-c s p") #'tategaki-diagnostics-list)
    (define-key map (kbd "C-c s a") #'tategaki-assistant)
    (define-key map (kbd "C-c s m") #'tategaki-studio-menu)
    (define-key map (kbd "C-c s t") #'tategaki-timeline)
    (define-key map (kbd "C-c s f") #'tategaki-foreshadow)
    (define-key map (kbd "C-c s v") #'tategaki-voice)
    (define-key map (kbd "C-c s k") #'tategaki-knowledge-compare)
    (define-key map (kbd "C-c s c") #'tategaki-corpus)
    (define-key map (kbd "C-c s /") #'tategaki-semantic-search)
    (define-key map (kbd "C-c s b") #'tategaki-scene-branch)
    (define-key map (kbd "C-c s .") #'tategaki-tts-stop)
    map))

;;;###autoload
(define-minor-mode tategaki-studio-mode
  "Use optional Novel IDE tools around the ordinary manuscript buffer."
  :lighter " Studio" :keymap tategaki-studio-mode-map
  (if tategaki-studio-mode
      (unless tategaki-studio--saved
        (unless (derived-mode-p 'text-mode)
          (setq tategaki-studio-mode nil)
          (user-error "Studio requires a text buffer"))
        (setq tategaki-studio--saved
              (mapcar (lambda (symbol)
                        (list symbol (local-variable-p symbol) (symbol-value symbol)))
                      '(header-line-format mode-line-format)))
        (setq tategaki-studio--windows (current-window-configuration)
              tategaki-studio-state 'write)
        (let ((vertical-before tategaki-mode)
              (tategaki-studio--starting t))
          (condition-case error-data
              (progn
                (tategaki-project-apply-settings)
                (tategaki-mode 1)
                (setq-local header-line-format '(:eval (tategaki-studio--toolbar)))
                (setq-local mode-line-format '((:eval (tategaki-studio--status))))
                (tategaki-history-mode 1)
                (tategaki-proofread-mode 1)
                (add-hook 'after-save-hook #'tategaki-studio--save-session nil t)
                (add-hook 'kill-buffer-hook #'tategaki-studio--exit nil t)
                (add-hook 'change-major-mode-hook #'tategaki-studio--exit nil t)
                (tategaki-studio-set-state 'write))
            (error
             (tategaki-studio-mode -1)
             (unless vertical-before (tategaki-mode -1))
             (signal (car error-data) (cdr error-data))))))
    (when tategaki-studio--saved
      (when (and (bound-and-true-p tategaki-reader-mode)
                 (fboundp 'tategaki-reader-quit))
        (tategaki-reader-quit))
      ;; Save the last Studio state, even though define-minor-mode already
      ;; changed its flag before reaching this branch.
      (let ((tategaki-studio-mode t)) (tategaki-studio--save-session))
      (tategaki-history-mode -1)
      (tategaki-proofread-mode -1)
      (tategaki-diagnostics-clear)
      (dolist (entry tategaki-studio--saved)
        (if (nth 1 entry) (set (make-local-variable (car entry)) (nth 2 entry))
          (kill-local-variable (car entry))))
      (setq tategaki-studio--saved nil)
      (remove-hook 'after-save-hook #'tategaki-studio--save-session t)
      (remove-hook 'kill-buffer-hook #'tategaki-studio--exit t)
      (remove-hook 'change-major-mode-hook #'tategaki-studio--exit t)
      (when (and tategaki-studio--windows
                 (frame-live-p (window-configuration-frame tategaki-studio--windows)))
        (set-window-configuration tategaki-studio--windows))
      (setq tategaki-studio--windows nil tategaki-studio--review-windows nil)
      (force-mode-line-update))))

(defun tategaki-studio-new ()
  "Start a new manuscript without writing a file until the user saves it."
  (interactive)
  (switch-to-buffer (generate-new-buffer "新しい小説.txt"))
  (text-mode)
  (tategaki-studio-mode 1)
  (tategaki-studio-write))

(defun tategaki-studio-open (file)
  "Open FILE as a Studio manuscript."
  (interactive "f原稿を開く: ")
  (find-file file)
  (unless (derived-mode-p 'text-mode) (text-mode))
  (tategaki-studio-mode 1)
  (tategaki-studio-write))

(define-derived-mode tategaki-studio-menu-mode special-mode "Studio"
  "Clickable entry point for manuscript commands."
  (setq-local truncate-lines nil))

(defun tategaki-studio--insert-action (label command &optional source)
  "Insert LABEL as a button invoking COMMAND in SOURCE when supplied."
  (insert-text-button label 'follow-link t
                      'action (lambda (_)
                                (if source (tategaki-studio-command command source)
                                  (call-interactively command))))
  (insert "\n\n"))

(defun tategaki-studio-welcome ()
  "Show the clickable start screen and recent manuscripts."
  (interactive)
  (let ((buffer (get-buffer-create "*my-tategaki*")))
    (with-current-buffer buffer
      (tategaki-studio-menu-mode)
      (tategaki-pane-install nil nil "my-tategaki")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "\n  my-tategaki\n  小説を書くためのワークスペース\n\n")
        (tategaki-studio--insert-action "新しい小説を書く" #'tategaki-studio-new)
        (tategaki-studio--insert-action "原稿を開く" #'tategaki-studio-open)
        (tategaki-studio--insert-action "前回の原稿を復元" #'tategaki-session-open-last)
        (insert "最近の原稿\n\n")
        (dolist (file (tategaki-session-recent-files 10))
          (insert-text-button (abbreviate-file-name file) 'follow-link t
                              'action (lambda (_) (tategaki-studio-open file)))
          (insert "\n\n"))
        (tategaki-studio--insert-action
         "⚙ 設定" (lambda () (interactive)
                    (tategaki-studio-new) (tategaki-settings)))
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(defun tategaki-studio-menu ()
  "Show all manuscript actions as clickable buttons."
  (interactive)
  (let ((source (tategaki-studio-source-buffer))
        (buffer (get-buffer-create "*Tategaki 原稿*")))
    (with-current-buffer buffer
      (tategaki-studio-menu-mode)
      (setq-local tategaki-studio-source source)
      (tategaki-pane-install source nil "原稿の操作")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "原稿の操作\n\n")
        (dolist (item '(("保存" . save-buffer)
                        ("Write — 執筆に集中" . tategaki-studio-write)
                        ("Review — 推敲" . tategaki-studio-review)
                        ("目次・アウトライン" . tategaki-studio-toggle-outline)
                        ("検索" . tategaki-studio-search)
                        ("辞書" . tategaki-lookup-word)
                        ("校正" . tategaki-diagnostics-list)
                        ("人物・設定" . tategaki-world)
                        ("時系列" . tategaki-timeline)
                        ("伏線" . tategaki-foreshadow)
                        ("人物の話し方" . tategaki-voice)
                        ("読者と人物の知識を比較" . tategaki-knowledge-compare)
                        ("作品・資料の横断検索" . tategaki-corpus)
                        ("関連箇所を検索" . tategaki-semantic-search)
                        ("この場面の別案を作る" . tategaki-scene-branch)
                        ("履歴" . tategaki-history)
                        ("AI に相談" . tategaki-assistant)
                        ("音読" . tategaki-tts-play)
                        ("選択範囲を音読" . tategaki-tts-read-region)
                        ("音読を一時停止" . tategaki-tts-pause)
                        ("音読を再開" . tategaki-tts-resume)
                        ("音読を止める" . tategaki-tts-stop)
                        ("Reader" . tategaki-reader-mode)
                        ("レビュー一覧" . tategaki-review)
                        ("出力" . tategaki-export)
                        ("⚙ 設定" . tategaki-settings)
                        ("Studio を終了" . tategaki-studio-mode)))
          (tategaki-studio--insert-action (car item) (cdr item) source))
        (tategaki-studio--insert-action "別の原稿を開く" #'tategaki-studio-open)
        (goto-char (point-min))))
    (select-window (display-buffer-in-side-window buffer '((side . right) (slot . 0))))))

;;;###autoload
(defun tategaki-studio (&optional source)
  "Start Studio in SOURCE, current text manuscript, or the welcome screen."
  (interactive)
  (if (or source (derived-mode-p 'text-mode))
      (progn
        (when source (switch-to-buffer source))
        (tategaki-studio-mode 1)
        (tategaki-studio-write))
    (tategaki-studio-welcome)))

(provide 'tategaki-studio)
;;; tategaki-studio.el ends here
