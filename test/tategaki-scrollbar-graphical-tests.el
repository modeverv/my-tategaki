;;; tategaki-scrollbar-graphical-tests.el --- Scrollbar pixels and input -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(let* ((directory (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (file-name-directory (directory-file-name directory))))
(setq load-prefer-newer t)
(require 'tategaki)

(defmacro tategaki-scroll-gui--with-text (rich &rest body)
  (declare (indent 1))
  `(save-window-excursion
     (let ((source (generate-new-buffer " *scroll GUI*")))
       (unwind-protect
           (progn
             (switch-to-buffer source) (delete-other-windows) (text-mode)
             (insert (make-string 1000 ?字)) (goto-char 1)
             (setq-local tategaki-typesetting ,rich tategaki-column-height 10)
             (buffer-enable-undo) (setq buffer-undo-list nil)
             (set-buffer-modified-p nil) (tategaki-mode 1)
             ,@body)
         (when (buffer-live-p source) (kill-buffer source))))))

(defun tategaki-scroll-gui--bar-position (&optional x)
  "Find the real scrollbar glyph at X in the rendered bottom area."
  (redisplay t)
  (let* ((height (window-body-height nil t))
         (x (or x (/ (window-body-width nil t) 2)))
         found)
    (cl-loop for y from (- height 45) below height
             for position = (posn-at-x-y x y)
             for object = (and position (posn-string position))
             when (and object (get-text-property (cdr object) 'tategaki-scrollbar (car object)))
             do (setq found position) and return nil)
    (should found)
    found))

(ert-deftest tategaki-scroll-gui-bottom-track-and-caret ()
  (dolist (rich '(nil t))
    (tategaki-scroll-gui--with-text rich
      (goto-char 8) (tategaki-refresh) (redisplay t)
      (let* ((bar (tategaki-scroll-gui--bar-position))
             (y (cdr (posn-x-y bar)))
             (pixel (tategaki-position-pixel (point)))
             (cursor (window-cursor-info)))
        (should (> y (- (window-body-height nil t) 45)))
        (should (= (aref cursor 2) (plist-get pixel :y)))
        (should (= (window-vscroll nil t) 0))))))

(ert-deftest tategaki-scroll-gui-click-drag-and-undo ()
  (tategaki-scroll-gui--with-text t
    (let* ((width (window-body-width nil t))
           (start (tategaki-scroll-gui--bar-position (/ width 2)))
           (finish (tategaki-scroll-gui--bar-position 30))
           (events (list (list 'mouse-movement finish) (list 'mouse-1 finish))))
      (cl-letf (((symbol-function 'read-event) (lambda (&rest _) (pop events))))
        (tategaki-scrollbar-drag (list 'down-mouse-1 start)))
      (should (> tategaki--page 50))
      (should (<= tategaki--page (aref (tategaki--entry) 3)
                  (+ tategaki--page tategaki--page-size -1)))
      (should-not (buffer-modified-p)) (should-not buffer-undo-list)
      (tategaki-scroll-gui--bar-position)
      (should (= (window-vscroll nil t) 0)))))

(ert-deftest tategaki-scroll-gui-resize-and-fixed-paper ()
  (tategaki-scroll-gui--with-text t
    (setq-local tategaki-manuscript-size '(20 . 20) tategaki-manuscript-grid t)
    (dolist (width '(65 90))
      (set-frame-size nil width 28)
      (tategaki-refresh) (redisplay t)
      (tategaki-scroll-to-column 3)
      (tategaki-scroll-gui--bar-position)
      (should (= tategaki--page 3))
      (should (= (window-vscroll nil t) 0)))))

(ert-deftest tategaki-scroll-gui-text-fallback-uses-pixel-event-coordinates ()
  (let ((available (symbol-function 'image-type-available-p)))
    (cl-letf (((symbol-function 'image-type-available-p)
               (lambda (type) (and (not (eq type 'svg)) (funcall available type)))))
      (tategaki-scroll-gui--with-text nil
        (let* ((start (tategaki-scroll-gui--bar-position (/ (window-body-width nil t) 2)))
               (events (list (list 'mouse-1 start))))
          (cl-letf (((symbol-function 'read-event) (lambda (&rest _) (pop events))))
            (tategaki-scrollbar-drag (list 'down-mouse-1 start)))
          (should (> tategaki--page 20))
          (should (< tategaki--page 80))
          (should-not (buffer-modified-p)))))))

(run-at-time 50 nil (lambda () (kill-emacs 2)))
(run-at-time
 1 nil
 (lambda ()
   (let ((status 2))
     (condition-case err
         (progn
           (set-frame-size nil 80 30)
           (let ((stats (ert-run-tests-batch "^tategaki-scroll-gui-")))
             (setq status (if (= (ert-stats-completed-expected stats) 4) 0 1))))
       (error (message "Scrollbar GUI setup failed: %S" err)))
     (with-current-buffer "*Messages*"
       (write-region (point-min) (point-max)
                     (expand-file-name "tategaki-scrollbar-gui-tests.log" temporary-file-directory)))
     (kill-emacs status))))
