;;; tategaki-tts.el --- Local asynchronous manuscript read-aloud -*- lexical-binding: t; -*-

;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; macOS say reads one source sentence at a time from stdin.  No shell, remote
;; service, temporary manuscript file or stdout transcript is used.  Sentence
;; highlighting is approximate to sentence boundaries, not word alignment.
;; Editing the source invalidates the queue and stops playback immediately.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tategaki-typeset)

(defgroup tategaki-tts nil "Local manuscript read-aloud." :group 'text)
(defcustom tategaki-tts-program "say"
  "Local speech executable compatible with macOS say."
  :type 'file :group 'tategaki-tts)
(defcustom tategaki-tts-voice "Kyoko"
  "Voice name used for local read-aloud."
  :type 'string :group 'tategaki-tts)
(defcustom tategaki-tts-rate 1.0
  "Read-aloud speed multiplier relative to `tategaki-tts-base-rate'."
  :type 'number :group 'tategaki-tts)
(defcustom tategaki-tts-base-rate 180
  "Words per minute at a rate multiplier of 1.0."
  :type 'integer :group 'tategaki-tts)
(defcustom tategaki-tts-pronunciations nil
  "Literal (WORD . READING) replacements used only for synthesized speech.
Longest matching names win.  The manuscript itself is never changed."
  :type '(alist :key-type string :value-type string) :group 'tategaki-tts)
(defface tategaki-tts-face '((t (:inherit highlight)))
  "Current spoken sentence, projected through the vertical display."
  :group 'tategaki-tts)

(defvar-local tategaki-tts--process nil)
(defvar-local tategaki-tts--queue nil)
(defvar-local tategaki-tts--overlay nil)
(defvar-local tategaki-tts--tick nil)
(defvar-local tategaki-tts--hash nil)
(defvar-local tategaki-tts--generation 0)
(defvar-local tategaki-tts-state 'stopped
  "Read-aloud state: stopped, playing or paused.")
(defvar tategaki-tts--active-buffer nil)
(declare-function tategaki-studio-source-buffer "tategaki-studio" (&optional buffer))
(declare-function tategaki-refresh "tategaki" ())

(defun tategaki-tts--source ()
  "Resolve the current Studio manuscript or active read-aloud source."
  (or (and (fboundp 'tategaki-studio-source-buffer) (tategaki-studio-source-buffer))
      (and (derived-mode-p 'special-mode) (buffer-live-p tategaki-tts--active-buffer)
           tategaki-tts--active-buffer)
      (current-buffer)))

(defun tategaki-tts-voices ()
  "Return installed voice names, or nil when local speech is unavailable."
  (when-let* ((program (executable-find tategaki-tts-program)))
    (with-temp-buffer
      (when (zerop (call-process program nil t nil "-v" "?"))
        (goto-char (point-min))
        (let (names)
          (while (re-search-forward "^\\(.+?\\)[ \t]+[a-z][a-z]_[A-Z][A-Z][ \t]" nil t)
            (push (string-trim (match-string 1)) names))
          (delete-dups (nreverse names)))))))

(defun tategaki-tts--pronounce (text)
  "Produce speech TEXT, applying annotation plain text and literal readings."
  (setq text (tategaki-typeset-plain-text text))
  (let ((entries (cl-remove-if-not
                  (lambda (entry) (and (consp entry) (stringp (car entry))
                                        (not (string-empty-p (car entry)))
                                        (stringp (cdr entry))))
                  tategaki-tts-pronunciations)))
    (when entries
      (setq text (replace-regexp-in-string
                  (regexp-opt (mapcar #'car entries))
                  (lambda (word) (cdr (assoc-string word entries))) text t t))))
  ;; Speech manager [[...]] control sequences in prose are not instructions.
  (replace-regexp-in-string "\\[\\[" "［［" text t t))

(defun tategaki-tts--sentences (begin end)
  "Return source (START END SPEECH) chunks within BEGIN and END."
  (save-excursion
    (goto-char begin)
    (let (chunks)
      (while (< (point) end)
        (skip-chars-forward " \t\r\n　" end)
        (when (< (point) end)
          (let* ((start (point))
                 (limit (min end (+ start 1500)))
                 (finish (if (re-search-forward "[。！？.!?\n]" limit t)
                             (progn (skip-chars-forward "。！？.!?」』）)\"”’" limit) (point))
                           limit))
                 (text (buffer-substring-no-properties start finish)))
            (goto-char finish)
            (push (list start finish (tategaki-tts--pronounce text)) chunks))))
      (nreverse chunks))))

(defun tategaki-tts--refresh ()
  "Update vertical overlay projection and status."
  (when (and (bound-and-true-p tategaki-mode) (fboundp 'tategaki-refresh))
    (tategaki-refresh))
  (force-mode-line-update))

(defun tategaki-tts--stop ()
  "Stop current-buffer playback and remove its queue and highlight."
  (cl-incf tategaki-tts--generation)
  (let ((process tategaki-tts--process))
    (setq tategaki-tts--process nil tategaki-tts--queue nil
          tategaki-tts-state 'stopped tategaki-tts--tick nil tategaki-tts--hash nil)
    (when (processp process)
      (set-process-sentinel process #'ignore)
      (when (process-live-p process) (delete-process process))))
  (when (overlayp tategaki-tts--overlay) (delete-overlay tategaki-tts--overlay))
  (setq tategaki-tts--overlay nil)
  (remove-hook 'after-change-functions #'tategaki-tts--source-changed t)
  (remove-hook 'kill-buffer-hook #'tategaki-tts--stop t)
  (when (eq tategaki-tts--active-buffer (current-buffer))
    (setq tategaki-tts--active-buffer nil))
  (tategaki-tts--refresh))

(defun tategaki-tts--source-changed (&rest _)
  "Invalidate playback immediately after any manuscript edit."
  (tategaki-tts--stop)
  (message "原稿が変更されたため音読を停止しました"))

(defun tategaki-tts--next ()
  "Speak the next immutable sentence if the source is still current."
  (cond
   ((not (equal tategaki-tts--tick (buffer-chars-modified-tick))) (tategaki-tts--stop))
   ((null tategaki-tts--queue) (tategaki-tts--stop) (message "音読が完了しました"))
   (t
    (pcase-let* ((`(,begin ,end ,text) (pop tategaki-tts--queue))
                 (source (current-buffer)) (generation tategaki-tts--generation)
                 (program (executable-find tategaki-tts-program)))
      (unless program (tategaki-tts--stop) (user-error "音読には macOS の say が必要です"))
      (unless (overlayp tategaki-tts--overlay)
        (setq tategaki-tts--overlay (make-overlay begin end source)))
      (move-overlay tategaki-tts--overlay begin end source)
      (overlay-put tategaki-tts--overlay 'face 'tategaki-tts-face)
      (overlay-put tategaki-tts--overlay 'priority 90)
      (overlay-put tategaki-tts--overlay 'tategaki-tts t)
      (setq tategaki-tts-state 'playing)
      (condition-case err
          (progn
            (setq tategaki-tts--process
                  (make-process
                   :name "tategaki-tts" :buffer nil :noquery t :connection-type 'pipe
                   :coding 'utf-8-unix
                   :command (list program "-v" tategaki-tts-voice "-r"
                                  (number-to-string (round (* tategaki-tts-base-rate tategaki-tts-rate)))
                                  "-f" "-")
                   :filter #'ignore
                   :sentinel
                   (lambda (process _event)
                     (when (and (buffer-live-p source) (memq (process-status process) '(exit signal)))
                       (with-current-buffer source
                         (when (and (= generation tategaki-tts--generation)
                                    (eq process tategaki-tts--process))
                           (setq tategaki-tts--process nil)
                           (if (and (eq (process-status process) 'exit)
                                    (zerop (process-exit-status process)))
                               (tategaki-tts--next)
                             (tategaki-tts--stop)
                             (message "音読に失敗しました。Voice と say の設定を確認してください"))))))))
            (process-send-string tategaki-tts--process (concat text "\n"))
            (process-send-eof tategaki-tts--process))
        (error (tategaki-tts--stop) (signal (car err) (cdr err))))
      (tategaki-tts--refresh)))))

(defun tategaki-tts--start (begin end)
  "Start explicit local speech of source range BEGIN through END."
  (unless (and (<= (point-min) begin end (point-max)) (< begin end))
    (user-error "音読する本文がありません"))
  (unless (executable-find tategaki-tts-program)
    (user-error "この環境では音読を利用できません（macOS say が必要です）"))
  (unless (and (stringp tategaki-tts-voice) (numberp tategaki-tts-rate)
               (<= 0.1 tategaki-tts-rate 4.0))
    (user-error "Voice または速度の設定が不正です"))
  (when (and (buffer-live-p tategaki-tts--active-buffer)
             (not (eq tategaki-tts--active-buffer (current-buffer))))
    (with-current-buffer tategaki-tts--active-buffer (tategaki-tts--stop)))
  (tategaki-tts--stop)
  (setq tategaki-tts--queue (tategaki-tts--sentences begin end)
        tategaki-tts--tick (buffer-chars-modified-tick)
        tategaki-tts--hash (secure-hash 'sha256 (current-buffer) begin end)
        tategaki-tts--active-buffer (current-buffer))
  (add-hook 'after-change-functions #'tategaki-tts--source-changed nil t)
  (add-hook 'kill-buffer-hook #'tategaki-tts--stop nil t)
  (tategaki-tts--next))

;;;###autoload
(defun tategaki-tts-play ()
  "Read the current manuscript from point, or resume paused speech."
  (interactive)
  (with-current-buffer (tategaki-tts--source)
    (if (eq tategaki-tts-state 'paused) (tategaki-tts-resume)
      (tategaki-tts--start (point) (point-max)))))

;;;###autoload
(defun tategaki-tts-read-region (begin end)
  "Read only the explicitly selected source range BEGIN to END."
  (interactive "r")
  (tategaki-tts--start begin end))

;;;###autoload
(defun tategaki-tts-pause ()
  "Pause speech at its current position; `tategaki-tts-play' resumes it."
  (interactive)
  (with-current-buffer (tategaki-tts--source)
    (unless (and (eq tategaki-tts-state 'playing) (process-live-p tategaki-tts--process))
      (user-error "音読していません"))
    (stop-process tategaki-tts--process)
    (setq tategaki-tts-state 'paused)
    (force-mode-line-update)))

;;;###autoload
(defun tategaki-tts-resume ()
  "Resume paused speech if its source remains unchanged."
  (interactive)
  (with-current-buffer (tategaki-tts--source)
    (unless (and (eq tategaki-tts-state 'paused) (process-live-p tategaki-tts--process))
      (user-error "一時停止中の音読がありません"))
    (unless (equal tategaki-tts--tick (buffer-chars-modified-tick))
      (tategaki-tts--stop) (user-error "原稿が変更されました。音読を開始し直してください"))
    (continue-process tategaki-tts--process)
    (setq tategaki-tts-state 'playing)
    (force-mode-line-update)))

;;;###autoload
(defun tategaki-tts-stop ()
  "Stop read-aloud, clearing all speech-owned overlays and pending work."
  (interactive)
  (with-current-buffer (tategaki-tts--source) (tategaki-tts--stop)))

(provide 'tategaki-tts)
;;; tategaki-tts.el ends here
