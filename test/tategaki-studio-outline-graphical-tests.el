;;; tategaki-studio-outline-graphical-tests.el --- Writing sidebar GUI -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Run ONLY in a dedicated Emacs -Q -l /absolute/path/to/this-file.
;; This exits that Emacs.  It never connects to the user's Emacs server.
(require 'ert)
(setq load-prefer-newer t)
(let* ((directory (file-name-directory (or load-file-name buffer-file-name)))
       (root (file-name-directory (directory-file-name directory))))
  (add-to-list 'load-path root)
  (load (expand-file-name "tategaki-studio-outline-test.el" directory) nil nil t))

(defun tategaki-studio-outline-gui--click (window help)
  "Dispatch the handler at WINDOW's real header pixel bearing HELP."
  (force-window-update window)
  (redisplay t)
  (let* ((height (window-header-line-height window))
         (position
          (cl-loop for x from 0 below (window-pixel-width window) by 2
                   for position = (posn-at-x-y x (max 1 (/ height 2)) window)
                   for object = (and position (posn-string position))
                   when (and object (equal (get-text-property (cdr object) 'help-echo (car object)) help))
                   return position)))
    (should position) (should (eq (posn-area position) 'header-line))
    (let ((handler (key-binding [header-line mouse-1] nil nil position)))
      (should (commandp handler))
      (funcall handler (list 'mouse-1 position)))
    (set-buffer (window-buffer (selected-window)))
    (redisplay t)))

(defun tategaki-studio-outline-gui--click-header (window command)
  "Click COMMAND in WINDOW's rendered Studio toolbar."
  (tategaki-studio-outline-gui--click window (symbol-name command)))

(defun tategaki-studio-outline-gui--close (window)
  "Click WINDOW's visible persistent close control."
  (tategaki-studio-outline-gui--click window "このペインを閉じて原稿へ戻る"))

(ert-deftest tategaki-studio-outline-gui-narrow-review-and-write-header-round-trip ()
  (should (display-graphic-p))
  (tategaki-studio-outline-test--source
    ;; A completed user edit already has its command-loop Undo boundary.
    ;; Seed it before real keyboard macros so their first event does not merely
    ;; add the missing boundary to the synthetic setup's direct `insert'.
    (undo-boundary)
    (let ((state (tategaki-studio-outline-test--state source))
          (source-window (get-buffer-window source)))
      (tategaki-studio-outline-gui--click-header source-window #'tategaki-studio-toggle-outline)
      (let ((outline (buffer-local-value 'tategaki-outline--buffer source)))
        (should (eq (selected-window) source-window))
        (tategaki-studio-outline-gui--click-header source-window #'tategaki-studio-review)
        (should (eq (buffer-local-value 'tategaki-studio-state source) 'review))
        ;; Widen the sidebar to force the compact Review toolbar in a real window.
        (let* ((window (get-buffer-window outline))
               (delta (- (window-body-width source-window) 55)))
          (when (> delta 0) (window-resize window delta t)))
        (should (< (window-body-width source-window) 85))
        (tategaki-studio-outline-gui--click-header source-window #'tategaki-studio-toggle-outline)
        (should-not (get-buffer-window outline))
        (tategaki-studio-outline-gui--click-header source-window #'tategaki-studio-toggle-outline)
        (setq outline (buffer-local-value 'tategaki-outline--buffer source))
        (should (get-buffer-window outline))
        (tategaki-studio-outline-gui--click-header source-window #'tategaki-studio-write)
        (should (eq (buffer-local-value 'tategaki-studio-state source) 'write))
        (should (get-buffer-window outline))
        (should (eq (selected-window) source-window))
        (execute-kbd-macro (kbd "C-c s o"))
        (should-not (get-buffer-window outline))
        (execute-kbd-macro (kbd "C-c s o"))
        (should (get-buffer-window (buffer-local-value 'tategaki-outline--buffer source))))
      (tategaki-studio-outline-test--unchanged source state))))

(run-with-timer
 1 nil
 (lambda ()
   (let ((stats
          (cl-letf (((symbol-function 'tategaki-studio-outline-test--click-header)
                     #'tategaki-studio-outline-gui--click-header)
                    ((symbol-function 'tategaki-studio-outline-test--close)
                     #'tategaki-studio-outline-gui--close))
            (ert-run-tests-batch "^tategaki-studio-outline-"))))
     (with-current-buffer "*Messages*"
       (write-region (point-min) (point-max)
                     (expand-file-name "tategaki-studio-outline-gui-tests.log" temporary-file-directory) nil 'silent))
     (kill-emacs (if (zerop (ert-stats-completed-unexpected stats)) 0 1)))))
;;; tategaki-studio-outline-graphical-tests.el ends here
