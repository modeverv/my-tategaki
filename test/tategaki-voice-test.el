;;; tategaki-voice-test.el --- Phrase discovery and speaker review -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'tategaki-voice)

(defmacro tategaki-voice-test--source (text &rest body)
  "Run BODY with known characters and manuscript TEXT."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min))
     (tategaki-world-upsert '(:type "Character" :name "花子" :state "author-confirmed"))
     (tategaki-world-upsert '(:type "Character" :name "太郎" :state "author-confirmed"))
     ,@body))

(ert-deftest tategaki-voice-discovers-unknown-repeated-phrases ()
  (let* ((metrics (tategaki-voice--metrics "「風まかせで行こう。」\n「今日は風まかせだ。」\n「約束は守る。」"))
         (phrases (plist-get metrics :expressions)))
    (should (= 2 (cdr (assoc "風まかせ" phrases))))
    (should-not (assoc "まかせ" phrases))
    (should-not (assoc "約束は守る" phrases)))
  (should-not (tategaki-voice--frequent-expressions "ああああああああ"))
  (should-not (tategaki-voice--frequent-expressions "12345。12345。"))
  (should (equal (tategaki-voice--frequent-expressions "おやおや、すごいな。おやおや、静かだ。")
                 '(("おやおや" . 2)))))

(ert-deftest tategaki-voice-candidates-read-narrative-without-attribution ()
  (tategaki-voice-test--source
      "花子は静かに言った。「私は行く。」\n「俺は残る」と太郎は答えた。\n「誰の台詞か不明。」\n"
    (buffer-enable-undo) (setq buffer-undo-list nil) (set-buffer-modified-p nil)
    (let ((before (buffer-string)) (point (point))
          (candidates (tategaki-voice-speaker-candidates)))
      (should (= 3 (length candidates)))
      (should (equal "花子" (plist-get (car (plist-get (nth 0 candidates) :candidates)) :character)))
      (should (equal "太郎" (plist-get (car (plist-get (nth 1 candidates) :candidates)) :character)))
      (should-not (plist-get (nth 2 candidates) :candidates))
      (should (cl-every (lambda (item) (equal "inferred" (plist-get item :state))) candidates))
      (should-not (tategaki-world--read-store "voice"))
      (should-not (tategaki-voice--current-dialogues))
      (should-not (tategaki-voice-check))
      (should (equal before (buffer-string)))
      (should (= point (point)))
      (should-not buffer-undo-list)
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-voice-ambiguous-evidence-remains-multiple-candidates ()
  (tategaki-voice-test--source "花子は言った。「行こう」と太郎は答えた。\n"
    (let ((names (mapcar (lambda (hint) (plist-get hint :character))
                         (plist-get (car (tategaki-voice-speaker-candidates)) :candidates))))
      (should (member "花子" names))
      (should (member "太郎" names))
      (should-not (tategaki-world--read-store "voice")))))

(ert-deftest tategaki-voice-candidates-do-not-guess-from-names-alone ()
  (tategaki-voice-test--source "花子は太郎を見た。\n「明日は雨だ。」\n"
    (should-not (plist-get (car (tategaki-voice-speaker-candidates)) :candidates)))
  (tategaki-voice-test--source "花子「私は行く。」\n「俺は行く。」\n"
    (should (= 1 (length (tategaki-voice-speaker-candidates))))))

(ert-deftest tategaki-voice-example-phrases-suggest-but-never-register ()
  (tategaki-voice-test--source
      "花子「風まかせで行こう。」\n花子「今日は風まかせだ。」\n「風まかせなら大丈夫。」\n"
    (goto-char (point-min))
    (dotimes (_ 2)
      (re-search-forward "「[^」]*」")
      (tategaki-voice-register "花子" (match-beginning 0) (match-end 0)))
    (let* ((candidate (car (tategaki-voice-speaker-candidates)))
           (hint (car (plist-get candidate :candidates))))
      (should (equal "花子" (plist-get hint :character)))
      (should (member "見本の反復表現: 風まかせ" (plist-get hint :reasons)))
      (should (= 2 (length (tategaki-world--read-store "voice")))))))

(ert-deftest tategaki-voice-adoption-requires-current-source-and-known-candidate ()
  (tategaki-voice-test--source "花子は言った。「俺は行く。」\n"
    (let* ((candidate (car (tategaki-voice-speaker-candidates)))
           (before (buffer-string)))
      (should-error (tategaki-voice-adopt-speaker candidate "太郎") :type 'user-error)
      (tategaki-voice-adopt-speaker candidate "花子")
      (should (= 1 (length (tategaki-world--read-store "voice"))))
      (should-not (tategaki-voice-speaker-candidates))
      (should (equal before (buffer-string)))
      (goto-char (point-max)) (insert "変更")
      (should-error (tategaki-voice-adopt-speaker candidate "花子") :type 'user-error)
      (should (= 1 (length (tategaki-world--read-store "voice")))))))

(ert-deftest tategaki-voice-panel-adoption-button-registers-only-on-action ()
  (save-window-excursion
    (let ((source (generate-new-buffer " *voice-review-test*")) panel)
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (insert "花子は言った。「私は行く。」\n")
            (goto-char (point-min))
            (tategaki-world-upsert '(:type "Character" :name "花子" :state "author-confirmed"))
            (setq panel (tategaki-voice))
            (with-current-buffer source (should-not (tategaki-world--read-store "voice")))
            (with-current-buffer panel
              (goto-char (point-min))
              (should (search-forward "話者候補（未採用）" nil t))
              (should (search-forward "花子として採用" nil t))
              (button-activate (button-at (1- (point)))))
            (with-current-buffer source
              (should (= 1 (length (tategaki-world--read-store "voice"))))))
        (when (buffer-live-p panel) (kill-buffer panel))
        (when (buffer-live-p source) (kill-buffer source))))))

(provide 'tategaki-voice-test)
;;; tategaki-voice-test.el ends here
