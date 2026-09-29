;;; tategaki-pane-graphical-tests.el --- Actual pane header dispatch -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Launch ONLY in a dedicated Emacs -Q -l /absolute/path/to/this-file.
;; It exits this Emacs, never uses another server, and performs no AI/Docker work.
(require 'ert)
(setq load-prefer-newer t)
(let* ((directory (file-name-directory (or load-file-name buffer-file-name)))
       (root (file-name-directory (directory-file-name directory))))
  (add-to-list 'load-path root)
  (load (expand-file-name "tategaki-pane-test.el" directory) nil nil t))

(defun tategaki-pane-gui--position (window &optional help)
  "Find a real header pixel in WINDOW with HELP, without selecting WINDOW."
  (force-window-update window)
  (redisplay t)
  (let* ((help (or help "このペインを閉じて原稿へ戻る"))
         (height (window-header-line-height window))
         (position
          (cl-loop for x from 0 below (window-pixel-width window) by 2
                   for pos = (posn-at-x-y x (max 1 (/ height 2)) window)
                   for object = (and pos (posn-string pos))
                   when (and object (equal (get-text-property (cdr object) 'help-echo (car object)) help))
                   return pos)))
    (should position) (should (eq (posn-area position) 'header-line))
    position))

(defun tategaki-pane-gui--click (window)
  "Resolve and call WINDOW's mouse handler from its actual rendered header."
  (let* ((position (tategaki-pane-gui--position window))
         (handler (key-binding [header-line mouse-1] nil nil position)))
    (should (eq handler #'tategaki-pane-close))
    (funcall handler (list 'mouse-1 position))))

(ert-deftest tategaki-pane-gui-close-stays-visible-after-body-scroll ()
  (should (display-graphic-p))
  (tategaki-pane-test--source
    (let* ((state (tategaki-pane-test--source-state source))
           (panel (tategaki-world-panel "スクロール検証"
                                        (lambda () (dotimes (n 200) (insert (format "行 %d\n" n))))))
           (window (get-buffer-window panel))
           (other (tategaki-pane-test--other-pane)))
      (with-selected-window window
        (goto-char (point-min)) (forward-line 100)
        (set-window-start window (point)) (set-window-point window (point)))
      (select-window (get-buffer-window other))
      (redisplay t)
      (should (> (window-start window) 1))
      (tategaki-pane-gui--click window)
      (should-not (get-buffer-window panel)) (should (get-buffer-window other))
      (tategaki-pane-test--assert-source source state))))

(ert-deftest tategaki-pane-gui-reader-visible-close-restores-editing-and-layout ()
  (should (display-graphic-p))
  (tategaki-pane-test--source
    (let ((state (tategaki-pane-test--source-state source))
          (other (tategaki-pane-test--other-pane)))
      (select-window (get-buffer-window source)) (set-buffer source)
      (tategaki-reader-mode 1)
      (let* ((position (tategaki-pane-gui--position (selected-window) "[閉じる・執筆に戻る]"))
             (handler (key-binding [header-line mouse-1] nil nil position)))
        (should (commandp handler)) (funcall handler (list 'mouse-1 position)))
      (with-current-buffer source (should-not tategaki-reader-mode) (should-not buffer-read-only))
      (should (get-buffer-window other))
      (tategaki-pane-test--assert-source source state))))

(run-with-timer
 1 nil
 (lambda ()
   (let ((stats
          (cl-letf (((symbol-function 'tategaki-pane-test--click) #'tategaki-pane-gui--click))
            (ert-run-tests-batch "^tategaki-pane-"))))
     (with-current-buffer "*Messages*"
       (write-region (point-min) (point-max)
                     (expand-file-name "tategaki-pane-gui-tests.log" temporary-file-directory) nil 'silent))
     (kill-emacs (if (zerop (ert-stats-completed-unexpected stats)) 0 1)))))
;;; tategaki-pane-graphical-tests.el ends here
