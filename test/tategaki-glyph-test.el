;;; tategaki-glyph-test.el --- Typesetting cell tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'dom)
(require 'xml)
(require 'tategaki-glyph)

(defun tategaki-glyph-test--image (string)
  (get-text-property 0 'tategaki-glyph-image string))

(defun tategaki-glyph-test--svg (string)
  (plist-get (cdr (tategaki-glyph-test--image string)) :data))

(defun tategaki-glyph-test--texts (svg)
  (with-temp-buffer
    (insert svg)
    (mapcar (lambda (node) (apply #'concat (cddr node)))
            (dom-by-tag (car (xml-parse-region (point-min) (point-max))) 'text))))

(ert-deftest tategaki-glyph-svg-keeps-exact-unit-dimensions ()
  (let* ((unit '(:start 10 :end 15 :text "Emacs" :kind latin :span 3))
         (original (copy-tree unit))
         (rendered (tategaki-glyph-render unit 36 42 32 'default)))
    (should (= (length rendered) 1))
    (should (= (get-text-property 0 'tategaki-glyph-width rendered) 36))
    (should (= (get-text-property 0 'tategaki-glyph-height rendered) 126))
    (should (string-match-p "width=\"36\" height=\"126\""
                            (tategaki-glyph-test--svg rendered)))
    (should (string-match-p "rotate(90)" (tategaki-glyph-test--svg rendered)))
    (should (equal original unit))))

(ert-deftest tategaki-glyph-tcy-keeps-digits-horizontal ()
  (let* ((rendered (tategaki-glyph-render '(:text "12" :kind tcy :span 1)
                                         36 42 32 'default))
         (svg (tategaki-glyph-test--svg rendered)))
    (should (string-match-p ">12</text>" svg))
    (should-not (string-match-p "rotate" svg))))

(ert-deftest tategaki-glyph-ruby-and-emphasis-are-rendered ()
  (let ((ruby (tategaki-glyph-test--svg
               (tategaki-glyph-render '(:text "漢" :kind ruby :span 1 :ruby "かん")
                                      48 48 36 'default)))
        (dot (tategaki-glyph-test--svg
              (tategaki-glyph-render '(:text "点" :kind glyph :span 1 :emphasis dot)
                                     48 48 36 'default)))
        (line (tategaki-glyph-test--svg
               (tategaki-glyph-render '(:text "線" :kind glyph :span 1 :emphasis line)
                                      48 48 36 'default))))
    (should (equal (tategaki-glyph-test--texts ruby) '("漢" "か" "ん")))
    (should (string-match-p "<circle" dot))
    (should (string-match-p "<line" line))))

(ert-deftest tategaki-glyph-slices-use-pixel-offsets-and-isolated-specs ()
  (let* ((rendered (tategaki-glyph-render '(:text "Emacs" :kind latin :span 3)
                                         36 42 32 'default))
         (first (tategaki-glyph-slice rendered 0 42))
         (second (tategaki-glyph-slice-pixels rendered 21 21))
         (fractional (tategaki-glyph-slice-pixels rendered 21.25 20.75)))
    (should (= (length first) 1))
    (should (equal (car (get-text-property 0 'display first)) '(slice 0 0 36 42)))
    (should (equal (car (get-text-property 0 'display second)) '(slice 0 21 36 21)))
    (should (equal (car (get-text-property 0 'display fractional)) '(slice 0 21 36 21)))
    (should-not (eq (cadr (get-text-property 0 'display first))
                    (cadr (get-text-property 0 'display second))))
    (should-error (tategaki-glyph-slice-pixels rendered 125 2) :type 'args-out-of-range)))

(ert-deftest tategaki-glyph-fallback-preserves-all-text ()
  (let ((tategaki-glyph-use-svg nil))
    (dolist (unit '((:text "Emacs" :kind latin :span 3)
                    (:text "12" :kind tcy :span 1)
                    (:text "漢" :ruby "かん" :kind ruby :span 1)))
      (let ((rendered (tategaki-glyph-render unit 48 48 36 'default)))
        (should-not (tategaki-glyph-test--image rendered))
        (should (string-match-p (regexp-quote (plist-get unit :text)) rendered))
        (when (plist-get unit :ruby)
          (should (string-match-p "かん" rendered)))))))

(ert-deftest tategaki-glyph-emoji-and-zwj-keep-complete-sequences ()
  (dolist (text '("👩‍👩‍👧‍👧" "❤️" "🇯🇵"))
    (let ((rendered (tategaki-glyph-render (list :text text :kind 'glyph :span 1)
                                         48 48 36 'default)))
      (should (equal (tategaki-glyph-test--texts (tategaki-glyph-test--svg rendered))
                     (list text))))
    (let* ((tategaki-glyph-use-svg nil)
           (rendered (tategaki-glyph-render (list :text text :kind 'glyph :span 1)
                                           48 48 36 'default)))
      (should-not (tategaki-glyph-test--image rendered))
      (should (string-match-p (regexp-quote text) rendered)))))

(ert-deftest tategaki-glyph-cache-is-bounded-and-cleared ()
  (let ((tategaki-glyph-cache-limit 2)
        (tategaki-glyph--cache (make-hash-table :test #'equal))
        (tategaki-glyph--cache-order nil))
    (dolist (text '("一" "二" "三"))
      (tategaki-glyph-render (list :text text :kind 'glyph :span 1) 40 40 30 'default))
    (should (= (hash-table-count tategaki-glyph--cache) 2))
    (tategaki-glyph-clear-cache)
    (should (zerop (hash-table-count tategaki-glyph--cache)))
    (should-not tategaki-glyph--cache-order)))

(ert-deftest tategaki-glyph-cache-shares-images-but-not-display-conses ()
  (let* ((unit '(:text "一" :kind glyph :span 1))
         (first (tategaki-glyph-render unit 40 40 30 'default))
         (second (tategaki-glyph-render unit 40 40 30 'default)))
    (should (eq (tategaki-glyph-test--image first) (tategaki-glyph-test--image second)))
    (should-not (eq (get-text-property 0 'display first)
                    (get-text-property 0 'display second)))))

(ert-deftest tategaki-glyph-cache-reuses-glyphs-at-different-source-positions ()
  (let ((first (tategaki-glyph-render '(:text "字" :start 1 :end 2 :kind glyph :span 1)
                                     40 40 30 'default))
        (second (tategaki-glyph-render '(:text "字" :start 50 :end 51 :kind glyph :span 1)
                                      40 40 30 'default)))
    (should (eq (tategaki-glyph-test--image first) (tategaki-glyph-test--image second)))))

(ert-deftest tategaki-glyph-shared-body-width-aligns-ruby-and-normal-text ()
  (dolist (unit '((:text "字" :kind glyph :span 1)
                  (:text "字" :kind ruby :span 1 :ruby "じ")
                  (:text "字" :kind glyph :span 1 :emphasis dot)))
    (let ((svg (tategaki-glyph-test--svg
                (tategaki-glyph-render
                 (append unit '(:body-width 40 :annotation-width 20))
                 60 40 30 'default))))
      (should (string-match-p "x=\"20.0\">&#23383;</text>" svg)))))

(ert-deftest tategaki-glyph-resolves-highlight-colors-and-underline ()
  (let ((svg (tategaki-glyph-test--svg
              (tategaki-glyph-render '(:text "字" :kind glyph :span 1)
                                     40 40 30
                                     '(:foreground "#123456" :background "#abcdef"
                                       :underline t :family "Arial")))))
    (should (string-match-p "fill=\"#abcdef\"" svg))
    (should (string-match-p "fill=\"#123456\"" svg))
    (should (string-match-p "font-family=\"Arial\"" svg))
    (should (string-match-p "<line" svg))))

(ert-deftest tategaki-glyph-grid-divides-a-rotated-run-into-cells ()
  (let ((svg (tategaki-glyph-test--svg
              (tategaki-glyph-render '(:text "word" :kind latin :span 3)
                                     40 40 30 'default nil "#cccccc"))))
    (should (string-match-p "height=\"119\"" svg))
    (should (string-match-p "y1=\"40\"" svg))
    (should (string-match-p "y1=\"80\"" svg))))

(ert-deftest tategaki-glyph-invalid-dimensions-fail-without-mutation ()
  (should-error (tategaki-glyph-render '(:text "字") 0 40 30 'default)
                :type 'wrong-type-argument)
  (should-error (tategaki-glyph-render '(:text "字") 40 -1 30 'default)
                :type 'wrong-type-argument))

(ert-deftest tategaki-glyph-hanging-marks-keep-the-normal-body-font-size ()
  (let ((style '(:family "Hiragino Sans" :foreground "#000000" :background "#ffffff")))
    (dolist (dimensions '((24 34) (40 40) (13 17)))
      (let* ((width (car dimensions)) (height (cadr dimensions))
             (normal (car (dom-by-tag
                           (tategaki-glyph--svg '(:text "字" :kind glyph :span 1)
                                               width height style nil) 'text))))
        (dolist (mark '("︑" "︒" "、" "。" "，" "．"))
          (let* ((unit (list :text mark :kind 'glyph :span 1 :hanging t :font-height height))
                 (hanging (tategaki-glyph--svg unit width (/ (float height) 2) style nil))
                 (text (car (dom-by-tag hanging 'text))))
            (should (= (dom-attr text 'font-size) (dom-attr normal 'font-size)))
            (should (= (dom-attr hanging 'height) (round (/ (float height) 2))))
            ;; The shorter canvas crops blank space, not the ink.  Vertical
            ;; forms retain their normal baseline; ordinary marks are lifted.
            (should (= (dom-attr text 'y)
                       (- (dom-attr normal 'y)
                          (if (member mark '("︑" "︒")) 0 (/ (float height) 2)))))))))))

(ert-deftest tategaki-glyph-hanging-font-size-and-alignment-affect-the-cache ()
  (let* ((small (tategaki-glyph-render '(:text "。" :kind glyph :span 1)
                                      40 20 20 'default))
         (hanging (tategaki-glyph-render '(:text "。" :kind glyph :span 1
                                          :font-height 40 :hanging t)
                                        40 20 20 'default))
         (unshifted (tategaki-glyph-render '(:text "。" :kind glyph :span 1
                                            :font-height 40)
                                          40 20 20 'default)))
    (should-not (eq (tategaki-glyph-test--image small) (tategaki-glyph-test--image hanging)))
    (should-not (eq (tategaki-glyph-test--image unshifted) (tategaki-glyph-test--image hanging)))
    (should (= (get-text-property 0 'tategaki-glyph-height hanging) 20))))

(provide 'tategaki-glyph-test)
;;; tategaki-glyph-test.el ends here
