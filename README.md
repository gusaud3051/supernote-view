# supernote-view

A read-only Emacs major mode for Supernote `.note` documents. Handwriting is
rendered as vector SVG where stroke data is available, with a PNG fallback.
The bundled Node helper parses documents in a separate process.

Features include asynchronous page rendering, prefetch, zoom and fit modes,
a handwritten-title outline, theme-aware ink, optional Evil keys, and reload
when a synced file changes. The viewer never saves changes to source notes.

## Requirements

- Emacs 29.1 or later, with SVG or PNG image support (tested on Emacs 32).
- Node.js 18.17 or later and npm.
- Local `.note` files. No cloud account is required.

## Installation

With straight.el and use-package:

```elisp
(use-package supernote-view
  :straight (supernote-view :type git :host github :repo "gusaud3051/supernote-view"
                           :files ("supernote-view.el" "renderer"))
  :commands (supernote-view-file supernote-view-dwim supernote-view-install-helper)
  :mode ("\\.note\\'" . supernote-view-mode)
  :init
  (add-to-list 'auto-coding-alist '("\\.note\\'" . no-conversion))
  (add-to-list 'inhibit-local-variables-regexps "\\.note\\'"))
```

Doom `packages.el`:

```elisp
(package! supernote-view
  :recipe (:host github :repo "gusaud3051/supernote-view"
           :files ("supernote-view.el" "renderer")))
```

Use the same declaration in `config.el` with `use-package!` and without
`:straight`, then run `doom sync`. Keeping the coding registration in `:init`
is necessary before `find-file` reads a binary note.

For a manual install, clone this repository, add it to `load-path`, and
`(require 'supernote-view)`. The renderer directory must stay beside the Lisp
file. Run `M-x supernote-view-install-helper` once to install pinned npm
dependencies (or `npm ci --prefix /path/to/supernote-view/renderer`). Nothing
is downloaded when the package loads. `supernote-view-helper` can point to an
existing helper installation instead.

## Usage

`M-x supernote-view-file` opens a note without first inserting its binary data
into an ordinary editing buffer. `find-file` also works. `M-x
supernote-view-dwim` opens a note at point or prompts for a file.

| Key | Action |
| --- | --- |
| `n`, `p` | Next / previous page |
| `M-g g` | Go to page |
| `W`, `H`, `P` | Fit width / height / page |
| `o` | Toggle handwritten-title outline |
| `r` | Refresh |
| `q` | Quit viewer |

Evil normal state additionally supports `j`/`k` across page boundaries,
`]]`/`[[`, `gg`/`G`, and `zi`/`zo`. See `C-h m` for the complete map.
Customize the `supernote-view` group for caching, prefetch, sizing, and theme
colors. Cached artifacts live outside the source-note directory.

## Android

The mode has no Doom dependency. Native Android Emacs needs a working Node
executable and helper dependencies in its own accessible environment; set
`supernote-view-node-executable` and `supernote-view-helper` if needed.
Android rendering and file notifications still need device verification.

## Tests

```sh
npm ci --prefix renderer
npm test --prefix renderer
emacs -Q --batch --eval '(setq native-comp-enable-subr-trampolines nil)' -L . -l test/supernote-view-test.el -f ert-run-tests-batch-and-exit
```

Evil checks skip unless Evil is available on `load-path`. Optional real-note
tests use a private reference corpus; no notes are shipped. Set
`SUPERNOTE_TEST_NOTE` to the five-page reference note for the ERT integration
test. Set `SUPERNOTE_TEST_FIXTURES` to a JSON mapping of the three reference
fixtures for CLI integration tests. Expected corpus metadata is documented in
`renderer/test/helpers.mjs`; arbitrary notes may not match those assertions.

The package was extracted from the author's dotfiles. The renderer protocol,
cache design, and dependency notices are documented in [renderer/README.md](renderer/README.md).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). Dependencies retain their own notices.
