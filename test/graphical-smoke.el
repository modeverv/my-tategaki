;;; graphical-smoke.el --- Isolated GUI regression check -*- lexical-binding: t; -*-

;; Run in a NEW Emacs process:
;; emacs -Q -L . -l test/graphical-smoke.el
;; This process exits after testing.  Do not load into your editing session.
(unless (display-graphic-p)
  (error "This test requires a graphical Emacs frame"))
(load (expand-file-name "../org-tategaki-preview.el"
                        (file-name-directory load-file-name)) nil t)
(load (expand-file-name "org-tategaki-preview-test.el"
                        (file-name-directory load-file-name)) nil t)
(set-face-attribute 'default nil :family "Helvetica" :height 220)
(run-at-time
 1 nil
 (lambda ()
   (let ((stats (ert-run-tests-batch "org-tategaki-preview-graphical-alignment")))
     (kill-emacs (if (and (= 1 (ert-stats-total stats))
                          (= 0 (ert-stats-completed-unexpected stats)))
                     0 1)))))
