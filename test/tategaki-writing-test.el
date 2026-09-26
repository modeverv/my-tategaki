;;; tategaki-writing-test.el --- Writing support tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'tategaki-writing)

(defmacro tategaki-writing-test--with-buffer (&rest body)
  "Run BODY in an isolated writing buffer and clean native modes afterwards."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (text-mode)
     (let ((tategaki-writing-assistance t)
           (tategaki-writing-auto-indent t)
           (tategaki-writing-electric-pair t)
           (tategaki-writing-paragraph-indent 1)
           (tategaki-writing-dialogue-indent 0)
           (tategaki-script-speaker-indent 0)
           (tategaki-script-dialogue-indent 2)
           (tategaki-script-stage-direction-indent 1))
       (unwind-protect
           (progn (tategaki-writing-enable) ,@body)
         (tategaki-writing-disable)))))

(defun tategaki-writing-test--type (character)
  "Enter CHARACTER through native self insertion and post-self-insert hooks."
  (let ((this-command 'self-insert-command)
        (last-command-event character))
    (self-insert-command 1)))

(ert-deftest tategaki-writing-enable-does-not-edit-and-is-buffer-local ()
  (let ((global-pairs (default-value 'electric-pair-pairs))
        (global-mode (default-value 'electric-pair-mode)))
    (with-temp-buffer
      (text-mode)
      (insert "本文\n「会話」")
      (set-buffer-modified-p nil)
      (let ((position (point)) (tick (buffer-chars-modified-tick)))
        (tategaki-writing-enable)
        (should electric-pair-mode)
        (should (equal (assq ?「 electric-pair-pairs) '(?「 . ?」)))
        (should (= position (point)))
        (should (= tick (buffer-chars-modified-tick)))
        (should-not (buffer-modified-p))
        (tategaki-writing-disable)
        (should-not (local-variable-p 'electric-pair-mode))
        (should-not (local-variable-p 'electric-pair-pairs))
        (should-not (buffer-modified-p))))
    (should (eq global-pairs (default-value 'electric-pair-pairs)))
    (should (eq global-mode (default-value 'electric-pair-mode)))))

(ert-deftest tategaki-writing-restores-native-local-pair-settings ()
  (with-temp-buffer
    (setq-local electric-pair-mode nil)
    (setq-local electric-pair-pairs '((?x . ?y)))
    (setq-local electric-pair-text-pairs '((?a . ?b)))
    (tategaki-writing-enable)
    (tategaki-writing-enable)
    (tategaki-writing-disable)
    (should (local-variable-p 'electric-pair-mode))
    (should-not electric-pair-mode)
    (should (equal electric-pair-pairs '((?x . ?y))))
    (should (equal electric-pair-text-pairs '((?a . ?b))))))

(ert-deftest tategaki-writing-keeps-independently-enabled-mode ()
  (with-temp-buffer
    (tategaki-writing-mode 1)
    (unwind-protect
        (progn
          (tategaki-writing-enable)
          (tategaki-writing-disable)
          (should tategaki-writing-mode))
      (tategaki-writing-mode -1))))

(ert-deftest tategaki-writing-pair-mode-enabled-beforehand-is-restored ()
  (with-temp-buffer
    (setq-local electric-pair-mode t)
    (let ((before local-minor-modes))
      (tategaki-writing-enable)
      (tategaki-writing-disable)
      (should electric-pair-mode)
      (should (equal before local-minor-modes)))))

(ert-deftest tategaki-writing-pair-opt-out-preserves-foreign-settings ()
  (with-temp-buffer
    (let ((tategaki-writing-electric-pair nil)
          (original electric-pair-pairs))
      (tategaki-writing-enable)
      (should-not electric-pair-mode)
      (should (eq original electric-pair-pairs))
      (tategaki-writing-disable)
      (should-not (local-variable-p 'electric-pair-pairs)))))

(ert-deftest tategaki-writing-opt-out-does-not-enable-support ()
  (with-temp-buffer
    (let ((tategaki-writing-assistance nil))
      (tategaki-writing-enable)
      (should-not tategaki-writing-mode)
      (should-not tategaki-writing--managed))))

(ert-deftest tategaki-writing-newline-fullwidth-indent-and-blank-separator ()
  (tategaki-writing-test--with-buffer
    (insert "本文")
    (tategaki-writing-newline 1)
    (should (equal (buffer-string) "本文\n　"))
    (tategaki-writing-newline 1)
    (should (equal (buffer-string) "本文\n\n　"))
    (insert "次")
    (tategaki-writing-newline 2)
    (should (equal (buffer-string) "本文\n\n　次\n\n　"))))

(ert-deftest tategaki-writing-disabled-auto-indent-is-native-newline ()
  (tategaki-writing-test--with-buffer
    (let ((tategaki-writing-auto-indent nil))
      (insert "本文")
      (tategaki-writing-newline 1)
      (tategaki-writing-test--type ?「)
      (should (equal (buffer-string) "本文\n「」")))))

(ert-deftest tategaki-writing-first-character-and-dialogue-use-native-pair ()
  (tategaki-writing-test--with-buffer
    (tategaki-writing-test--type ?本)
    (should (equal (buffer-string) "　本"))
    (should (= (point) (point-max)))
    (tategaki-writing-newline 1)
    (tategaki-writing-test--type ?「)
    (should (equal (buffer-string) "　本\n「」"))
    (should (= (char-after) ?」))
    (tategaki-writing-test--type ?声)
    (should (equal (buffer-string) "　本\n「声」"))))

(ert-deftest tategaki-writing-native-closing-bracket-skips-existing-pair ()
  (tategaki-writing-test--with-buffer
    (tategaki-writing-test--type ?「)
    (tategaki-writing-test--type ?」)
    (should (equal (buffer-string) "「」"))
    (should (= (point) (point-max)))))

(ert-deftest tategaki-writing-newline-inside-dialogue-keeps-dialogue-indent ()
  (tategaki-writing-test--with-buffer
    (insert "「こんにちは」")
    (goto-char 5)
    (tategaki-writing-newline 1)
    (should (equal (buffer-string) "「こんに\nちは」"))
    (goto-char (point-max))
    (tategaki-writing-newline 1)
    (should (string-suffix-p "\n　" (buffer-string)))))

(ert-deftest tategaki-writing-space-insertion-is-not-immediately-normalized ()
  (tategaki-writing-test--with-buffer
    (tategaki-writing-test--type ?　)
    (tategaki-writing-test--type ?　)
    (should (equal (buffer-string) "　　"))))

(ert-deftest tategaki-writing-headings-remain-compatible-with-outline ()
  (tategaki-writing-test--with-buffer
    (dolist (heading '("# 見出し" "* 見出し" "第一章　導入" "第12節 本文"))
      (erase-buffer)
      (insert "前文\n　")
      (mapc #'tategaki-writing-test--type heading)
      (should (equal (buffer-string) (concat "前文\n" heading))))))

(ert-deftest tategaki-script-manually-typed-speaker-adjusts-on-colon ()
  (tategaki-writing-test--with-buffer
    (setq-local tategaki-writing-style 'script)
    (mapc #'tategaki-writing-test--type "太郎：")
    (should (equal (buffer-string) "太郎："))
    (tategaki-writing-newline 1)
    (mapc #'tategaki-writing-test--type "「声」")
    (should (equal (buffer-string) "太郎：\n　　「声」"))))

(ert-deftest tategaki-writing-committed-ime-prefix-adjusts-after-command ()
  (tategaki-writing-test--with-buffer
    (insert "本文")
    (tategaki-writing-newline 1)
    (let ((this-command 'ns-insert-text))
      (insert "「会話」")
      (run-hooks 'post-command-hook))
    (should (equal (buffer-string) "本文\n「会話」"))))

(ert-deftest tategaki-writing-indent-precedes-ordinary-post-command-refresh ()
  (tategaki-writing-test--with-buffer
    (let (refreshed-text)
      (add-hook 'post-command-hook
                (lambda () (setq refreshed-text (buffer-string))) 0 t)
      (insert "本文\n　")
      (let ((this-command 'ns-insert-text))
        (insert "「会話」")
        (run-hooks 'post-command-hook))
      (should (equal refreshed-text "本文\n「会話」")))))

(ert-deftest tategaki-writing-paste-and-programmatic-insert-are-unchanged ()
  (tategaki-writing-test--with-buffer
    (let ((this-command 'yank)) (insert "本文\n「会話」"))
    (run-hooks 'post-command-hook)
    (should (equal (buffer-string) "本文\n「会話」"))
    (erase-buffer)
    (let ((this-command nil)) (insert "本文"))
    (run-hooks 'post-command-hook)
    (should (equal (buffer-string) "本文"))))

(ert-deftest tategaki-writing-newline-undo-preserves-source ()
  (tategaki-writing-test--with-buffer
    (insert "本文")
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (tategaki-writing-newline 1)
    (undo-boundary)
    (undo-only 1)
    (should (equal (buffer-string) "本文"))))

(ert-deftest tategaki-writing-typed-dialogue-and-indent-share-one-undo-step ()
  (tategaki-writing-test--with-buffer
    (insert "本文\n　")
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (tategaki-writing-test--type ?「)
    (undo-boundary)
    (undo-only 1)
    (should (equal (buffer-string) "本文\n　"))))

(ert-deftest tategaki-writing-custom-indent-and-point-offset ()
  (tategaki-writing-test--with-buffer
    (let ((tategaki-writing-paragraph-indent 3)
          (tategaki-writing-dialogue-indent 1))
      (insert "  本文\n　「声」")
      (goto-char 5)
      (tategaki-writing-indent-line)
      (should (equal (buffer-string) "　　　本文\n　「声」"))
      (should (= (point) 6))
      (forward-line 1)
      (tategaki-writing-indent-line)
      (should (equal (buffer-string) "　　　本文\n　「声」")))))

(ert-deftest tategaki-script-style-is-buffer-local-and-nonediting ()
  (with-temp-buffer
    (insert "元の本文")
    (set-buffer-modified-p nil)
    (tategaki-writing-set-style 'script)
    (should (eq tategaki-writing-style 'script))
    (should (local-variable-p 'tategaki-writing-style))
    (should-not (buffer-modified-p))
    (should-error (tategaki-writing-set-style 'invalid) :type 'user-error)))

(ert-deftest tategaki-script-format-region-aligns-three-paragraph-types ()
  (tategaki-writing-test--with-buffer
    (insert "　太郎：\n 「おはよう」\n　　（入ってくる）\n\n次の台詞\n末尾：")
    (tategaki-script-format-region (point-min) (point-max))
    (should (equal (buffer-string)
                   "太郎：\n　　「おはよう」\n　（入ってくる）\n\n　　次の台詞\n末尾："))
    (let ((original (buffer-string)))
      (tategaki-script-format-region (point-min) (point-max))
      (should (equal original (buffer-string))))))

(ert-deftest tategaki-script-region-at-line-start-excludes-next-paragraph ()
  (with-temp-buffer
    (insert "台詞\n次の台詞")
    (tategaki-script-format-region 1 4)
    (should (equal (buffer-string) "　　台詞\n次の台詞"))))

(ert-deftest tategaki-script-format-region-is-one-undo-step ()
  (tategaki-writing-test--with-buffer
    (insert "　太郎：\n「声」\n（退場）")
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (let ((original (buffer-string)))
      (tategaki-script-format-region (point-min) (point-max))
      (undo-boundary)
      (undo-only 1)
      (should (equal original (buffer-string))))))

(ert-deftest tategaki-script-dialogue-and-stage-commands-insert-editable-text ()
  (tategaki-writing-test--with-buffer
    (tategaki-script-insert-dialogue "太郎")
    (should (equal (buffer-string) "太郎：\n　　「」"))
    (should (= (char-after) ?」))
    (insert "こんにちは")
    (should (eq tategaki-writing-style 'script))
    (tategaki-script-insert-stage-direction "退場")
    (should (equal (buffer-string)
                   "太郎：\n　　「こんにちは」\n　（退場）"))
    (tategaki-script-insert-stage-direction "")
    (should (= (char-after) ?）))
    (should (string-suffix-p "\n　（）" (buffer-string)))))

(ert-deftest tategaki-script-invalid-input-does-not-modify-source ()
  (with-temp-buffer
    (insert "本文")
    (dolist (speaker '("" "　 " "太郎：" "太郎\n次郎"))
      (should-error (tategaki-script-insert-dialogue speaker) :type 'user-error))
    (should-error (tategaki-script-insert-stage-direction "次\n頁")
                  :type 'user-error)
    (should (equal (buffer-string) "本文"))))

(provide 'tategaki-writing-test)
;;; tategaki-writing-test.el ends here
