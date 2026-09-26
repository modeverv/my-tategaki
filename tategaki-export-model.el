;;; tategaki-export-model.el --- Immutable source model for export -*- lexical-binding: t; -*-

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

;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; This adapter calls the editor's annotation parser, without using its layout,
;; buffers, overlays, or glyph substitutions.  JSON offsets are Unicode character
;; offsets relative to the snapshot; original buffer offsets live in source.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'tategaki-typeset)

(defun tategaki-export-model--get (key object &optional default)
  "Read KEY from JSON-style alist OBJECT, falling back to DEFAULT."
  (or (alist-get key object) (alist-get (symbol-name key) object nil nil #'equal) default))

(defun tategaki-export-model--diagnostic (code message start end)
  "Make an annotation diagnostic with CODE, MESSAGE, START and END."
  `((code . ,code) (severity . "error") (message . ,message)
    (start . ,start) (end . ,end)))

(defun tategaki-export-model--raw-run (text start)
  "Make an unformatted run for TEXT at START."
  `((kind . "text") (text . ,text) (emphasis . [])
    (start . ,start) (end . ,(+ start (length text)))))

(defun tategaki-export-model--line-runs (text offset)
  "Return runs for line TEXT at OFFSET using the shared annotation parser."
  (if (not (string-match-p "[《［]" text))
      (if (string-empty-p text) nil (list (tategaki-export-model--raw-run text offset)))
    (let* ((tategaki-typeset-annotation-display 'rendered)
           (tategaki-typeset--boundaries nil)
           (units (tategaki-typeset--parse text))
           runs current-key texts readings start end)
      (cl-labels
          ((flush ()
             (when current-key
               (let ((run `((kind . ,(car current-key))
                            (text . ,(apply #'concat (nreverse texts)))
                            (emphasis . ,(if (nth 1 current-key)
                                             (vector (symbol-name (nth 1 current-key))) []))
                            (start . ,(+ offset start)) (end . ,(+ offset end)))))
                 (when (equal (car current-key) "ruby")
                   (setq run (append run `((reading . ,(apply #'concat (nreverse readings)))))))
                 (push run runs)))
             (setq texts nil readings nil)))
        (dolist (unit units)
          (let* ((kind (pcase (plist-get unit :kind) ('ruby "ruby") ('tcy "tcy") (_ "text")))
                 (key (list kind (plist-get unit :emphasis)
                            (and (not (equal kind "text")) (plist-get unit :annotation-start)))))
            (unless (equal key current-key)
              (flush)
              (setq current-key key start (plist-get unit :start)))
            (push (plist-get unit :source-text) texts)
            (push (or (plist-get unit :ruby) "") readings)
            (setq end (plist-get unit :end))))
        (flush))
      (nreverse runs))))

(defun tategaki-export-model--literal-diagnostics (runs source source-offset)
  "Report literal notes in RUNS, locating them in SOURCE at SOURCE-OFFSET."
  (let (diagnostics)
    (dolist (run runs)
      (when (equal (alist-get 'kind run) "text")
        (let ((text (alist-get 'text run)) (at 0)
              (search-from (max 0 (- (alist-get 'start run) source-offset))))
          (while (string-match "［＃[^］\n]*］?\\|《[^》\n]*》?\\|》" text at)
            (let* ((literal (match-string 0 text)) (next (match-end 0))
                   (from (or (string-match (regexp-quote literal) source search-from) search-from))
                   (to (+ from (length literal))))
              (push (tategaki-export-model--diagnostic
                     "unresolved_annotation" "未対応または未完成の注記を原文のまま保持しました。"
                     (+ source-offset from) (+ source-offset to)) diagnostics)
              (setq at next search-from to))))))
    (nreverse diagnostics)))

(defun tategaki-export-model--heading (line mode)
  "Classify LINE with explicit heading MODE, returning (LEVEL . PREFIX-LENGTH)."
  (save-match-data
    (cond
     ((and (equal mode "markdown") (string-match "\\`\\(#+\\)[ \t]+" line))
      (cons (min 6 (length (match-string 1 line))) (match-end 0)))
     ((and (equal mode "org") (string-match "\\`\\(\\*+\\)[ \t]+" line))
      (cons (min 6 (length (match-string 1 line))) (match-end 0)))
     ((and (equal mode "japanese")
           (string-match-p "\\`[ \t　]*第[一二三四五六七八九十百千〇零0-9０-９]+[章部幕節]" line))
      (cons 1 0)))))

(defun tategaki-export-model--refresh-expectations (model)
  "Recompute semantic expectations after changing MODEL's blocks."
  (let (bodies readings chapters (ruby 0) (tcy 0) (dot 0) (line 0))
    (mapc (lambda (block)
            (let* ((runs (alist-get 'runs block))
                   (body (mapconcat (lambda (run) (alist-get 'text run)) runs "")))
              (push body bodies)
              (when (equal (alist-get 'type block) "heading")
                (push `((id . ,(alist-get 'id block)) (title . ,body)
                        (level . ,(alist-get 'level block))) chapters)))
            (mapc (lambda (run)
                    (pcase (alist-get 'kind run)
                      ("ruby" (cl-incf ruby) (push (alist-get 'reading run) readings))
                      ("tcy" (cl-incf tcy)))
                    (when (member "dot" (append (alist-get 'emphasis run) nil)) (cl-incf dot))
                    (when (member "line" (append (alist-get 'emphasis run) nil)) (cl-incf line)))
                  (alist-get 'runs block)))
          (alist-get 'blocks model))
    (setf (alist-get 'expectations model)
          `((body_text . ,(mapconcat #'identity (nreverse bodies) "\n"))
            (ruby_readings . ,(vconcat (nreverse readings)))
            (chapters . ,(vconcat (nreverse chapters)))
            (annotation_counts . ((ruby . ,ruby) (tcy . ,tcy) (dot . ,dot) (line . ,line)))))
    model))

(defun tategaki-export-model-create (text &optional metadata options)
  "Create an export model from TEXT, optional METADATA and OPTIONS alists.
OPTIONS accepts input.headings (literal, markdown, org, japanese), source_name,
timestamp, range_start and range_end.  Offsets in blocks/runs are zero-based
Unicode codepoints in TEXT.  No text property or display glyph is exported."
  (save-match-data
    (setq text (substring-no-properties text))
    (let* ((input (tategaki-export-model--get 'input options))
           (headings (tategaki-export-model--get 'headings input "literal"))
           (hash (secure-hash 'sha256 (encode-coding-string text 'utf-8-unix t)))
           (metadata (copy-tree metadata))
           (at 0) (number 0) blocks bodies chapters readings diagnostics
           (ruby-count 0) (tcy-count 0) (dot-count 0) (line-count 0))
      (unless (member headings '("literal" "markdown" "org" "japanese"))
        (error "Unsupported input.headings: %S" headings))
      (dolist (entry `((title . "無題") (author . "") (language . "ja")
                       (identifier . ,(concat "urn:sha256:" hash))))
        (unless (tategaki-export-model--get (car entry) metadata)
          (push entry metadata)))
      ;; split-string retains the final empty element, preserving terminal LF.
      (dolist (raw-line (split-string text "\n" nil))
        (let* ((heading (tategaki-export-model--heading raw-line headings))
               (prefix (or (cdr heading) 0))
               (line (substring raw-line prefix))
               (runs (tategaki-export-model--line-runs line (+ at prefix)))
               (type (cond (heading "heading") ((equal line "\f") "page_break") (t "paragraph")))
               (id (format "b%06d" (cl-incf number)))
               (body (mapconcat (lambda (run) (alist-get 'text run)) runs ""))
               (block `((id . ,id) (type . ,type) (start . ,at)
                        (end . ,(+ at (length raw-line))) (runs . ,(vconcat runs)))))
          (when heading
            (push (cons 'level (car heading)) block)
            (push `((id . ,id) (title . ,body) (level . ,(car heading))) chapters))
          (dolist (run runs)
            (pcase (alist-get 'kind run)
              ("ruby" (cl-incf ruby-count) (push (alist-get 'reading run) readings))
              ("tcy" (cl-incf tcy-count)))
            (when (member "dot" (append (alist-get 'emphasis run) nil)) (cl-incf dot-count))
            (when (member "line" (append (alist-get 'emphasis run) nil)) (cl-incf line-count)))
          (dolist (diagnostic (tategaki-export-model--literal-diagnostics runs line (+ at prefix)))
            (push diagnostic diagnostics))
          (push block blocks) (push body bodies)
          (setq at (+ at (length raw-line) 1))))
      `((schema_version . 1) (metadata . ,metadata)
        (source . ((name . ,(tategaki-export-model--get 'source_name options "source.txt"))
                   (sha256 . ,hash)
                   (timestamp . ,(tategaki-export-model--get 'timestamp options
                                                            (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)))
                   (range_start . ,(tategaki-export-model--get 'range_start options 0))
                   (range_end . ,(tategaki-export-model--get 'range_end options (length text)))))
        (blocks . ,(vconcat (nreverse blocks)))
        (expectations . ((body_text . ,(mapconcat #'identity (nreverse bodies) "\n"))
                         (ruby_readings . ,(vconcat (nreverse readings)))
                         (chapters . ,(vconcat (nreverse chapters)))
                         (annotation_counts . ((ruby . ,ruby-count) (tcy . ,tcy-count)
                                               (dot . ,dot-count) (line . ,line-count)))))
        (diagnostics . ,(vconcat (nreverse diagnostics)))))))

(defun tategaki-export-model--cut-annotation-p (full start end)
  "Whether START or END cuts a recognized annotation in FULL."
  (let ((tategaki-typeset-annotation-display 'rendered)
        (tategaki-typeset--boundaries nil))
    (cl-some
     (lambda (boundary)
       (when (and (> boundary 0) (< boundary (length full)))
         (let* ((line-start (1+ (or (cl-position ?\n full :end boundary :from-end t) -1)))
                (line-end (or (string-match "\n" full boundary) (length full)))
                (line (substring full line-start line-end))
                (relative (- boundary line-start)))
           (and (string-match-p "[《［]" line)
                (cl-some (lambda (unit)
                           (when (plist-get unit :annotation-start)
                             (< (min (plist-get unit :start) (plist-get unit :annotation-start))
                                relative
                                (max (plist-get unit :end) (plist-get unit :annotation-end)))))
                         (tategaki-typeset--parse line))))))
     (list start end))))

(defun tategaki-export-model-snapshot (&optional scope metadata options)
  "Return (:text TEXT :model MODEL) for current buffer without altering it.
SCOPE is nil/full, region, or narrowed.  Full ignores narrowing by default.
METADATA and OPTIONS are as for `tategaki-export-model-create'.  An annotation
cut by an explicit range remains literal and produces an error diagnostic."
  (let* ((begin (pcase scope ('region (region-beginning)) ('narrowed (point-min)) (_ nil)))
         (end (pcase scope ('region (region-end)) ('narrowed (point-max)) (_ nil))))
    (save-restriction
      (widen)
      (setq begin (or begin (point-min)) end (or end (point-max)))
      (let* ((full (buffer-substring-no-properties (point-min) (point-max)))
             (start (1- begin)) (finish (1- end))
             (text (substring full start finish))
             (options (append `((source_name . ,(or buffer-file-name (buffer-name)))
                                (range_start . ,start) (range_end . ,finish)) options))
             (model (tategaki-export-model-create text metadata options)))
        (when (tategaki-export-model--cut-annotation-p full start finish)
          ;; Context is required to recognize a cut suffix/outer annotation.
          ;; Retain that boundary line wholly rather than deleting any fragments.
          (let ((blocks (alist-get 'blocks model)))
            (dotimes (index (length blocks))
              (let* ((block (aref blocks index)) (from (alist-get 'start block))
                     (to (alist-get 'end block)) (raw (substring text from to)))
                (when (or (= index 0) (= index (1- (length blocks))))
                  (setf (alist-get 'runs block)
                        (if (string-empty-p raw) []
                          (vector (tategaki-export-model--raw-run raw from)))))))
            (tategaki-export-model--refresh-expectations model))
          (setf (alist-get 'diagnostics model)
                (vconcat (alist-get 'diagnostics model)
                         (vector (tategaki-export-model--diagnostic
                                  "cut_annotation" "選択範囲で切れた注記の境界行を原文のまま保持しました。"
                                  0 (length text))))))
        (list :text text :model model)))))

(defun tategaki-export-model-write-json (model path)
  "Write MODEL as UTF-8 JSON to PATH."
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file path (insert (json-encode model) "\n"))))

(defun tategaki-export-model-batch ()
  "Batch entry point: SOURCE OUTPUT [OPTIONS.json] from remaining arguments.
OPTIONS may contain metadata, input, source_name and timestamp.  Source is
strict UTF-8 text; newline codepoints are preserved, including CRLF."
  (let* ((args (if (equal (car command-line-args-left) "--")
                   (cdr command-line-args-left) command-line-args-left))
         (source (nth 0 args)) (output (nth 1 args)) (options-file (nth 2 args))
         (json-object-type 'alist) (json-array-type 'vector) (json-key-type 'symbol)
         (options (and options-file (json-read-file options-file)))
         text)
    (setq command-line-args-left nil)
    (unless (and source output) (error "Usage: SOURCE OUTPUT [OPTIONS.json]"))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents source))
      (setq text (buffer-string)))
    (when (cl-some (lambda (char) (or (> char #x10ffff) (<= #xd800 char #xdfff))) text)
      (error "Source is not valid UTF-8"))
    (tategaki-export-model-write-json
     (tategaki-export-model-create text (tategaki-export-model--get 'metadata options)
                                   (append `((source_name . ,(file-name-nondirectory source))) options))
     output)))

(provide 'tategaki-export-model)
;;; tategaki-export-model.el ends here
