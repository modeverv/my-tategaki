;;; tategaki-corfu-test.el --- Real Corfu adapter checks -*- lexical-binding: t; -*-

;; Add installed Corfu and compat directories to load-path for these tests.
;; The installed Corfu overlay and insertion functions run unchanged; only
;; the renderer boundary is recorded so tests can also run in batch Emacs.

(require 'ert)
(require 'cl-lib)
(require 'tategaki-corfu)
(require 'corfu nil t)

(defvar tategaki-ime--text nil)
(defvar-local tategaki-corfu-test--snapshot nil)

(defmacro tategaki-corfu-test--with-buffer (text &rest body)
  "Run BODY with real Corfu and a recording renderer for TEXT."
  (declare (indent 1))
  `(progn
     (skip-unless (featurep 'corfu))
     (save-window-excursion
       (let ((buffer (generate-new-buffer " *Tategaki Corfu test*"))
             (corfu--preview-ov nil)
             (corfu--candidates '("日本語入力" "日本語能力"))
             (corfu--base "")
             (corfu--index 0)
             (corfu--preselect -1)
             (corfu--total 2)
             (corfu-preview-current t))
         (cl-letf (((symbol-function 'tategaki-completion-set)
                    (lambda (owner beg end value &optional caret)
                      (setq tategaki-corfu-test--snapshot
                            (list owner beg end value caret))))
                   ((symbol-function 'tategaki-completion-clear)
                    (lambda (owner)
                      (when (eq owner (car tategaki-corfu-test--snapshot))
                        (setq tategaki-corfu-test--snapshot nil)))))
           (unwind-protect
               (progn
                 (switch-to-buffer buffer)
                 (text-mode)
                 (insert ,text)
                 (buffer-enable-undo)
                 (setq buffer-undo-list nil)
                 (set-buffer-modified-p nil)
                 (setq-local tategaki--window (selected-window))
                 (tategaki-corfu-enable)
                 ,@body)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (corfu--preview-delete)
                 (tategaki-corfu-disable)
                 (set-buffer-modified-p nil))
               (kill-buffer buffer))))))))

(ert-deftest tategaki-corfu-preview-replaces-range-without-source-edits ()
  (tategaki-corfu-test--with-buffer "前日本後"
    (goto-char 4)
    (let ((tick (buffer-chars-modified-tick)))
      (corfu--preview-current 2 4)
      (should (equal tategaki-corfu-test--snapshot
                     '(corfu 2 4 "日本語入力" nil)))
      (should (eq corfu--preview-ov (car tategaki-corfu--preview)))
      (should (eq (overlay-get corfu--preview-ov 'window) (selected-window)))
      (should-not (overlay-get corfu--preview-ov 'display))
      (should-not (overlay-get corfu--preview-ov 'after-string))
      (should (equal (buffer-string) "前日本後"))
      (should (= (point) 4))
      (should (= (buffer-chars-modified-tick) tick))
      (should-not (buffer-modified-p))
      (should-not buffer-undo-list))))

(ert-deftest tategaki-corfu-preview-keeps-completion-base ()
  (tategaki-corfu-test--with-buffer "前/日本後"
    (setq corfu--base "前/")
    (goto-char 5)
    (corfu--preview-current 1 5)
    (should (equal tategaki-corfu-test--snapshot
                   '(corfu 3 5 "日本語入力" nil)))))

(ert-deftest tategaki-corfu-selection-replaces-and-cancellation-clears-preview ()
  (tategaki-corfu-test--with-buffer "日本"
    (corfu--preview-current 1 3)
    (let ((previous corfu--preview-ov))
      (corfu-next)
      (corfu--preview-current 1 3)
      (should-not (overlay-buffer previous))
      (should (equal (nth 3 tategaki-corfu-test--snapshot) "日本語能力")))
    (corfu--preview-delete)
    (should-not tategaki-corfu-test--snapshot)
    (should-not tategaki-corfu--preview)
    (should (equal (buffer-string) "日本"))
    (should-not buffer-undo-list)))

(ert-deftest tategaki-corfu-insertion-remains-native-and-undoable ()
  (tategaki-corfu-test--with-buffer "前日本後"
    (goto-char 4)
    (let ((completion-in-region--data (list 2 (copy-marker 4 t) nil nil)))
      (corfu--preview-current 2 4)
      ;; This is Corfu's usual pre-command cleanup before native insertion.
      (corfu--preview-delete)
      (undo-boundary)
      (corfu--insert nil)
      (undo-boundary)
      (should (equal (buffer-string) "前日本語入力後"))
      (should-not tategaki-corfu-test--snapshot)
      (let ((inhibit-message t)) (undo 1))
      (should (equal (buffer-string) "前日本後")))))

(ert-deftest tategaki-corfu-disable-restores-native-insertion-preview ()
  (tategaki-corfu-test--with-buffer "前"
    (corfu--preview-current 2 2)
    (let ((overlay corfu--preview-ov))
      (tategaki-corfu-disable)
      (should (eq overlay corfu--preview-ov))
      (should (eq (overlay-buffer overlay) (current-buffer)))
      (should (equal (overlay-get overlay 'after-string) "日本語入力"))
      (should-not tategaki-corfu-test--snapshot)
      (should-not (advice-member-p #'tategaki-corfu--popup-show
                                   'corfu--popup-show)))))

(ert-deftest tategaki-corfu-enable-adopts-existing-native-preview ()
  (tategaki-corfu-test--with-buffer "日本"
    (tategaki-corfu-disable)
    (corfu--preview-current 1 3)
    (let ((overlay corfu--preview-ov))
      (tategaki-corfu-enable)
      (should (eq overlay corfu--preview-ov))
      (should-not (overlay-get overlay 'display))
      (should (equal (nth 3 tategaki-corfu-test--snapshot) "日本語入力")))))

(ert-deftest tategaki-corfu-other-window-keeps-native-preview ()
  (tategaki-corfu-test--with-buffer "日本"
    (let ((other (split-window-right)))
      (set-window-buffer other (current-buffer))
      (with-selected-window other
        (corfu--preview-current 1 3)
        (should (equal (overlay-get corfu--preview-ov 'display) "日本語入力"))
        (should-not tategaki-corfu-test--snapshot)))))

(ert-deftest tategaki-corfu-popup-uses-vertical-caret-and-cell-height ()
  (tategaki-corfu-test--with-buffer "日本"
    (cl-letf (((symbol-function 'tategaki-position-pixel)
               (lambda (position window)
                 (should (= position (point)))
                 (should (eq window tategaki--window))
                 '(:x 192 :y 66 :width 26 :height 33))))
      (let* ((result (tategaki-corfu--popup-show #'list '(bad-pos) 7 12 '("候補") 1))
             (pos (car result)))
        (should (eq (posn-window pos) (selected-window)))
        (should (equal (posn-x-y pos) '(192 . 66)))
        (should (equal (posn-object-width-height pos) '(26 . 33)))
        (should (equal (cdr result) '(0 12 ("候補") 1)))))))

(ert-deftest tategaki-corfu-popup-delegates-outside-owner-and-hides-for-ime ()
  (tategaki-corfu-test--with-buffer "日本"
    (let ((tategaki-corfu--enabled nil))
      (should (equal (tategaki-corfu--popup-show #'list '(original) 7 12)
                     '((original) 7 12))))
    (let ((tategaki-ime--text "にほん")
          hidden)
      (cl-letf (((symbol-function 'corfu--popup-hide) (lambda () (setq hidden t))))
        (tategaki-corfu--popup-show (lambda (&rest _) (ert-fail "Popup displayed"))
                                  '(original) 7 12)
        (should hidden)))))

(ert-deftest tategaki-corfu-teardown-clears-original-buffer-from-other-buffer ()
  (tategaki-corfu-test--with-buffer "日本"
    (corfu--preview-current 1 3)
    (with-temp-buffer (corfu--preview-delete))
    (should-not tategaki-corfu-test--snapshot)
    (should-not tategaki-corfu--preview)))

(ert-deftest tategaki-corfu-popup-waits-for-visible-vertical-anchor ()
  (tategaki-corfu-test--with-buffer "日本"
    (let (hidden)
      (cl-letf (((symbol-function 'tategaki-position-pixel) (lambda (&rest _) nil))
                ((symbol-function 'corfu--popup-hide) (lambda () (setq hidden t))))
        (tategaki-corfu--popup-show (lambda (&rest _) (ert-fail "Hidden anchor used"))
                                  '(original) 7 12)
        (should hidden)))))

(provide 'tategaki-corfu-test)
;;; tategaki-corfu-test.el ends here
