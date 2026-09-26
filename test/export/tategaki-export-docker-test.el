;;; tategaki-export-docker-test.el --- Opt-in Docker integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 seijiro and contributors.
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is part of my-tategaki.
;;
;; my-tategaki is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; my-tategaki is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with my-tategaki.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; Run explicitly with TATEGAKI_EXPORT_DOCKER_TESTS=1, after building the image.
;; These tests start real Docker containers.  They use disposable Emacs buffers
;; and retain export reports under dist/emacs-integration-tests.  They are not
;; registered in ordinary ERT runs, so no editing test requires Docker.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'tategaki-export)

(defun tategaki-export-docker-test--wait (job &optional timeout)
  "Wait for real JOB completion, serving the event loop for TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 120)))
        (process (plist-get job :process)))
    (while (and (process-live-p process) (< (float-time) deadline))
      (accept-process-output process 0.1))
    (when (process-live-p process)
      (ignore-errors (tategaki-export-cancel (plist-get job :id)))
      (ert-fail "Docker export timed out"))
    ;; Deliver the final sentinel if process exit and status arrived separately.
    (accept-process-output nil 0.05)
    job))

(defun tategaki-export-docker-test--report (job)
  "Read JOB's real JSON report."
  (let ((json-object-type 'alist) (json-key-type 'symbol))
    (json-read-file (expand-file-name "report.json" (plist-get job :directory)))))

(defun tategaki-export-docker-test--finish (job evidence)
  "Retain JOB's log and EVIDENCE, and clean up its test log buffer."
  (when job
    (when (file-directory-p (plist-get job :directory))
      (tategaki-export-model-write-json evidence
                                        (expand-file-name "emacs-integration.json" (plist-get job :directory)))
      (when-let* ((buffer (get-buffer (plist-get job :buffer))))
        (with-current-buffer buffer
          (write-region (point-min) (point-max)
                        (expand-file-name "emacs-integration.log" (plist-get job :directory)) nil 'silent))))
    (when (get-buffer (plist-get job :buffer)) (kill-buffer (plist-get job :buffer)))))

(when (equal (getenv "TATEGAKI_EXPORT_DOCKER_TESTS") "1")
  (ert-deftest tategaki-export-docker-real-snapshot-and-editing ()
    (let* ((source-dir (make-temp-file "tategaki 原稿 " t))
           (source-file (expand-file-name "原稿 保存.txt" source-dir))
           (tategaki-export-output-directory
            (expand-file-name "dist/emacs-integration-tests" tategaki-export--directory))
           (tategaki-export--jobs (make-hash-table :test #'equal))
           (tategaki-export--last-job nil)
           (original "保存済みの本文。\n")
           (snapshot-text "未保存の冒頭。\n｜漢字《かんじ》と［＃縦中横］12［＃縦中横終わり］。\n末尾。\n")
           job (ticks 0) timer passed)
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region original nil source-file nil 'silent))
            (with-temp-buffer
              (setq buffer-file-name source-file)
              (buffer-enable-undo)
              (insert snapshot-text)
              (goto-char 12) (set-mark 17) (setq mark-active t)
              (narrow-to-region 10 30)
              (let ((point-before (point)) (mark-before (mark))
                    (min-before (point-min)) (max-before (point-max))
                    (modified-before (buffer-modified-p)) (undo-before buffer-undo-list)
                    (start (float-time)))
                (setq timer (run-at-time 0.05 0.05 (lambda () (cl-incf ticks))))
                (let ((id (tategaki-export '("txt" "docx" "epub" "html") "preview" 'full)))
                  (setq job (gethash id tategaki-export--jobs)))
                (should (< (- (float-time) start) 3))
                (should (= point-before (point))) (should (= mark-before (mark)))
                (should (= min-before (point-min))) (should (= max-before (point-max)))
                (should (eq undo-before buffer-undo-list))
                (should (eq modified-before (buffer-modified-p)))
                (should (process-live-p (plist-get job :process)))
                (insert "開始後の追記")
                (should (string-match-p "開始後の追記" (buffer-string)))
                (tategaki-export-docker-test--wait job)
                (should (eq (plist-get job :state) 'succeeded))
                (should (> ticks 0))
                (let* ((report (tategaki-export-docker-test--report job))
                       (hash (secure-hash 'sha256 (encode-coding-string snapshot-text 'utf-8-unix))))
                  (should (equal "succeeded" (alist-get 'status report)))
                  (should (equal hash (alist-get 'input_sha256 report)))
                  (dolist (format '(txt docx epub html))
                    (should (equal "succeeded" (alist-get 'status (alist-get format (alist-get 'formats report)))))))))
            (with-temp-buffer
              (insert-file-contents source-file)
              (should (equal original (buffer-string))))
            (setq passed t))
        (when timer (cancel-timer timer))
        (tategaki-export-docker-test--finish
         job `((test . "real-snapshot-and-editing") (event_loop_ticks . ,ticks)
               (checks_passed . ,(if passed t :json-false))
               (source_file_unchanged . ,(if passed t :json-false))
               (snapshot_immutable . ,(if passed t :json-false))
               (source_state_preserved . ,(if passed t :json-false))))
        (delete-directory source-dir t))))

  (ert-deftest tategaki-export-docker-real-cancel-isolated-job ()
    (let ((tategaki-export-output-directory
           (expand-file-name "dist/emacs-integration-tests" tategaki-export--directory))
          (tategaki-export--jobs (make-hash-table :test #'equal))
          (tategaki-export--last-job nil) cancelled control passed)
      (unwind-protect
          (progn
            (with-temp-buffer
              (insert (apply #'concat (make-list 10000 "長い本文の取消を確認する。\n")))
              (let ((id (tategaki-export '("pdf") "preview" 'full)))
                (setq cancelled (gethash id tategaki-export--jobs))))
            (let ((deadline (+ (float-time) 30))
                  (report (expand-file-name "report.json" (plist-get cancelled :directory))))
              (while (and (not (file-exists-p report)) (< (float-time) deadline)
                          (process-live-p (plist-get cancelled :process)))
                (accept-process-output (plist-get cancelled :process) 0.1))
              (should (file-exists-p report))
              (should (process-live-p (plist-get cancelled :process))))
            (with-temp-buffer
              (insert "別のジョブは継続する。\n")
              (let ((id (tategaki-export '("txt" "html") "preview" 'full)))
                (setq control (gethash id tategaki-export--jobs))))
            (tategaki-export-cancel (plist-get cancelled :id))
            (tategaki-export-docker-test--wait cancelled 30)
            (tategaki-export-docker-test--wait control 30)
            (should (eq 'cancelled (plist-get cancelled :state)))
            (should (eq 'succeeded (plist-get control :state)))
            (should (equal "succeeded" (alist-get 'status (tategaki-export-docker-test--report control))))
            (setq passed t))
        (tategaki-export-docker-test--finish
         cancelled `((test . "real-cancel-isolated-job") (checks_passed . ,(if passed t :json-false))))
        (tategaki-export-docker-test--finish
         control `((test . "real-cancel-isolated-job-control") (checks_passed . ,(if passed t :json-false))))))))

(when (equal (getenv "TATEGAKI_EXPORT_DOCKER_TESTS") "1")
  (ert-deftest tategaki-export-docker-immediate-cancel-during-startup ()
    (let ((tategaki-export-output-directory
           (expand-file-name "dist/emacs-integration-tests" tategaki-export--directory))
          (tategaki-export--jobs (make-hash-table :test #'equal))
          (tategaki-export--last-job nil) job passed)
      (unwind-protect
          (progn
            (with-temp-buffer
              (insert (apply #'concat (make-list 10000 "起動中にも取り消せる。\n")))
              (let ((id (tategaki-export '("pdf") "preview" 'full)))
                (setq job (gethash id tategaki-export--jobs))
                ;; Deliberately do not wait for the report or container.  Docker
                ;; inspect initially fails until the launcher's setup completes.
                (tategaki-export-cancel id)))
            (tategaki-export-docker-test--wait job 35)
            (should (eq 'cancelled (plist-get job :state)))
            (should (equal "cancelled" (alist-get 'status (tategaki-export-docker-test--report job))))
            (setq passed t))
        (tategaki-export-docker-test--finish
         job `((test . "immediate-cancel-during-startup") (checks_passed . ,(if passed t :json-false))))))))

(provide 'tategaki-export-docker-test)
;;; tategaki-export-docker-test.el ends here
