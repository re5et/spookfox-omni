;;; spookfox-omni.el --- Firefox awesome-bar in Emacs via spookfox  -*- lexical-binding: t; -*-

;; Author: atom <re5etsmyth@gmail.com>
;; URL: https://github.com/re5et/spookfox-omni
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (spookfox "0.8"))
;; Keywords: convenience, hypermedia

;;; Commentary:
;;
;; spookfox-omni reimplements (most of) Firefox's awesome-bar in
;; Emacs's minibuffer.  With the spookfox bridge connected, it draws
;; candidates from the browser's open tabs, history, bookmarks, top
;; sites, and recently-closed tabs, exposes them through plain
;; `completing-read', and either focuses the chosen tab or opens its
;; URL.  Free-form input that doesn't match a candidate is opened as
;; a URL (or, optionally, sent to the default search engine).
;;
;; Entry points:
;;   `spookfox-omni'           — all enabled sources at once
;;   `spookfox-omni-tabs'      — only open tabs
;;   `spookfox-omni-history'   — only history
;;   `spookfox-omni-bookmarks' — only bookmarks
;;   `spookfox-omni-top-sites' — only top sites
;;   `spookfox-omni-closed'    — only recently-closed tabs
;;
;; Customize `spookfox-omni-enabled-sources' to opt into / out of
;; sources for the all-in-one picker.  Register additional sources
;; with `spookfox-omni-register-source'.
;;
;; A `consult' adapter (multi-source narrowing) ships separately as
;; `spookfox-omni-consult'.

;;; Code:

(require 'cl-lib)
(require 'spookfox)
(require 'spookfox-tabs)
(require 'spookfox-js-injection)

;; ---------------------------------------------------------------------------
;; Customization

(defgroup spookfox-omni nil
  "Firefox awesome-bar via spookfox."
  :group 'spookfox
  :prefix "spookfox-omni-")

(defcustom spookfox-omni-enabled-sources '(tabs history bookmarks)
  "Source symbols that `spookfox-omni' draws from by default.
Order matters: when two sources contain the same URL, the earlier
source wins (its candidate is the one that appears).  Available
built-ins: `tabs', `history', `bookmarks', `top-sites', `closed'."
  :type '(repeat symbol))

(defcustom spookfox-omni-history-limit 500
  "Maximum number of history entries to fetch in one call."
  :type 'integer)

(defcustom spookfox-omni-history-predicate
  #'spookfox-omni-history-default-predicate
  "Function deciding whether a history candidate is kept.
Called with the raw history plist (:title :url :visitCount
:lastVisitTime); returning non-nil keeps the entry.  The default,
`spookfox-omni-history-default-predicate', drops entries with empty
titles -- downloads, redirect-source URLs, iframe loads, and most
background requests all surface that way.  Set to `always' (or
`identity') to keep everything; supply your own function to filter
further by URL pattern, visit count, etc."
  :type '(choice (const :tag "Default: drop empty titles" spookfox-omni-history-default-predicate)
                 (function :tag "Custom predicate")))

(defcustom spookfox-omni-top-sites-limit 50
  "Maximum number of top sites to fetch in one call."
  :type 'integer)

(defcustom spookfox-omni-closed-limit 25
  "Maximum number of recently-closed entries to fetch in one call."
  :type 'integer)

(defcustom spookfox-omni-fallback 'open
  "How to treat free-form input that doesn't match a candidate.
- `open'   — pass the input to OPEN_TAB; Firefox decides whether
             to navigate or hand it to the default search engine.
- `search' — explicitly invoke the default search engine via
             SEARCH_FOR.
- nil      — do nothing, just message."
  :type '(choice (const :tag "Open as URL" open)
                 (const :tag "Default search engine" search)
                 (const :tag "Do nothing" nil)))

;; ---------------------------------------------------------------------------
;; Source registry
;;
;; A source is a plist:
;;   :label     STRING   — short tag shown as the right-side annotation.
;;   :js        STRING   — JS expression evaluated against the spookfox
;;                or FUNCTION  background script.  When a function, it's
;;                          called with no args and must return the JS.
;;   :transform FUNCTION — (raw-eval-result) -> list of candidate plists.
;;                          Required iff :js is provided.
;;   :fetch     FUNCTION — () -> list of candidate plists.  Fallback for
;;                          sources that aren't spookfox-backed; used iff
;;                          :js is absent.  Not parallel-batchable.
;;   :open      FUNCTION — (candidate) -> nil, optional; defaults to
;;                          opening :url in a new tab.
;;
;; The picker prefers :js + :transform because all such sources can be
;; fanned out into a single batch of parallel websocket round-trips.
;;
;; A candidate plist:
;;   :title STRING
;;   :url   STRING
;;   :extra PLIST  — source-specific metadata.

(defvar spookfox-omni-sources (make-hash-table :test 'eq)
  "Hash table mapping source symbols to source plists.")

(defun spookfox-omni-register-source (key plist)
  "Register a source named KEY with the given PLIST.
See the commentary at the top of `spookfox-omni--' for the plist shape."
  (puthash key plist spookfox-omni-sources))

(defun spookfox-omni--source (key)
  "Return the source plist for KEY, signalling if absent."
  (or (gethash key spookfox-omni-sources)
      (error "Unknown spookfox-omni source: %s" key)))

;; ---------------------------------------------------------------------------
;; JS snippets
;;
;; The addon's EVAL_IN_BACKGROUND_SCRIPT handler `window.eval's whatever we
;; ship.  Each snippet is an IIFE that returns a Promise resolving to a list
;; of plain objects spookfox auto-converts to elisp plists.

(defun spookfox-omni--js-tabs ()
  "(async () => {
     const tabs = await browser.tabs.query({});
     return tabs.map(t => ({
       title: t.title || '', url: t.url, id: t.id,
       windowId: t.windowId, active: t.active, pinned: t.pinned
     }));
   })()")

(defun spookfox-omni--js-history (limit)
  (format
   "(async () => {
      const items = await browser.history.search({text: '', maxResults: %d, startTime: 0});
      return items.map(h => ({
        title: h.title || '', url: h.url,
        visitCount: h.visitCount, lastVisitTime: h.lastVisitTime
      }));
    })()"
   limit))

(defun spookfox-omni--js-bookmarks ()
  "(async () => {
     const flat = (nodes) => nodes.flatMap(n =>
       n.url ? [{title: n.title || '', url: n.url, parent: n.parentId}]
             : (n.children ? flat(n.children) : []));
     const tree = await browser.bookmarks.getTree();
     return flat(tree);
   })()")

(defun spookfox-omni--js-top-sites (limit)
  (format
   "(async () => {
      const sites = await browser.topSites.get({
        newtab: true, includeBlocked: false, limit: %d
      });
      return sites.map(s => ({title: s.title || '', url: s.url}));
    })()"
   limit))

(defun spookfox-omni--js-closed (limit)
  (format
   "(async () => {
      const sessions = await browser.sessions.getRecentlyClosed({maxResults: %d});
      return sessions
        .filter(s => s.tab)
        .map(s => ({title: s.tab.title || '', url: s.tab.url}));
    })()"
   limit))

;; ---------------------------------------------------------------------------
;; Transforms (raw JS result -> canonical candidate plists)
;;
;; The addon hands plists back with :keyword keys mirrored from the JS object
;; keys.  Each transform normalises that to our canonical (:title :url :extra)
;; shape.

(defun spookfox-omni-history-default-predicate (h)
  "Default `spookfox-omni-history-predicate': drop empty-title items.
H is the raw history plist (:title :url :visitCount :lastVisitTime).
Empty titles are the strongest cheap signal that something isn't
real navigation -- downloads, redirect-source URLs, and most
background requests all surface that way."
  (let ((title (plist-get h :title)))
    (and title (not (string-empty-p title)))))

(defun spookfox-omni--transform-tabs (raw)
  (mapcar (lambda (tab)
            (list :title (plist-get tab :title)
                  :url   (plist-get tab :url)
                  :extra (list :id        (plist-get tab :id)
                               :window-id (plist-get tab :windowId)
                               :pinned    (plist-get tab :pinned))))
          raw))

(defun spookfox-omni--transform-history (raw)
  (mapcar (lambda (h)
            (list :title (plist-get h :title)
                  :url   (plist-get h :url)
                  :extra (list :visits (plist-get h :visitCount)
                               :last   (plist-get h :lastVisitTime))))
          (cl-remove-if-not spookfox-omni-history-predicate raw)))

(defun spookfox-omni--transform-bookmarks (raw)
  (mapcar (lambda (b)
            (list :title (plist-get b :title)
                  :url   (plist-get b :url)
                  :extra (list :parent (plist-get b :parent))))
          raw))

(defun spookfox-omni--transform-flat (raw)
  "Generic transform for sources whose raw items only need :title + :url."
  (mapcar (lambda (s)
            (list :title (plist-get s :title)
                  :url   (plist-get s :url)))
          raw))

;; ---------------------------------------------------------------------------
;; Actions

(defun spookfox-omni--client ()
  "Return the current spookfox client or nil."
  (cl-first spookfox--connected-clients))

(defun spookfox-omni--focus-tab (cand)
  "Focus the existing tab represented by CAND."
  (let* ((extra (plist-get cand :extra))
         (id    (plist-get extra :id))
         (wid   (plist-get extra :window-id))
         (client (spookfox-omni--client)))
    (when client
      (spookfox-tabs--request client "FOCUS_TAB"
                              `((tab-id . ,id) (window-id . ,wid))))))

(defun spookfox-omni--open-url (url)
  "Open URL in a new tab."
  (when-let* ((client (spookfox-omni--client)))
    (spookfox-tabs--request client "OPEN_TAB" `((url . ,url)))))

(defun spookfox-omni--search-for (query)
  "Send QUERY to the default search engine."
  (when-let* ((client (spookfox-omni--client)))
    (spookfox-tabs--request client "SEARCH_FOR" query)))

(defun spookfox-omni--default-open (cand)
  "Default :open: open the candidate's URL in a new tab."
  (spookfox-omni--open-url (plist-get cand :url)))

;; ---------------------------------------------------------------------------
;; Built-in source registrations
;;
;; Limits read from defcustoms at fetch time (hence :js as a function for the
;; sources that interpolate them), so M-x customize takes effect without
;; re-registering.

(spookfox-omni-register-source
 'tabs       (list :label "tab"
                   :js    (spookfox-omni--js-tabs)
                   :transform #'spookfox-omni--transform-tabs
                   :open  #'spookfox-omni--focus-tab))

(spookfox-omni-register-source
 'history    (list :label "history"
                   :js    (lambda ()
                            (spookfox-omni--js-history
                             spookfox-omni-history-limit))
                   :transform #'spookfox-omni--transform-history))

(spookfox-omni-register-source
 'bookmarks  (list :label "bookmark"
                   :js    (spookfox-omni--js-bookmarks)
                   :transform #'spookfox-omni--transform-bookmarks))

(spookfox-omni-register-source
 'top-sites  (list :label "top"
                   :js    (lambda ()
                            (spookfox-omni--js-top-sites
                             spookfox-omni-top-sites-limit))
                   :transform #'spookfox-omni--transform-flat))

(spookfox-omni-register-source
 'closed     (list :label "closed"
                   :js    (lambda ()
                            (spookfox-omni--js-closed
                             spookfox-omni-closed-limit))
                   :transform #'spookfox-omni--transform-flat))

;; ---------------------------------------------------------------------------
;; Free-form input detection

(defun spookfox-omni--url-like-p (s)
  "Return non-nil if S looks like a URL or bare hostname."
  (or (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*://" s)
      (string-match-p "\\`\\([[:alnum:]_-]+\\.\\)+[[:alpha:]]\\{2,\\}\\(:\\|/\\|\\?\\|$\\)" s)
      (string-match-p "\\`localhost\\(:[0-9]+\\)?\\(/\\|$\\)" s)))

(defun spookfox-omni--maybe-https (s)
  "Add an https:// prefix to S if it has no scheme."
  (if (string-match-p "://" s) s (concat "https://" s)))

;; ---------------------------------------------------------------------------
;; Parallel fetch primitive
;;
;; spookfox-request is non-blocking: it sends the message and returns the
;; request ID immediately, then a response handler stashes the result in
;; `spookfox--responses' whenever it arrives.  By issuing every request
;; first, *then* polling each ID, we let the addon's async handlers run
;; concurrently — wall-clock collapses to roughly max(per-request) instead
;; of sum(per-request).

(defun spookfox-omni--source-js (src)
  "Return the JS string for SRC, or nil if SRC uses :fetch instead."
  (let ((js (plist-get src :js)))
    (cond ((stringp   js) js)
          ((functionp js) (funcall js)))))

(defun spookfox-omni--js-eval-parallel (js-list)
  "Eval each JS string in JS-LIST against the addon's background script.
All sends are issued first, polls happen second; total wall-clock is
roughly max(individual round-trips).  Returns results positionally
matched to JS-LIST.  Returns nil if no spookfox client is connected."
  (when-let* ((client (cl-first spookfox--connected-clients)))
    (let* ((spookfox--msg-prefix "JS_INJECT_")
           (ids (mapcar (lambda (js)
                          (spookfox-request client "EVAL_IN_BACKGROUND_SCRIPT"
                                            `((code . ,js))))
                        js-list)))
      (mapcar (lambda (id)
                (plist-get (spookfox--poll-response id) :payload))
              ids))))

;; ---------------------------------------------------------------------------
;; Gather

(defun spookfox-omni--fetch-grouped (source-keys)
  "Fetch candidates for each of SOURCE-KEYS; return alist (KEY . CANDS).
Sources providing :js are batched into a single parallel round-trip;
:fetch fallbacks run serially after.  Output preserves SOURCE-KEYS
order.  No dedup."
  (let* ((entries     (mapcar (lambda (k) (cons k (spookfox-omni--source k)))
                              source-keys))
         (js-entries  (cl-remove-if-not (lambda (e) (plist-get (cdr e) :js)) entries))
         (raw-results (spookfox-omni--js-eval-parallel
                       (mapcar (lambda (e) (spookfox-omni--source-js (cdr e)))
                               js-entries)))
         (results-by-key (make-hash-table :test 'eq)))
    (cl-mapc (lambda (entry raw)
               (puthash (car entry)
                        (funcall (plist-get (cdr entry) :transform) raw)
                        results-by-key))
             js-entries raw-results)
    (dolist (e entries)
      (let ((key (car e)) (src (cdr e)))
        (unless (gethash key results-by-key)
          (puthash key (funcall (plist-get src :fetch)) results-by-key))))
    (mapcar (lambda (key) (cons key (gethash key results-by-key)))
            source-keys)))

(defun spookfox-omni--gather (source-keys)
  "Flat candidate list across SOURCE-KEYS, tagged with :source.
Deduped by URL; earlier source wins."
  (let ((seen (make-hash-table :test 'equal))
        (acc  '()))
    (dolist (group (spookfox-omni--fetch-grouped source-keys))
      (let ((key (car group)))
        (dolist (c (cdr group))
          (let ((url (plist-get c :url)))
            (when (and url (not (gethash url seen)))
              (puthash url t seen)
              (push (plist-put (copy-sequence c) :source key) acc))))))
    (nreverse acc)))

;; ---------------------------------------------------------------------------
;; Picker

(defun spookfox-omni--display (cand)
  "Compute the bare display string for CAND."
  (let ((title (plist-get cand :title))
        (url   (plist-get cand :url)))
    (if (and title (not (string-empty-p title))) title url)))

(defun spookfox-omni--act (selected table)
  "Take action on SELECTED, looked up in completion TABLE.
If SELECTED matches a known candidate, dispatch to that source's
:open (or the default open).  Otherwise consult
`spookfox-omni-fallback'."
  (if-let* ((cand (gethash selected table)))
      (let* ((src  (spookfox-omni--source (plist-get cand :source)))
             (open (or (plist-get src :open) #'spookfox-omni--default-open)))
        (funcall open cand))
    (cond
     ((null spookfox-omni-fallback)
      (message "No match: %S" selected))
     ((eq spookfox-omni-fallback 'search)
      (if (spookfox-omni--url-like-p selected)
          (spookfox-omni--open-url (spookfox-omni--maybe-https selected))
        (spookfox-omni--search-for selected)))
     (t                                  ; `open' (default)
      (spookfox-omni--open-url
       (if (spookfox-omni--url-like-p selected)
           (spookfox-omni--maybe-https selected)
         selected))))))

(defun spookfox-omni--pick (source-keys &optional prompt)
  "Internal picker used by the public entry points.
SOURCE-KEYS is a list of registered source symbols.  PROMPT is the
minibuffer prompt."
  (let* ((cands  (spookfox-omni--gather source-keys))
         (table  (make-hash-table :test 'equal))
         (order  nil))
    (dolist (cand cands)
      (let* ((base (spookfox-omni--display cand))
             (key  base)
             (n    2))
        ;; Disambiguate duplicate display strings without ever clobbering
        ;; an existing entry (a tabbed Wikipedia search would otherwise lose
        ;; all but the last hit).
        (while (gethash key table)
          (setq key (format "%s <%d>" base n))
          (cl-incf n))
        (puthash key cand table)
        (push key order)))
    (let* ((completion-extra-properties
            (list :annotation-function
                  (lambda (s)
                    (when-let* ((c (gethash s table)))
                      (let ((url   (plist-get c :url))
                            (label (plist-get (spookfox-omni--source
                                               (plist-get c :source))
                                              :label)))
                        (concat "  " (propertize (or url "")
                                                 'face 'completions-annotations)
                                "  ["
                                (propertize (or label "?")
                                            'face 'completions-annotations)
                                "]"))))))
           (picked (completing-read (or prompt "Firefox: ")
                                    (nreverse order) nil nil)))
      (spookfox-omni--act picked table))))

;; ---------------------------------------------------------------------------
;; Public commands

;;;###autoload
(defun spookfox-omni ()
  "Pick from every enabled Firefox source via `completing-read'.
See `spookfox-omni-enabled-sources' to configure which sources
participate.  Free-form input is handled per `spookfox-omni-fallback'."
  (interactive)
  (spookfox-omni--pick spookfox-omni-enabled-sources "Firefox: "))

;;;###autoload
(defun spookfox-omni-tabs ()
  "Pick from open Firefox tabs."
  (interactive)
  (spookfox-omni--pick '(tabs) "tab: "))

;;;###autoload
(defun spookfox-omni-history ()
  "Pick from Firefox history."
  (interactive)
  (spookfox-omni--pick '(history) "history: "))

;;;###autoload
(defun spookfox-omni-bookmarks ()
  "Pick from Firefox bookmarks."
  (interactive)
  (spookfox-omni--pick '(bookmarks) "bookmark: "))

;;;###autoload
(defun spookfox-omni-top-sites ()
  "Pick from Firefox top sites."
  (interactive)
  (spookfox-omni--pick '(top-sites) "top: "))

;;;###autoload
(defun spookfox-omni-closed ()
  "Pick from recently-closed Firefox tabs."
  (interactive)
  (spookfox-omni--pick '(closed) "closed: "))

(provide 'spookfox-omni)
;;; spookfox-omni.el ends here
