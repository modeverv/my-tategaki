;;; tategaki-settings.el --- Clickable live manuscript preferences -*- lexical-binding: t; -*-

;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; This buffer edits preferences, never manuscript contents.  Display changes
;; preview in the original buffer.  A transaction tracks the opening and last
;; saved state, so cancel also removes temporary session overrides.

;;; Code:
(require 'tategaki-pane)

(require 'cl-lib)
(require 'wid-edit)
(require 'tategaki)
(require 'tategaki-project)
(require 'tategaki-ai)

(autoload 'tategaki-ai-health "tategaki-ai" nil t)
(declare-function tategaki-studio-source-buffer "tategaki-studio" (&optional buffer))
(declare-function tategaki-tts-voices "tategaki-tts" ())

(defvar-local tategaki-settings-source nil)
(defvar-local tategaki-settings--values nil)
(defvar-local tategaki-settings--opening nil)
(defvar-local tategaki-settings--saved nil)
(defvar-local tategaki-settings--saved-values nil)
(defvar-local tategaki-settings--opening-values nil)
(defvar-local tategaki-settings--scope 'project)
(defvar-local tategaki-settings--saved-scope nil)
(defvar-local tategaki-settings--edited-keys nil)
(defvar-local tategaki-settings--pending-keys nil)
(defvar-local tategaki-settings--saved-edited-keys nil)
(defvar-local tategaki-settings--widgets nil)
(defvar-local tategaki-settings--status "")
(defvar-local tategaki-settings--closing nil)
(defvar-local tategaki-settings--allow-kill nil)
(defvar-local tategaki-settings--ai-models nil)
(defvar-local tategaki-settings--ai-model-key nil)
(defvar-local tategaki-settings--ai-request nil)
(defvar-local tategaki-settings--ai-generation nil)
(defvar-local tategaki-settings--ai-status "モデル一覧は未取得です")
(defvar-local tategaki-settings--ai-status-widget nil)
(defvar-local tategaki-settings--paper-draft nil)
(defvar-local tategaki-settings--paper-value 'uninitialized)
(defvar-local tategaki-settings--paper-fields nil)
(defvar-local tategaki-settings--paper-status-widget nil)

(defvar tategaki-settings-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map widget-keymap)
    (define-key map (kbd "q") #'tategaki-settings-close)
    (define-key map (kbd "C-c C-c") #'tategaki-settings-save)
    (define-key map (kbd "C-c C-k") #'tategaki-settings-revert)
    (define-key map (kbd "<backtab>") #'widget-backward)
    map))

(define-derived-mode tategaki-settings-mode special-mode "Tategaki 設定"
  "Preferences with TAB/S-TAB navigation, RET activation and mouse buttons."
  (setq-local buffer-read-only nil)
  (setq-local truncate-lines t)
  ;; Native checkbox images can disappear against custom dark themes.
  (setq-local widget-image-enable nil)
  (setq-local header-line-format " 設定を変更すると原稿へ即時プレビュー  |  TAB 次  S-TAB 前  q 閉じる")
  (add-hook 'kill-buffer-query-functions #'tategaki-settings--kill-query nil t)
  (add-hook 'kill-buffer-hook #'tategaki-settings--cancel-ai-request nil t))

(defun tategaki-settings--ensure-ui ()
  "Require the settings UI before running a settings transaction command."
  (unless (derived-mode-p 'tategaki-settings-mode)
    (user-error "設定画面で実行してください（M-x tategaki-settings）")))

(defun tategaki-settings--source ()
  "Return the live source buffer for this settings transaction."
  (tategaki-settings--ensure-ui)
  (unless (buffer-live-p tategaki-settings-source) (user-error "原稿が閉じられています"))
  tategaki-settings-source)

(defun tategaki-settings--capture ()
  "Capture only settings-owned source values, preserving binding locality."
  (with-current-buffer (tategaki-settings--source)
    (mapcar (lambda (symbol)
              (list symbol (local-variable-p symbol) (boundp symbol)
                    (and (boundp symbol) (copy-tree (symbol-value symbol)))))
            (append (cons 'tategaki-project-session-settings
                          (mapcar #'cadr tategaki-project-setting-specs))
                    '(tategaki-project--inferred-ai-provider)))))

(defun tategaki-settings--restore (snapshot)
  "Restore source settings from SNAPSHOT without editing its text."
  (when (buffer-live-p tategaki-settings-source)
    (with-current-buffer tategaki-settings-source
      (dolist (entry snapshot)
        (pcase-let ((`(,symbol ,local ,bound ,value) entry))
          (cond (local (set (make-local-variable symbol) (copy-tree value)))
                (t (kill-local-variable symbol)
                   ;; Never change a global default while undoing a preview.
                   (unless bound (when (local-variable-p symbol) (makunbound symbol)))))))
      (tategaki-project-refresh))))

(defun tategaki-settings--current-values ()
  "Read effective metadata and current Lisp values from the source."
  (with-current-buffer (tategaki-settings--source)
    (let ((metadata (tategaki-project-metadata)) result)
      (dolist (key tategaki-project-metadata-keys)
        (let* ((property (intern (concat ":" (symbol-name key))))
               (fallback (pcase key
                           ('title (if buffer-file-name (file-name-base buffer-file-name) (buffer-name)))
                           ('language "ja") (_ ""))))
          (push (cons key (if (plist-member metadata property) (plist-get metadata property)
                            (or (and (boundp 'tategaki-export-metadata)
                                     (alist-get key (symbol-value 'tategaki-export-metadata)))
                                fallback))) result)))
      (dolist (spec tategaki-project-setting-specs)
        (push (cons (car spec) (copy-tree (if (boundp (cadr spec))
                                            (symbol-value (cadr spec)) (nth 3 spec)))) result))
      (nreverse result))))

(defun tategaki-settings--data (values)
  "Turn flattened form VALUES into the project data format."
  (let (result settings)
    (dolist (entry values)
      (if (memq (car entry) tategaki-project-metadata-keys)
          (push (copy-tree entry) result)
        (push (copy-tree entry) settings)))
    (when settings (push (cons 'settings (nreverse settings)) result))
    (nreverse result)))

(defun tategaki-settings--changes ()
  "Return values changed since the last save."
  (cl-remove-if (lambda (entry) (equal (cdr entry) (alist-get (car entry) tategaki-settings--saved-values)))
                tategaki-settings--values))

(defun tategaki-settings--save-values ()
  "Return preferences explicitly chosen for the currently selected scope.
An equal value can still be deliberately applied to a new scope.  After
saving, changing scope transfers only keys edited in this settings screen,
using their currently displayed values, never all inherited preferences."
  (let ((keys (append tategaki-settings--pending-keys
                      (unless (eq tategaki-settings--scope tategaki-settings--saved-scope)
                        tategaki-settings--edited-keys))))
    (cl-remove-if
     (lambda (entry)
       (and (not (memq (car entry) keys))
            (equal (cdr entry) (alist-get (car entry) tategaki-settings--saved-values))))
     tategaki-settings--values)))

(defun tategaki-settings--validate-value (key value)
  "Check KEY's VALUE using the same rules for text fields and Lisp calls."
  (unless (if (memq key tategaki-project-metadata-keys)
              (and (stringp value) (<= (length value) 4096))
            (tategaki-project-setting-valid-p key value))
    (user-error "設定値が不正です: %s = %S" key value))
  value)

(defun tategaki-settings--widget-value (widget)
  "Read WIDGET's visible value, rejecting incomplete or invalid numbers."
  (let ((value (widget-value widget)))
    (when (and (eq (widget-type widget) 'editable-field)
               (widget-get widget :tategaki-number))
      (unless (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" value)
        (user-error "数値を入力してください: %s" (widget-get widget :tategaki-key)))
      (setq value (string-to-number value)))
    (tategaki-settings--validate-value (widget-get widget :tategaki-key) value)))

(defun tategaki-settings-set (key value)
  "Set form KEY to VALUE and immediately preview it in the source.
This function, widgets and commands share validation and application."
  (tategaki-settings--ensure-ui)
  (tategaki-settings--validate-value key value)
  (when (and (memq key '(ai-provider ai-endpoint))
             (not (equal value (alist-get key tategaki-settings--values))))
    (tategaki-settings--invalidate-ai-models))
  (setf (alist-get key tategaki-settings--values) (copy-tree value))
  (with-current-buffer (tategaki-settings--source)
    (tategaki-project-save (tategaki-settings--data (list (cons key value))) 'session)
    (when-let* ((spec (assq key tategaki-project-setting-specs)))
      (set (make-local-variable (cadr spec)) value)
      (tategaki-project-refresh)))
  (cl-pushnew key tategaki-settings--edited-keys)
  (cl-pushnew key tategaki-settings--pending-keys)
  (when (eq key 'manuscript-size) (tategaki-settings--paper-reset-draft))
  (when (and (eq key 'ai-provider) (tategaki-ai-provider-endpoint value)
             (tategaki-ai-standard-endpoint-p (alist-get 'ai-endpoint tategaki-settings--values)))
    (tategaki-settings-set 'ai-endpoint (tategaki-ai-provider-endpoint value))
    (when-let* ((widget (alist-get 'ai-endpoint tategaki-settings--widgets)))
      (let ((inhibit-read-only t) (inhibit-modification-hooks t))
        (widget-value-set widget (alist-get 'ai-endpoint tategaki-settings--values)))))
  (setq tategaki-settings--status "プレビュー中 — 保存先を選んで保存してください")
  (force-mode-line-update)
  value)

(defun tategaki-settings--notify (widget &rest _ignore)
  "Preview a WIDGET's value without disrupting field editing."
  (condition-case err
      (tategaki-settings-set (widget-get widget :tategaki-key)
                             (tategaki-settings--widget-value widget))
    (user-error (setq tategaki-settings--status (error-message-string err)))))

(defun tategaki-settings--button (label function &rest arguments)
  "Create a clickable LABEL invoking FUNCTION with ARGUMENTS."
  (widget-create 'push-button :notify (lambda (&rest _) (apply function arguments)) label))

(defun tategaki-settings--field (key label &optional numeric)
  "Create an editable KEY field with LABEL and optional NUMERIC parsing."
  (let* ((value (alist-get key tategaki-settings--values))
         (widget (widget-create 'editable-field :size (if numeric 7 32)
                                :format (if numeric "%v" (concat "  " label "  %v\n"))
                                :tategaki-key key :tategaki-number numeric
                                :notify #'tategaki-settings--notify
                                (if numeric (format "%s" (or value 0)) (or value "")))))
    (push (cons key widget) tategaki-settings--widgets)
    widget))

(defun tategaki-settings--step (key amount)
  "Change numeric preference KEY by AMOUNT, then update the form."
  (let* ((spec (assq key tategaki-project-setting-specs))
         (minimum (if (eq (nth 2 spec) 'rate) 0.1 (if (eq key 'text-scale) -12 0)))
         (value (max minimum (+ (or (alist-get key tategaki-settings--values) 0) amount))))
    (when (eq (nth 2 spec) 'rate) (setq value (/ (round (* value 10)) 10.0)))
    (tategaki-settings-set key value)
    (tategaki-settings--render)))

(defun tategaki-settings--number (key label &optional step)
  "Create LABEL with minus/plus controls for KEY by STEP."
  (widget-insert (format "  %-12s " label))
  (tategaki-settings--button "−" #'tategaki-settings--step key (- (or step 1)))
  (widget-insert "  ")
  (if (eq key 'text-scale)
      (widget-insert (format "%s%%" (round (* 100 (expt text-scale-mode-step
                                                        (alist-get key tategaki-settings--values))))))
    (tategaki-settings--field key label t))
  (widget-insert "  ")
  (tategaki-settings--button "＋" #'tategaki-settings--step key (or step 1))
  (when (eq key 'text-scale)
    (widget-insert "  ")
    (tategaki-settings--button "リセット"
                               (lambda () (tategaki-settings-set 'text-scale 0)
                                 (tategaki-settings--render))))
  (widget-insert "\n"))

(defun tategaki-settings--checkbox (key label)
  "Create a checkbox for KEY labelled LABEL."
  (widget-insert "  ")
  (let ((widget (widget-create 'checkbox :value (alist-get key tategaki-settings--values)
                               :tategaki-key key :notify #'tategaki-settings--notify)))
    (push (cons key widget) tategaki-settings--widgets))
  (widget-insert (concat " " label "\n")))

(defun tategaki-settings--choice (key label choices &optional value-button)
  "Create a labelled KEY menu from CHOICES, (LABEL . VALUE) pairs.
With VALUE-BUTTON, make the displayed value an explicit dropdown button."
  ;; Lisp users may have a valid custom paper size or history interval.
  (let ((current (alist-get key tategaki-settings--values)))
    (unless (cl-find current choices :key #'cdr :test #'equal)
      (setq choices (cons (cons (format "現在の値: %S" current) current) choices))))
  (let ((widget (apply #'widget-create 'menu-choice :tag label
                       :format (if value-button "  %t: %[[%v ▼]%]\n" "  %[%t%]: %v\n")
                       :value (alist-get key tategaki-settings--values)
                       :tategaki-key key :notify #'tategaki-settings--notify
                       (mapcar (lambda (entry)
                                 `(const :tag ,(car entry)
                                         ,@(when value-button '(:format "%t")) ,(cdr entry))) choices))))
    (push (cons key widget) tategaki-settings--widgets)))

(defun tategaki-settings--heading (text)
  "Insert a section heading TEXT."
  (widget-insert (propertize (concat "\n" text "\n") 'face 'bold)))

(defun tategaki-settings--paper-strings (size)
  "Return SIZE's editable vertical-character and column strings."
  (if size (cons (number-to-string (car size)) (number-to-string (cdr size)))
    (cons "" "")))

(defun tategaki-settings--paper-draft-p ()
  "Whether the paper dimensions have input that has not been applied."
  (and tategaki-settings--paper-draft
       (not (equal tategaki-settings--paper-draft
                   (tategaki-settings--paper-strings
                    (alist-get 'manuscript-size tategaki-settings--values))))))

(defun tategaki-settings--paper-status (&optional message)
  "Display MESSAGE, or the current paper draft status, beside its fields."
  (when-let* ((widget tategaki-settings--paper-status-widget))
    (let ((inhibit-read-only t) (inhibit-modification-hooks t))
      (widget-value-set
       widget (or message
                  (if (tategaki-settings--paper-draft-p)
                      "未適用 — 各1〜200の整数を入力し、[寸法を適用]を押してください"
                    (if (alist-get 'manuscript-size tategaki-settings--values)
                        "適用済み — 保存先を選んで保存できます"
                      "フリー — 文字サイズを優先し、画面に応じて字数・列数を決めます")))))))

(defun tategaki-settings--paper-reset-draft ()
  "Replace paper inputs with the currently applied manuscript dimensions."
  (setq tategaki-settings--paper-value
        (copy-tree (alist-get 'manuscript-size tategaki-settings--values))
        tategaki-settings--paper-draft
        (tategaki-settings--paper-strings tategaki-settings--paper-value))
  (dolist (entry tategaki-settings--paper-fields)
    (let ((inhibit-read-only t) (inhibit-modification-hooks t))
      (widget-value-set (cdr entry)
                        (if (eq (car entry) 'rows) (car tategaki-settings--paper-draft)
                          (cdr tategaki-settings--paper-draft)))))
  (tategaki-settings--paper-status))

(defun tategaki-settings--paper-notify (widget &rest _)
  "Retain WIDGET input without changing the applied paper size or source."
  (if (eq (widget-get widget :tategaki-paper-axis) 'rows)
      (setcar tategaki-settings--paper-draft (widget-value widget))
    (setcdr tategaki-settings--paper-draft (widget-value widget)))
  (tategaki-settings--paper-status))

(defun tategaki-settings-apply-paper-size ()
  "Validate both draft dimensions and apply the pair as one preference change."
  (interactive)
  (tategaki-settings--ensure-ui)
  (condition-case err
      (let* ((rows (string-trim (car tategaki-settings--paper-draft)))
             (columns (string-trim (cdr tategaki-settings--paper-draft)))
             (size (and (string-match-p "\\`[0-9]+\\'" rows)
                        (string-match-p "\\`[0-9]+\\'" columns)
                        (cons (string-to-number rows) (string-to-number columns)))))
        (unless (and size (tategaki-project-setting-valid-p 'manuscript-size size))
          (user-error "縦字数と列数をそれぞれ1〜200の整数で入力してください"))
        (tategaki-settings-set 'manuscript-size size)
        (tategaki-settings--render))
    (user-error
     (tategaki-settings--paper-status (error-message-string err))
     (signal (car err) (cdr err)))))

(defun tategaki-settings--paper-controls ()
  "Render presets and a two-field draft editor for custom paper dimensions."
  (setq tategaki-settings--paper-fields nil tategaki-settings--paper-status-widget nil)
  (unless (equal tategaki-settings--paper-value (alist-get 'manuscript-size tategaki-settings--values))
    (tategaki-settings--paper-reset-draft))
  (tategaki-settings--choice 'manuscript-size "原稿用紙"
                             '(("フリー（文字サイズ優先）" . nil) ("20×20" 20 . 20)
                               ("40×30" 40 . 30) ("40×40" 40 . 40)))
  (widget-insert "  縦字数 ")
  (push (cons 'rows (widget-create 'editable-field :size 5 :format "%v"
                                   :tategaki-paper-axis 'rows :notify #'tategaki-settings--paper-notify
                                   (car tategaki-settings--paper-draft)))
        tategaki-settings--paper-fields)
  (widget-insert "\n  列数   ")
  (push (cons 'columns (widget-create 'editable-field :size 5 :format "%v"
                                      :tategaki-paper-axis 'columns :notify #'tategaki-settings--paper-notify
                                      (cdr tategaki-settings--paper-draft)))
        tategaki-settings--paper-fields)
  (widget-insert "\n  ")
  (tategaki-settings--button "寸法を適用" #'tategaki-settings-apply-paper-size)
  (widget-insert "\n  ")
  (setq tategaki-settings--paper-status-widget (widget-create 'item :format "%v\n" ""))
  (tategaki-settings--paper-status))

(defun tategaki-settings--render ()
  "Render settings widgets, retaining scroll position when possible."
  (let ((inhibit-read-only t) (inhibit-modification-hooks t) (old-point (point))
        (window (get-buffer-window (current-buffer)))
        (old-start (when-let* ((window (get-buffer-window (current-buffer)))) (window-start window))))
    (setq widget-field-list nil widget-field-new nil
          tategaki-settings--paper-fields nil tategaki-settings--paper-status-widget nil)
    (remove-overlays)
    (erase-buffer)
    (setq tategaki-settings--widgets nil)
    (widget-insert (propertize "my-tategaki 設定\n" 'face '(:height 1.3 :weight bold)))
    (widget-insert (format "原稿: %s\n" (if (buffer-live-p tategaki-settings-source)
                                           (buffer-name tategaki-settings-source) "閉じられた原稿")))
    (if tategaki-settings--closing
        (progn
          (widget-insert "\n変更を保存しますか？\n\n")
          (tategaki-settings--button "保存して閉じる" #'tategaki-settings--save-and-close)
          (widget-insert "  ")
          (tategaki-settings--button "保存せず閉じる" #'tategaki-settings-discard)
          (widget-insert "  ")
          (tategaki-settings--button "戻る" (lambda () (setq tategaki-settings--closing nil)
                                               (tategaki-settings--render))))
      (tategaki-settings--button "元に戻す" #'tategaki-settings-revert)
      (widget-insert "  ")
      (tategaki-settings--button "保存" #'tategaki-settings-save)
      (widget-insert "  ")
      (tategaki-settings--button "閉じる" #'tategaki-settings-close)
      (widget-insert (concat "\n" tategaki-settings--status "\n"))
      (tategaki-settings--heading "作品")
      (dolist (entry '((title . "タイトル") (author . "著者名")
                       (language . "言語") (identifier . "識別子")))
        (tategaki-settings--field (car entry) (cdr entry)))
      (tategaki-settings--heading "表示")
      (tategaki-settings--number 'text-scale "文字サイズ")
      (let* ((current (alist-get 'font-family tategaki-settings--values))
             (families (delete-dups (append (and current (list current))
                                           (and (display-graphic-p) (font-family-list))))))
        (tategaki-settings--choice 'font-family "フォント"
                                   (cons '("エディタの既定値" . nil)
                                         (mapcar (lambda (font) (cons font font))
                                                 (sort families #'string-lessp)))))
      (tategaki-settings--paper-controls)
      (tategaki-settings--checkbox 'manuscript-fit-window "用紙全体を画面に収める")
      (widget-insert "  OFFでは文字サイズを優先。収まらない列は横スクロール。\n")
      (widget-insert "  縦20字などが画面高に収まる大きさが拡大の上限です。\n")
      (tategaki-settings--checkbox 'manuscript-grid "原稿用紙罫線")
      (tategaki-settings--checkbox 'manuscript-spread "見開き")
      (tategaki-settings--number 'character-spacing "文字間")
      (tategaki-settings--number 'line-spacing "行間")
      (dolist (entry '((padding-top . "上余白") (padding-bottom . "下余白")
                       (padding-left . "左余白") (padding-right . "右余白")))
        (tategaki-settings--number (car entry) (cdr entry)))
      (tategaki-settings--heading "執筆")
      (tategaki-settings--checkbox 'writing-auto-indent "自動字下げ")
      (tategaki-settings--checkbox 'writing-electric-pair "括弧補完")
      (tategaki-settings--checkbox 'history-enabled "自動履歴")
      (tategaki-settings--choice 'history-idle-interval "保存間隔"
                                 '(("1分" . 60) ("3分" . 180) ("5分" . 300)
                                   ("10分" . 600) ("保存時のみ" . nil)))
      (tategaki-settings--heading "校正")
      (tategaki-settings--checkbox 'proofread-enabled "ルールベース校正")
      (tategaki-settings--checkbox 'proofread-live "入力中にリアルタイム校正")
      (tategaki-settings--number 'proofread-max-sentence-length "一文の警告文字数" 10)
      (tategaki-settings--heading "AI")
      (tategaki-settings--checkbox 'ai-enabled "ローカルLLMを使用")
      (tategaki-settings--choice 'ai-provider "Provider"
                                 '(("Ollama" . ollama) ("OpenAI-compatible" . openai-compatible)
                                   ("LM Studio" . lm-studio) ("llama.cpp" . llama-cpp)) t)
      (tategaki-settings--field 'ai-endpoint "Endpoint")
      (widget-insert "  ")
      (tategaki-settings--button "標準URLを使う" #'tategaki-settings-use-ai-preset)
      (widget-insert "  ")
      (tategaki-settings--button "モデル一覧を取得" #'tategaki-settings-fetch-models)
      (widget-insert "  ")
      (tategaki-settings--button "接続テスト" #'tategaki-settings-test-ai)
      (widget-insert "\n  ")
      (setq tategaki-settings--ai-status-widget
            (widget-create 'item :format "%v\n" tategaki-settings--ai-status))
      (tategaki-settings--field 'ai-model "Model")
      (widget-insert "  ")
      (tategaki-settings--button "一覧からModelを選択" #'tategaki-settings-choose-model 'ai-model)
      (widget-insert "\n")
      (tategaki-settings--field 'ai-embedding-model "Embedding Model")
      (widget-insert "  ")
      (tategaki-settings--button "一覧からEmbeddingを選択" #'tategaki-settings-choose-model 'ai-embedding-model)
      (widget-insert "\n  名前は自由入力もできます。一覧だけではモデルの用途を判別しません。\n")
      (widget-insert "  標準URL以外はProvider変更時にも保持します。\n")
      (widget-insert "  既定では外部送信しません。外部接続先への本文送信には確認が必要です。\n")
      (tategaki-settings--heading "音読")
      (tategaki-settings--field 'tts-voice "Voice")
      (widget-insert "  ")
      (tategaki-settings--button "利用可能なVoice" #'tategaki-settings-choose-voice)
      (widget-insert "\n")
      (tategaki-settings--number 'tts-rate "速度" 0.1)
      (tategaki-settings--heading "設定の保存先")
      (widget-create 'radio-button-choice :value tategaki-settings--scope
                     :notify (lambda (widget &rest _) (setq tategaki-settings--scope (widget-value widget)))
                     '(item :tag "このセッションだけ（現在の原稿）" session)
                     '(item :tag "この作品（.tategaki/project.json）" project)
                     '(item :tag "全作品の既定値（作品・セッション設定が優先）" default))
      (widget-insert "\n")
      (tategaki-settings--button "元に戻す" #'tategaki-settings-revert)
      (widget-insert "  ")
      (tategaki-settings--button "保存" #'tategaki-settings-save)
      (widget-insert "  ")
      (tategaki-settings--button "閉じる" #'tategaki-settings-close))
    (widget-setup)
    (set-buffer-modified-p nil)
    (goto-char (min old-point (point-max)))
    (when (and (window-live-p window) old-start)
      (set-window-start window (min old-start (point-max)) t))))

(defun tategaki-settings-save ()
  "Save explicitly edited preferences to the selected scope."
  (interactive)
  (tategaki-settings--ensure-ui)
  (when (tategaki-settings--paper-draft-p)
    (setq tategaki-settings--closing nil
          tategaki-settings--status "原稿用紙の入力が未適用です。[寸法を適用]を押してから保存してください")
    (tategaki-settings--render)
    (user-error "%s" tategaki-settings--status))
  ;; Never silently replace a visibly invalid entry with an older valid value.
  (dolist (entry tategaki-settings--widgets)
    (tategaki-settings--widget-value (cdr entry)))
  (let* ((values (tategaki-settings--save-values))
         (data (tategaki-settings--data values))
         (scope tategaki-settings--scope))
    (if (not values)
        (setq tategaki-settings--status "保存する変更はありません")
      ;; Persist first.  A failed write must retain both preview and save intent.
      (unless (eq scope 'session)
        (with-current-buffer (tategaki-settings--source) (tategaki-project-save data scope)))
      (tategaki-settings--restore tategaki-settings--saved)
      (with-current-buffer (tategaki-settings--source)
        (when (eq scope 'session) (tategaki-project-save data 'session))
        (tategaki-project-apply-settings))
      (dolist (entry values) (cl-pushnew (car entry) tategaki-settings--edited-keys))
      (setq tategaki-settings--values (tategaki-settings--current-values)
            tategaki-settings--saved-values (copy-tree tategaki-settings--values)
            tategaki-settings--saved (tategaki-settings--capture)
            tategaki-settings--saved-scope scope
            tategaki-settings--saved-edited-keys (copy-sequence tategaki-settings--edited-keys)
            tategaki-settings--pending-keys nil
            tategaki-settings--status "保存しました"))
    (tategaki-settings--render)))

(defun tategaki-settings-revert ()
  "Restore the settings shown when this screen was first opened.
Previously saved files change only if Save is pressed again."
  (interactive)
  (tategaki-settings--ensure-ui)
  (tategaki-settings--invalidate-ai-models)
  (tategaki-settings--restore tategaki-settings--opening)
  (setq tategaki-settings--values (copy-tree tategaki-settings--opening-values)
        tategaki-settings--closing nil
        tategaki-settings--pending-keys nil
        tategaki-settings--edited-keys (copy-sequence tategaki-settings--saved-edited-keys))
  (tategaki-settings--paper-reset-draft)
  ;; Keep metadata in sync with the opening preview, including after a save.
  (let ((data (tategaki-settings--data tategaki-settings--opening-values)))
    (with-current-buffer (tategaki-settings--source)
      (tategaki-project-save data 'session)))
  (setq tategaki-settings--status "画面を開いた時点へ戻しました")
  (tategaki-settings--render))

(defun tategaki-settings--finish ()
  "Close this settings buffer and select the original manuscript."
  (tategaki-settings--ensure-ui)
  (let ((source tategaki-settings-source) (tategaki-settings--allow-kill t)
        (settings (current-buffer)) (window (get-buffer-window (current-buffer) t)))
    (if (window-live-p window) (quit-window t window) (kill-buffer settings))
    (when (buffer-live-p source)
      (when-let* ((window (get-buffer-window source t))) (select-window window)))))

(defun tategaki-settings-discard ()
  "Discard unsaved previews and close the settings screen."
  (interactive)
  (tategaki-settings--ensure-ui)
  (tategaki-settings--restore tategaki-settings--saved)
  (tategaki-settings--finish))

(defun tategaki-settings--save-and-close ()
  "Save changed preferences and close the settings screen."
  (tategaki-settings--ensure-ui)
  (tategaki-settings-save)
  (tategaki-settings--finish))

(defun tategaki-settings-close ()
  "Close settings, presenting clickable save/discard/cancel if changed."
  (interactive)
  (tategaki-settings--ensure-ui)
  (if (or (tategaki-settings--save-values) (tategaki-settings--paper-draft-p))
      (progn (setq tategaki-settings--closing t)
             (goto-char (point-min))
             (tategaki-settings--render))
    ;; Clearing previews that match the saved values avoids leaked overrides.
    (tategaki-settings-discard)))

(defun tategaki-settings--kill-query ()
  "Prevent accidentally killing a settings buffer with unsaved previews."
  (cond (tategaki-settings--allow-kill t)
        ((or (tategaki-settings--save-values) (tategaki-settings--paper-draft-p))
         (tategaki-settings-close) nil)
        (t (tategaki-settings--restore tategaki-settings--saved) t)))

(defun tategaki-settings--ai-key ()
  "Return the displayed provider and endpoint identity."
  (list (alist-get 'ai-provider tategaki-settings--values)
        (alist-get 'ai-endpoint tategaki-settings--values)))

(defun tategaki-settings--ai-key-current-p (key)
  "Whether KEY still matches both this form and its live manuscript settings."
  (and (buffer-live-p tategaki-settings-source)
       (equal key (tategaki-settings--ai-key))
       (equal key (with-current-buffer tategaki-settings-source
                    (list tategaki-ai-provider tategaki-ai-endpoint)))))

(defun tategaki-settings--cancel-ai-request ()
  "Cancel this panel's metadata request and invalidate late callbacks."
  (setq tategaki-settings--ai-generation nil)
  (when (buffer-live-p tategaki-settings--ai-request)
    (tategaki-ai-cancel tategaki-settings--ai-request))
  (setq tategaki-settings--ai-request nil))

(defun tategaki-settings--invalidate-ai-models ()
  "Discard choices belonging to the old connection without rerendering fields."
  (tategaki-settings--cancel-ai-request)
  (setq tategaki-settings--ai-models nil tategaki-settings--ai-model-key nil
        tategaki-settings--ai-status "接続先が変わりました。モデル一覧を取得してください")
  (when-let* ((widget tategaki-settings--ai-status-widget)
              (start (widget-get widget :from))
              (_ (and (markerp start) (marker-buffer start))))
    (let ((inhibit-read-only t) (inhibit-modification-hooks t))
      (widget-value-set widget tategaki-settings--ai-status))))

(defun tategaki-settings-use-ai-preset ()
  "Explicitly replace the endpoint with the selected provider's local preset."
  (interactive)
  (tategaki-settings--ensure-ui)
  (let ((endpoint (tategaki-ai-provider-endpoint (alist-get 'ai-provider tategaki-settings--values))))
    (unless endpoint (user-error "このProviderはEndpointを自由入力してください"))
    (tategaki-settings-set 'ai-endpoint endpoint)
    (tategaki-settings--render)))

(defun tategaki-settings-fetch-models ()
  "Fetch server models asynchronously without transmitting manuscript text."
  (interactive)
  (tategaki-settings--ensure-ui)
  (let* ((settings (current-buffer)) (source (tategaki-settings--source))
         (key (tategaki-settings--ai-key)) (generation (list 'models)))
    (tategaki-settings--cancel-ai-request)
    (setq tategaki-settings--ai-generation generation
          tategaki-settings--ai-models nil tategaki-settings--ai-model-key nil
          tategaki-settings--ai-status "モデル一覧を取得しています…")
    (tategaki-settings--render)
    (condition-case err
        (let ((request
               (with-current-buffer source
                 (tategaki-ai-health
                  (lambda (result)
                    (when (buffer-live-p settings)
                      (with-current-buffer settings
                        (when (eq generation tategaki-settings--ai-generation)
                          (setq tategaki-settings--ai-generation nil
                                tategaki-settings--ai-request nil)
                          (if (not (tategaki-settings--ai-key-current-p key))
                              (setq tategaki-settings--ai-status "原稿または接続設定が変わったため結果を破棄しました")
                            (setq tategaki-settings--ai-models (and (plist-get result :ok) (plist-get result :models))
                                  tategaki-settings--ai-model-key (and (plist-get result :ok) key)
                                  tategaki-settings--status
                                  (format "%s %s" (if (plist-get result :ok) "✓ 接続成功" "✗ 接続できません")
                                          (or (plist-get result :message) ""))
                                  tategaki-settings--ai-status
                                  (if (plist-get result :ok)
                                      (format "取得済み: %dモデル — Model / Embeddingを別々に選択できます"
                                              (length tategaki-settings--ai-models))
                                    tategaki-settings--status)))
                          (tategaki-settings--render)))))))))
          ;; Synchronous providers may have already completed their callback.
          (when (eq generation tategaki-settings--ai-generation)
            (setq tategaki-settings--ai-request request)))
      (error
       (setq tategaki-settings--ai-generation nil
             tategaki-settings--ai-status (concat "✗ " (error-message-string err)))
       (tategaki-settings--render)))))

(defun tategaki-settings-test-ai ()
  "Check connectivity and obtain selectable models without sending text."
  (interactive)
  (tategaki-settings-fetch-models))

(defun tategaki-settings-choose-model (key)
  "Choose a retrieved model for KEY, retaining the independent text fields."
  (interactive (list 'ai-model))
  (tategaki-settings--ensure-ui)
  (unless (memq key '(ai-model ai-embedding-model)) (user-error "不正なモデル欄です"))
  (unless (and (tategaki-settings--ai-key-current-p tategaki-settings--ai-model-key)
               tategaki-settings--ai-models)
    (user-error "モデル一覧を取得してください。0件の場合はサーバーのモデルを確認してください"))
  (let* ((connection tategaki-settings--ai-model-key)
         (current (alist-get key tategaki-settings--values))
         (model (completing-read (if (eq key 'ai-model) "Chat Model: " "Embedding Model: ")
                                 tategaki-settings--ai-models nil t nil nil
                                 (and (member current tategaki-settings--ai-models) current))))
    (unless (and (tategaki-settings--ai-key-current-p connection)
                 (equal connection tategaki-settings--ai-model-key)
                 (member model tategaki-settings--ai-models))
      (user-error "接続先が変わりました。モデル一覧を取得し直してください"))
    (tategaki-settings-set key model)
    (tategaki-settings--render)))

(defun tategaki-settings-choose-voice ()
  "Show available macOS voices as clickable choices in this screen."
  (interactive)
  (tategaki-settings--ensure-ui)
  (let ((voices (cond ((fboundp 'tategaki-tts-voices) (tategaki-tts-voices))
                       ((and (eq system-type 'darwin) (executable-find "say"))
                        (with-temp-buffer
                          (when (zerop (call-process "say" nil t nil "-v" "?"))
                            (goto-char (point-min))
                            (let (names)
                              (while (re-search-forward "^\\(.+?\\)[ \t]+[a-z][a-z]_[A-Z][A-Z][ \t]" nil t)
                                (push (string-trim (match-string 1)) names))
                              (nreverse names))))))))
    (unless voices (user-error "利用可能なVoiceを取得できません。Voice欄に名前を入力してください"))
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (widget-insert "\n利用可能なVoice（クリックして選択）\n")
      (dolist (voice voices)
        (tategaki-settings--button voice (lambda (value)
                                           (tategaki-settings-set 'tts-voice value)
                                           (tategaki-settings--render)) voice)
        (widget-insert " "))
      (widget-insert "\n")
      (widget-setup))))

;;;###autoload
(defun tategaki-settings (&optional source)
  "Open live settings for SOURCE, defaulting to the current manuscript."
  (interactive)
  (setq source (or source (and (fboundp 'tategaki-studio-source-buffer)
                               (tategaki-studio-source-buffer)) (current-buffer)))
  (unless (buffer-live-p source) (user-error "原稿を開いてください"))
  (let* ((name (format "*Tategaki Settings: %s*" (buffer-name source)))
         (existing (cl-find-if
                    (lambda (buffer)
                      (and (eq (buffer-local-value 'major-mode buffer) 'tategaki-settings-mode)
                           (eq (buffer-local-value 'tategaki-settings-source buffer) source)))
                    (buffer-list)))
         (settings (or existing (generate-new-buffer name))))
    (unless existing
      (condition-case err
          (progn
            (with-current-buffer source (tategaki-project-apply-settings))
            (with-current-buffer settings
              (tategaki-settings-mode)
              (setq tategaki-settings-source source)
              (setq-local tategaki-studio-source source)
              (setq tategaki-settings--values (tategaki-settings--current-values)
                    tategaki-settings--opening-values (copy-tree tategaki-settings--values)
                    tategaki-settings--saved-values (copy-tree tategaki-settings--values)
                    tategaki-settings--opening (tategaki-settings--capture)
                    tategaki-settings--saved (copy-tree tategaki-settings--opening))
              (tategaki-settings--render)))
        (error
         (with-current-buffer settings
           (let ((tategaki-settings--allow-kill t)) (kill-buffer settings)))
         (signal (car err) (cdr err)))))
    (with-current-buffer settings
      (tategaki-pane-install source #'tategaki-settings-close "設定"))
    (pop-to-buffer settings '((display-buffer-in-side-window) (side . right)
                             (slot . 1) (window-width . 0.45)))
    settings))

(provide 'tategaki-settings)
;;; tategaki-settings.el ends here
