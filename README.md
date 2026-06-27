# spookfox-omni

Firefox's awesome-bar, in Emacs's minibuffer.

Given a connected [spookfox](https://github.com/bitspook/spookfox) bridge,
`spookfox-omni` gathers candidates from your browser's open tabs, history,
bookmarks, top sites, and recently-closed tabs and exposes them through plain
`completing-read`. Selecting a candidate either focuses an existing tab or
opens its URL. Free-form input that doesn't match anything is opened as a URL
(or sent to the default search engine if you prefer).

## Install

Requires the [spookfox](https://github.com/bitspook/spookfox) Emacs package
and its Firefox extension already running. Then:

```elisp
(use-package spookfox-omni
  :ensure t
  :vc (:url "https://github.com/re5et/spookfox-omni" :rev :newest))
```

## Commands

| Command                   | Sources                |
| ------------------------- | ---------------------- |
| `spookfox-omni`           | Every enabled source   |
| `spookfox-omni-tabs`      | Open tabs              |
| `spookfox-omni-history`   | History                |
| `spookfox-omni-bookmarks` | Bookmarks              |
| `spookfox-omni-top-sites` | Top sites              |
| `spookfox-omni-closed`    | Recently-closed tabs   |

## Configuration

Defaults:

```elisp
(setq spookfox-omni-enabled-sources '(tabs history bookmarks))
(setq spookfox-omni-history-limit 500)
(setq spookfox-omni-fallback 'open) ; 'open | 'search | nil
```

Add your own source — anything that returns a list of `(:title :url :extra)`
plists can join the picker:

```elisp
(spookfox-omni-register-source
 'reading-list
 (list :label "reading"
       :fetch (lambda () ...)
       :open  (lambda (cand) ...)))   ; optional; defaults to OPEN_TAB
```

## Consult adapter

`spookfox-omni-consult` (shipped alongside) wraps each source as a
[consult](https://github.com/minad/consult) `consult--multi` source so you
get narrowing-key switching between sources and async filtering.

## License

GPL-3.0-or-later.
