;;; tategaki-tts-test.el --- Async local speech and source safety -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'tategaki-tts)

(defmacro tategaki-tts-test--with-engine (&rest body)
  "Run BODY with a real, silent subprocess implementing the say contract."
  (declare (indent 0) (debug t))
  `(let* ((program (make-temp-file "tategaki-fake-say-"))
          (tategaki-tts-program program)
          (process-environment (cons "TATEGAKI_TEST_SLEEP=0.05" process-environment)))
     (unwind-protect
         (progn
           (with-temp-file program
             (insert "#!/usr/bin/env python3\nimport os, sys, time\n"
                     "if sys.argv[1:3] == ['-v', '?']:\n"
                     " print('Kyoko     ja_JP    # hello')\n"
                     " print('Otoya     ja_JP    # hello')\n"
                     "else:\n sys.stdin.read()\n time.sleep(float(os.environ.get('TATEGAKI_TEST_SLEEP', '0.05')))\n"))
           (set-file-modes program #o700)
           (with-temp-buffer
             (insert "太郎は窓を開けた。花子が来た！\n次の段落。")
             (goto-char (point-min))
             (buffer-enable-undo)
             (setq buffer-undo-list nil)
             (set-buffer-modified-p nil)
             (unwind-protect (progn ,@body) (tategaki-tts--stop))))
       (delete-file program))))

(defun tategaki-tts-test--wait ()
  "Wait at most four seconds for test speech completion."
  (let ((deadline (+ (float-time) 4)))
    (while (and (not (eq tategaki-tts-state 'stopped)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (eq tategaki-tts-state 'stopped))))

(ert-deftest tategaki-tts-voices-are-local-and-optional ()
  (tategaki-tts-test--with-engine
    (should (equal (tategaki-tts-voices) '("Kyoko" "Otoya")))
    (let ((tategaki-tts-program "no-such-tategaki-speech-executable"))
      (should-not (tategaki-tts-voices))
      (should-error (tategaki-tts-play) :type 'user-error)
      (should-not tategaki-tts--process))))

(ert-deftest tategaki-tts-sentence-ranges-and-readings-do-not-edit-source ()
  (tategaki-tts-test--with-engine
    (let* ((original (buffer-string))
           (tategaki-tts-pronunciations '(("太郎" . "たろう") ("太郎は" . "たろうわ")))
           (sentences (tategaki-tts--sentences (point-min) (point-max))))
      (should (= (length sentences) 3))
      (should (equal (nth 2 (car sentences)) "たろうわ窓を開けた。"))
      (should (equal (buffer-substring-no-properties (caar sentences) (cadar sentences))
                     "太郎は窓を開けた。"))
      (should (equal original (buffer-string)))
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-tts-real-sentinel-progression-and-overlay-cleanup ()
  (tategaki-tts-test--with-engine
    (let ((original (buffer-string)) (undo buffer-undo-list) (position (point))
          (real-make-process (symbol-function 'make-process)) commands)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest args)
                   (push (plist-get args :command) commands)
                   (apply real-make-process args))))
        (tategaki-tts-play)
        (should (eq tategaki-tts-state 'playing))
        (should (overlayp tategaki-tts--overlay))
        (should (= (overlay-start tategaki-tts--overlay) 1))
        (should (eq (overlay-get tategaki-tts--overlay 'face) 'tategaki-tts-face))
        (should (equal (nthcdr 1 (car commands)) '("-v" "Kyoko" "-r" "180" "-f" "-")))
        (should-not (process-buffer tategaki-tts--process))
        (tategaki-tts-test--wait))
      (should (= (length commands) 3))
      (should-not tategaki-tts--overlay)
      (should-not tategaki-tts--process)
      (should-not (memq #'tategaki-tts--source-changed after-change-functions))
      (should (equal original (buffer-string)))
      (should (eq undo buffer-undo-list))
      (should (= position (point)))
      (should-not (buffer-modified-p)))))

(ert-deftest tategaki-tts-pause-resume-retains-current-process ()
  (tategaki-tts-test--with-engine
    (let ((process-environment (cons "TATEGAKI_TEST_SLEEP=0.5" process-environment)))
      (tategaki-tts-play)
      (let ((process tategaki-tts--process))
        (tategaki-tts-pause)
        (should (eq tategaki-tts-state 'paused))
        (should (eq process tategaki-tts--process))
        (tategaki-tts-play)
        (should (eq tategaki-tts-state 'playing))
        (should (eq process tategaki-tts--process))
        (tategaki-tts-stop)
        (should-not (process-live-p process))
        (should-not tategaki-tts--overlay)))))

(ert-deftest tategaki-tts-source-edit-invalidates-process-and-queue ()
  (tategaki-tts-test--with-engine
    (let ((process-environment (cons "TATEGAKI_TEST_SLEEP=0.5" process-environment)))
      (tategaki-tts-play)
      (let ((process tategaki-tts--process))
        (insert "改稿")
        (should (eq tategaki-tts-state 'stopped))
        (should-not (process-live-p process))
        (should-not tategaki-tts--overlay)
        (should-not tategaki-tts--queue)))))

(ert-deftest tategaki-tts-old-sentinel-cannot-advance-new-playback ()
  (tategaki-tts-test--with-engine
    (let ((process-environment (cons "TATEGAKI_TEST_SLEEP=0.5" process-environment)))
      (tategaki-tts-play)
      (let ((old-process tategaki-tts--process)
            (old-sentinel (process-sentinel tategaki-tts--process)))
        (tategaki-tts-play)
        (let ((new-process tategaki-tts--process) (queue (copy-tree tategaki-tts--queue)))
          (funcall old-sentinel old-process "finished\n")
          (should (eq new-process tategaki-tts--process))
          (should (equal queue tategaki-tts--queue))
          (should (eq tategaki-tts-state 'playing)))))))

(ert-deftest tategaki-tts-region-limits-and-failure-cleanup ()
  (tategaki-tts-test--with-engine
    (let ((begin 11) (end 17))
      (tategaki-tts-read-region begin end)
      (should (= (overlay-start tategaki-tts--overlay) begin))
      (should (<= (overlay-end tategaki-tts--overlay) end))
      (should-not tategaki-tts--queue)
      (tategaki-tts-test--wait))
    (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (error "Spawn failure"))))
      (should-error (tategaki-tts-play))
      (should (eq tategaki-tts-state 'stopped))
      (should-not tategaki-tts--overlay)
      (should-not tategaki-tts--queue))))

(provide 'tategaki-tts-test)
;;; tategaki-tts-test.el ends here
