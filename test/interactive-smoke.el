;;; interactive-smoke.el --- Real command-loop smoke test -*- lexical-binding: t; -*-

;; Run: emacs -Q -nw -L . -l test/interactive-smoke.el
;; Exits 0 on success, 1 on failure, 2 on timeout (15 seconds).
(require 'org-tategaki-preview)
(require 'cl-lib)

(defun org-tategaki-preview-smoke--check (function)
  "Run FUNCTION and exit with status 1 on failure."
  (condition-case err
      (funcall function)
    (error (message "Smoke failure: %S" err) (kill-emacs 1))))

(switch-to-buffer (get-buffer-create "smoke.org"))
(org-mode)
(insert "* 第一章\n\n吾輩は猫である。\n名前はまだ無い。\n\n「こんにちは。」")
(org-tategaki-preview)
(run-at-time 15 nil (lambda () (kill-emacs 2)))
(run-at-time
 0.5 nil
 (lambda ()
   (org-tategaki-preview-smoke--check
    (lambda ()
      (with-current-buffer "smoke.org"
        (goto-char (point-min))
        (search-forward "猫")
        (replace-match "犬"))
      (run-with-idle-timer
       1 nil
       (lambda ()
         (org-tategaki-preview-smoke--check
          (lambda ()
            (let* ((source (get-buffer "smoke.org"))
                   (preview (buffer-local-value 'org-tategaki-preview--preview source))
                   (window (get-buffer-window preview)))
              (with-current-buffer preview
                (cl-assert (string-match-p "犬" (buffer-string)))
                (cl-assert (string-match-p "︒" (buffer-string))))
              (split-window window 8 'below)
              ;; Let redisplay deliver the real buffer-local resize hook.
              (run-at-time
               1 nil
               (lambda ()
                 (org-tategaki-preview-smoke--check
                  (lambda ()
                    (with-current-buffer preview
                      (cl-assert (equal org-tategaki-preview--size
                                        (org-tategaki-preview--window-size window)))
                      (org-tategaki-preview-close))
                    (cl-assert (not (buffer-live-p preview)))
                    (with-current-buffer source
                      (cl-assert (not org-tategaki-preview-mode))
                      (cl-assert (not org-tategaki-preview--timer)))
                    (kill-emacs 0))))))))))))))
