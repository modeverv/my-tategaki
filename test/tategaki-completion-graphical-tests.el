;;; tategaki-completion-graphical-tests.el --- Copilot GUI checks -*- lexical-binding: t; -*-
;; Run in a dedicated Emacs process; exits after the tests.  No server requests.
(require 'ert)
(let* ((directory (file-name-directory (or load-file-name buffer-file-name)))
       (root (file-name-directory (directory-file-name directory))))
  (add-to-list 'load-path root)
  (setq load-prefer-newer t)
  (load (expand-file-name "test/tategaki-completion-test.el" root) nil t t))

(defun tategaki-completion-gui--glyph (virtual)
  "Find VIRTUAL glyph's screen location in the current display."
  (redisplay t)
  (cl-loop for y from 0 below (window-body-height nil t) by 4
           thereis (cl-loop for x from 0 below (window-body-width nil t) by 4
                            for posn = (posn-at-x-y x y)
                            for object = (and posn (posn-string posn))
                            when (and object (eql virtual (get-text-property (cdr object)
                                                    'tategaki-virtual-position (car object))))
                            return posn)))

(defun tategaki-completion-gui--xy (posn)
  "Return the glyph origin, not the sampled pixel within it."
  (cons (- (car (posn-x-y posn)) (car (posn-object-x-y posn)))
        (- (cdr (posn-x-y posn)) (cdr (posn-object-x-y posn)))))

(ert-deftest tategaki-completion-gui-ghost-wraps-and-keeps-cursor ()
  (tategaki-completion-test--with-text "前後"
    (goto-char 2)
    (copilot--display-overlay-completion "日本語入力" nil "日本語入力" 2 2)
    (redisplay t)
    (let* ((first (tategaki-completion-gui--glyph 2))
           (second (tategaki-completion-gui--glyph 3))
           (third (tategaki-completion-gui--glyph 4))
           (cursor (window-cursor-info)))
      (should first) (should second) (should third) (should cursor)
      (should (= (car (tategaki-completion-gui--xy first)) (car (tategaki-completion-gui--xy second))))
      (should (< (cdr (tategaki-completion-gui--xy first)) (cdr (tategaki-completion-gui--xy second))))
      (should (< (car (tategaki-completion-gui--xy third)) (car (tategaki-completion-gui--xy first))))
      (should (< (cdr (tategaki-completion-gui--xy third)) (cdr (tategaki-completion-gui--xy first))))
      (should (= (aref cursor 1) (car (tategaki-completion-gui--xy first))))
      (should (= (aref cursor 2) (cdr (tategaki-completion-gui--xy first))))
      (let* ((object (posn-string first))
             (face (get-text-property (cdr object) 'face (car object))))
        (should (memq 'copilot-overlay-face face))))
    (should (equal (buffer-string) "前後"))
    (should-not (buffer-modified-p))))

(ert-deftest tategaki-completion-gui-native-accept-key-at-empty-and-eof ()
  (dolist (text '("" "前文"))
    (tategaki-completion-test--with-text text
      (goto-char (point-max))
      (let ((copilot-completion-map (copy-keymap copilot-completion-map)))
        (define-key copilot-completion-map (kbd "<f6>") #'copilot-accept-completion)
        (copilot--display-overlay-completion "日本語" nil "日本語" (point) (point))
        (redisplay t)
        (should (eq (key-binding (kbd "<f6>")) #'copilot-accept-completion))
        (execute-kbd-macro (kbd "<f6>"))
        (should (equal (buffer-string) (concat text "日本語")))
        (should-not (tategaki-completion-current))
        (undo-boundary)
        (undo-only 1)
        (tategaki-refresh)
        (should (equal (buffer-string) text))))))

(ert-deftest tategaki-completion-gui-restore-horizontal-with-native-object ()
  (tategaki-completion-test--with-text "原文"
    (goto-char (point-max))
    (copilot--display-overlay-completion "続き" nil "続き" (point) (point))
    (let ((native copilot--overlay))
      (tategaki-mode -1)
      (redisplay t)
      (should (eq native copilot--overlay))
      (should (equal (overlay-get native 'after-string) "続き"))
      (should (equal (buffer-string) "原文"))
      (should-not (buffer-modified-p)))))

(run-at-time 60 nil (lambda () (kill-emacs 2)))
(run-at-time
 1 nil
 (lambda ()
   (let ((status 2))
     (condition-case err
         (progn
           (unless (and (display-graphic-p) (featurep 'copilot))
             (error "GUI Emacs and installed Copilot required"))
           (delete-other-windows)
           (set-frame-size (selected-frame) 64 23)
           (let ((stats (ert-run-tests-batch "^tategaki-completion-gui-")))
             (setq status (if (and (= (ert-stats-completed-expected stats) 3)
                                  (zerop (ert-stats-skipped stats))) 0 1))))
       (error (message "Completion GUI failure: %S" err)))
     (with-current-buffer "*Messages*"
       (write-region (point-min) (point-max)
                     (expand-file-name "tategaki-completion-gui-tests.log" temporary-file-directory)))
     (kill-emacs status))))
;;; tategaki-completion-graphical-tests.el ends here
