;;; tategaki-corpus-http-tests.el --- Actual collection HTTP integration -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Opt-in: load this file and run selector "^tategaki-corpus-http-".
(require 'tategaki-corpus)
(load (expand-file-name "tategaki-ai-http-tests.el"
                        (file-name-directory (or load-file-name buffer-file-name))) nil nil t)

(ert-deftest tategaki-corpus-http-index-query-and-explicit-transmission ()
  (tategaki-ai-http--with-fixture
    (let ((first (expand-file-name "manuscript-two.txt" directory))
          (resource (expand-file-name "reference.txt" directory))
          (unregistered (expand-file-name "not-selected.txt" directory))
          indexed found)
      (with-temp-file first (insert "第3章\n海は穏やかだった。"))
      (with-temp-file resource (insert "資料\n古い鍵は真鍮でできている。"))
      (with-temp-file unregistered (insert "未登録機密は送信禁止。"))
      (tategaki-corpus-register first 'manuscript)
      (tategaki-corpus-register resource 'resource)
      (tategaki-corpus-index (lambda (result) (setq indexed result)))
      (tategaki-ai-http--wait (lambda () indexed))
      (should (plist-get indexed :ok))
      (tategaki-corpus-retrieve "鍵" (lambda (result) (setq found result)))
      (tategaki-ai-http--wait (lambda () found))
      (should (eq (plist-get found :method) 'semantic))
      (should (eq (plist-get (car (plist-get found :chunks)) :kind) 'resource))
      (let ((requests (tategaki-ai-http--log fixture-root)))
        (should (= (length requests) 2))
        (should (cl-every (lambda (request) (equal (alist-get 'path request) "/v1/embeddings")) requests))
        (should (equal (alist-get 'input (alist-get 'payload (cadr requests))) '("鍵")))
        (should-not (string-match-p "未登録機密" (prin1-to-string requests)))))))

(ert-deftest tategaki-corpus-http-cancel-closes-real-request ()
  (tategaki-ai-http--with-fixture
    (let ((resource (expand-file-name "slow-resource.txt" directory)) job responses)
      (with-temp-file resource (insert "鍵についての合成資料。"))
      (tategaki-corpus-register resource)
      (setq-local tategaki-ai-endpoint (concat fixture-root "/slow/v1"))
      (setq job (tategaki-corpus-index (lambda (result) (push result responses))))
      (let* ((request (plist-get job :request)) (process (get-buffer-process request)))
        (should (buffer-live-p request))
        (tategaki-corpus-cancel job)
        (should-not (buffer-live-p request))
        (should-not (process-live-p process))
        (accept-process-output nil 0.7)
        (should (= (length responses) 1))
        (should (eq (plist-get (car responses) :method) 'cancelled))
        (should-not (file-exists-p (tategaki-corpus--file directory t)))))))

;;; tategaki-corpus-http-tests.el ends here
