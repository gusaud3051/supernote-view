# supernote-emacs-renderer

A thin, pinned Node.js adapter around
[`supernote-typescript`](https://github.com/philips/supernote-typescript) that
turns a Supernote `.note` page into a cached SVG (or PNG) for the Emacs
`supernote-view-mode` in this package.

From the repository root, run `npm ci --prefix renderer`, or use
`M-x supernote-view-install-helper` after installing the Emacs package.
Dependencies are pinned and installed locally; no global npm install is used.

## Command contract

Stdout carries exactly one JSON object and nothing else; diagnostics go to
stderr. Exit status zero means the JSON on stdout is complete and usable.
`--page` is always zero-based; the page numbers a person sees are one-based.

```sh
node bin/supernote-render.mjs version
node bin/supernote-render.mjs manifest     --input PATH [--cache-dir DIR]
node bin/supernote-render.mjs render       --input PATH --page N [--format svg|png] [--upscale N] [--cache-dir DIR]
node bin/supernote-render.mjs render-title --input PATH --title-id TITLE_NNNNNNNNNNNN [--cache-dir DIR]
```

Failures answer with `{"schema_version":1,"error":{"code":…,"message":…}}` and
a distinct exit status per class: `2` usage, `3` input, `4` parse/signature,
`5` render, `6` cache, `7` internal, `8` out of range, `9` dependencies
missing.

`render` reports `render_mode` honestly as one of:

- `vector-ink` — the page's `TOTALPATH` strokes decoded and were drawn as real
  SVG paths;
- `raster-fallback` — they did not, so the page's own rasterized ink is shown;
- `raster-requested` — PNG output, which is raster by definition.

## Cache

Derived artifacts live under `~/.cache/emacs-supernote` (or `--cache-dir`),
never beside the `.note` source, which is only ever opened for reading.
Artifacts are written to a same-directory temporary and renamed into place.

Two kinds of thing are cached, keyed differently on purpose:

- **The manifest** describes the whole file, so it belongs to one revision of
  it: the key is the canonical source path, the file's size and mtime, the
  renderer ABI and version, and the pinned library version. The file's contents
  are never hashed for this.
- **Page and title artifacts** describe one page or one title, so each is keyed
  by *that content* — the page's ink and template layers, its stroke record, its
  compositing order and template identity, and the page geometry — plus the
  render options and the same ABI/version pair. They live in a flat `content/`
  directory shared across revisions.

Keying pages on their own bytes is what makes an edit incremental: writing one
new stroke on page 5 changes only page 5's key, so every other page's render
survives and `manifest` reports it as already available. Hashing those buffers
is cheap — 3 ms for the 97 MiB fixture, because only ~7 MiB of it is page data —
and happens once per manifest, not once per page turn.

`manifest` therefore reports, for each page, its `content_key`, the `artifact`
path when one is already cached in the requested `--format`, and the
`render_mode` that artifact was produced with, so a caller can display an
unchanged page without asking for a render and still report `V`/`R` truthfully.

Reclamation follows the two keyings. A superseded manifest generation is dropped
whole once it has aged out; a content-keyed artifact is reclaimed individually by
age, and serving one renews it, so a page read often but rarely re-rendered is
not thrown away under the reader.

## Tests and dependencies

Run `npm test --prefix renderer`. Unit tests use generated data. The optional
CLI corpus tests run only when `SUPERNOTE_TEST_FIXTURES` names a local JSON
mapping with `topology`, `realAnalysis`, and `mldl` paths. See the root README.
Source notes are read-only; mutation tests use temporary copies.

This repository distributes the adapter source and an npm lockfile, without
vendoring dependencies. `supernote-typescript` 0.7.1 declares GPL-3.0-or-later
in npm metadata while its upstream repository has an Apache-2.0 LICENSE.
Those upstream notices are separate from this adapter's GPL-3.0-or-later
license; consult the dependency's own distribution when redistributing it.

## Theme-aware SVG

Vector SVGs keep their original colors when opened outside Emacs. They carry
semantic `sn-pen-R-G-B` and `sn-marker-R-G-B` classes using `currentColor`,
and a marked definitions block for the viewer to replace in memory. Marker
classification comes from stroke metadata, including filled contours, rather
than its color. White cover-up strokes follow paper even when made by a marker.
The template raster has a separate sRGB component-transfer filter. Geometry,
recognition text, embedded pixels and source notes are never rewritten by a
theme change. Renderer ABI 3 invalidates artifacts made before these roles existed.

In Emacs, `supernote-view-follow-theme` defaults to `t`; ordinary ink and paper
follow the default face foreground/background, including their hue. Set it to
`nil` for original paper colors. `supernote-view-theme-highlighters` defaults to
`nil`. Gray markers (157/158) display as red and light-gray markers (201/202)
as yellow at 40% opacity; all other marker colors retain their source color
and 100% opacity. Customize `supernote-view-highlighter-colors` and
`supernote-view-highlighter-opacity` to change these mappings. Explicit
highlighter mappings take precedence over `supernote-view-theme-highlighters`.
Theme enable/disable automatically redisplays open notes from their cached SVGs.
After setting these options manually, run `M-x supernote-view-refresh-theme`.
PNG and raster-only fallback pages retain original colors: their pen types
cannot be separated reliably.
