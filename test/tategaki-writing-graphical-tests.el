;;; tategaki-writing-graphical-tests.el --- Native writing integration -*- lexical-binding: t; -*-

;; Run in a dedicated NS Emacs; this runner exits after testing.
;; emacs -Q -l /absolute/path/to/test/tategaki-writing-graphical-tests.el

(setq load-prefer-newer t)
(let* ((directory (file-name-directory (or load-file-name buffer-file-name)))
       (root (file-name-directory (directory-file-name directory))))
  (add-to-list 'load-path root))
(require 'ert)
(require 'tategaki)

(declare-function ns-put-marked-text "ns-win" (event))
(declare-function ns-unput-working-text "ns-win" ())
(declare-function ns-delete-working-text "ns-win" ())
(defvar ns-working-text)
(defvar ns-working-overlay)

(defmacro tategaki-writing-gui--with-buffer (&rest body)
  "Run BODY in an isolated GUI buffer with writing assistance enabled."
  (declare (indent 0) (debug t))
  `(save-window-excursion
     (let ((buffer (generate-new-buffer " *Tategaki writing GUI test*"))
           (tategaki-writing-assistance t)
           (tategaki-writing-auto-indent t)
           (tategaki-writing-electric-pair t)
           (tategaki-writing-style 'prose)
           (tategaki-writing-paragraph-indent 1)
           (tategaki-writing-dialogue-indent 0)
           (ns-working-text "")
           (ns-working-overlay nil))
       (unwind-protect
           (progn
             (switch-to-buffer buffer)
             (text-mode)
             (buffer-enable-undo)
             (setq buffer-undo-list nil)
             ,@body)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (ns-delete-working-text)
             (tategaki-mode -1)
             (set-buffer-modified-p nil))
           (kill-buffer buffer))))))

(ert-deftest tategaki-writing-gui-command-loop-and-undo ()
  (tategaki-writing-gui--with-buffer
    (tategaki-typeset-edit)
    (should tategaki-writing-mode)
    (execute-kbd-macro (vconcat "本文" (kbd "RET") "「声」"))
    (redisplay t)
    (should (equal (buffer-string) "　本文\n「声」"))
    (should (= tategaki--caret-position (point)))
    (should (window-cursor-info))
    ;; Native command-loop grouping keeps RET separate.  Undoing the dialogue
    ;; also restores the provisional paragraph indent removed by 「 input.
    (undo-boundary)
    (undo-only 1)
    (tategaki-refresh)
    (should (equal (buffer-string) "　本文\n　"))
    (tategaki-mode -1)
    (should-not tategaki-writing-mode)
    (should-not (local-variable-p 'electric-pair-mode))))

(ert-deftest tategaki-writing-gui-native-marked-then-commit ()
  (tategaki-writing-gui--with-buffer
    (insert "前文\n　")
    (tategaki-typeset-edit)
    (setq ns-working-text "「会話」")
    (ns-put-marked-text '(ns-put-marked-text 1 2))
    (should (equal (buffer-string) "前文\n　"))
    ;; Exercise actual native preedit teardown and committed command-loop
    ;; input; the OS candidate selection interaction itself is outside scope.
    (ns-unput-working-text)
    (execute-kbd-macro "「会話」")
    (redisplay t)
    (should (equal (buffer-string) "前文\n「会話」"))
    (should-not tategaki-ime--text)
    (should (= tategaki--caret-position (point)))
    (should (window-cursor-info))))

(unless noninteractive
  (run-at-time 60 nil (lambda () (kill-emacs 2)))
  (run-at-time
   1 nil
   (lambda ()
     (let ((status 2))
       (condition-case err
           (progn
             (unless (and (eq window-system 'ns)
                          (image-type-available-p 'svg)
                          (fboundp 'window-cursor-info)
                          (fboundp 'ns-put-marked-text))
               (error "Writing GUI tests require NS Emacs with SVG and marked text"))
             (delete-other-windows)
             (set-frame-size (selected-frame) 80 32)
             (let ((stats (ert-run-tests-batch "^tategaki-writing-gui-")))
               (setq status
                     (if (and (= (ert-stats-total stats) 2)
                              (= (ert-stats-completed-expected stats) 2)
                              (zerop (ert-stats-skipped stats))) 0 1))))
         (error (message "Writing GUI setup failed: %S" err)))
       (with-current-buffer "*Messages*"
         (write-region
          (point-min) (point-max)
          (expand-file-name "tategaki-writing-gui-tests.log"
                            temporary-file-directory)))
       (kill-emacs status)))))

(provide 'tategaki-writing-graphical-tests)
;;; tategaki-writing-graphical-tests.el ends here
