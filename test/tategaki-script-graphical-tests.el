;;; tategaki-script-graphical-tests.el --- Script mode GUI integration -*- lexical-binding: t; -*-

;; Run in a dedicated GUI process; this file runs its own ERT selector and exits.
(setq load-prefer-newer t)
(let* ((directory (file-name-directory (or load-file-name buffer-file-name)))
       (root (file-name-directory (directory-file-name directory))))
  (add-to-list 'load-path root))
(require 'ert)
(require 'cl-lib)
(require 'tategaki)
(require 'tategaki-script)

(defmacro tategaki-script-gui--with-text (text &rest body)
  "Run BODY in a fresh GUI script source containing TEXT."
  (declare (indent 1) (debug t))
  `(save-window-excursion
     (let ((source (generate-new-buffer " *Tategaki script GUI test*"))
           (tategaki-script-start-vertical t)
           (tategaki-writing-auto-indent t)
           (tategaki-script-speaker-indent 0)
           (tategaki-script-dialogue-indent 2)
           (tategaki-script-stage-direction-indent 1)
           (tategaki-column-height 10))
       (unwind-protect
           (progn
             (switch-to-buffer source)
             (delete-other-windows)
             (insert ,text)
             (goto-char (point-min))
             (buffer-enable-undo)
             (setq buffer-undo-list nil)
             (set-buffer-modified-p nil)
             (tategaki-script-mode)
             (font-lock-ensure)
             (tategaki-refresh)
             (redisplay t)
             ,@body)
         (when (buffer-live-p source)
           (with-current-buffer source
             (text-mode)
             (set-buffer-modified-p nil))
           (kill-buffer source))))))

(defun tategaki-script-gui--cell ()
  "Verify native source caret alignment and return its composed string cell."
  (tategaki-refresh)
  (redisplay t)
  (let* ((pixel (tategaki-position-pixel (point)))
         (cursor (window-cursor-info))
         (position (and pixel
                        (posn-at-x-y (+ 1 (plist-get pixel :x))
                                     (+ 1 (plist-get pixel :y)))))
         (cell (and position (posn-string position))))
    (should pixel)
    (should cursor)
    (should cell)
    (should (= (aref cursor 1) (plist-get pixel :x)))
    (should (= (aref cursor 2) (plist-get pixel :y)))
    cell))

(ert-deftest tategaki-script-gui-auto-start-renders-semantic-faces ()
  (tategaki-script-gui--with-text "○ 居間\n太郎：\n　　「声」\n　（退場）\n"
    (should tategaki-mode)
    (should tategaki-writing-mode)
    (should (plist-get tategaki--layout :typeset))
    (dolist (spec '(("○" . tategaki-script-scene-face)
                    ("太郎" . tategaki-script-speaker-face)
                    ("「" . tategaki-script-dialogue-face)
                    ("（" . tategaki-script-stage-direction-face)))
      (goto-char (point-min))
      (search-forward (car spec))
      (backward-char (length (car spec)))
      (let* ((cell (tategaki-script-gui--cell))
             (face (get-text-property (cdr cell) 'face (car cell)))
             (display (get-text-property (cdr cell) 'display (car cell))))
        (should (memq (cdr spec) face))
        (should display)))
    (should-not buffer-undo-list)
    (should-not (buffer-modified-p))))

(ert-deftest tategaki-script-gui-ret-native-pairs-and-undo ()
  (tategaki-script-gui--with-text "太郎："
    (goto-char (point-max))
    (execute-kbd-macro (kbd "RET"))
    (should (equal (buffer-string) "太郎：\n　　「」"))
    (should (eq (char-after) ?」))
    (tategaki-script-gui--cell)
    (execute-kbd-macro "声」")
    (should (equal (buffer-string) "太郎：\n　　「声」"))
    (tategaki-script-gui--cell)
    (undo-boundary)
    ;; Keep both undo commands in the same native command loop; a separate
    ;; keyboard macro restarts Emacs's undo/redo sequence.
    (execute-kbd-macro (kbd "C-/ C-/"))
    (should (equal (buffer-string) "太郎："))
    (tategaki-script-gui--cell)))

(ert-deftest tategaki-script-gui-scene-sidebar-ret-visits-source ()
  (tategaki-script-gui--with-text
      (concat "○ 居間\n太郎：\n「" (make-string 150 ?声) "」\n○ 廊下\n（退場）\n")
    (let ((text (buffer-string)))
      (execute-kbd-macro (kbd "C-c C-o"))
      (should (derived-mode-p 'tategaki-outline-mode))
      (let* ((entries (buffer-local-value 'tategaki-outline--entries source))
             (second (aref entries 1)))
        (should (= (length entries) 2))
        (goto-char (aref second 3))
        (execute-kbd-macro (kbd "RET")))
      (should (eq (current-buffer) source))
      (should (looking-at "○ 廊下"))
      (tategaki-script-gui--cell)
      (should (equal text (buffer-string)))
      (should-not buffer-undo-list)
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-script-gui-horizontal-toggle-keeps-script-then-exit-cleans-view ()
  (tategaki-script-gui--with-text "○ 居間\n太郎：\n　　「声」"
    (let ((text (buffer-string)) (undo buffer-undo-list))
      (execute-kbd-macro (kbd "C-c C-c"))
      (should (derived-mode-p 'tategaki-script-mode))
      (should-not tategaki-mode)
      (should tategaki-writing-mode)
      (should (eq (key-binding (kbd "RET")) #'tategaki-script-newline))
      (tategaki-typeset-edit)
      (tategaki-script-gui--cell)
      (text-mode)
      (redisplay t)
      (should-not tategaki-mode)
      (should-not tategaki-writing-mode)
      (should-not (cl-find-if
                   (lambda (overlay) (overlay-get overlay 'tategaki-internal))
                   (overlays-in (point-min) (point-max))))
      (should (equal text (buffer-string)))
      (should (eq undo buffer-undo-list))
      (should-not (buffer-modified-p)))))

(unless noninteractive
  (run-at-time 60 nil (lambda () (kill-emacs 2)))
  (run-at-time
   1 nil
   (lambda ()
     (let ((status 2))
       (condition-case err
           (progn
             (unless (and (display-graphic-p) (image-type-available-p 'svg)
                          (fboundp 'window-cursor-info))
               (error "Script GUI tests require graphical Emacs with SVG"))
             (set-frame-size (selected-frame) 100 36)
             (let ((stats (ert-run-tests-batch "^tategaki-script-gui-")))
               (setq status
                     (if (and (= (ert-stats-completed-expected stats) 4)
                              (zerop (ert-stats-completed-unexpected stats))
                              (zerop (ert-stats-skipped stats))) 0 1))))
         (error (message "Script GUI setup failed: %S" err)))
       (with-current-buffer "*Messages*"
         (write-region
          (point-min) (point-max)
          (expand-file-name "tategaki-script-gui-tests.log" temporary-file-directory)))
       (kill-emacs status)))))

(provide 'tategaki-script-graphical-tests)
;;; tategaki-script-graphical-tests.el ends here
