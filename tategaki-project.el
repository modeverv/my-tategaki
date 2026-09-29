;;; tategaki-project.el --- Safe per-novel settings and metadata -*- lexical-binding: t; -*-

;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; JSON is data, never executable Lisp.  Only the settings below may become
;; buffer-local variables.  Merely loading this module does not read files,
;; change defaults, contact a service, or enable the Studio.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'face-remap)

(defgroup tategaki-project nil "Novel metadata and scoped preferences." :group 'text)
(defcustom tategaki-project-default-file
  (expand-file-name "tategaki/defaults.json" user-emacs-directory)
  "JSON file containing preferences for new novels."
  :type 'file :group 'tategaki-project)
(defcustom tategaki-settings-font-family nil
  "Font family for this manuscript, or nil to inherit the editor face."
  :type '(choice (const :tag "Inherit" nil) string) :group 'tategaki-project)
(defvar-local tategaki-project-session-settings nil
  "Session overrides, in the same alist format as project.json.")
(defvar-local tategaki-project--font-cookie nil)
(defvar-local tategaki-project-last-error nil
  "Last settings read error; invalid files never prevent opening a manuscript.")
(defvar-local tategaki-project--inferred-ai-provider nil
  "Provider local owned by compatibility inference, or nil.
Settings transactions must snapshot this after their provider variable so
restoring a preview also restores whether its provider was inferred.")
(defvar tategaki-project--inferring-ai-provider nil)
(defvar tategaki-ai-provider)

(defconst tategaki-project-setting-specs
  '((text-scale tategaki--text-scale-amount scale 0)
    (font-family tategaki-settings-font-family font nil)
    (manuscript-size tategaki-manuscript-size paper nil)
    (manuscript-grid tategaki-manuscript-grid boolean nil)
    (manuscript-spread tategaki-manuscript-spread boolean nil)
    (manuscript-fit-window tategaki-manuscript-fit-window boolean nil)
    (character-spacing tategaki-character-spacing spacing 0)
    (line-spacing tategaki-line-spacing optional-spacing nil)
    (padding-top tategaki-padding-top spacing 0)
    (padding-bottom tategaki-padding-bottom spacing 0)
    (padding-left tategaki-padding-left spacing 0)
    (padding-right tategaki-padding-right spacing 0)
    (writing-auto-indent tategaki-writing-auto-indent boolean t)
    (writing-electric-pair tategaki-writing-electric-pair boolean t)
    (history-enabled tategaki-history-enabled boolean t)
    (history-idle-interval tategaki-history-idle-interval interval 120)
    (proofread-enabled tategaki-proofread-enabled boolean t)
    (proofread-live tategaki-proofread-live boolean nil)
    (proofread-max-sentence-length tategaki-proofread-max-sentence-length positive 120)
    (ai-enabled tategaki-ai-enabled boolean nil)
    (ai-provider tategaki-ai-provider provider ollama)
    (ai-model tategaki-ai-model string "")
    (ai-embedding-model tategaki-ai-embedding-model string "")
    (ai-endpoint tategaki-ai-endpoint string "http://localhost:11434/v1")
    (tts-voice tategaki-tts-voice string "Kyoko")
    (tts-rate tategaki-tts-rate rate 1.0))
  "Allowlist of (JSON-KEY VARIABLE TYPE FALLBACK) settings.")
(defconst tategaki-project-metadata-keys '(title author language identifier))

(declare-function tategaki-refresh "tategaki")
(declare-function tategaki--text-scale-apply "tategaki")
(declare-function tategaki-writing-mode "tategaki-writing" (&optional arg))
(declare-function tategaki-history-reconfigure "tategaki-history")
(declare-function tategaki-proofread-reconfigure "tategaki-proofread")
(declare-function tategaki-ai-provider-for-endpoint "tategaki-ai" (endpoint))

(defun tategaki-project-root (&optional directory)
  "Find the nearest novel root from DIRECTORY, or use its containing directory.
A root contains .tategaki/project.json.  A new manuscript without a project
uses its file directory, without requiring Git or creating any files."
  (let* ((candidate (or directory buffer-file-name default-directory))
         (dir (file-name-as-directory
               (expand-file-name (if (file-directory-p candidate) candidate
                                   (file-name-directory candidate))))))
    (or (locate-dominating-file
         dir (lambda (parent)
               (file-exists-p (expand-file-name ".tategaki/project.json" parent))))
        dir)))

(defun tategaki-project-file (&optional directory)
  "Return the project JSON filename for DIRECTORY."
  (expand-file-name ".tategaki/project.json" (tategaki-project-root directory)))

(defun tategaki-project--read (file &optional strict)
  "Read FILE as JSON data, returning nil if absent or invalid.
When STRICT, signal invalid-file errors instead of tolerating them."
  (when (file-exists-p file)
    (condition-case err
        (progn
          (when (> (file-attribute-size (file-attributes file)) (* 1024 1024))
            (error "Settings file exceeds 1 MiB"))
          (let* ((json-object-type 'alist) (json-array-type 'vector)
                 (json-key-type 'symbol) (json-false :false) (json-null nil)
                 (data (with-temp-buffer
                         (insert-file-contents file)
                         (let ((value (json-read)))
                           (skip-chars-forward " \t\r\n")
                           (unless (eobp) (error "Unexpected content after JSON"))
                           value))))
            (unless (and (listp data)
                         (cl-every (lambda (entry) (and (consp entry) (symbolp (car entry)))) data)
                         (equal (alist-get 'schema_version data) 1)
                         (let ((settings (alist-get 'settings data)))
                           (and (listp settings)
                                (cl-every (lambda (entry) (and (consp entry) (symbolp (car entry))))
                                          settings))))
              (error "Expected a JSON object with schema_version 1"))
            data))
      (error
       (setq tategaki-project-last-error (format "%s: %s" file (error-message-string err)))
       (if strict (user-error "設定ファイルを保護しました: %s" tategaki-project-last-error)
         (display-warning 'tategaki-project tategaki-project-last-error :warning)
         nil)))))

(defun tategaki-project-load (&optional directory)
  "Read the novel's project JSON as an alist, tolerating corrupt files."
  (tategaki-project--read (tategaki-project-file directory)))

(defun tategaki-project--merge (base overrides)
  "Merge config OVERRIDES over BASE, merging the settings object by key."
  (let ((result (copy-tree base)))
    (dolist (entry overrides)
      (if (eq (car entry) 'settings)
          (dolist (setting (cdr entry))
            (setf (alist-get (car setting) (alist-get 'settings result)) (cdr setting)))
        (setf (alist-get (car entry) result) (copy-tree (cdr entry)))))
    result))

(defun tategaki-project-effective-data ()
  "Return resolved default, project and current-buffer session data."
  (tategaki-project--merge
   (tategaki-project--merge (tategaki-project--read tategaki-project-default-file)
                            (tategaki-project-load))
   tategaki-project-session-settings))

(defun tategaki-project-metadata (&optional buffer)
  "Return resolved novel metadata as a plist for BUFFER, or the current one.
Missing properties are omitted, so export can fall back to buffer metadata."
  (with-current-buffer (or buffer (current-buffer))
    (let ((data (tategaki-project-effective-data)) result)
      (dolist (key tategaki-project-metadata-keys)
        (let ((entry (assq key data)))
          (when (and entry (stringp (cdr entry)))
            (setq result (plist-put result (intern (concat ":" (symbol-name key)))
                                    (cdr entry))))))
      result)))

(defun tategaki-project-setting-valid-p (key value)
  "Whether VALUE is valid for the allowlisted setting KEY."
  (let ((spec (assq key tategaki-project-setting-specs)))
    (and spec
         (pcase (nth 2 spec)
           ('boolean (memq value '(t nil :false)))
           ('scale (and (numberp value) (<= -12 value 12)))
           ('font (or (null value) (and (stringp value) (< (length value) 256))))
           ('paper (or (null value)
                       (and (consp value) (integerp (car value)) (integerp (cdr value))
                            (<= 1 (car value) 200) (<= 1 (cdr value) 200))))
           ('spacing (and (integerp value) (<= 0 value 1000)))
           ('optional-spacing (or (null value) (and (integerp value) (<= 0 value 1000))))
           ('interval (or (null value) (and (integerp value) (<= 1 value 86400))))
           ('positive (and (integerp value) (<= 1 value 100000)))
           ('provider (memq value '(ollama openai-compatible lm-studio llama-cpp)))
           ('string (and (stringp value) (<= (length value) 4096)))
           ('rate (and (numberp value) (<= 0.1 value 4.0)))))))

(defun tategaki-project--decode-setting (key value)
  "Decode the safe JSON representation of setting KEY's VALUE."
  (pcase (nth 2 (assq key tategaki-project-setting-specs))
    ('boolean (if (eq value :false) nil value))
    ('paper (if (and (vectorp value) (= (length value) 2))
                (cons (aref value 0) (aref value 1)) value))
    ('provider (if (stringp value)
                   (cdr (assoc value '(("ollama" . ollama)
                                       ("openai-compatible" . openai-compatible)
                                       ("lm-studio" . lm-studio) ("llama-cpp" . llama-cpp))))
                 value))
    (_ value)))

(defun tategaki-project-refresh ()
  "Refresh display and optional integrations without editing the source."
  (when tategaki-project--font-cookie
    (face-remap-remove-relative tategaki-project--font-cookie)
    (setq tategaki-project--font-cookie nil))
  (when (and (stringp tategaki-settings-font-family)
             (not (string-empty-p tategaki-settings-font-family)))
    (setq tategaki-project--font-cookie
          (face-remap-add-relative 'tategaki-face :family tategaki-settings-font-family)))
  (when (fboundp 'tategaki--text-scale-apply) (tategaki--text-scale-apply))
  (when (bound-and-true-p tategaki-writing-mode)
    (tategaki-writing-mode -1)
    (tategaki-writing-mode 1))
  (when (fboundp 'tategaki-history-reconfigure) (tategaki-history-reconfigure))
  (when (fboundp 'tategaki-proofread-reconfigure) (tategaki-proofread-reconfigure))
  (when (and (bound-and-true-p tategaki-mode) (fboundp 'tategaki-refresh))
    (tategaki-refresh))
  (force-mode-line-update))

(defun tategaki-project--provider-written (_symbol _value operation where)
  "Stop owning an inferred provider after an explicit write in WHERE.
Even setting the same value is an explicit choice.  Ignore our own writes
and temporary dynamic bindings, described by OPERATION."
  (when (and (not tategaki-project--inferring-ai-provider)
             (memq operation '(set makunbound)) (buffer-live-p where)
             (buffer-local-value 'tategaki-project--inferred-ai-provider where))
    (with-current-buffer where
      (setq tategaki-project--inferred-ai-provider nil))))

(add-variable-watcher 'tategaki-ai-provider #'tategaki-project--provider-written)

(defun tategaki-project--clear-inferred-provider ()
  "Remove only the provider local still owned by compatibility inference."
  (when tategaki-project--inferred-ai-provider
    (when (and (local-variable-p 'tategaki-ai-provider)
               (boundp 'tategaki-ai-provider)
               (eq tategaki-ai-provider tategaki-project--inferred-ai-provider))
      (let ((tategaki-project--inferring-ai-provider t))
        (kill-local-variable 'tategaki-ai-provider)))
    (setq tategaki-project--inferred-ai-provider nil)))

(defun tategaki-project--infer-provider (settings)
  "Recover a missing provider from a standard saved endpoint in SETTINGS.
An explicit saved provider, including an invalid one, or any explicit
buffer-local provider prevents inference.  Never rewrite saved JSON."
  (when (and (not (assq 'ai-provider settings))
             (not (local-variable-p 'tategaki-ai-provider))
             (stringp (alist-get 'ai-endpoint settings)))
    (require 'tategaki-ai)
    (when-let* ((provider (tategaki-ai-provider-for-endpoint
                          (alist-get 'ai-endpoint settings))))
      (let ((tategaki-project--inferring-ai-provider t))
        (setq-local tategaki-ai-provider provider))
      (setq tategaki-project--inferred-ai-provider provider))))

(defun tategaki-project-apply-settings ()
  "Apply allowlisted default/project/session preferences to this buffer.
Unknown keys and invalid values are ignored.  Ordinary Lisp defaults remain
effective wherever no saved preference exists.  Source text is never edited."
  (interactive)
  (let ((settings (alist-get 'settings (tategaki-project-effective-data))))
    ;; Re-resolve our own inference on every apply, including when an old
    ;; endpoint disappears or becomes custom.  Explicit locals are untouched.
    (tategaki-project--clear-inferred-provider)
    (when (listp settings)
      (dolist (spec tategaki-project-setting-specs)
        (let* ((entry (assq (car spec) settings))
               (value (and entry (tategaki-project--decode-setting (car spec) (cdr entry)))))
          (when (and entry (tategaki-project-setting-valid-p (car spec) value))
            (set (make-local-variable (cadr spec)) value))))
      (tategaki-project--infer-provider settings)))
  (tategaki-project-refresh))

(defun tategaki-project--json-data (data)
  "Encode allowlisted settings in DATA for interoperable JSON."
  (setq data (copy-tree data))
  (dolist (entry (alist-get 'settings data))
    (pcase (nth 2 (assq (car entry) tategaki-project-setting-specs))
      ('boolean (setcdr entry (if (memq (cdr entry) '(nil :false)) :false t)))
      ('paper (when (consp (cdr entry))
                (setcdr entry (vector (cadr entry) (cddr entry)))))
      ('provider (when (symbolp (cdr entry)) (setcdr entry (symbol-name (cdr entry)))))))
  (setf (alist-get 'schema_version data) 1)
  data)

(defun tategaki-project-save (data &optional scope)
  "Save configuration DATA to SCOPE: session, project (default), or default.
Only DATA's provided keys change.  Writes are atomic; malformed existing
files are retained and reported rather than silently replaced."
  (setq scope (or scope 'project))
  (unless (memq scope '(session project default)) (user-error "Unknown scope: %s" scope))
  (if (eq scope 'session)
      (setq tategaki-project-session-settings
            (tategaki-project--merge tategaki-project-session-settings data))
    (let* ((file (if (eq scope 'default) tategaki-project-default-file
                   (tategaki-project-file)))
           (existing (tategaki-project--read file t))
           (merged (tategaki-project--json-data (tategaki-project--merge existing data)))
           (directory (file-name-directory file)) temporary)
      (make-directory directory t)
      (setq temporary (make-temp-file (expand-file-name ".settings-" directory)))
      (unwind-protect
          (progn
            (with-temp-file temporary
              (let ((json-encoding-pretty-print t) (json-false :false)
                    (coding-system-for-write 'utf-8-unix))
                (insert (json-encode merged) "\n")))
            (set-file-modes temporary #o600)
            (rename-file temporary file t))
        (when (file-exists-p temporary) (delete-file temporary)))))
  data)

(provide 'tategaki-project)
;;; tategaki-project.el ends here
