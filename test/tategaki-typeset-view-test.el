;;; tategaki-typeset-view-test.el --- Compositor boundary checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'tategaki)

(ert-deftest tategaki-view-gc-allowance-is-scoped-even-on-failure ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer)) (text-mode) (insert "原稿")
      (let ((gc-cons-threshold 1000000)
            (tategaki-render-gc-threshold 16000000))
        (tategaki-mode 1)
        (should (= gc-cons-threshold 1000000))
        (cl-letf (((symbol-function 'tategaki--paint)
                   (lambda (_) (should (= gc-cons-threshold 16000000))
                     (error "Synthetic paint failure"))))
          (should-error (tategaki-refresh)))
        (should (= gc-cons-threshold 1000000))
        (tategaki-mode -1)))))

(ert-deftest tategaki-view-preview-clause-boundaries-prevent-source-merging ()
  (let ((tategaki--preedit-start 3) (tategaki--preedit-length 3)
        (tategaki--preview-kind 'ime)
        (tategaki--preedit-text (concat (propertize "あ" 'face 'highlight)
                                      (propertize "いう" 'face 'underline))))
    (should (equal (sort (delete-dups (tategaki--preview-boundaries)) #'<) '(3 4 6)))))

(ert-deftest tategaki-view-slices-share-spacer-baseline-without-mutating-image ()
  (cl-letf (((symbol-function 'image-type-available-p) (lambda (_) t)))
    (let* ((picture (tategaki-glyph-render '(:text "abcde" :kind latin :span 3) 30 30 22 nil))
           (original (copy-tree (get-text-property 0 'tategaki-glyph-image picture)))
           (slice (tategaki-typeset-view--slice picture 30 30))
           (spec (cadr (get-text-property 0 'display slice))))
      (should (= (plist-get (cdr spec) :ascent) 0))
      (should (equal original (get-text-property 0 'tategaki-glyph-image picture))))))

(ert-deftest tategaki-view-flymake-wave-color-and-inverse-video ()
  (let* ((tategaki-glyph--style-cache (make-hash-table :test #'equal))
         (face '(:foreground "#00aa00" :background "#ffffff"
                 :inverse-video t :underline (:style wave :color "Red1")))
         (style (tategaki-glyph--style face (selected-frame))))
    (should (equal (plist-get style :foreground) "#ffffff"))
    (should (equal (plist-get style :background) "#00aa00"))
    (should (equal (plist-get style :underline-color) "#ff0000"))
    (should (eq style (tategaki-glyph--style face (selected-frame))))
    (let* ((svg (tategaki-glyph--svg '(:text "字" :kind glyph :span 1) 30 30 style nil))
           (wave (car (dom-by-tag svg 'polyline))))
      (should wave)
      (should (equal (dom-attr wave 'stroke) "#ff0000")))))

(provide 'tategaki-typeset-view-test)
;;; tategaki-typeset-view-test.el ends here
