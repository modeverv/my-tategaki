;;; tategaki-corpus-graphical-tests.el --- Dedicated collection panel GUI check -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; This named isolated GUI process exits after its test.  Never load it in a
;; user's working Emacs process.
(require 'server)
(defvar tategaki-corpus-gui--directory (make-temp-file "/tmp/tategaki-corpus-gui-" t))
(setq server-name "tategaki-isolated-corpus-gui"
      server-socket-dir (expand-file-name "sockets" tategaki-corpus-gui--directory)
      user-emacs-directory (expand-file-name "userdata/" tategaki-corpus-gui--directory)
      load-prefer-newer t inhibit-startup-screen t)
(make-directory server-socket-dir t)
(set-file-modes server-socket-dir #o700)
(make-directory user-emacs-directory t)
(server-start)
(let ((directory (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (file-name-directory (directory-file-name directory)))
  (load (expand-file-name "tategaki-corpus-test.el" directory) nil nil t))
(require 'tategaki-studio)

(ert-deftest tategaki-corpus-gui-panel-selection-search-and-citation ()
  (tategaki-corpus-test--isolated
    (switch-to-buffer source)
    (setq-local tategaki-typesetting t)
    (set-buffer-modified-p nil)
    (tategaki-studio-mode 1)
    (let ((text (buffer-string)) (undo buffer-undo-list)
          (position (point)) panel results)
      (unwind-protect
          (progn
            (tategaki-corpus-register sea 'manuscript)
            (tategaki-corpus-register forest 'resource)
            (setq panel (tategaki-corpus))
            (should (eq (window-parameter (selected-window) 'window-side) 'right))
            (should (eq (tategaki-studio-source-buffer) source))
            (goto-char (point-min))
            (search-forward "[対象]")
            (button-activate (button-at (1- (point))))
            (should-not (alist-get 'enabled (car (tategaki-corpus--read directory))))
            (goto-char (point-min)) (search-forward "[除外]")
            (button-activate (button-at (1- (point))))
            (should (alist-get 'enabled (car (tategaki-corpus--read directory))))
            (tategaki-corpus-search "海")
            (setq results (get-buffer (format "*Tategaki Corpus Search: %s*" (buffer-name source))))
            (should (buffer-live-p results))
            (should (eq (window-parameter (get-buffer-window results) 'window-side) 'bottom))
            (select-window (get-buffer-window results))
            (goto-char (point-min)) (search-forward "sea.txt")
            (button-activate (button-at (1- (point))))
            (should (equal (file-truename buffer-file-name) sea))
            (with-current-buffer source
              (should (equal text (buffer-string)))
              (should (eq undo buffer-undo-list))
              (should (= position (point)))
              (should-not (buffer-modified-p))))
        (dolist (buffer (list panel results))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(add-hook
 'emacs-startup-hook
 (lambda ()
   (run-at-time
    1 nil
    (lambda ()
      (let ((status 2))
        (condition-case error-data
            (progn
              (unless (display-graphic-p) (error "GUI required"))
              (set-frame-size nil 150 48)
              (let ((stats (ert-run-tests-batch "^tategaki-corpus-gui-")))
                (setq status (if (and (= (ert-stats-completed-expected stats) 1)
                                      (zerop (ert-stats-completed-unexpected stats))) 0 1))))
          (error (message "Corpus GUI error: %S" error-data)))
        (with-current-buffer "*Messages*"
          (write-region (point-min) (point-max) "/tmp/tategaki-corpus-gui-tests.log"))
        (kill-emacs status))))) t)
(add-hook 'kill-emacs-hook
          (lambda () (ignore-errors (delete-directory tategaki-corpus-gui--directory t))) t)
(run-at-time 60 nil
             (lambda ()
               (with-current-buffer "*Messages*"
                 (write-region (point-min) (point-max) "/tmp/tategaki-corpus-gui-tests.log"))
               (kill-emacs 2)))
;;; tategaki-corpus-graphical-tests.el ends here
