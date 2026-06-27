;;; spookfox-omni-consult.el --- Consult adapter for spookfox-omni  -*- lexical-binding: t; -*-

;; Author: atom <re5etsmyth@gmail.com>
;; URL: https://github.com/re5et/spookfox-omni
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (spookfox-omni "0.1") (consult "1.0"))

;;; Commentary:
;;
;; Wraps each `spookfox-omni' source as a `consult--multi' source so
;; the same data flows through consult's UI: narrowing keys to switch
;; sources, marginalia annotations via category, async filtering.
;;
;; Usage:
;;   (require 'spookfox-omni-consult)
;;   M-x spookfox-omni-consult
;;
;; Narrowing keys (typed at the prompt after `<'):
;;   t  tabs        b  bookmarks   c  closed
;;   h  history     s  top sites

;;; Code:

(require 'consult)
(require 'spookfox-omni)

(defun spookfox-omni-consult--items (cands)
  "Turn CANDS (list of candidate plists) into propertized strings.
The original plist rides along on each string under the
`spookfox-omni-cand' text property so the :action callback can
recover it after consult returns just the display string."
  (let ((seen (make-hash-table :test 'equal))
        (out  nil))
    (dolist (c cands)
      (let* ((title (or (plist-get c :title) ""))
             (url   (or (plist-get c :url) ""))
             (disp  (if (string-empty-p title) url title))
             (n     2))
        (while (gethash disp seen)
          (setq disp (format "%s <%d>" (if (string-empty-p title) url title) n))
          (cl-incf n))
        (puthash disp t seen)
        (push (propertize disp
                          'spookfox-omni-cand c
                          'spookfox-omni-url  url)
              out)))
    (nreverse out)))

(defun spookfox-omni-consult--action (string)
  "Invoke the chosen candidate's :open action.
Recovers the candidate plist from the text properties consult
preserves through its UI."
  (when-let* ((cand (get-text-property 0 'spookfox-omni-cand string)))
    (let* ((src  (spookfox-omni--source (plist-get cand :source)))
           (open (or (plist-get src :open) #'spookfox-omni--default-open)))
      (funcall open cand))))

(defun spookfox-omni-consult--annotate (string)
  "Annotation function: show URL + source label after the title."
  (when-let* ((c (get-text-property 0 'spookfox-omni-cand string)))
    (let ((url   (plist-get c :url))
          (label (plist-get (spookfox-omni--source (plist-get c :source))
                            :label)))
      (concat "  " (propertize (or url "") 'face 'completions-annotations)
              "  [" (propertize (or label "?") 'face 'completions-annotations) "]"))))

(defun spookfox-omni-consult--source (key narrow cands)
  "Build a `consult--multi' source plist for spookfox-omni source KEY.
NARROW is the single-character narrowing key.  CANDS is the
already-fetched candidate list for this source (we pre-fetch all
sources in parallel before building any consult sources, so each
:items thunk is just a no-op closure over its slice).

KEY is closed over lexically so the :source tag stamped on each
candidate ends up as a real symbol (a backquoted `,key' inside the
lambda would NOT expand — the outer backquote treats the substituted
lambda as opaque data)."
  (let* ((src   (spookfox-omni--source key))
         (label (plist-get src :label)))
    (list :name     (capitalize (or label (symbol-name key)))
          :category 'spookfox-omni
          :narrow   narrow
          :annotate #'spookfox-omni-consult--annotate
          :items    (lambda ()
                      (mapcar (lambda (s)
                                (let ((cand (get-text-property
                                             0 'spookfox-omni-cand s)))
                                  (propertize s
                                              'spookfox-omni-cand
                                              (plist-put (copy-sequence cand)
                                                         :source key))))
                              (spookfox-omni-consult--items cands)))
          :action   #'spookfox-omni-consult--action)))

(defcustom spookfox-omni-consult-sources
  '((tabs      . ?t)
    (history   . ?h)
    (bookmarks . ?b))
  "Alist of (SOURCE-KEY . NARROW-CHAR) shown by `spookfox-omni-consult'.
Top-sites and closed are opt-in: they each cost one extra websocket
round-trip per invocation and most people don't reach for them often.
Add `(top-sites . ?s)' / `(closed . ?c)' to opt in."
  :type '(alist :key-type symbol :value-type character)
  :group 'spookfox-omni)

;;;###autoload
(defun spookfox-omni-consult ()
  "Pick from Firefox sources via `consult--multi'.
Narrowing keys per `spookfox-omni-consult-sources'.  All sources are
pre-fetched in a single parallel batch, so the consult prompt opens
in roughly max(per-source-round-trip) wall-clock time rather than
the sum."
  (interactive)
  (let* ((keys   (mapcar #'car spookfox-omni-consult-sources))
         (groups (spookfox-omni--fetch-grouped keys)))
    (consult--multi
     (mapcar (lambda (cell)
               (let* ((key    (car cell))
                      (narrow (cdr cell))
                      (cands  (cdr (assq key groups))))
                 (spookfox-omni-consult--source key narrow cands)))
             spookfox-omni-consult-sources)
     :prompt   "Firefox: "
     :sort     nil
     :require-match nil
     :history  'spookfox-omni-consult--history)))

(provide 'spookfox-omni-consult)
;;; spookfox-omni-consult.el ends here
