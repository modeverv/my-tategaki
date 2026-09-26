;;; graphical-tests.el --- Run GUI checks in a dedicated Emacs -*- lexical-binding: t; -*-

;; Run: emacs -Q -l /absolute/path/to/test/graphical-tests.el
;; Exit status: 0 success, 1 failed test, 2 setup error or timeout.
(let* ((directory (file-name-directory (or load-file-name buffer-file-name)))
       (root (file-name-directory (directory-file-name directory))))
  (add-to-list 'load-path root)
  (load (expand-file-name "org-tategaki-preview.el" root) nil nil t)
  (load (expand-file-name "org-tategaki-preview-test.el" directory) nil nil t))

(run-at-time 60 nil (lambda () (kill-emacs 2)))
(run-at-time
 1 nil
 (lambda ()
   (let ((status 2))
     (condition-case err
         (progn
           (unless (display-graphic-p) (error "A graphical frame is required"))
           ;; A named selector errors if the test was not loaded.
           (let ((stats (ert-run-tests-batch
                         '(member org-tategaki-preview-frame-lifecycle
                                  org-tategaki-preview-frame-move-and-cleanup
                                  org-tategaki-preview-graphical-alignment
                                  org-tategaki-preview-cursor-scroll-sync
                                  org-tategaki-preview-sync-edit-and-narrowing
                                  org-tategaki-preview-sync-source-scroll
                                  org-tategaki-preview-text-modes-and-markup
                                  org-tategaki-preview-graphical-padding-and-row-height))))
             (setq status
                   (if (and (= (ert-stats-total stats) 8)
                            (= (ert-stats-completed-expected stats) 8)
                            (zerop (ert-stats-skipped stats)))
                       0 1))))
       (error (message "GUI test setup failed: %S" err)))
     (with-current-buffer "*Messages*"
       (write-region (point-min) (point-max)
                     (expand-file-name "org-tategaki-preview-gui-tests.log"
                                       temporary-file-directory)))
     (kill-emacs status))))

;;; graphical-tests.el ends here
