;;; tategaki-navigation-test.el --- Optional movement key checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'tategaki)
(require 'tategaki-navigation)

(defmacro tategaki-navigation-test--with-buffer (&rest body)
  "Run BODY in an isolated vertical text buffer with physical key support."
  (declare (indent 0))
  `(save-window-excursion
     (let ((buffer (generate-new-buffer " *Tategaki navigation test*"))
           (tategaki-column-height 3)
           ;; Keep this test independent of whether tategaki's loader has
           ;; already installed the optional bindings in its production map.
           (tategaki-mode-map (copy-keymap tategaki-mode-map)))
       (tategaki-navigation-install tategaki-mode-map)
       (let ((minor-mode-map-alist
              (mapcar (lambda (entry)
                        (if (eq (car entry) 'tategaki-mode)
                            (cons 'tategaki-mode tategaki-mode-map)
                          entry))
                      minor-mode-map-alist)))
         (unwind-protect
             (progn
               (switch-to-buffer buffer)
               (text-mode)
               (insert "abcdefghijklmnopqr")
               (goto-char 8)
               (buffer-enable-undo)
               (setq buffer-undo-list nil)
               (set-buffer-modified-p nil)
               (tategaki-mode 1)
               ,@body)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (tategaki-mode -1)
               (set-buffer-modified-p nil))
             (kill-buffer buffer)))))))

(ert-deftest tategaki-navigation-nil-preserves-user-local-and-global-bindings ()
  (let ((tategaki-physical-navigation nil)
        (saved-global (current-global-map)))
    (unwind-protect
        (progn
          (use-global-map (copy-keymap saved-global))
          (global-set-key (kbd "C-f") #'end-of-buffer)
          (global-set-key (kbd "C-n") #'forward-paragraph)
          (tategaki-navigation-test--with-buffer
            (should (eq (key-binding (kbd "C-f")) #'end-of-buffer))
            (should (eq (key-binding (kbd "C-n")) #'forward-paragraph))
            (use-local-map (make-sparse-keymap))
            (local-set-key (kbd "C-f") #'beginning-of-buffer)
            (local-set-key (kbd "C-p") #'backward-paragraph)
            (should (eq (key-binding (kbd "C-f")) #'beginning-of-buffer))
            (should (eq (key-binding (kbd "C-p")) #'backward-paragraph))))
      (use-global-map saved-global))))

(ert-deftest tategaki-navigation-setq-switches-immediately ()
  (let ((tategaki-physical-navigation nil))
    (tategaki-navigation-test--with-buffer
      (let ((before (mapcar (lambda (key) (key-binding (kbd key)))
                            '("C-f" "C-b" "C-n" "C-p"))))
        (setq tategaki-physical-navigation t)
        (should (equal (mapcar (lambda (key) (key-binding (kbd key)))
                              '("C-f" "C-b" "C-n" "C-p"))
                       '(tategaki-backward-column tategaki-forward-column
                         tategaki-next-character tategaki-previous-character)))
        (setq tategaki-physical-navigation nil)
        (should (equal (mapcar (lambda (key) (key-binding (kbd key)))
                              '("C-f" "C-b" "C-n" "C-p")) before))))))

(ert-deftest tategaki-navigation-physical-directions-preserve-source ()
  (let ((tategaki-physical-navigation t))
    (tategaki-navigation-test--with-buffer
      (let ((source (buffer-string)))
        (call-interactively (key-binding (kbd "C-f")))
        (should (= (point) 5))
        (call-interactively (key-binding (kbd "C-b")))
        (should (= (point) 8))
        (call-interactively (key-binding (kbd "C-n")))
        (should (= (point) 9))
        (call-interactively (key-binding (kbd "C-p")))
        (should (= (point) 8))
        (should (equal source (buffer-string)))
        (should-not (buffer-modified-p))
        (should-not buffer-undo-list)))))

(ert-deftest tategaki-navigation-numeric-and-negative-prefixes ()
  (let ((tategaki-physical-navigation t))
    (tategaki-navigation-test--with-buffer
      (let ((current-prefix-arg 2))
        (call-interactively (key-binding (kbd "C-f"))))
      (should (= (point) 2))
      (let ((current-prefix-arg -2))
        (call-interactively (key-binding (kbd "C-f"))))
      (should (= (point) 8))
      (let ((current-prefix-arg 3))
        (call-interactively (key-binding (kbd "C-n"))))
      (should (= (point) 11))
      (let ((current-prefix-arg -2))
        (call-interactively (key-binding (kbd "C-p"))))
      (should (= (point) 13)))))

(ert-deftest tategaki-navigation-keeps-active-region-and-numeric-motion ()
  (let ((tategaki-physical-navigation t)
        (transient-mark-mode t))
    (tategaki-navigation-test--with-buffer
      (push-mark 4 t t)
      (let ((current-prefix-arg 2))
        (call-interactively (key-binding (kbd "C-n"))))
      (should (= (point) 10))
      (should (use-region-p))
      (should (= (mark) 4))
      (should (equal (buffer-substring-no-properties (region-beginning) (region-end))
                     "defghi")))))

(ert-deftest tategaki-navigation-buffer-local-choice-and-disabled-mode ()
  (let ((tategaki-physical-navigation t))
    (tategaki-navigation-test--with-buffer
      (should (eq (key-binding (kbd "C-f")) #'tategaki-backward-column))
      (setq-local tategaki-physical-navigation nil)
      (should (eq (key-binding (kbd "C-f")) #'forward-char))
      (with-temp-buffer
        (should tategaki-physical-navigation)
        (should (eq (key-binding (kbd "C-f")) #'forward-char))))
    (tategaki-navigation-test--with-buffer
      (should (eq (key-binding (kbd "C-f")) #'tategaki-backward-column))
      (tategaki-mode -1)
      (should (eq (key-binding (kbd "C-f")) #'forward-char)))))

(ert-deftest tategaki-navigation-corfu-retains-candidate-selection-keys ()
  (skip-unless (require 'corfu nil t))
  (let ((tategaki-physical-navigation t)
        (corfu-auto nil))
    (tategaki-navigation-test--with-buffer
      (corfu-mode 1)
      (let ((completion-in-region-mode-predicate #'always))
        (unwind-protect
            (progn
              (corfu--setup 7 8 '("giraffe" "globe") nil)
              (should (eq (key-binding (kbd "C-n")) #'corfu-next))
              (should (eq (key-binding (kbd "C-p")) #'corfu-previous))
              (should (eq (key-binding (kbd "<down>")) #'corfu-next)))
          (when completion-in-region-mode (corfu-quit))))
      (should (eq (key-binding (kbd "C-n")) #'tategaki-next-character))
      (should (eq (key-binding (kbd "C-p")) #'tategaki-previous-character)))))

(provide 'tategaki-navigation-test)
;;; tategaki-navigation-test.el ends here
