;;; supernote-view.el --- Read-only viewer for Supernote .note files -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Hyeonmyeong Kim
;; Author: gusaud3051 <https://github.com/gusaud3051>
;; URL: https://github.com/gusaud3051/supernote-view
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: multimedia, files
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See LICENSE.


;;; Commentary:
;;
;; A read-only major mode for local Supernote `.note' documents, built around a
;; small pinned Node helper that wraps `supernote-typescript'.  It shows one
;; page at a time as a hybrid vector SVG -- handwriting is reconstructed from
;; the file's own `TOTALPATH' stroke data and drawn as real `<path>' elements,
;; while page templates and a few bitmap-only elements stay raster -- and it
;; opens the note's handwritten title hierarchy in an outline buffer with `o'.
;;
;; The mode never writes to a `.note' file.  Editing, annotating, and writing
;; changes back to a Supernote document are out of scope; every buffer is
;; read-only and every save path signals.
;;
;; Two entry points:
;;
;;   `supernote-view-file'  the recommended one.  It builds the viewer buffer
;;                          without first inserting a hundred megabytes of
;;                          binary into a normal buffer.
;;   `supernote-view-mode'  registered on `auto-mode-alist', so an ordinary
;;                          `find-file' also works.  `.note' is registered in
;;                          `auto-coding-alist' as `no-conversion' and the
;;                          inserted bytes are discarded on activation.
;;
;; Why a Node helper rather than parsing in Lisp: the `.note' format is
;; reverse-engineered and still moving, and `supernote-typescript' is the only
;; implementation that both reads current Manta files and reconstructs native
;; pen paths instead of tracing a rasterized page.  Keeping the binary parsing
;; in a separate short-lived process also keeps a malformed document from
;; taking Emacs with it.  The helper is invoked with a list-valued
;; `make-process' `:command'; no path ever passes through a shell.
;;
;; Rendering is asynchronous and cancellable.  Each request carries a
;; buffer-local generation token, so a callback that arrives after the reader
;; has already turned the page is dropped rather than displayed.  Zooming
;; resizes the image Emacs already has; it does not ask the helper for a new
;; one, because the cached artifact is vector and scales on its own.
;;
;; Pages are prepared before they are asked for, one at a time, once the
;; current one is on screen, and the artifact each produced is remembered.
;; Turning to a page that is already in hand therefore shows it immediately: no
;; process is started and no loading placeholder appears.  Three groups get
;; prepared, in this order:
;;
;;   the next page;
;;   the previous one, which reading straight through already has but an
;;     outline jump or a `G' does not;
;;   the rest of `supernote-view-prefetch-count' pages ahead, and then every
;;     page a title points at, up to
;;     `supernote-view-prefetch-outline-pages'.
;;
;; Speculative work always yields: turning to a page that has not been rendered
;; cancels it first, and a render already in flight is left to finish rather
;; than being restarted from a reshuffled queue.
;;
;; Evil is supported as part of the mode rather than left to the user, but it
;; is optional at load time: the ordinary mode maps are complete on their own,
;; and the normal-state bindings are installed only once Evil is loaded.
;;
;; Keys are documented in `supernote-view-mode-map' and
;; `supernote-outline-mode-map'.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'filenotify)
(require 'image-mode)
(require 'outline)
(require 'seq)
(require 'subr-x)

(declare-function evil-define-key* "evil-core")
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-normalize-keymaps "evil-core")
(declare-function evil-collection-inhibit-insert-state "evil-collection")


;;;; Customization

(defgroup supernote-view nil
  "Read-only viewer for Supernote `.note' documents."
  :group 'multimedia
  :prefix "supernote-view-")

(defconst supernote-view--package-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this installed package, including its renderer.")

(defcustom supernote-view-helper
  (file-truename
   (expand-file-name "renderer/bin/supernote-render.mjs"
                     supernote-view--package-directory))
  "Path to the bundled Node helper script.
Install its pinned dependencies with `supernote-view-install-helper', or run
`supernote-view-repair-command' in a terminal.  No installation runs on load."
  :type 'file)

;;;###autoload
(defun supernote-view-install-helper ()
  "Install the bundled helper's pinned dependencies asynchronously."
  (interactive)
  (let ((npm (executable-find "npm"))
        (directory (file-name-directory
                    (directory-file-name (file-name-directory (file-truename supernote-view-helper))))))
    (unless npm (user-error "npm is required; install Node.js first"))
    (unless (file-readable-p (expand-file-name "package-lock.json" directory))
      (user-error "Bundled renderer is missing; include renderer/ in the package recipe"))
    (let ((buffer (get-buffer-create "*supernote-view-install*")))
      (when (get-buffer-process buffer)
        (user-error "Helper installation is already running"))
      (with-current-buffer buffer
        (let ((inhibit-read-only t)) (erase-buffer)))
      (make-process :name "supernote-view-install" :buffer buffer
                    :command (list npm "ci" "--prefix" directory)
                    :sentinel #'supernote-view--install-sentinel)
      (display-buffer buffer))))

(defun supernote-view--install-sentinel (process event)
  "Report completion EVENT from helper installation PROCESS."
  (when (memq (process-status process) '(exit signal))
    (message "Supernote helper installation %s; see *supernote-view-install*"
             (if (zerop (process-exit-status process)) "finished" (string-trim event)))))

(defcustom supernote-view-node-executable "node"
  "Node.js executable used to run `supernote-view-helper'.
Looked up with `executable-find' unless it is an absolute file name."
  :type 'string)

(defcustom supernote-view-cache-directory
  (expand-file-name "emacs-supernote"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name ".cache" (or (getenv "HOME") "~"))))
  "Directory holding rendered pages and title thumbnails.
Nothing is ever written beside the `.note' source, which is only opened for
reading.  The directory is deliberately outside the Syncthing tree."
  :type 'directory)

(defcustom supernote-view-image-format 'auto
  "Image format requested from the helper.
`auto' asks for SVG when this Emacs can display it and PNG otherwise.  The
explicit values exist so a build with a broken librsvg can be pinned to PNG."
  :type '(choice (const :tag "SVG when available, else PNG" auto)
                 (const :tag "Always SVG" svg)
                 (const :tag "Always PNG" png)))

(defcustom supernote-view-follow-theme t
  "Adapt vector pages' ink and paper to the default face colors.
Gray levels are mapped between the theme foreground and background.
Raster-only pages and PNG output retain their original colors because their
pen types cannot be separated reliably.  Run `supernote-view-refresh-theme'
after changing this option with `setq'."
  :type 'boolean)

(defcustom supernote-view-theme-highlighters nil
  "When non-nil, also adapt marker colors to the theme.
Colors in `supernote-view-highlighter-colors' take precedence.  Other markers
retain their source colors by default.  White cover-up strokes always follow
paper, so they continue to conceal the ink underneath.  Run
`supernote-view-refresh-theme' after changing this option with `setq'."
  :type 'boolean)

(defcustom supernote-view-highlighter-colors
  '((157 . "#ff5555") (158 . "#ff5555")
    (201 . "#ffd84a") (202 . "#ffd84a"))
  "Display colors for gray marker strokes, keyed by source gray level.
Supernote gray is 157 (marker variant 158), and light gray is 201 (202).
These become red and yellow respectively.  Other colors stay opaque.
This applies only to markers, never to ordinary pens of the same shade.
Set to nil to preserve all source marker colors."
  :type '(alist :key-type integer :value-type color))

(defcustom supernote-view-highlighter-opacity 0.4
  "Opacity of markers recolored by `supernote-view-highlighter-colors'.
Zero is transparent and one is opaque.  All other markers remain opaque.
Run `supernote-view-refresh-theme' after changing this option with `setq'."
  :type '(restricted-sexp :match-alternatives
                          ((lambda (value) (and (numberp value) (<= 0 value 1))))))

(defcustom supernote-view-default-display-size 'fit-page
  "How a page is sized when a note is first opened.
Either one of the fit symbols or a number, which is a scale factor against the
page's own pixel size."
  :type '(choice (const :tag "Fit the whole page" fit-page)
                 (const :tag "Fit the width" fit-width)
                 (const :tag "Fit the height" fit-height)
                 (number :tag "Scale factor")))

(defcustom supernote-view-resize-factor 1.25
  "Multiplier applied by `supernote-view-enlarge' and `supernote-view-shrink'."
  :type 'number)

(defcustom supernote-view-timeout 60
  "Seconds to wait for the helper before giving up on a request.
A cold render of the largest note in the reference corpus takes well under a
second; this only exists so a wedged process cannot leak."
  :type 'number)

(defcustom supernote-view-retry-delay 0.5
  "Seconds to wait before retrying a parse that failed while the source moved.
Syncthing can expose a `.note' midway through being replaced.  When the size or
mtime is still changing, the request is retried rather than reported."
  :type 'number)

(defcustom supernote-view-retry-limit 3
  "How many times to retry a parse that failed while the source was changing."
  :type 'integer)

(defcustom supernote-view-auto-sync t
  "Whether to notice a `.note' being replaced on disk and reload it.
The tree this is built for is Syncthing-managed, so a note can change while it
is open, at a moment nothing in Emacs is looking.  With this on, one watch is
placed on the directory holding the open note -- the directory rather than the
file, because Syncthing installs the new copy with a rename, which invalidates
a watch on the file itself.

A note whose buffer is not on screen is left alone; it reloads by itself the
next time it is looked at, which costs nothing extra."
  :type 'boolean)

(defcustom supernote-view-auto-sync-delay 1.0
  "Seconds to let disk activity settle before reloading a changed note.
Syncthing writes a temporary and renames it, and may touch several files in a
row; waiting coalesces that into one reload."
  :type 'number)

(defcustom supernote-view-prefetch-count 2
  "How many pages ahead to render before the reader asks for them.
The page *behind* is prepared as well, second in line: arriving somewhere by
the outline or by `G' leaves it unrendered, while reading straight through
already has it in hand, where it costs nothing to skip.  So the order at the
default of 2 is next, previous, then the page after next.

A page whose artifact is already in hand is shown the instant it is asked for,
with no helper round trip and no loading placeholder.  Zero turns this off; the
pages are rendered one at a time, after the visible page is on screen, so it
never competes with what the reader is looking at."
  :type 'integer)

(defcustom supernote-view-prefetch-outline-pages 16
  "How many of the note's title pages to render in the background.
Every page a title points at is somewhere the reader is likely to jump, so they
are prepared once the note is open -- after the pages either side of the
current one, one at a time, and only while nothing else needs rendering.  Zero
turns this off; the limit is what keeps a note with a great many titles from
queueing a great deal of background work."
  :type 'integer)

(defcustom supernote-view-outline-indent 2
  "Spaces of indentation per outline level in the title buffer."
  :type 'integer)

(defcustom supernote-view-outline-thumbnail-height 28
  "Height in pixels at which a handwritten title thumbnail is displayed."
  :type 'integer)

(defcustom supernote-view-max-stderr 4000
  "Characters of helper stderr kept for an error report."
  :type 'integer)

(defcustom supernote-view-max-response (* 4 1024 1024)
  "Largest helper response, in characters, that will be parsed.
Rendered pages travel as files, so a legitimate response is a few kilobytes;
this exists so untrusted metadata cannot make Emacs accumulate an unbounded
JSON document."
  :type 'integer)


;;;; Buffer-local state

(defvar-local supernote-view--source nil
  "Absolute path of the `.note' file this buffer shows.")

(defvar-local supernote-view--manifest nil
  "Parsed manifest alist for `supernote-view--source', or nil.")

(defvar-local supernote-view--page 0
  "Zero-based index of the page currently displayed.
The page number shown to the reader is always this plus one.")

(defvar-local supernote-view--generation 0
  "Token identifying the current request round.
Every navigation, zoom and revert bumps it; a helper callback whose token no
longer matches is discarded instead of displayed.")

(defvar-local supernote-view--jobs nil
  "Alist of (KIND . PROCESS) for the helper processes this buffer owns.
Starting a new job of a kind cancels the one it replaces.")

(defvar-local supernote-view--image nil
  "Image descriptor currently displayed, or nil.")

(defvar-local supernote-view--artifact nil
  "File holding the rendered artifact for `supernote-view--page'.")

(defvar-local supernote-view--theme-cache nil
  "Last SVG source and its themed form, keyed by file state and palette.
Only the current page is retained; resizing reuses its themed source.")

(defvar-local supernote-view--render-mode nil
  "How the current page was rendered: `vector-ink', `raster-fallback' or
`raster-requested'.")

(defvar-local supernote-view--display-size nil
  "Current sizing: `fit-width', `fit-height', `fit-page', or a scale number.")

(defvar-local supernote-view--status nil
  "Short string describing what the viewer is waiting for, or nil.")

(defvar-local supernote-view--error nil
  "Plist describing the failure currently displayed, or nil.")

(defvar-local supernote-view--outline-buffer nil
  "Outline buffer belonging to this note, while it lives.")

(defvar-local supernote-view--range-reload nil
  "Generation for which an out-of-range page already forced a manifest reload.
Without this a helper that answered `E_PAGE_RANGE' unconditionally would spin,
each reload starting another render that fails the same way.")

(defvar-local supernote-view--artifacts nil
  "Hash table of page index to the artifact already rendered for it.
Each value is a plist of `:artifact', `:format' and `:render-mode'.  Knowing
the path is what lets an already-rendered page be displayed without asking the
helper -- the helper would answer from its own cache in about 30 ms, but that
is still a process round trip, and long enough for the loading placeholder to
flash on screen.")

(defvar-local supernote-view--artifacts-stat nil
  "Source stat the entries in `supernote-view--artifacts' were rendered from.
Every entry is discarded at once when the file underneath changes.")

(defvar-local supernote-view--prefetch-queue nil
  "Page indices still to be rendered ahead of the reader, most useful first.")

(defvar-local supernote-view--prefetch-failed nil
  "Pages whose speculative render failed, so it is not attempted again.
Without this a page the helper cannot render would be re-queued on every page
turn for as long as the note stayed open.")

(defvar-local supernote-view--watch nil
  "File-notify descriptor watching this note's directory, or nil.")

(defvar-local supernote-view--watch-directory nil
  "Directory `supernote-view--watch' is placed on, so it can be reused.")

(defvar-local supernote-view--sync-timer nil
  "Timer coalescing a burst of disk activity into one reload.")

(defvar-local supernote-view--pending-scroll nil
  "Where the page currently being rendered should be positioned when it lands.
A plist accepting `:bottom' (show the page from its bottom edge) and
`:hscroll'.  Crossing a page boundary decides both before the new page exists,
so the intent is recorded here and consumed by `supernote-view--display'
instead of being written to a window that is still showing a placeholder.")

(defvar-local supernote-outline--note-buffer nil
  "Viewer buffer this outline describes.")

(defvar-local supernote-outline--note-window nil
  "Window last used to display `supernote-outline--note-buffer'.")

(defvar-local supernote-outline--entries nil
  "Vector of outline entry alists, in the order they appear in the buffer.")

(defvar-local supernote-outline--filled nil
  "The outline list this buffer was last built from.
`o' on an unchanged note reuses what is on screen, so point, folding and the
thumbnails already decoded survive.")

(defvar-local supernote-outline--generation 0
  "Bumped every time the outline is refilled.
A thumbnail request captures this; when it comes back against a buffer that has
since been rebuilt, its marker points at whatever now occupies that position, so
the answer is dropped rather than drawn onto the wrong title.")


;;;; Small helpers

(defun supernote-view--node ()
  "Absolute path of the Node executable, or nil when it cannot be found."
  (if (file-name-absolute-p supernote-view-node-executable)
      (and (file-executable-p supernote-view-node-executable)
           supernote-view-node-executable)
    (executable-find supernote-view-node-executable)))

(defun supernote-view-repair-command ()
  "Shell command that reinstalls the helper's pinned dependencies."
  (format "npm ci --prefix %s"
          (shell-quote-argument
           (directory-file-name
            (file-name-directory (directory-file-name
                                  (file-name-directory (file-truename supernote-view-helper))))))))

(defun supernote-view--field (object key)
  "Value of KEY in OBJECT, which is an alist or nil."
  (and (listp object) (alist-get key object)))

(defun supernote-view--truncate (string)
  "STRING, cut to `supernote-view-max-stderr' characters."
  (let ((string (or string "")))
    (if (> (length string) supernote-view-max-stderr)
        (concat (substring string 0 supernote-view-max-stderr) "\n[truncated]")
      string)))

(defun supernote-view--source-stat (&optional file)
  "Return (SIZE . MTIME-MS) for FILE, or nil when it cannot be stat'ed."
  (when-let* ((file (or file supernote-view--source))
              (attributes (file-attributes file)))
    (cons (file-attribute-size attributes)
          (floor (* 1000 (float-time (file-attribute-modification-time
                                      attributes)))))))

(defun supernote-view--page-count ()
  "Number of pages in the loaded manifest, or 0."
  (or (supernote-view--field supernote-view--manifest 'page_count) 0))

(defun supernote-view--page-size ()
  "Return (WIDTH . HEIGHT) in page pixels, or nil."
  (when-let ((size (supernote-view--field supernote-view--manifest 'page_size)))
    (cons (supernote-view--field size 'width)
          (supernote-view--field size 'height))))

(defun supernote-view--format ()
  "Image format to request from the helper for this Emacs."
  (pcase supernote-view-image-format
    ('svg "svg")
    ('png "png")
    (_ (if (image-type-available-p 'svg) "svg" "png"))))

(defun supernote-view--assert-mode ()
  "Signal unless the current buffer is a Supernote viewer."
  (unless (derived-mode-p 'supernote-view-mode)
    (user-error "Not a Supernote viewer buffer")))

(defun supernote-view--count (arg)
  "Turn a raw prefix ARG into a repeat count.
Evil's normal-state digits and Emacs' `C-u' both arrive here as the raw prefix,
so `3]]' passes 3 and a bare `]]' passes nil, which becomes 1."
  (if arg (prefix-numeric-value arg) 1))


;;;; The helper process

(defun supernote-view--abandon (process)
  "Kill PROCESS without running its callback, reclaiming what it owns.
Silencing the sentinel is what makes the result obsolete, but the sentinel is
also the only thing that kills the two hidden buffers the job allocated, so
they have to be reclaimed here instead."
  (when (processp process)
    (let ((stdout (process-buffer process))
          (stderr (process-get process 'supernote-stderr-buffer)))
      (set-process-sentinel process #'ignore)
      (when (process-live-p process) (delete-process process))
      (dolist (buffer (list stdout stderr))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun supernote-view--cancel (kind)
  "Cancel the pending helper job of KIND, if any."
  (when-let ((process (alist-get kind supernote-view--jobs)))
    (setf (alist-get kind supernote-view--jobs nil t) nil)
    (supernote-view--abandon process)))

(defun supernote-view--cancel-all ()
  "Cancel every helper job this buffer owns, and stop prefetching."
  (dolist (entry supernote-view--jobs)
    (supernote-view--abandon (cdr entry)))
  (setq supernote-view--jobs nil
        supernote-view--prefetch-queue nil))

(defun supernote-view--run (kind args callback)
  "Run the helper with ARGS, then call CALLBACK with a result plist.
KIND names the slot in `supernote-view--jobs'; starting a job cancels the one
it replaces, which is what makes rapid navigation cheap.  CALLBACK receives
\(:json ALIST :status INT :stderr STRING) and runs in the originating buffer
only if that buffer is still alive.  Arguments are passed as a real argv list,
never through a shell."
  (let ((node (supernote-view--node)))
    (cond
     ((null node)
      (funcall callback (list :status -1 :json nil
                              :stderr (format "cannot find the Node executable %S"
                                              supernote-view-node-executable))))
     ((not (file-readable-p supernote-view-helper))
      (funcall callback (list :status -1 :json nil
                              :stderr (format "cannot read the helper at %s"
                                              supernote-view-helper))))
     (t
      (supernote-view--cancel kind)
      (let* ((origin (current-buffer))
             (stdout (generate-new-buffer " *supernote-render*"))
             (stderr-buffer (generate-new-buffer " *supernote-render-stderr*"))
             ;; A dedicated pipe process keeps this job's diagnostics out of
             ;; every other job's, and lets the sentinel tear it down without
             ;; killing a buffer some other process still writes to.
             (stderr (make-pipe-process :name "supernote-render-stderr"
                                        :buffer stderr-buffer :noquery t))
             (timer nil)
             process)
        (setq process
              (make-process
               :name "supernote-render"
               :buffer stdout
               :noquery t
               :connection-type 'pipe
               :coding 'utf-8-unix
               :stderr stderr
               :command (append (list node supernote-view-helper) args)
               ;; Stop accumulating past the cap rather than letting a crafted
               ;; note's metadata grow the buffer without limit.
               :filter
               (lambda (proc chunk)
                 (when-let ((buffer (process-buffer proc)))
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (when (< (buffer-size) supernote-view-max-response)
                         (goto-char (point-max))
                         (insert chunk))))))
               :sentinel
               (lambda (proc _event)
                 (unless (process-live-p proc)
                   (when timer (cancel-timer timer))
                   (let* ((status (process-exit-status proc))
                          (size (with-current-buffer stdout (buffer-size)))
                          (overflow (>= size supernote-view-max-response))
                          (out (if overflow "" (with-current-buffer stdout (buffer-string))))
                          (err (if overflow
                                   (format "the renderer produced more than %d bytes of JSON"
                                           supernote-view-max-response)
                                 (with-current-buffer stderr-buffer (buffer-string)))))
                     (ignore-errors (delete-process stderr))
                     (ignore-errors (kill-buffer stdout))
                     (ignore-errors (kill-buffer stderr-buffer))
                     (when (buffer-live-p origin)
                       (with-current-buffer origin
                         (setf (alist-get kind supernote-view--jobs nil t) nil)
                         (funcall callback
                                  (list :status status
                                        :json (supernote-view--parse out)
                                        :stderr (supernote-view--truncate err))))))))))
        (process-put process 'supernote-stderr-buffer stderr-buffer)
        (setf (alist-get kind supernote-view--jobs) process)
        (setq timer
              (run-at-time supernote-view-timeout nil
                           (lambda ()
                             (when (process-live-p process)
                               (delete-process process)))))
        process)))))

(defun supernote-view--parse (text)
  "Parse TEXT as the helper's single JSON object, or return nil.
Metadata from a `.note' file is untrusted, so it is decoded as data and never
evaluated."
  (condition-case nil
      (json-parse-string (string-trim text)
                         :object-type 'alist
                         :array-type 'list
                         :null-object nil
                         :false-object nil)
    (error nil)))

(defun supernote-view--result-error (result)
  "Return a human-readable failure description for RESULT, or nil on success."
  (let* ((status (plist-get result :status))
         (json (plist-get result :json))
         (error-object (supernote-view--field json 'error)))
    (cond
     ;; Success needs all three: a clean exit, no error object, and JSON that
     ;; actually parsed.  A helper that exits 0 having written nothing usable
     ;; -- killed mid-write, or refused for exceeding the response cap -- must
     ;; not be mistaken for an empty but valid answer.
     ((and (eql status 0) (null error-object) json) nil)
     (error-object
      (list :code (supernote-view--field error-object 'code)
            :message (supernote-view--field error-object 'message)
            :status status
            :stderr (plist-get result :stderr)))
     (t
      (list :code (cond ((eql status -1) "E_HELPER")
                        ((eql status 0) "E_RESPONSE")
                        (t (format "exit-%s" status)))
            :message (or (car (split-string (or (plist-get result :stderr) "") "\n" t))
                         "the renderer produced no usable output")
            :status status
            :stderr (plist-get result :stderr))))))


;;;; Manifest

(defun supernote-view--load-manifest (&optional attempt then)
  "Load the manifest for this buffer's source, then call THEN.
ATTEMPT counts retries.  Syncthing can expose a `.note' while it is being
replaced, so a parse failure whose source stat is still moving is retried
rather than reported as a corrupt document."
  (supernote-view--assert-mode)
  (let ((attempt (or attempt 0))
        (before (supernote-view--source-stat))
        (generation supernote-view--generation))
    ;; Claim the file's current modification time before touching the buffer.
    ;; A reload is triggered precisely when the file has changed underneath,
    ;; and rewriting a buffer whose visited file has changed is what Emacs
    ;; interrupts with "really edit the buffer?" -- a question that makes no
    ;; sense for a viewer that cannot write, and which would otherwise fire on
    ;; the placeholder redisplay a few lines below.  There is nothing to lose
    ;; by claiming it here: the reload is about to read that very revision, and
    ;; a change arriving mid-read is caught by the stat guards instead.
    (when (and buffer-file-name (file-readable-p buffer-file-name))
      (set-visited-file-modtime))
    (setq supernote-view--status "reading manifest")
    (supernote-view--redisplay)
    (supernote-view--run
     'manifest
     (list "manifest" "--input" supernote-view--source
           ;; The format is passed so the manifest can say which pages are
           ;; already rendered *in that format*.
           "--format" (supernote-view--format)
           "--cache-dir" (expand-file-name supernote-view-cache-directory))
     (lambda (result)
       (when (= generation supernote-view--generation)
         (let ((failure (supernote-view--result-error result)))
           (cond
            ((null failure)
             (setq supernote-view--manifest (plist-get result :json)
                   supernote-view--error nil
                   supernote-view--status nil)
             ;; The manifest describes the file as it is on disk right now, so
             ;; record its modification time.  Two things go wrong without
             ;; this.  The buffer visits the file but never reads it, so its
             ;; recorded time stays at zero: `auto-revert' then sees a buffer
             ;; that can never be stale and never syncs it.  And once the file
             ;; does change, the viewer's own redisplay counts as editing a
             ;; superseded buffer, which interrupts with "really edit the
             ;; buffer?" -- a prompt that makes no sense for a viewer that
             ;; cannot write.
             (set-visited-file-modtime)
             (supernote-view--forget-artifacts)
             (supernote-view--adopt-manifest-artifacts)
             (supernote-view--watch-source)
             (setq supernote-view--page
                   (max 0 (min supernote-view--page
                               (1- (max 1 (supernote-view--page-count))))))
             (supernote-view--refresh-outline)
             (if then (funcall then) (supernote-view--render-page)))
            ;; A source that is still moving is a race, not a broken file.
            ((and (< attempt supernote-view-retry-limit)
                  (member (plist-get failure :code)
                          '("E_PARSE" "E_SIGNATURE" "E_INPUT_MISSING"
                            "E_INPUT_UNREADABLE"))
                  (not (equal before (supernote-view--source-stat))))
             (setq supernote-view--status
                   (format "source is changing, retry %d/%d"
                           (1+ attempt) supernote-view-retry-limit))
             (supernote-view--redisplay)
             (let ((buffer (current-buffer)))
               (run-at-time supernote-view-retry-delay nil
                            (lambda ()
                              (when (buffer-live-p buffer)
                                (with-current-buffer buffer
                                  (when (= generation supernote-view--generation)
                                    (supernote-view--load-manifest
                                     (1+ attempt) then))))))))
            (t (supernote-view--fail failure)))))))))


;;;; Rendering

(defun supernote-view--forget-artifacts ()
  "Drop every remembered artifact, and any prefetching still queued.
Called whenever the manifest is (re)loaded: the entries describe one revision
of one file, and nothing may outlive it."
  (setq supernote-view--artifacts (make-hash-table :test #'eql)
        supernote-view--artifacts-stat (supernote-view--source-stat)
        supernote-view--prefetch-queue nil
        supernote-view--prefetch-failed nil))

(defun supernote-view--adopt-manifest-artifacts ()
  "Take into the index every page the helper says it has already rendered.
Page artifacts are keyed by the page's own content, so a note that gained a
stroke on one page keeps every other page's render.  Adopting them here is what
makes those pages appear with no helper round trip at all -- including the page
on screen when a sync happens, which is why a reload does not flash a loading
placeholder."
  (let ((format (supernote-view--format)))
    (dolist (page (supernote-view--field supernote-view--manifest 'pages))
      (let ((index (supernote-view--field page 'page_index))
            (artifact (supernote-view--field page 'artifact)))
        (when (and (integerp index) (stringp artifact) (file-readable-p artifact))
          ;; The manifest carries how each cached page was actually rendered,
          ;; read back from the render's own sidecar, so the mode line reports
          ;; `V' or `R' truthfully for a page this session never rendered.
          (supernote-view--remember-artifact
           index format
           (list (cons 'artifact artifact)
                 (cons 'render_mode (supernote-view--field page 'render_mode)))))))))

(defun supernote-view--remember-artifact (page format json)
  "Record the artifact the helper produced for PAGE in FORMAT, from JSON."
  (when-let ((artifact (supernote-view--field json 'artifact)))
    (unless (hash-table-p supernote-view--artifacts)
      (setq supernote-view--artifacts (make-hash-table :test #'eql)))
    (puthash page
             (list :artifact artifact
                   :format format
                   :render-mode
                   (intern (or (supernote-view--field json 'render_mode) "unknown")))
             supernote-view--artifacts)))

(defun supernote-view--cached-artifact (page)
  "The entry for PAGE that can be shown without asking the helper, or nil.
Refuses an entry rendered in another format, one belonging to an older
revision of the source, or one whose file has since been reclaimed."
  (when-let* (((hash-table-p supernote-view--artifacts))
              (entry (gethash page supernote-view--artifacts)))
    (and (equal (plist-get entry :format) (supernote-view--format))
         (equal supernote-view--artifacts-stat (supernote-view--source-stat))
         (file-readable-p (plist-get entry :artifact))
         entry)))

(defun supernote-view--prefetch-plan ()
  "Pages worth rendering before they are asked for, most useful first.
Nearby pages come first, in the order described by
`supernote-view-prefetch-count'; the pages the note's titles point at follow,
in document order, because a reader who opens the outline is about to jump to
one of them.  Anything already in hand, or already known to fail, is dropped."
  (let* ((count (supernote-view--page-count))
         (here supernote-view--page)
         (usable
          (lambda (page)
            (and (integerp page)
                 (>= page 0) (< page count)
                 ;; The page on screen is already rendered by definition.
                 (/= page here)
                 (not (memq page supernote-view--prefetch-failed))
                 (null (supernote-view--cached-artifact page)))))
         (near nil)
         (outline nil))
    (when (> supernote-view-prefetch-count 0)
      (push (1+ here) near)
      (push (1- here) near)
      (cl-loop for step from 2 to supernote-view-prefetch-count
               do (push (+ here step) near))
      (setq near (seq-filter usable (delete-dups (nreverse near)))))
    (when (> supernote-view-prefetch-outline-pages 0)
      (dolist (entry (supernote-view--field supernote-view--manifest 'outlines))
        (push (supernote-view--field entry 'page_index) outline))
      ;; The limit counts pages actually queued, so titles sitting on pages
      ;; already in hand do not use it up.
      (setq outline
            (seq-take (seq-remove (lambda (page) (memq page near))
                                  (seq-filter usable (delete-dups (nreverse outline))))
                      supernote-view-prefetch-outline-pages)))
    (append near outline)))

(defun supernote-view--prefetch-schedule ()
  "Rebuild the prefetch queue for where the reader is now, and keep it moving.
A render already in flight is left to finish rather than having its work thrown
away; it pumps the requeued list itself when it lands."
  (setq supernote-view--prefetch-queue
        (if supernote-view--error nil (supernote-view--prefetch-plan)))
  (unless (alist-get 'prefetch supernote-view--jobs)
    (supernote-view--prefetch-next)))

(defun supernote-view--prefetch-next ()
  "Render the next queued page in the background, then the one after it.
One at a time: preparing pages is a courtesy, not a reason to put several
renderers on the machine at once."
  (when-let ((page (pop supernote-view--prefetch-queue)))
    (let ((generation supernote-view--generation)
          (stat (supernote-view--source-stat))
          (format (supernote-view--format)))
      (supernote-view--run
       'prefetch
       (list "render"
             "--input" supernote-view--source
             "--page" (number-to-string page)
             "--format" format
             "--cache-dir" (expand-file-name supernote-view-cache-directory))
       (lambda (result)
         ;; Purely speculative: this only ever fills the index.  It must not
         ;; touch the page on screen, and a failure is not the reader's
         ;; problem -- they will simply wait for that page the normal way.
         (when (and (= generation supernote-view--generation)
                    (equal stat (supernote-view--source-stat)))
           (if (supernote-view--result-error result)
               (push page supernote-view--prefetch-failed)
             (supernote-view--remember-artifact page format (plist-get result :json)))
           (supernote-view--prefetch-next)))))))

(defun supernote-view--stale-p ()
  "Non-nil when the source has changed since the manifest was built.
The check is a single `stat', cheap enough to make on every page turn, and it
is what keeps the viewer from rendering a page out of the new file while the
page count, page size and outline still describe the old one."
  ;; A nil baseline is compared like any other value rather than being treated
  ;; as "cannot tell": a note that was missing when the manifest was built and
  ;; is present now has changed, which is exactly when a reload is wanted.
  (and supernote-view--manifest
       (not (equal supernote-view--artifacts-stat (supernote-view--source-stat)))))

(defun supernote-view--ensure-fresh ()
  "Reload the note if it changed on disk, and say whether that was started.
Callers that are about to make a decision from the manifest -- how many pages
there are, where the titles sit -- must consult this first.  The boundary tests
in the page commands are exactly such decisions, and they answer before any
rendering happens, so a check buried in the render path would never see them."
  (when (supernote-view--stale-p)
    (message "Supernote: %s changed on disk -- reloading"
             (file-name-nondirectory (or supernote-view--source "note")))
    (setq supernote-view--generation (1+ supernote-view--generation))
    (supernote-view--load-manifest)
    t))

(defun supernote-view--render-page ()
  "Display the current page, rendering it first if it is not already in hand."
  (supernote-view--assert-mode)
  (if (supernote-view--stale-p)
      ;; Reload first: rendering now would put the new file's pixels under the
      ;; old file's page count and outline, and leave any pages it gained
      ;; unreachable.  The manifest load renders the page itself afterwards.
      (progn
        (setq supernote-view--generation (1+ supernote-view--generation))
        (supernote-view--load-manifest))
    (let ((entry (supernote-view--cached-artifact supernote-view--page)))
      (if (and entry (supernote-view--display-cached entry))
          (supernote-view--prefetch-schedule)
        (supernote-view--render-page-1)))))

(defun supernote-view--display-cached (entry)
  "Show ENTRY's already-rendered artifact.  Returns nil if it could not be."
  (setq supernote-view--artifact (plist-get entry :artifact)
        supernote-view--render-mode (plist-get entry :render-mode)
        supernote-view--status nil
        supernote-view--error nil)
  (supernote-view--display)
  ;; The artifact could still have gone away between the check and the read,
  ;; in which case the caller falls back to rendering it again.
  (and supernote-view--image t))

(defun supernote-view--render-page-1 ()
  "Ask the helper for the current page, showing a placeholder meanwhile."
  (let ((generation supernote-view--generation)
        (page supernote-view--page)
        (stat (supernote-view--source-stat))
        (format (supernote-view--format)))
    ;; The page the reader is waiting for outranks anything speculative.
    (supernote-view--cancel 'prefetch)
    (setq supernote-view--prefetch-queue nil)
    (setq supernote-view--status (format "rendering page %d" (1+ page)))
    (supernote-view--redisplay)
    (supernote-view--run
     'page
     (list "render"
           "--input" supernote-view--source
           "--page" (number-to-string page)
           "--format" format
           "--cache-dir" (expand-file-name supernote-view-cache-directory))
     (lambda (result)
       ;; Three independent guards, because any of them can change while a
       ;; render is in flight: the reader may have turned the page, reverted
       ;; the buffer, or Syncthing may have replaced the file under us.
       (when (and (= generation supernote-view--generation)
                  (= page supernote-view--page))
         (if (not (equal stat (supernote-view--source-stat)))
             ;; The source moved between the request and the answer, so this
             ;; image and the loaded manifest describe different revisions.
             ;; Never show it as though it were the current file: reload.
             (progn
               (setq supernote-view--generation (1+ supernote-view--generation))
               (supernote-view--load-manifest))
           (let ((failure (supernote-view--result-error result)))
             (if failure
                 (if (and (equal (plist-get failure :code) "E_PAGE_RANGE")
                          (not (eql supernote-view--range-reload generation)))
                     ;; The note shrank under us; reload and clamp, but only
                     ;; once, so a helper that always says this cannot spin.
                     (progn (setq supernote-view--range-reload generation)
                            (supernote-view--load-manifest))
                   (supernote-view--fail failure))
               (let ((json (plist-get result :json)))
                 (setq supernote-view--artifact (supernote-view--field json 'artifact)
                       supernote-view--render-mode
                       (intern (or (supernote-view--field json 'render_mode) "unknown"))
                       supernote-view--status nil
                       supernote-view--error nil)
                 (supernote-view--remember-artifact page format json)
                 (supernote-view--display)
                 (supernote-view--prefetch-schedule))))))))))

(defun supernote-view--intrinsic-size ()
  "Return (WIDTH . HEIGHT) of the page in its own pixels."
  (or (supernote-view--page-size) (cons 1920 2560)))

(defun supernote-view--target-width (&optional window)
  "Pixel width at which the current page should be displayed in WINDOW."
  (let* ((window (or window (get-buffer-window (current-buffer)) (selected-window)))
         (size (supernote-view--intrinsic-size))
         (page-width (float (max 1 (car size))))
         (page-height (float (max 1 (cdr size))))
         (available-width (float (max 1 (window-body-width window t))))
         ;; One pixel of slack keeps a fitted page from wrapping onto a second
         ;; screen line, which would hide its top edge.
         (available-height (float (max 1 (1- (window-body-height window t)))))
         (width-scale (/ available-width page-width))
         (height-scale (/ available-height page-height))
         (scale (pcase supernote-view--display-size
                  ((and size (pred numberp)) (float size))
                  ('fit-height height-scale)
                  ('fit-page (min width-scale height-scale))
                  (_ width-scale))))
    (max 1 (floor (* page-width scale)))))

(defun supernote-view--window ()
  "A live window showing this buffer, preferring the selected one.
The image scroll helpers all act on the selected window, so a caller that is
not in that window -- the outline previewing a page with SPC, or an
asynchronous render callback -- has to borrow one rather than scroll whatever
happens to be selected."
  (if (eq (current-buffer) (window-buffer (selected-window)))
      (selected-window)
    (get-buffer-window (current-buffer))))

(defun supernote-view--showing-p ()
  "Non-nil when the selected window is showing this buffer."
  (eq (current-buffer) (window-buffer (selected-window))))

(defun supernote-view--apply-scroll (vscroll hscroll bottom)
  "Position the displayed page at VSCROLL/HSCROLL, or at its BOTTOM edge.
A nil axis is left where it is, so `W' can reset the column without also
throwing the reader back to the top of the page."
  (when-let ((window (supernote-view--window)))
    (with-selected-window window
      ;; `image-eob' measures the image, which needs a window-system frame; on
      ;; a terminal frame it signals rather than returning.  Failing to
      ;; position a page is not a reason to fail the page turn.
      (ignore-errors
        (cond (bottom (image-eob) (image-bol 1))
              (vscroll (image-set-window-vscroll vscroll)))
        ;; Last: `image-bol' zeroes the horizontal position on its way past.
        (when hscroll (image-set-window-hscroll hscroll))))))

(defun supernote-view--theme-colors ()
  "Return (FOREGROUND BACKGROUND) for this buffer's visible frame."
  (let ((frame (if-let* ((window (supernote-view--window)))
                   (window-frame window)
                 (selected-frame))))
    (mapcar (lambda (attribute)
              (let ((value (face-attribute 'default attribute frame t)))
                (if (and (stringp value) (color-values value frame))
                    value
                  (if (eq attribute :foreground) "black" "white"))))
            '(:foreground :background))))

(defun supernote-view--color-components (color)
  "Convert COLOR to three floating point components between zero and one."
  ;; Parse hex directly: color-values quantizes colors on terminal frames,
  ;; which would also spoil exported/tested SVGs generated in batch Emacs.
  (if (string-match "\\`#\\([[:xdigit:]]+\\)\\'" color)
      (let* ((hex (match-string 1 color))
             (digits (/ (length hex) 3)))
        (unless (and (memq digits '(1 2 3 4)) (= (* digits 3) (length hex)))
          (error "Invalid SVG theme color: %s" color))
        (cl-loop for i below 3
                 collect (/ (string-to-number (substring hex (* i digits) (* (1+ i) digits)) 16)
                            (float (1- (expt 16 digits))))))
    (mapcar (lambda (component) (/ component 65535.0)) (color-values color))))

(defun supernote-view--theme-svg (source foreground background)
  "Apply FOREGROUND and BACKGROUND to semantic SVG SOURCE.
Only the renderer's marked definitions are replaced.  Geometry, original
artifacts, recognition text and embedded PNG bytes remain unchanged."
  (if (not (string-match "<!--sn-theme-start-->\\(\\(?:.\\|\n\\)*?\\)<!--sn-theme-end-->" source))
      source
    (let* ((start (match-beginning 0))
           (end (match-end 0))
           (definitions (match-string 1 source))
           (fg (supernote-view--color-components foreground))
           (bg (supernote-view--color-components background))
           (position 0)
           rules)
      (while (string-match
              "\\.sn-\\(pen\\|marker\\)-\\([0-9]+\\)-\\([0-9]+\\)-\\([0-9]+\\){color:[^}]+}"
              definitions position)
        (let* ((name (substring (match-string 0 definitions) 0
                                (string-search "{" (match-string 0 definitions))))
               (marker (equal (match-string 1 definitions) "marker"))
               (rgb (mapcar (lambda (group)
                              (string-to-number (match-string group definitions)))
                            '(2 3 4)))
               (original (match-string 0 definitions))
               (highlight (and marker (apply #'= rgb)
                               (alist-get (car rgb) supernote-view-highlighter-colors))))
          (setq position (match-end 0))
          (push
           (cond
            (highlight
             (format "%s{color:%s;opacity:%s}" name
                     (apply #'format "#%02x%02x%02x"
                            (mapcar (lambda (component) (round (* 255 component)))
                                    (supernote-view--color-components highlight)))
                     (max 0 (min 1 supernote-view-highlighter-opacity))))
            ((and marker (not supernote-view-theme-highlighters))
             (concat (substring original 0 -1) ";opacity:1}"))
            (t
             (format "%s{color:%s;opacity:1}" name
                     (if (equal rgb '(0 0 0))
                         "inherit"
                       (apply #'format "#%02x%02x%02x"
                              (cl-mapcar
                               (lambda (shade ink paper)
                                 (round (* 255 (+ ink (* (/ shade 255.0) (- paper ink))))))
                               rgb fg bg))))))
           rules)))
      (concat
       (substring source 0 start)
       "<!--sn-theme-start--><defs><style>" (apply #'concat (nreverse rules))
       "</style><filter id=\"sn-template\" color-interpolation-filters=\"sRGB\" x=\"0\" y=\"0\" width=\"100%\" height=\"100%\"><feComponentTransfer>"
       (apply #'concat
              (cl-mapcar
               (lambda (channel ink paper)
                 (format "<feFunc%s type=\"linear\" slope=\"%.8f\" intercept=\"%.8f\"/>"
                         channel (- paper ink) ink))
               '("R" "G" "B") fg bg))
       "</feComponentTransfer></filter></defs><!--sn-theme-end-->"
       (substring source end)))))

(defun supernote-view--themed-source (foreground background)
  "Read the current SVG and cache its FOREGROUND/BACKGROUND presentation."
  (let* ((attributes (file-attributes supernote-view--artifact))
         (file-key (list supernote-view--artifact
                         (file-attribute-modification-time attributes)
                         (file-attribute-size attributes)))
         (theme-key (list foreground background supernote-view-theme-highlighters
                          (copy-tree supernote-view-highlighter-colors)
                          supernote-view-highlighter-opacity)))
    (unless (equal file-key (plist-get supernote-view--theme-cache :file))
      (setq supernote-view--theme-cache
            (list :file file-key
                  :source (with-temp-buffer
                            (insert-file-contents (car file-key))
                            (buffer-string)))))
    (unless (equal theme-key (plist-get supernote-view--theme-cache :theme))
      (setq supernote-view--theme-cache
            (plist-put supernote-view--theme-cache :rendered
                       (supernote-view--theme-svg
                        (plist-get supernote-view--theme-cache :source)
                        foreground background)))
      (setq supernote-view--theme-cache
            (plist-put supernote-view--theme-cache :theme theme-key)))
    (plist-get supernote-view--theme-cache :rendered)))

(defun supernote-view-refresh-theme (&rest _)
  "Redisplay open Supernote pages using the current theme, without rendering.
Preserve each visible window's scroll position and the current page."
  (interactive)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'supernote-view-mode) supernote-view--artifact)
        (let ((windows (mapcar (lambda (window)
                                (list window (window-vscroll window t)
                                      (window-hscroll window)))
                              (get-buffer-window-list buffer nil t))))
          (supernote-view--display)
          (dolist (state windows)
            (set-window-vscroll (nth 0 state) (nth 1 state) t)
            (set-window-hscroll (nth 0 state) (nth 2 state))))))))

;; These hooks cover load-theme as well as enable/disable-theme in Emacs 32.
;; The guarded advice also supports older Emacs builds with SVG but no hooks.
(if (boundp 'enable-theme-functions)
    (progn
      (add-hook 'enable-theme-functions #'supernote-view-refresh-theme)
      (add-hook 'disable-theme-functions #'supernote-view-refresh-theme))
  (advice-add 'enable-theme :after #'supernote-view-refresh-theme)
  (advice-add 'disable-theme :after #'supernote-view-refresh-theme))

(defun supernote-view--display (&optional vscroll hscroll)
  "Put the rendered artifact on screen at the current display size.
VSCROLL and HSCROLL, when given, are restored afterwards instead of resetting
to the page's top-left corner."
  (when (and supernote-view--artifact (file-readable-p supernote-view--artifact))
    ;; Rebuilding from the cached artifact is what makes zoom cheap: the file
    ;; is vector, so Emacs rasterizes it at the new size and the helper is
    ;; never asked for new pixels.
    (let* ((type (if (string-suffix-p ".png" supernote-view--artifact) 'png 'svg))
           (themed (and supernote-view-follow-theme (eq type 'svg)))
           (colors (if themed (supernote-view--theme-colors) '("black" "white")))
           (source (if themed (apply #'supernote-view--themed-source colors)
                     supernote-view--artifact))
           (image (create-image source type themed
                                :width (supernote-view--target-width)
                                :foreground (car colors)
                                :background (cadr colors))))
      (setq supernote-view--image image)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-image image " ")
        (goto-char (point-min)))
      (set-buffer-modified-p nil)
      (let ((pending supernote-view--pending-scroll))
        (setq supernote-view--pending-scroll nil)
        ;; A page arriving with nothing else asked of it starts at its
        ;; top-left corner, so both axes are given explicitly here.
        (supernote-view--apply-scroll
         (or vscroll 0)
         (or hscroll (plist-get pending :hscroll) 0)
         (plist-get pending :bottom)))
      (force-mode-line-update))))

(defun supernote-view--resize ()
  "Redisplay the page Emacs already has at the current display size."
  (when supernote-view--artifact
    (supernote-view--display (window-vscroll nil t) (window-hscroll))))

(defun supernote-view--redisplay ()
  "Show the placeholder for the current status or error."
  (when (and (derived-mode-p 'supernote-view-mode)
             (or supernote-view--status supernote-view--error)
             (null supernote-view--image))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (or (supernote-view--error-text) (supernote-view--status-text)))
      (goto-char (point-min)))
    (set-buffer-modified-p nil))
  (force-mode-line-update))

(defun supernote-view--status-text ()
  "Placeholder text for a request in flight."
  (format "\n  %s\n\n  %s\n"
          (or supernote-view--status "loading")
          (abbreviate-file-name (or supernote-view--source ""))))


;;;; Errors

(defun supernote-view--fail (failure)
  "Record FAILURE and show it in the buffer instead of only in the echo area."
  (setq supernote-view--error failure
        supernote-view--status nil
        supernote-view--image nil
        supernote-view--artifact nil
        supernote-view--pending-scroll nil)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (supernote-view--error-text))
    (goto-char (point-min)))
  (set-buffer-modified-p nil)
  (force-mode-line-update))

(defun supernote-view--error-text ()
  "Actionable description of `supernote-view--error', or nil."
  (when-let ((failure supernote-view--error))
    (let ((code (or (plist-get failure :code) "error")))
      (concat
       (format "\n  Supernote: cannot show %s\n\n"
               (abbreviate-file-name (or supernote-view--source "this file")))
       (format "  %s: %s\n\n" code (or (plist-get failure :message) ""))
       (cond
        ((member code '("E_HELPER" "E_DEPENDENCIES"))
         (format (concat "  The renderer is not usable.\n"
                         "    helper:  %s\n"
                         "    node:    %s\n"
                         "    repair:  %s\n\n")
                 supernote-view-helper
                 (or (supernote-view--node)
                     (format "not found (%s)" supernote-view-node-executable))
                 (supernote-view-repair-command)))
        ((equal code "E_SIGNATURE")
         (concat "  This file's signature is not one the pinned renderer knows.\n"
                 "  Updating the pinned `supernote-typescript' version is the fix;\n"
                 "  the note itself has not been touched.\n\n"))
        ((member code '("E_INPUT_MISSING" "E_INPUT_UNREADABLE"))
         "  The source has gone away.  Press `r' to look again.\n\n")
        (t ""))
       "  Press `r' to retry.\n"
       (let ((stderr (plist-get failure :stderr)))
         (if (and stderr (not (string-empty-p (string-trim stderr))))
             (format "\n  renderer output:\n%s\n"
                     (mapconcat (lambda (line) (concat "    " line))
                                (split-string (string-trim stderr) "\n")
                                "\n"))
           ""))))))


;;;; Mode line

(defun supernote-view--mode-line ()
  "Compact page counter and render state for the mode line."
  (let ((count (supernote-view--page-count)))
    (concat
     (if (> count 0)
         (format " %d/%d" (1+ supernote-view--page) count)
       " -/-")
     (pcase supernote-view--render-mode
       ('vector-ink " V")
       ('raster-fallback " R")
       ('raster-requested " R")
       (_ ""))
     (cond (supernote-view--error " !")
           (supernote-view--status " ...")
           (t "")))))


;;;; Navigation

(defun supernote-view--goto (page &optional pending)
  "Display PAGE, a one-based page number, positioned per PENDING.
PENDING is the plist `supernote-view--pending-scroll' takes, and is installed
before the render starts: a page that is already in hand is displayed
synchronously from here, so an intent set afterwards would arrive too late."
  (supernote-view--assert-mode)
  (when (supernote-view--ensure-fresh)
    ;; The reload clamps and renders by itself; this request is answered by it.
    (setq page nil))
  (when page
    (supernote-view--goto-1 page pending)))

(defun supernote-view--goto-1 (page pending)
  "Move to PAGE with PENDING scroll, against a manifest already known fresh."
  (let* ((count (supernote-view--page-count))
         (wanted (max 1 (min page (max 1 count))))
         (index (1- wanted)))
    (when (and (/= page wanted) (> count 0))
      (message "Supernote: page %d is outside 1-%d" page count))
    (if (and (= index supernote-view--page) supernote-view--image)
        ;; Already here: a direct page command still resets to the page edge.
        (progn (setq supernote-view--pending-scroll pending)
               (supernote-view--display))
      (setq supernote-view--page index
            supernote-view--generation (1+ supernote-view--generation)
            ;; The artifact goes with the image: leaving it behind would let a
            ;; zoom arriving before the render redraw the *previous* page.
            supernote-view--image nil
            supernote-view--artifact nil
            supernote-view--pending-scroll pending)
      (supernote-view--render-page))))

(defun supernote-view-goto-page (page)
  "Display PAGE, a one-based page number.
Out-of-range requests are clamped and reported rather than signalled, so a
count that runs off the end of the note is not an error."
  (interactive
   (list (if current-prefix-arg
             (prefix-numeric-value current-prefix-arg)
           (read-number "Page: " (1+ supernote-view--page)))))
  (supernote-view--goto page))

(defun supernote-view-next-page (&optional count)
  "Show the page COUNT after this one, or report the last page."
  (interactive "P")
  (supernote-view--assert-mode)
  ;; "Last page" is a claim about the manifest, so make sure it still holds:
  ;; a note that gained pages while this one was buried would otherwise report
  ;; a boundary that no longer exists.
  (unless (supernote-view--ensure-fresh)
    (if (>= supernote-view--page (1- (supernote-view--page-count)))
        (message "Supernote: last page")
      (supernote-view-goto-page (+ 1 supernote-view--page
                                   (supernote-view--count count))))))

(defun supernote-view-previous-page (&optional count)
  "Show the page COUNT before this one, or report the first page."
  (interactive "P")
  (supernote-view--assert-mode)
  (unless (supernote-view--ensure-fresh)
    (if (zerop supernote-view--page)
        (message "Supernote: first page")
      (supernote-view-goto-page (- (1+ supernote-view--page)
                                   (supernote-view--count count))))))

(defun supernote-view-first-page (&optional count)
  "Show the first page, or page COUNT when one is given."
  (interactive "P")
  (supernote-view-goto-page (if count (prefix-numeric-value count) 1)))

(defun supernote-view-last-page (&optional count)
  "Show the last page, or page COUNT when one is given."
  (interactive "P")
  (supernote-view-goto-page (if count
                                (prefix-numeric-value count)
                              (max 1 (supernote-view--page-count)))))


;;;; Scrolling, crossing page boundaries

(defun supernote-view--cross-forward (hscroll)
  "Move to the top of the next page, keeping HSCROLL.
Returns nil, without a message, at the last page: running off the end of a
scroll is not the same event as pressing `]]' there."
  (when (< supernote-view--page (1- (supernote-view--page-count)))
    ;; The column travels with the request rather than being written to the
    ;; window: the new page may not exist yet, or may appear instantly.
    (supernote-view--goto (+ 2 supernote-view--page) (list :hscroll hscroll))
    t))

(defun supernote-view--cross-backward (hscroll)
  "Move to the bottom of the previous page, keeping HSCROLL."
  (when (> supernote-view--page 0)
    ;; `supernote-view--page' is zero-based, so using it as a one-based page
    ;; number names the page before this one.
    (supernote-view--goto supernote-view--page (list :bottom t :hscroll hscroll))
    t))

(defun supernote-view--scroll-or-cross (scroll cross)
  "Call SCROLL; when it could not move the page, call CROSS with the hscroll.
Whether the page moved is decided by comparing the window's vscroll before and
after, rather than by trusting what SCROLL returned, because the image scroll
commands differ in what they hand back."
  (supernote-view--assert-mode)
  (when (supernote-view--showing-p)
    (let ((hscroll (window-hscroll))
          (before (window-vscroll nil t)))
      ;; With no image on screen the scroll cannot move, which would read as
      ;; "at the page edge" and turn the page on a placeholder.
      (when supernote-view--image
        (ignore-errors (funcall scroll))
        (when (= before (window-vscroll nil t))
          (funcall cross hscroll))))))

(defun supernote-view-next-line-or-next-page (&optional count)
  "Scroll down COUNT lines, crossing into the next page at the bottom edge."
  (interactive "P")
  (let ((lines (supernote-view--count count)))
    (supernote-view--scroll-or-cross
     (lambda () (image-next-line lines)) #'supernote-view--cross-forward)))

(defun supernote-view-previous-line-or-previous-page (&optional count)
  "Scroll up COUNT lines, crossing into the previous page at the top edge."
  (interactive "P")
  (let ((lines (supernote-view--count count)))
    (supernote-view--scroll-or-cross
     (lambda () (image-previous-line lines)) #'supernote-view--cross-backward)))

(defun supernote-view-scroll-up-or-next-page (&optional count)
  "Scroll forward a window, crossing into the next page at the bottom edge.
COUNT scrolls that many lines instead."
  (interactive "P")
  (supernote-view--assert-mode)
  ;; A page sized to fit can never scroll, so the vscroll test would wedge;
  ;; there, one keystroke is one page.
  (if (and (null count) supernote-view--image
           (memq supernote-view--display-size '(fit-page fit-height)))
      (supernote-view--cross-forward (window-hscroll))
    (supernote-view--scroll-or-cross
     (lambda () (image-scroll-up count)) #'supernote-view--cross-forward)))

(defun supernote-view-scroll-down-or-previous-page (&optional count)
  "Scroll back a window, crossing into the previous page at the top edge.
COUNT scrolls that many lines instead."
  (interactive "P")
  (supernote-view--assert-mode)
  (if (and (null count) supernote-view--image
           (memq supernote-view--display-size '(fit-page fit-height)))
      (supernote-view--cross-backward (window-hscroll))
    (supernote-view--scroll-or-cross
     (lambda () (image-scroll-down count)) #'supernote-view--cross-backward)))

(defun supernote-view--image-command (command &optional count)
  "Run image COMMAND with COUNT, doing nothing when no page is displayed.
The buffer holds plain text whenever a render is in flight or an error is on
screen, and the `image-mode' motions signal `Invalid image specification: nil'
rather than no-op when asked to measure it."
  (when (and supernote-view--image (supernote-view--showing-p))
    ;; nil is meaningful to some of these -- `image-scroll-left' reads it as a
    ;; near-full-screen step -- so it is passed through rather than coerced.
    (if count (funcall command count) (funcall command))))

(defun supernote-view-scroll-left (&optional count)
  "Scroll COUNT columns left, when the page is wider than the window."
  (interactive "P")
  (supernote-view--image-command #'image-backward-hscroll
                                 (supernote-view--count count)))

(defun supernote-view-scroll-right (&optional count)
  "Scroll COUNT columns right, when the page is wider than the window."
  (interactive "P")
  (supernote-view--image-command #'image-forward-hscroll
                                 (supernote-view--count count)))

(defun supernote-view--wheel-scroll-left (&optional count)
  "Wheel the page leftward by COUNT columns, revealing what is further right.
Named for `scroll-left', whose place in `mwheel-scroll-left-function' this
takes; `image-scroll-left' measures the image and so signals on a placeholder."
  (interactive "P")
  (supernote-view--image-command #'image-scroll-left count))

(defun supernote-view--wheel-scroll-right (&optional count)
  "Wheel the page rightward by COUNT columns, back toward its left edge."
  (interactive "P")
  (supernote-view--image-command #'image-scroll-right count))

(defun supernote-view-beginning-of-line ()
  "Move to the left edge of the page."
  (interactive)
  (supernote-view--image-command #'image-bol 1))

(defun supernote-view-end-of-line ()
  "Move to the right edge of the page."
  (interactive)
  (supernote-view--image-command #'image-eol 1))

(defun supernote-view-scroll-half-up (&optional count)
  "Scroll forward half a window, crossing a page boundary when appropriate."
  (interactive "P")
  (supernote-view-scroll-up-or-next-page
   (or count (max 1 (/ (window-body-height) 2)))))

(defun supernote-view-scroll-half-down (&optional count)
  "Scroll back half a window, crossing a page boundary when appropriate."
  (interactive "P")
  (supernote-view-scroll-down-or-previous-page
   (or count (max 1 (/ (window-body-height) 2)))))


;;;; Fitting and zooming

(defun supernote-view--set-display-size (size)
  "Set the display SIZE and redisplay the page already in hand."
  (supernote-view--assert-mode)
  (setq supernote-view--display-size size)
  (supernote-view--resize))

(defun supernote-view-fit-width ()
  "Scale the page so its width fills the window."
  (interactive)
  (supernote-view--set-display-size 'fit-width)
  (supernote-view--apply-scroll nil 0 nil))

(defun supernote-view-fit-height ()
  "Scale the page so its height fills the window."
  (interactive)
  (supernote-view--set-display-size 'fit-height)
  (supernote-view--apply-scroll 0 nil nil))

(defun supernote-view-fit-page ()
  "Scale the page so all of it is visible."
  (interactive)
  (supernote-view--set-display-size 'fit-page)
  (supernote-view--apply-scroll 0 0 nil))

(defun supernote-view--current-scale ()
  "Scale factor the page is currently displayed at."
  (/ (float (supernote-view--target-width))
     (float (max 1 (car (supernote-view--intrinsic-size))))))

(defun supernote-view-enlarge (&optional factor)
  "Zoom in by FACTOR, defaulting to `supernote-view-resize-factor'."
  (interactive)
  (supernote-view--set-display-size
   (* (or factor supernote-view-resize-factor) (supernote-view--current-scale))))

(defun supernote-view-shrink (&optional factor)
  "Zoom out by FACTOR, defaulting to `supernote-view-resize-factor'."
  (interactive)
  (supernote-view-enlarge (/ 1.0 (or factor supernote-view-resize-factor))))

(defun supernote-view-scale-reset ()
  "Display the page at its own pixel size."
  (interactive)
  (supernote-view--set-display-size 1.0))


;;;; Reverting

(defun supernote-view-revert (&optional _ignore-auto _noconfirm)
  "Re-read the source, keeping the current page when it still exists.
The buffer stays read-only and unmodified throughout; nothing is written."
  (interactive)
  (supernote-view--assert-mode)
  (supernote-view--cancel-all)
  ;; The page already on screen deliberately stays there: a reload is usually a
  ;; sync, the replacement is often already rendered and appears immediately,
  ;; and blanking first is what made "rendering page N" flash on every sync.
  ;; `supernote-view--redisplay' only paints the placeholder when there is no
  ;; image, so keeping it is enough; the mode line shows `...' meanwhile.
  (setq supernote-view--generation (1+ supernote-view--generation)
        supernote-view--manifest nil
        supernote-view--render-mode nil
        supernote-view--error nil)
  (set-buffer-modified-p nil)
  (supernote-view--load-manifest))

(defun supernote-view--unwatch-source ()
  "Drop this buffer's file watch and any pending reload."
  (when supernote-view--watch
    (ignore-errors (file-notify-rm-watch supernote-view--watch))
    (setq supernote-view--watch nil
          supernote-view--watch-directory nil))
  (when (timerp supernote-view--sync-timer)
    (cancel-timer supernote-view--sync-timer)
    (setq supernote-view--sync-timer nil)))

(defun supernote-view--watch-source ()
  "Watch the directory holding this note, so a replacement is noticed.
Idempotent: an existing watch on the right directory is kept."
  (let ((directory (and supernote-view--source
                        (file-name-directory supernote-view--source)))
        (buffer (current-buffer)))
    (unless (and supernote-view-auto-sync
                 directory
                 supernote-view--watch
                 (file-notify-valid-p supernote-view--watch)
                 (equal supernote-view--watch-directory directory))
      (supernote-view--unwatch-source)
      (when (and supernote-view-auto-sync directory (file-directory-p directory))
        (setq supernote-view--watch-directory directory
              supernote-view--watch
              ;; A filesystem that cannot be watched is not the reader's
              ;; problem: it falls back to reloading on the next page turn,
              ;; which `supernote-view--stale-p' already handles.
              (ignore-errors
                (file-notify-add-watch
                 directory '(change)
                 (lambda (event)
                   (supernote-view--source-event buffer event)))))))))

(defun supernote-view--source-event (buffer event)
  "Handle file-notify EVENT for the note shown in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      ;; A directory watch reports every file in it, and a rename reports the
      ;; name it moved to as a third element.
      (when (and supernote-view--source
                 (seq-some (lambda (name)
                             (and (stringp name)
                                  (equal (file-name-nondirectory name)
                                         (file-name-nondirectory supernote-view--source))))
                           (list (nth 2 event) (nth 3 event))))
        (when (timerp supernote-view--sync-timer)
          (cancel-timer supernote-view--sync-timer))
        (setq supernote-view--sync-timer
              (run-at-time supernote-view-auto-sync-delay nil
                           #'supernote-view--sync-if-changed buffer))))))

(defun supernote-view--sync-if-changed (buffer)
  "Reload BUFFER's note if the file really did change and anyone is looking.
A buffer nobody is showing is left as it is; `supernote-view--stale-p' reloads
it the moment it is used again, so nothing is lost by waiting."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq supernote-view--sync-timer nil)
      (when (and (supernote-view--stale-p)
                 (get-buffer-window buffer t))
        (message "Supernote: %s changed on disk -- reloading"
                 (file-name-nondirectory supernote-view--source))
        (supernote-view-revert)))))

(defun supernote-view-refresh ()
  "Refresh the manifest and the page on screen."
  (interactive)
  (revert-buffer))

(defun supernote-view--refuse-save ()
  "Refuse to write a `.note' file.  Installed in `write-contents-functions'."
  (user-error "Supernote notes are read-only here -- refusing to write %s"
              (abbreviate-file-name (or supernote-view--source (buffer-name)))))


;;;; Quitting

(defun supernote-view-quit ()
  "Bury the viewer window."
  (interactive)
  (quit-window))

(defun supernote-view-kill ()
  "Cancel this buffer's helper processes and kill it."
  (interactive)
  (supernote-view--cancel-all)
  (when (buffer-live-p supernote-view--outline-buffer)
    (kill-buffer supernote-view--outline-buffer))
  (kill-buffer (current-buffer)))

(defun supernote-view--kill-buffer-hook ()
  "Tear down the helper processes, watch and outline buffer of a dying viewer."
  (supernote-view--cancel-all)
  (supernote-view--unwatch-source)
  (when (buffer-live-p supernote-view--outline-buffer)
    (kill-buffer supernote-view--outline-buffer)))


;;;; Outline: building the buffer

(defun supernote-view--outline-buffer-name (&optional buffer)
  "Name of the outline buffer belonging to BUFFER."
  (format "*Supernote Outline %s*" (buffer-name (or buffer (current-buffer)))))

(defun supernote-view-outline ()
  "Open, or select, the buffer listing this note's handwritten titles.
A note with no titles still gets a buffer saying so; that is not an error."
  (interactive)
  (supernote-view--assert-mode)
  ;; The title list is manifest data, so it has to be the current one.
  (supernote-view--ensure-fresh)
  (let ((window (display-buffer (supernote-view--outline-noselect)
                                '(nil (inhibit-same-window . t)))))
    (when (window-live-p window) (select-window window))))

(defun supernote-view--outline-noselect ()
  "Return the outline buffer for this note, building it when needed."
  (let* ((note (current-buffer))
         (window (and (eq note (window-buffer)) (selected-window)))
         (outlines (supernote-view--field supernote-view--manifest 'outlines))
         (buffer (get-buffer-create (supernote-view--outline-buffer-name note))))
    (setq supernote-view--outline-buffer buffer)
    (with-current-buffer buffer
      (unless (derived-mode-p 'supernote-outline-mode)
        (supernote-outline-mode))
      (setq supernote-outline--note-buffer note)
      (when window (setq supernote-outline--note-window window))
      (setq-local other-window-scroll-buffer note)
      (supernote-outline--fill-if-changed outlines))
    buffer))

(defun supernote-outline--fill-if-changed (outlines)
  "Rebuild the outline from OUTLINES only when they differ from what is shown."
  (unless (and supernote-outline--filled (equal outlines supernote-outline--filled))
    (supernote-outline--fill outlines)))

(defun supernote-view--refresh-outline ()
  "Rebuild this note's outline buffer, if it is still alive."
  (when (buffer-live-p supernote-view--outline-buffer)
    (let ((outlines (supernote-view--field supernote-view--manifest 'outlines))
          (note (current-buffer)))
      (with-current-buffer supernote-view--outline-buffer
        (setq supernote-outline--note-buffer note)
        (supernote-outline--fill-if-changed outlines)))))

(defun supernote-outline--fill (outlines)
  "Fill the current outline buffer with OUTLINES from the manifest."
  (let ((inhibit-read-only t)
        (entries (vconcat outlines)))
    (erase-buffer)
    (setq supernote-outline--entries entries
          supernote-outline--filled outlines
          supernote-outline--generation (1+ supernote-outline--generation))
    (if (zerop (length entries))
        (insert "This note has no title entries.\n\n"
                "Headings written on the device with the title tool appear here.\n")
      (seq-doseq (entry entries)
        (let* ((level (max 1 (or (supernote-view--field entry 'level) 1)))
               (page (1+ (or (supernote-view--field entry 'page_index) 0)))
               (indent (make-string (* supernote-view-outline-indent (1- level)) ?\s))
               (start (point)))
          (insert indent
                  (format "[L%d] p.%d" level page)
                  "\n")
          ;; The entry travels on the line itself, so movement commands can
          ;; recover it wherever point lands.
          (put-text-property start (point) 'supernote-outline-entry entry))))
    (goto-char (point-min))
    (set-buffer-modified-p nil)
    (when (> (length entries) 0)
      (supernote-outline--request-thumbnails))))

(defun supernote-outline--request-thumbnails ()
  "Ask the helper for each title's bitmap and swap it in when it arrives.
Thumbnails are lazy by design: the manifest never carries image data, and a
title whose bitmap will not decode simply keeps its textual fallback."
  (let ((note supernote-outline--note-buffer)
        (outline (current-buffer))
        (generation supernote-outline--generation))
    (when (buffer-live-p note)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (let ((entry (get-text-property (point) 'supernote-outline-entry)))
            (when (and entry (supernote-view--field entry 'has_bitmap))
              (let ((id (supernote-view--field entry 'id))
                    (marker (copy-marker (line-beginning-position))))
                (with-current-buffer note
                  (supernote-view--run
                   (intern (concat "title-" id))
                   (list "render-title"
                         "--input" supernote-view--source
                         "--title-id" id
                         "--cache-dir" (expand-file-name
                                        supernote-view-cache-directory))
                   (lambda (result)
                     (let ((failure (supernote-view--result-error result)))
                       (if failure
                           ;; A corrupt title bitmap keeps its text fallback.
                           (message "Supernote: no thumbnail for %s -- %s"
                                    id (plist-get failure :message))
                         (supernote-outline--insert-thumbnail
                          outline generation marker
                          (supernote-view--field (plist-get result :json)
                                                 'artifact))))))))))
          (forward-line 1))))))

(defun supernote-outline--insert-thumbnail (buffer generation marker artifact)
  "Show ARTIFACT on the outline line at MARKER inside BUFFER.
GENERATION is the fill this request belongs to; a later refill discards it."
  (when (and (buffer-live-p buffer)
             (markerp marker)
             (marker-position marker)
             artifact
             (file-readable-p artifact))
    (with-current-buffer buffer
      (when (= generation supernote-outline--generation)
	(save-excursion
          (goto-char marker)
          (when (get-text-property (point) 'supernote-outline-entry)
            (let* ((inhibit-read-only t)
                   (entry (get-text-property (point) 'supernote-outline-entry))
                   (image (create-image artifact 'png nil
					:height supernote-view-outline-thumbnail-height
					:ascent 'center
					:background "white"))
                   (bol (line-beginning-position))
                   (eol (line-end-position))
                   (indent (save-excursion
                             (goto-char bol)
                             (skip-chars-forward " ")
                             (buffer-substring bol (point)))))
              (delete-region bol eol)
              (goto-char bol)
              (insert indent)
              (insert-image image "*")
              (insert (format "  p.%d"
                              (1+ (or (supernote-view--field entry 'page_index) 0))))
              (put-text-property bol (line-end-position)
				 'supernote-outline-entry entry)
              (set-buffer-modified-p nil))))))))


;;;; Outline: navigation

(defun supernote-outline--entry-at-point ()
  "Outline entry on the current line, or nil."
  (get-text-property (line-beginning-position) 'supernote-outline-entry))

(defun supernote-outline--note-buffer ()
  "The viewer buffer this outline belongs to, or signal."
  (unless (buffer-live-p supernote-outline--note-buffer)
    (user-error "The note this outline describes has been killed"))
  supernote-outline--note-buffer)

(defun supernote-outline--window (&optional if-visible)
  "Return a window showing the note, creating one unless IF-VISIBLE."
  (let* ((buffer (supernote-outline--note-buffer))
         (window (if (and (window-live-p supernote-outline--note-window)
                          (eq buffer (window-buffer supernote-outline--note-window)))
                     supernote-outline--note-window
                   (or (get-buffer-window buffer)
                       (and (not if-visible)
                            ;; Never let the note replace the outline in the
                            ;; outline's own window.
                            (display-buffer buffer
                                            '(nil (inhibit-same-window . t))))))))
    (setq supernote-outline--note-window window)
    window))

(defun supernote-outline--goto-page (entry)
  "Show ENTRY's page in the note window without leaving this one."
  (unless entry (user-error "Nothing to follow here"))
  (let ((page (1+ (or (supernote-view--field entry 'page_index) 0)))
        (window (supernote-outline--window)))
    (unless (window-live-p window)
      (user-error "The note is not displayed"))
    (with-selected-window window
      (supernote-view-goto-page page))
    (force-mode-line-update t)))

(defun supernote-outline-display ()
  "Show this entry's page, staying in the outline."
  (interactive)
  (supernote-outline--goto-page (supernote-outline--entry-at-point)))

(defun supernote-outline-follow ()
  "Show this entry's page and select the note window."
  (interactive)
  (let ((entry (supernote-outline--entry-at-point)))
    (unless entry (user-error "Nothing to follow here"))
    (supernote-outline--goto-page entry)
    (let ((window (supernote-outline--window)))
      (when (window-live-p window) (select-window window)))))

(defun supernote-outline-follow-and-quit ()
  "Show this entry's page, then bury the outline window."
  (interactive)
  (let ((entry (supernote-outline--entry-at-point))
        (window (selected-window)))
    ;; Read the entry before the window goes away, and refuse early, so a
    ;; misplaced point cannot silently bury the outline.
    (unless entry (user-error "Nothing to follow here"))
    (supernote-outline--goto-page entry)
    (let ((note-window (supernote-outline--window t)))
      (quit-window nil window)
      (when (window-live-p note-window) (select-window note-window)))))

(defun supernote-outline-select-note-window ()
  "Select the window showing the note, without changing its page."
  (interactive)
  (let ((window (supernote-outline--window)))
    (when (window-live-p window) (select-window window))))

(defun supernote-outline-move-to-current-page ()
  "Move to the entry nearest the page the note is showing."
  (interactive)
  (let ((page (with-current-buffer (supernote-outline--note-buffer)
                (1+ supernote-view--page)))
        (target nil)
        (last nil))
    ;; The first entry at or past the current page, or the final entry when
    ;; every title sits before it.  Entries are in document order, so one
    ;; forward pass is enough.
    (save-excursion
      (goto-char (point-min))
      (while (and (not target) (not (eobp)))
        (when-let ((entry (supernote-outline--entry-at-point)))
          (setq last (line-beginning-position))
          (when (>= (1+ (or (supernote-view--field entry 'page_index) 0)) page)
            (setq target (line-beginning-position))))
        (forward-line 1)))
    (when-let ((position (or target last)))
      (goto-char position)
      (supernote-outline--reveal)
      (back-to-indentation))))

(defun supernote-outline--reveal ()
  "Make the current line visible by unfolding its ancestors."
  (save-excursion
    (let ((guard 0))
      (while (and (outline-invisible-p) (< guard 32))
        (setq guard (1+ guard))
        (outline-up-heading 1 t)
        (outline-show-children)))))

(defun supernote-outline--move (motion count limit)
  "Apply MOTION COUNT times, staying on a real entry.
`outline-mode' happily walks onto the blank line past the last entry and
signals a bare `error' at the end of a level; neither is useful here, so point
is restored and LIMIT is reported instead."
  (let ((start (point)))
    (condition-case nil
        (funcall motion count)
      (error (goto-char start) (message "Supernote: %s" limit)))
    (if (supernote-outline--entry-at-point)
        (back-to-indentation)
      (goto-char start)
      (back-to-indentation)
      (message "Supernote: %s" limit))))

(defun supernote-outline-next-entry (&optional count)
  "Move to the COUNT'th next visible entry."
  (interactive "P")
  (supernote-outline--move #'outline-next-visible-heading
                           (supernote-view--count count) "last title"))

(defun supernote-outline-previous-entry (&optional count)
  "Move to the COUNT'th previous visible entry."
  (interactive "P")
  (supernote-outline--move #'outline-previous-visible-heading
                           (supernote-view--count count) "first title"))

(defun supernote-outline-forward-same-level (&optional count)
  "Move COUNT entries forward at this entry's level."
  (interactive "P")
  (supernote-outline--move #'outline-forward-same-level
                           (supernote-view--count count) "last title at this level"))

(defun supernote-outline-backward-same-level (&optional count)
  "Move COUNT entries back at this entry's level."
  (interactive "P")
  (supernote-outline--move #'outline-backward-same-level
                           (supernote-view--count count) "first title at this level"))

(defun supernote-outline-up-heading (&optional count)
  "Move COUNT levels up to the parent entry."
  (interactive "P")
  (let ((start (point)))
    (ignore-errors (outline-up-heading (supernote-view--count count) t))
    (unless (= start (point)) (push-mark start))
    (back-to-indentation)))

(defun supernote-outline-first-entry ()
  "Move to the first entry."
  (interactive)
  (goto-char (point-min))
  (back-to-indentation))

(defun supernote-outline-last-entry ()
  "Move to the last entry."
  (interactive)
  (goto-char (point-max))
  ;; The buffer ends in a newline, so `point-max' is the blank line after the
  ;; last entry; step back onto the entry itself.
  (when (and (bolp) (not (bobp))) (forward-line -1))
  (unless (supernote-outline--entry-at-point)
    (while (and (not (bobp)) (not (supernote-outline--entry-at-point)))
      (forward-line -1)))
  (back-to-indentation))

(defun supernote-outline-toggle-children ()
  "Show or hide this entry's direct children."
  (interactive)
  (ignore-errors (outline-toggle-children)))


;;;; Key maps

(defvar supernote-view-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "n") #'supernote-view-next-page)
    (define-key map (kbd "p") #'supernote-view-previous-page)
    (define-key map (kbd "SPC") #'supernote-view-scroll-up-or-next-page)
    (define-key map (kbd "S-SPC") #'supernote-view-scroll-down-or-previous-page)
    (define-key map (kbd "DEL") #'supernote-view-scroll-down-or-previous-page)
    (define-key map (kbd "C-n") #'supernote-view-next-line-or-next-page)
    (define-key map (kbd "C-p") #'supernote-view-previous-line-or-previous-page)
    (define-key map (kbd "<down>") #'supernote-view-next-line-or-next-page)
    (define-key map (kbd "<up>") #'supernote-view-previous-line-or-previous-page)
    (define-key map (kbd "g") #'supernote-view-goto-page)
    (define-key map (kbd "M-g g") #'supernote-view-goto-page)
    (define-key map (kbd "M-g M-g") #'supernote-view-goto-page)
    (define-key map (kbd "<") #'supernote-view-first-page)
    (define-key map (kbd ">") #'supernote-view-last-page)
    (define-key map (kbd "W") #'supernote-view-fit-width)
    (define-key map (kbd "H") #'supernote-view-fit-height)
    (define-key map (kbd "P") #'supernote-view-fit-page)
    (define-key map (kbd "+") #'supernote-view-enlarge)
    (define-key map (kbd "=") #'supernote-view-enlarge)
    (define-key map (kbd "-") #'supernote-view-shrink)
    (define-key map (kbd "0") #'supernote-view-scale-reset)
    (define-key map (kbd "o") #'supernote-view-outline)
    (define-key map (kbd "r") #'supernote-view-refresh)
    (define-key map (kbd "q") #'supernote-view-quit)
    map)
  "Keymap for `supernote-view-mode'.
Complete on its own: the Evil bindings in section `Evil integration' are an
addition, not a replacement.")

(defvar supernote-outline-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'supernote-outline-next-entry)
    (define-key map (kbd "p") #'supernote-outline-previous-entry)
    (define-key map (kbd "f") #'supernote-outline-forward-same-level)
    (define-key map (kbd "b") #'supernote-outline-backward-same-level)
    (define-key map (kbd "u") #'supernote-outline-up-heading)
    (define-key map (kbd "TAB") #'supernote-outline-toggle-children)
    (define-key map (kbd "<tab>") #'supernote-outline-toggle-children)
    (define-key map (kbd "RET") #'supernote-outline-follow)
    (define-key map (kbd "SPC") #'supernote-outline-display)
    (define-key map (kbd "C-o") #'supernote-outline-display)
    (define-key map (kbd "o") #'supernote-outline-select-note-window)
    (define-key map (kbd ".") #'supernote-outline-move-to-current-page)
    (define-key map (kbd "M-RET") #'supernote-outline-follow-and-quit)
    (define-key map (kbd "<") #'supernote-outline-first-entry)
    (define-key map (kbd ">") #'supernote-outline-last-entry)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `supernote-outline-mode'.")


;;;; Evil integration
;;
;; Evil is a first-class part of this mode, but it must stay optional at load
;; time.  Three details make that work:
;;
;;   * `evil-define-key*' is a function, while `evil-define-key' is a macro.  A
;;     file byte-compiled without Evil on the load path would compile the macro
;;     as a plain call and fail at run time with `invalid-function'; the
;;     function form cannot.
;;   * every command takes its count through `(interactive "P")', which Evil's
;;     normal-state digits fill in exactly like `C-u'.  `3]]' therefore passes
;;     3 and a bare `]]' passes nil, with no Evil-only macro involved and
;;     identical behaviour when Evil is absent.
;;   * `evil-collection-inhibit-insert-state' is used when it happens to be
;;     loaded, and an equivalent remap table is installed when it is not, so
;;     nothing here depends on evil-collection.
;;
;; Doom appends "gr" to `evil-collection-key-blacklist', so bindings that go
;; through evil-collection lose it.  These go through `evil-define-key*'
;; directly and keep it.

(defconst supernote-view--evil-insert-commands
  '(evil-append evil-append-line evil-insert evil-insert-line
		evil-change evil-change-line evil-substitute evil-change-whole-line
		evil-delete evil-delete-line evil-delete-char evil-delete-backward-char
		evil-replace evil-replace-state evil-open-below evil-open-above
		evil-paste-after evil-paste-before evil-join evil-indent
		evil-shift-left evil-shift-right evil-invert-char)
  "Editing commands neutralised in the viewer and outline buffers.
Entering insert state must never make a `.note' look writable.")

(defun supernote-view--evil-inhibit-insert (map-symbol)
  "Neutralise editing commands in MAP-SYMBOL's normal state."
  (if (fboundp 'evil-collection-inhibit-insert-state)
      (evil-collection-inhibit-insert-state map-symbol)
    (apply #'evil-define-key* 'normal (symbol-value map-symbol)
           (mapcan (lambda (command) (list (vector 'remap command) #'ignore))
                   supernote-view--evil-insert-commands))))

(defun supernote-view--evil-setup ()
  "Install Evil normal-state bindings for both modes.
Safe to call more than once; Doom loads evil-collection after Evil itself, so
this runs again from `evil-collection' to pick up its helper."
  (when (fboundp 'evil-define-key*)
    (evil-set-initial-state 'supernote-view-mode 'normal)
    (evil-set-initial-state 'supernote-outline-mode 'normal)
    (supernote-view--evil-inhibit-insert 'supernote-view-mode-map)
    (supernote-view--evil-inhibit-insert 'supernote-outline-mode-map)

    (evil-define-key* 'normal supernote-view-mode-map
		      "j" #'supernote-view-next-line-or-next-page
		      "k" #'supernote-view-previous-line-or-previous-page
		      (kbd "<down>") #'supernote-view-next-line-or-next-page
		      (kbd "<up>") #'supernote-view-previous-line-or-previous-page
		      (kbd "SPC") #'supernote-view-scroll-up-or-next-page
		      (kbd "S-SPC") #'supernote-view-scroll-down-or-previous-page
		      (kbd "DEL") #'supernote-view-scroll-down-or-previous-page
		      (kbd "C-f") #'supernote-view-scroll-up-or-next-page
		      (kbd "C-b") #'supernote-view-scroll-down-or-previous-page
		      "]]" #'supernote-view-next-page
		      "[[" #'supernote-view-previous-page
		      "gj" #'supernote-view-next-page
		      "gk" #'supernote-view-previous-page
		      (kbd "C-j") #'supernote-view-next-page
		      (kbd "C-k") #'supernote-view-previous-page
		      "n" #'supernote-view-next-page
		      "p" #'supernote-view-previous-page
		      "gg" #'supernote-view-first-page
		      "G" #'supernote-view-last-page
		      ;; Documented by `C-h m' through the ordinary map, so they must not fall
		      ;; through to Evil's shift operators (which the inhibit table ignores).
		      "<" #'supernote-view-first-page
		      ">" #'supernote-view-last-page
		      "h" #'supernote-view-scroll-left
		      "l" #'supernote-view-scroll-right
		      "^" #'supernote-view-beginning-of-line
		      "$" #'supernote-view-end-of-line
		      "+" #'supernote-view-enlarge
		      "=" #'supernote-view-enlarge
		      "zi" #'supernote-view-enlarge
		      "-" #'supernote-view-shrink
		      "zo" #'supernote-view-shrink
		      "0" #'supernote-view-scale-reset
		      "z0" #'supernote-view-scale-reset
		      "H" #'supernote-view-fit-height
		      "P" #'supernote-view-fit-page
		      "W" #'supernote-view-fit-width
		      ;; Doom appends "gr" to `evil-collection-key-blacklist', so a binding
		      ;; routed through evil-collection would be dropped; this one is not.
		      "gr" #'supernote-view-refresh
		      "r" #'supernote-view-refresh
		      "o" #'supernote-view-outline
		      "q" #'supernote-view-quit
		      "Q" #'supernote-view-kill
		      "ZQ" #'supernote-view-kill
		      "ZZ" #'supernote-view-quit)

    ;; `C-d'/`C-u' only when this user wants Evil's half-page scroll on them;
    ;; otherwise `C-u' must stay `universal-argument', as it is everywhere else
    ;; in their configuration.
    (when (bound-and-true-p evil-want-C-d-scroll)
      (evil-define-key* 'normal supernote-view-mode-map
			(kbd "C-d") #'supernote-view-scroll-half-up))
    (when (bound-and-true-p evil-want-C-u-scroll)
      (evil-define-key* 'normal supernote-view-mode-map
			(kbd "C-u") #'supernote-view-scroll-half-down))

    (evil-define-key* 'normal supernote-outline-mode-map
		      "j" #'supernote-outline-next-entry
		      "k" #'supernote-outline-previous-entry
		      "gj" #'supernote-outline-forward-same-level
		      "gk" #'supernote-outline-backward-same-level
		      "gg" #'supernote-outline-first-entry
		      "G" #'supernote-outline-last-entry
		      "h" #'supernote-outline-up-heading
		      "^" #'supernote-outline-up-heading
		      "<" #'supernote-outline-up-heading
		      "l" #'supernote-outline-toggle-children
		      (kbd "TAB") #'supernote-outline-toggle-children
		      (kbd "<tab>") #'supernote-outline-toggle-children
		      (kbd "RET") #'supernote-outline-follow
		      "go" #'supernote-outline-display
		      (kbd "SPC") #'supernote-outline-display
		      "o" #'supernote-outline-select-note-window
		      "." #'supernote-outline-move-to-current-page
		      ">" #'supernote-outline-last-entry
		      (kbd "M-RET") #'supernote-outline-follow-and-quit
		      "q" #'quit-window
		      "ZQ" #'quit-window
		      "ZZ" #'supernote-outline-follow-and-quit)))

(with-eval-after-load 'evil
  (supernote-view--evil-setup))

;; evil-collection loads after Evil under Doom, so run again to pick up
;; `evil-collection-inhibit-insert-state' once it exists.
(with-eval-after-load 'evil-collection
  (supernote-view--evil-setup))

(defun supernote-view--normalize-evil ()
  "Let Evil notice this buffer's auxiliary keymaps."
  (when (fboundp 'evil-normalize-keymaps) (evil-normalize-keymaps)))


;;;; Modes

;;;###autoload
(define-derived-mode supernote-view-mode special-mode "Supernote"
  "Read-only viewer for a Supernote `.note' document.

One page is shown at a time.  Handwriting is drawn as real vector paths where
the file's stroke data decodes, and the mode line reports `V' when it did and
`R' when the page fell back to the renderer's raster.

The pages either side of this one, and the pages your titles point at, are
rendered ahead of you, so turning to them is usually instant; see
`supernote-view-prefetch-count' and `supernote-view-prefetch-outline-pages'.

\\{supernote-view-mode-map}"
  ;; Ordinary `find-file' has already inserted the raw file by the time a major
  ;; mode runs.  Drop it: nothing downstream should ever see those bytes, and a
  ;; visual selection must not be able to expose them.
  (let ((inhibit-read-only t))
    (setq buffer-undo-list t)
    (erase-buffer))
  (set-buffer-modified-p nil)
  (setq-local supernote-view--source
              (or (and buffer-file-name (expand-file-name buffer-file-name))
                  supernote-view--source))
  (setq-local supernote-view--display-size supernote-view-default-display-size)
  (setq-local revert-buffer-function #'supernote-view-revert)
  (setq-local truncate-lines t)
  (setq-local cursor-type nil)
  (setq-local mode-line-process '(:eval (supernote-view--mode-line)))
  (setq-local bidi-paragraph-direction 'left-to-right)
  (buffer-disable-undo)
  (add-hook 'write-contents-functions #'supernote-view--refuse-save nil t)
  (add-hook 'kill-buffer-hook #'supernote-view--kill-buffer-hook nil t)
  (add-hook 'change-major-mode-hook #'supernote-view--cancel-all nil t)
  (add-hook 'change-major-mode-hook #'supernote-view--unwatch-source nil t)
  (image-mode-setup-winprops)

  ;; Scrolling a page is not scrolling text, and two defaults get in the way.
  ;;
  ;; `auto-hscroll-mode' is the one that bites hardest.  Point never leaves
  ;; (point-min), so once the reader has scrolled a zoomed page sideways, point
  ;; is off the left edge of the window and the next redisplay drags the window
  ;; back to column 0 to make it visible again -- the page snaps to the left
  ;; mid-scroll.  `image-mode' turns it off for exactly this reason, under the
  ;; comment "Allow navigation of large images".
  (setq-local auto-hscroll-mode nil)
  ;; High values are documented in `pdf-view' to trigger a display bug in
  ;; xdisp.c's try_scrolling on buffers like this one.
  (setq-local scroll-conservatively 0)

  ;; The wheel and the touchpad otherwise reach `scroll-up'/`scroll-down',
  ;; which count lines -- and the whole page is a single line, so they cannot
  ;; move within a page or cross to the next one.  Route them through the same
  ;; commands `SPC' and `j' use.
  (when (boundp 'mwheel-scroll-up-function)
    (setq-local mwheel-scroll-up-function #'supernote-view-scroll-up-or-next-page))
  (when (boundp 'mwheel-scroll-down-function)
    (setq-local mwheel-scroll-down-function #'supernote-view-scroll-down-or-previous-page))
  (when (boundp 'mwheel-scroll-left-function)
    (setq-local mwheel-scroll-left-function #'supernote-view--wheel-scroll-left))
  (when (boundp 'mwheel-scroll-right-function)
    (setq-local mwheel-scroll-right-function #'supernote-view--wheel-scroll-right))
  ;; One page turn per gesture rather than one per reported tick.
  (when (boundp 'mwheel-coalesce-scroll-events)
    (setq-local mwheel-coalesce-scroll-events t))
  ;; Pixel-precision scrolling works in lines of text and fights the image
  ;; vscroll here; the buffer-local nil takes this mode's buffers out of its
  ;; minor-mode map without disturbing it anywhere else.
  (when (bound-and-true-p pixel-scroll-precision-mode)
    (setq-local pixel-scroll-precision-mode nil))

  (supernote-view--normalize-evil)
  (when supernote-view--source
    (setq supernote-view--generation (1+ supernote-view--generation))
    (supernote-view--load-manifest)))

(define-derived-mode supernote-outline-mode outline-mode "Supernote Outline"
  "Outline of the handwritten titles in a Supernote note.

Entries are indented by their stored title level.  Each shows a thumbnail of
the handwriting itself once it has been decoded; no text is ever invented for a
handwritten title.

\\{supernote-outline-mode-map}"
  ;; Every non-blank line is a heading and the level is carried by the leading
  ;; indentation, exactly as `pdf-outline' does it -- there are no stars to
  ;; show, and the indentation is meaningful to the reader anyway.
  (setq-local outline-regexp "\\( *\\).")
  (setq-local outline-level
              (lambda ()
                (1+ (/ (length (match-string 1))
                       (max 1 supernote-view-outline-indent)))))
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (setq-local cursor-type 'box)
  (buffer-disable-undo)
  (add-hook 'write-contents-functions #'supernote-view--refuse-save nil t)
  (supernote-view--normalize-evil))


;;;; Entry points and registration

;;;###autoload
(defun supernote-view-file (file)
  "Open FILE, a Supernote `.note' document, in a viewer buffer.
Preferred over plain `find-file': the buffer is built directly, so a hundred
megabytes of binary never passes through `insert-file-contents'."
  (interactive
   (list (read-file-name "Supernote note: " nil nil t nil
                         (lambda (name)
                           (or (file-directory-p name)
                               (string-match-p "\\.note\\'" name))))))
  (let* ((file (expand-file-name file))
         (existing (seq-find (lambda (buffer)
                               (with-current-buffer buffer
                                 (and (derived-mode-p 'supernote-view-mode)
                                      (equal supernote-view--source file))))
                             (buffer-list)))
         buffer)
    ;; Checked before the buffer exists, so a failed open leaves nothing behind.
    (unless (file-readable-p file)
      (user-error "Cannot read %s" file))
    (setq buffer (or existing (generate-new-buffer (file-name-nondirectory file))))
    (with-current-buffer buffer
      (unless existing
        (setq buffer-file-name file
              buffer-file-truename (file-truename file)
              default-directory (file-name-directory file))
        (set-buffer-modified-p nil)
        (supernote-view-mode)))
    (pop-to-buffer-same-window buffer)
    buffer))

;;;###autoload
(defun supernote-view-dwim ()
  "Open the `.note' file at point, or prompt for one."
  (interactive)
  (let ((name (or (and (derived-mode-p 'dired-mode)
                       (fboundp 'dired-get-filename)
                       (ignore-errors (dired-get-filename nil t)))
                  (thing-at-point 'filename t))))
    (if (and name (string-match-p "\\.note\\'" name) (file-readable-p name))
        (supernote-view-file name)
      (call-interactively #'supernote-view-file))))

;;;###autoload
(progn
  ;; Read the file verbatim: it is binary, and any decoding attempt would both
  ;; be wasted work and risk mangling what the mode immediately discards.
  (add-to-list 'auto-coding-alist '("\\.note\\'" . no-conversion))
  (add-to-list 'auto-mode-alist '("\\.note\\'" . supernote-view-mode))
  ;; `.note' is binary; keep it out of the "is this really text" heuristics.
  (add-to-list 'inhibit-local-variables-regexps "\\.note\\'"))

(provide 'supernote-view)
;;; supernote-view.el ends here
