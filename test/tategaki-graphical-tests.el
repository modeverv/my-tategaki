;;; tategaki-graphical-tests.el --- Native editing GUI checks -*- lexical-binding: t; -*-

;; Run in a dedicated instance:
;; emacs -Q -l /absolute/path/to/test/tategaki-graphical-tests.el
;; Exit status: 0 success, 1 test failure, 2 setup error or timeout.

(require 'ert)
(require 'cl-lib)
(let* ((directory (file-name-directory (or load-file-name buffer-file-name)))
       (root (file-name-directory (directory-file-name directory))))
  (add-to-list 'load-path root)
  (load (expand-file-name "tategaki-layout.el" root) nil nil t)
  (load (expand-file-name "tategaki.el" root) nil nil t))

(defmacro tategaki-gui--with-text (text &rest body)
  "Display TEXT in an isolated editing buffer, then execute BODY."
  (declare (indent 1))
  `(save-window-excursion
     (let ((buffer (generate-new-buffer " *tategaki GUI test*"))
           (tategaki-column-height 4))
       (unwind-protect
           (progn
             (switch-to-buffer buffer)
             (delete-other-windows)
             (text-mode)
             (insert ,text)
             (goto-char (point-min))
             (buffer-enable-undo)
             (setq buffer-undo-list nil)
             (tategaki-mode 1)
             ,@body)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when tategaki-mode (tategaki-mode -1))
             (set-buffer-modified-p nil))
           (kill-buffer buffer))))))

(defun tategaki-gui--source-at-pixel (x y)
  "Return the source position of the glyph at window-relative X and Y."
  (let* ((position (posn-at-x-y x y (selected-window)))
         (object (and position (posn-string position))))
    (and object
         (get-text-property (cdr object) 'tategaki-position (car object)))))

(defun tategaki-gui--assert-cursor ()
  "Verify the actual native cursor covers the glyph for source point."
  (let ((source-point (point)))
    (tategaki-refresh)
    (redisplay t)
    (should (= (point) source-point))
    (let ((cursor (window-cursor-info (selected-window))))
      (should cursor)
      (should (<= 0 (aref cursor 1)))
      (should (<= 0 (aref cursor 2)))
      (should (equal source-point
                     (tategaki-gui--source-at-pixel
                      ;; NS reports width 0 in an inactive test frame.
                      ;; Probe inside the glyph, not its zero-width spacer
                      ;; boundary (which correctly has no source position).
                      (+ (aref cursor 1) (max 1 (/ (aref cursor 3) 2)))
                      (+ (aref cursor 2) (max 0 (/ (aref cursor 4) 2)))))))))

(ert-deftest tategaki-gui-native-cursor-every-cell ()
  ;; Include ASCII, Japanese, vertical punctuation, newlines and EOF.
  ;; Checking real cursor pixels catches display strings whose Lisp
  ;; `cursor' property exists but is ignored by the redisplay engine.
  (tategaki-gui--with-text "天地AB玄黄。「宇宙」\n洪荒日月盈昃"
    (dotimes (index (1+ (buffer-size)))
      (goto-char (1+ index))
      (tategaki-gui--assert-cursor))))

(ert-deftest tategaki-gui-stable-glyph-position ()
  (tategaki-gui--with-text "天地玄黄宇宙洪荒日月盈昃"
    (let (baseline)
      (dotimes (index (1+ (buffer-size)))
        (goto-char (1+ index))
        (tategaki-refresh)
        (redisplay t)
        (let ((locations (make-vector (1+ (buffer-size)) nil))
              (line-height (nth 2 tategaki--metrics)))
          (dotimes (row (plist-get tategaki--layout :height))
            (let ((y (+ (* row line-height) (/ line-height 2))))
              (dotimes (x (window-body-width nil t))
                (let ((position (tategaki-gui--source-at-pixel x y)))
                  (when (and position (not (aref locations (1- position))))
                    (aset locations (1- position) (cons x y)))))))
          (should (cl-every #'identity (append locations nil)))
          (if (zerop index)
              (setq baseline locations)
            (unless (equal locations baseline)
              (message "Glyph movement at point %s: expected %S; got %S"
                       (point) baseline locations))
            (should (equal (list (point) locations)
                           (list (point) baseline)))))))))

(ert-deftest tategaki-gui-native-keyboard-and-input-method ()
  (tategaki-gui--with-text "ABCDEFGHIJKL"
    (execute-kbd-macro (kbd "<down>"))
    (should (= (point) 2))
    (execute-kbd-macro "x")
    (should (equal (buffer-string) "AxBCDEFGHIJKL"))
    (should (= (point) 3))
    (tategaki-gui--assert-cursor)
    (execute-kbd-macro (kbd "DEL"))
    (should (equal (buffer-string) "ABCDEFGHIJKL"))
    (should (= (point) 2))
    (execute-kbd-macro (kbd "<left>"))
    (should (= (point) 6))
    (execute-kbd-macro (kbd "<right> <up>"))
    (should (= (point) 1))
    (unwind-protect
        (progn
          (activate-input-method "japanese")
          (execute-kbd-macro "ni")
          (should (equal (buffer-string) "にABCDEFGHIJKL"))
          (should (= (point) 2))
          (tategaki-gui--assert-cursor))
      (deactivate-input-method))))

(ert-deftest tategaki-gui-empty-eof-undo-and-save ()
  (tategaki-gui--with-text ""
    (tategaki-gui--assert-cursor)
    (execute-kbd-macro "ab")
    (should (equal (buffer-string) "ab"))
    (should (= (point) (point-max)))
    (tategaki-gui--assert-cursor)
    (execute-kbd-macro (kbd "DEL DEL"))
    (should (equal (buffer-string) ""))
    (tategaki-gui--assert-cursor)
    (insert "原文\t*literal*\n末尾\n")
    (undo-boundary)
    (insert "追加")
    (undo-boundary)
    (undo-only 1)
    (should (equal (buffer-string) "原文\t*literal*\n末尾\n"))
    (tategaki-gui--assert-cursor)
    (let ((file (make-temp-file "tategaki-gui-" nil ".txt"))
          (original (buffer-string)))
      (unwind-protect
          (progn
            (set-visited-file-name file t)
            (set-buffer-file-coding-system 'utf-8-unix)
            (save-buffer)
            (should-not (buffer-modified-p))
            (should (equal original
                           (with-temp-buffer
                             (insert-file-contents file)
                             (buffer-string)))))
        (set-visited-file-name nil t)
        (delete-file file)))))

(ert-deftest tategaki-gui-paging-and-resize ()
  (let ((width (frame-width)) (height (frame-height)))
    (unwind-protect
        (tategaki-gui--with-text (make-string 800 ?文)
          (goto-char (point-max))
          (tategaki-gui--assert-cursor)
          (should (> tategaki--page 0))
          (set-frame-size (selected-frame) 48 22)
          (sit-for 0.1)
          (tategaki-gui--assert-cursor)
          (should (> tategaki--page 0))
          (goto-char (point-min))
          (tategaki-gui--assert-cursor)
          (should (zerop tategaki--page)))
      (set-frame-size (selected-frame) width height))))

(ert-deftest tategaki-gui-auto-height-last-row-and-eof ()
  (let* ((frame (selected-frame))
         (width (frame-width frame))
         (height (frame-height frame))
         (font-height (face-attribute 'default :height frame)))
    (unwind-protect
        (tategaki-gui--with-text (make-string 200 ?文)
          (setq tategaki-column-height nil)
          (set-face-attribute 'default frame :height 220)
          (set-frame-size frame 42 16)
          (sit-for 0.1)
          (tategaki-refresh)
          (let ((rows (plist-get tategaki--layout :height)))
            (should (> rows 1))
            (goto-char rows)
            (tategaki-gui--assert-cursor)
            (should (= (aref (tategaki--entry) 2) (1- rows)))
            ;; Put EOF itself in the last fitted row, so a visible body
            ;; character cannot mask a cursor that has fallen below it.
            (erase-buffer)
            (insert (make-string (1- rows) ?文))
            (tategaki-gui--assert-cursor)
            (should (= (aref (tategaki--entry) 2) (1- rows)))))
      (set-face-attribute 'default frame :height font-height)
      (set-frame-size frame width height))))

(ert-deftest tategaki-gui-mouse-source-position ()
  (tategaki-gui--with-text "天地玄黄宇宙洪荒日月盈昃"
    (goto-char 7)
    (tategaki-gui--assert-cursor)
    (let* ((cursor (window-cursor-info))
           (x (+ (aref cursor 1) (/ (aref cursor 3) 2)))
           (y (+ (aref cursor 2) (/ (aref cursor 4) 2))))
      (goto-char 1)
      (tategaki-refresh)
      (redisplay t)
      (should (equal 7 (tategaki-gui--source-at-pixel x y)))
      ;; A real glyph position supplies the event; dispatch through the
      ;; mode keymap rather than calling its mouse handler directly.
      (execute-kbd-macro (vector (list 'down-mouse-1 (posn-at-x-y x y))))
      (should (= (point) 7))
      (tategaki-gui--assert-cursor))))

(ert-deftest tategaki-gui-drag-selects-source-region ()
  (tategaki-gui--with-text "天地玄黄宇宙洪荒日月盈昃"
    (let (pixels)
      (tategaki-refresh)
      (redisplay t)
      (dolist (position '(2 9))
        (let* ((row (aref (tategaki--entry position) 2))
               (line-height (nth 2 tategaki--metrics))
               (y (+ (* row line-height) (/ line-height 2)))
               (x (cl-loop for x from 0 below (window-body-width nil t)
                           when (equal position (tategaki-gui--source-at-pixel x y))
                           return x)))
          (should x)
          (push (cons x y) pixels)))
      (setq pixels (nreverse pixels))
      (let ((begin (posn-at-x-y (caar pixels) (cdar pixels)))
            (end (posn-at-x-y (caadr pixels) (cdadr pixels))))
        (should (= (tategaki--mouse-position begin) 2))
        (should (= (tategaki--mouse-position end) 9))
        (execute-kbd-macro (vector (list 'drag-mouse-1 begin end))))
      (should (use-region-p))
      (should (= (region-beginning) 2))
      (should (= (region-end) 9))
      (should (equal (buffer-substring (region-beginning) (region-end))
                     "地玄黄宇宙洪荒"))
      (tategaki-gui--assert-cursor)
      (execute-kbd-macro (kbd "C-w"))
      (should (equal (buffer-string) "天日月盈昃"))
      (tategaki-gui--assert-cursor))))

(run-at-time 60 nil (lambda () (kill-emacs 2)))
(run-at-time
 1 nil
 (lambda ()
   (let ((status 2))
     (condition-case err
         (progn
           (unless (and (display-graphic-p) (fboundp 'window-cursor-info))
             (error "A graphical Emacs with window-cursor-info is required"))
           (delete-other-windows)
           (set-frame-size (selected-frame) 72 28)
           (let ((stats (ert-run-tests-batch "^tategaki-gui-")))
             (setq status
                   (if (and (= (ert-stats-total stats) 8)
                            (= (ert-stats-completed-expected stats) 8)
                            (zerop (ert-stats-skipped stats)))
                       0 1))))
       (error (message "Vertical editing GUI setup failed: %S" err)))
     (with-current-buffer "*Messages*"
       (write-region (point-min) (point-max)
                     (expand-file-name "tategaki-gui-tests.log"
                                       temporary-file-directory)))
     (kill-emacs status))))

;;; tategaki-graphical-tests.el ends here
