;;; tategaki-annotations-test.el --- Source annotation editing tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'tategaki-annotations)
(require 'tategaki-glyph)

(ert-deftest tategaki-annotations-ruby-combining-marks-and-fractional-image-slices ()
  (let* ((layout (tategaki-typeset-layout "｜蛾《が》" 4 1))
         (unit (aref (tategaki-typeset-entry layout 2) 4)))
    (should (equal (plist-get unit :ruby-graphemes) '("が")))
    (cl-letf (((symbol-function 'image-type-available-p) (lambda (_) t)))
      (let* ((image (tategaki-glyph-render '(:text "Emacs" :kind latin :span 3)
                                          30 (/ 94.0 3) 20 nil))
             (tail (tategaki-glyph-slice-pixels image 93 1)))
        (should (= (get-text-property 0 'tategaki-glyph-height image) 94))
        (should (= (get-text-property 0 'tategaki-glyph-height tail) 1))))))

(ert-deftest tategaki-annotations-ruby-edit-undo ()
  (with-temp-buffer
    (text-mode) (insert "月と東京の夜") (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (tategaki-insert-ruby 3 5 "とうきょう")
    (should (equal (buffer-string) "月と｜東京《とうきょう》の夜"))
    (should (equal (tategaki-typeset-plain-text (buffer-string)) "月と東京の夜"))
    (undo-boundary)
    (tategaki-edit-ruby "トーキョー")
    (should (equal (buffer-string) "月と｜東京《トーキョー》の夜"))
    (undo-boundary) (undo-only 1)
    (should (equal (buffer-string) "月と｜東京《とうきょう》の夜"))))

(ert-deftest tategaki-annotations-implicit-ruby-reading-position ()
  (with-temp-buffer
    (insert "ここは東京《とうきょう》。") (goto-char 9)
    (tategaki-edit-ruby "トーキョー")
    (should (equal (buffer-string) "ここは東京《トーキョー》。"))
    (should (= (point) 5))))

(ert-deftest tategaki-annotations-tcy-and-emphasis-keep-body ()
  (with-temp-buffer
    (insert "12猫")
    (tategaki-insert-tcy 1 3)
    (should (equal (buffer-string) "［＃縦中横］12［＃縦中横終わり］猫"))
    (tategaki-add-emphasis (1- (point-max)) (point-max) 'dot)
    (should (string-suffix-p "［＃傍点］猫［＃傍点終わり］" (buffer-string)))
    (should (equal (tategaki-typeset-plain-text (buffer-string)) "12猫"))))

(ert-deftest tategaki-annotations-reject-invalid-without-changing-source ()
  (with-temp-buffer
    (insert "東京\n大阪")
    (let ((original (buffer-string)))
      (should-error (tategaki-insert-ruby 1 3 "") :type 'user-error)
      (should-error (tategaki-insert-ruby 1 3 "と》う") :type 'user-error)
      (should-error (tategaki-insert-tcy 1 6) :type 'user-error)
      (should-error (tategaki-add-emphasis 1 3 'bold) :type 'user-error)
      (should-error (tategaki-edit-ruby "とうきょう") :type 'user-error)
      (should (equal original (buffer-string))))))

(ert-deftest tategaki-annotations-toggle-is-buffer-local-and-nonediting ()
  (with-temp-buffer
    (insert "東京《とうきょう》") (set-buffer-modified-p nil)
    (let ((default (default-value 'tategaki-typeset-annotation-display)))
      (tategaki-toggle-annotations)
      (should (local-variable-p 'tategaki-typeset-annotation-display))
      (should (eq tategaki-typeset-annotation-display 'raw))
      (should (eq default (default-value 'tategaki-typeset-annotation-display)))
      (tategaki-toggle-annotations)
      (should (eq tategaki-typeset-annotation-display 'rendered))
      (should-not (buffer-modified-p)))))

(provide 'tategaki-annotations-test)
;;; tategaki-annotations-test.el ends here
