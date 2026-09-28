;;; supernote-view-test.el --- Tests for supernote-view -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; ERT suite for `supernote-view.el'.  Run it from the repository root:
;;
;;   emacs -Q --batch \
;;     --eval "(setq native-comp-enable-subr-trampolines nil)" \
;;     -L . \
;;     -l test/supernote-view-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; Evil is optional.  Add its build directory with `-L' to exercise the
;; normal-state tests; without it they skip and everything else still runs,
;; which is the point of the mode's own Evil-optional design:
;;
;;   -L /path/to/evil
;;
;; Most tests drive a stubbed helper, so they are deterministic and need
;; neither Node nor a `.note' file.  The few that exercise the real process
;; contract skip themselves when the helper or its dependency tree is absent,
;; and only ever read the reference notes.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'supernote-view)


(ert-deftest supernote-view-test-helper-install-follows-build-symlinks ()
  "Install dependencies beside the real Node source, as Node resolves imports."
  (let* ((root (make-temp-file "supernote-build-" t))
         (source (expand-file-name "source/bin/" root))
         (build (expand-file-name "build/bin/" root))
         (supernote-view-helper (expand-file-name "supernote-render.mjs" build))
         command)
    (unwind-protect
        (progn
          (make-directory source t) (make-directory build t)
          (with-temp-file (expand-file-name "supernote-render.mjs" source) (insert "// test"))
          (with-temp-file (expand-file-name "../package-lock.json" source) (insert "{}"))
          (make-symbolic-link (expand-file-name "supernote-render.mjs" source) supernote-view-helper)
          (should (string-match-p (regexp-quote (expand-file-name "source" root))
                                  (supernote-view-repair-command)))
          (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/npm"))
                    ((symbol-function 'make-process)
                     (lambda (&rest args) (setq command (plist-get args :command))))
                    ((symbol-function 'display-buffer) #'ignore))
            (supernote-view-install-helper))
          (should (equal (file-truename (expand-file-name "source/" root))
                         (file-truename (car (last command))))))
      (when (get-buffer "*supernote-view-install*") (kill-buffer "*supernote-view-install*"))
      (delete-directory root t))))

;;;; Fixtures and the stubbed helper

(defvar supernote-test--queue nil
  "Pending (KIND ARGS CALLBACK) triples recorded by the stubbed helper.
Emptied by `supernote-test--flush'; see `supernote-test--log' for the history.")

(defvar supernote-test--log nil
  "Every command the stubbed helper was asked for, newest first.
Unlike `supernote-test--queue' this is never emptied, so a test can count how
many times the viewer went back to the helper.")

(defvar supernote-test--responses nil
  "Alist of COMMAND (a string) to what the stub answers with.
A value is either a result plist or a function of no arguments returning one,
which is how a test makes the same command answer differently over time.")

(defvar supernote-test--defer nil
  "When non-nil the stub queues callbacks instead of running them.")

(defvar supernote-test--artifact
  (let ((file (make-temp-file "supernote-test-page" nil ".svg")))
    (with-temp-file file
      (insert "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1920\" height=\"2560\""
              " viewBox=\"0 0 1920 2560\"><rect width=\"1920\" height=\"2560\""
              " fill=\"white\"/></svg>"))
    file)
  "A real, readable artifact for the stubbed helper to hand back.
It has to exist on disk: the viewer refuses to reuse a remembered artifact it
cannot read, which is exactly what keeps a reclaimed cache entry off screen.")

(defun supernote-test--default-response (command)
  "A minimal valid answer for COMMAND.
It has to be valid JSON, not nil: the viewer treats a clean exit with nothing
parseable on stdout as a failure, which is the whole point of `E_RESPONSE'."
  (list :status 0 :stderr ""
        :json (pcase command
                ("render" `((artifact . ,supernote-test--artifact)
                            (render_mode . "vector-ink")))
                ("render-title" `((artifact . ,supernote-test--artifact)))
                (_ (supernote-test--manifest)))))

(defun supernote-test--response (command)
  "The result plist the stub should answer COMMAND with."
  (let ((response (alist-get command supernote-test--responses nil nil #'equal)))
    (cond ((functionp response) (funcall response))
          (response response)
          (t (supernote-test--default-response command)))))

(defun supernote-test--run (kind args callback)
  "Stand in for `supernote-view--run', answering from `supernote-test--responses'."
  (push (list kind args callback) supernote-test--queue)
  (push (car args) supernote-test--log)
  (unless supernote-test--defer
    (funcall callback (supernote-test--response (car args)))))

(defun supernote-test--flush ()
  "Run every deferred callback, oldest first."
  (let ((queue (nreverse supernote-test--queue)))
    (setq supernote-test--queue nil)
    (dolist (entry queue)
      (funcall (nth 2 entry) (supernote-test--response (car (nth 1 entry)))))))

(defun supernote-test--manifest (&rest overrides)
  "A schema-1 manifest alist, with OVERRIDES merged over the defaults."
  (let ((manifest
         `((schema_version . 1)
           (renderer . ((name . "supernote-emacs-renderer") (abi . 1)
                        (library_version . "0.7.1")))
           (source . ((path . "/tmp/note.note") (size . 1234) (mtime_ms . 1780000000000)
                      (signature . "noteSN_FILE_VER_20260016") (equipment . "N5")))
           (page_count . 5)
           (page_size . ((width . 1920) (height . 2560)))
           (pages . ,(cl-loop for i from 0 below 5
                              collect `((page_index . ,i) (display_page . ,(1+ i)))))
           (outlines . nil))))
    ;; `copy-tree' matters: a backquoted list shares its constant conses, so
    ;; overriding a key in place would rewrite the template for every later
    ;; caller in the same session.
    (setq manifest (copy-tree manifest))
    (dolist (pair overrides manifest)
      (setf (alist-get (car pair) manifest) (cdr pair)))))

(defun supernote-test--outlines ()
  "Three synthetic titles at levels 1, 2 and 3.
The live corpus only has level-1 titles, so the hierarchy has to be synthetic."
  '(((id . "TITLE_000102700138") (page_index . 0) (level . 1)
     (rect . ((x . 138) (y . 270) (width . 208) (height . 73)))
     (style . "1000000") (has_bitmap . t) (label . nil))
    ((id . "TITLE_000205000100") (page_index . 1) (level . 2)
     (rect . ((x . 100) (y . 500) (width . 180) (height . 60)))
     (style . "1000000") (has_bitmap . nil) (label . nil))
    ((id . "TITLE_000407000200") (page_index . 3) (level . 3)
     (rect . ((x . 200) (y . 700) (width . 160) (height . 55)))
     (style . "1000000") (has_bitmap . nil) (label . nil))))

(defmacro supernote-test--with-viewer (options &rest body)
  "Run BODY in a viewer buffer wired to the stubbed helper.
OPTIONS is a plist accepting :manifest, :responses, :defer, :prefetch and
:prefetch-outline and :auto-sync."
  (declare (indent 1) (debug t))
  `(let* ((supernote-test--queue nil)
          (supernote-test--log nil)
          (supernote-test--defer (plist-get ,options :defer))
          ;; Off unless a test asks for it, so counting helper calls stays
          ;; meaningful; `supernote-view-test-prefetch-*' turn it back on.
          (supernote-view-prefetch-count (or (plist-get ,options :prefetch) 0))
          (supernote-view-prefetch-outline-pages
           (or (plist-get ,options :prefetch-outline) 0))
          ;; Off by default: a live file-notify watch keeps
          ;; `accept-process-output' from draining a subprocess under
          ;; `--batch' (it works fine in a real event loop -- verified against
          ;; an Emacs daemon), which would hang every test that runs the real
          ;; helper.  `supernote-view-test-watch-*' set up their own watch.
          (supernote-view-auto-sync (plist-get ,options :auto-sync))
          (supernote-test--responses
           (or (plist-get ,options :responses)
               (list (cons "manifest"
                           (list :status 0 :stderr ""
                                 :json (or (plist-get ,options :manifest)
                                           (supernote-test--manifest)))))))
          (buffer (generate-new-buffer "*supernote-test*")))
     (unwind-protect
         (cl-letf (((symbol-function 'supernote-view--run) #'supernote-test--run))
           (with-current-buffer buffer
             (setq buffer-file-name "/tmp/supernote-test-note.note")
             (supernote-view-mode)
             ,@body))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (buffer-live-p supernote-view--outline-buffer)
             (kill-buffer supernote-view--outline-buffer)))
         (let ((kill-buffer-query-functions nil))
           (set-buffer-modified-p nil)
           (kill-buffer buffer))))))


;;;; Registration

(ert-deftest supernote-view-test-auto-mode-registration ()
  "`.note' opens in the viewer and is read without any decoding."
  (should (eq 'supernote-view-mode
              (cdr (assoc "\\.note\\'" auto-mode-alist))))
  (should (eq 'no-conversion
              (cdr (assoc "\\.note\\'" auto-coding-alist))))
  (should (member "\\.note\\'" inhibit-local-variables-regexps))
  ;; The mapping has to survive a real file name, not just the literal regexp.
  (should (eq 'supernote-view-mode
              (let ((buffer-file-name "/tmp/Some Note.note"))
                (cdr (cl-find-if (lambda (entry)
                                   (string-match-p (car entry) "/tmp/Some Note.note"))
                                 auto-mode-alist))))))

(ert-deftest supernote-view-test-format-falls-back-to-png ()
  "PNG is requested when this Emacs cannot display SVG."
  (let ((supernote-view-image-format 'auto))
    (cl-letf (((symbol-function 'image-type-available-p)
               (lambda (type) (not (eq type 'svg)))))
      (should (equal "png" (supernote-view--format))))
    (cl-letf (((symbol-function 'image-type-available-p) (lambda (_type) t)))
      (should (equal "svg" (supernote-view--format)))))
  ;; An explicit setting overrides the probe in both directions.
  (cl-letf (((symbol-function 'image-type-available-p) (lambda (_type) t)))
    (let ((supernote-view-image-format 'png))
      (should (equal "png" (supernote-view--format))))))


;;;; Page numbering and navigation

(ert-deftest supernote-view-test-page-numbering ()
  "Wire page 0 is the page the reader calls 1."
  (supernote-test--with-viewer nil
    (should (= 0 supernote-view--page))
    (should (string-match-p " 1/5" (supernote-view--mode-line)))
    (supernote-view-goto-page 3)
    (should (= 2 supernote-view--page))
    (should (string-match-p " 3/5" (supernote-view--mode-line)))
    ;; The helper is always asked for the zero-based index.
    (let ((render (cl-find-if (lambda (entry) (equal (car (nth 1 entry)) "render"))
                              supernote-test--queue)))
      (should render)
      (should (member "2" (nth 1 render))))
    (should (member "render" supernote-test--log))))

(ert-deftest supernote-view-test-prefetch-renders-pages-ahead ()
  "The next pages are rendered before the reader asks for them."
  (supernote-test--with-viewer '(:prefetch 2)
    ;; Page 1 is on screen; pages 2 and 3 are fetched behind it, one at a time.
    ;; There is no page before the first, so the plan is just forward here.
    (should (equal '("render" "render" "render" "manifest") supernote-test--log))
    (should (supernote-view--cached-artifact 1))
    (should (supernote-view--cached-artifact 2))
    (should-not (supernote-view--cached-artifact 3))
    ;; Nothing speculative may touch the page on screen.
    (should (= 0 supernote-view--page))
    (should-not supernote-view--status)
    (should-not supernote-view--error)))

(ert-deftest supernote-view-test-prefetch-order-covers-the-page-behind ()
  "The plan is next, then previous, then the rest of the way forward.
Reading straight through already holds the previous page and skips it for
free; arriving by the outline or `G' does not, which is what this is for."
  (supernote-test--with-viewer '(:prefetch 2)
    ;; Land on page 3 the way an outline jump does, with nothing around it.
    (supernote-view--forget-artifacts)
    (setq supernote-view--page 2)
    (should (equal '(3 1 4) (supernote-view--prefetch-plan)))
    ;; At the last page there is nothing ahead, so only the page behind is left.
    (setq supernote-view--page 4)
    (should (equal '(3) (supernote-view--prefetch-plan)))
    ;; The page on screen is never queued: it is rendered by definition.
    (setq supernote-view--page 2)
    (should-not (memq 2 (supernote-view--prefetch-plan)))
    ;; Pages already in hand drop out, so reading forward never re-renders.
    (supernote-view--remember-artifact 1 (supernote-view--format)
                                       `((artifact . ,supernote-test--artifact)))
    (should (equal '(3 4) (supernote-view--prefetch-plan)))
    ;; And a page whose render failed is not tried again.
    (setq supernote-view--prefetch-failed '(3))
    (should (equal '(4) (supernote-view--prefetch-plan)))))

(ert-deftest supernote-view-test-prefetch-covers-the-outline-pages ()
  "Every page a title points at is prepared once the note is open."
  (supernote-test--with-viewer
      (list :prefetch 2 :prefetch-outline 16
            :manifest (supernote-test--manifest
                       (cons 'outlines (supernote-test--outlines))))
    ;; Titles sit on pages 1, 2 and 4 (indices 0, 1 and 3).  From page 1 the
    ;; near plan is 2 and 3, so the outline contributes page 4, and the near
    ;; pages keep their priority.  All of them end up rendered, one at a time.
    (should (supernote-view--cached-artifact 1))
    (should (supernote-view--cached-artifact 2))
    (should (supernote-view--cached-artifact 3))
    (should (= 4 (cl-count "render" supernote-test--log :test #'equal)))
    ;; Nothing is left to do, and the page on screen was never queued.
    (should-not (supernote-view--prefetch-plan))))

(ert-deftest supernote-view-test-prefetch-outline-plan-order ()
  "Outline pages queue behind the nearby ones, in document order."
  (supernote-test--with-viewer
      (list :prefetch 2 :prefetch-outline 16
            :manifest (supernote-test--manifest
                       (cons 'outlines (supernote-test--outlines))))
    (supernote-view--forget-artifacts)
    (should (equal '(1 2 3) (supernote-view--prefetch-plan))))
  ;; The limit is what keeps a note full of titles from queueing endless work.
  (supernote-test--with-viewer
      (list :prefetch 0 :prefetch-outline 1
            :manifest (supernote-test--manifest
                       (cons 'outlines (supernote-test--outlines))))
    (supernote-view--forget-artifacts)
    (should (equal '(1) (supernote-view--prefetch-plan))))
  ;; Zero turns it off without affecting the near pages.
  (supernote-test--with-viewer
      (list :prefetch 1 :prefetch-outline 0
            :manifest (supernote-test--manifest
                       (cons 'outlines (supernote-test--outlines))))
    (supernote-view--forget-artifacts)
    (should (equal '(1) (supernote-view--prefetch-plan)))))

(ert-deftest supernote-view-test-prefetch-does-not-restart-work-in-flight ()
  "Reshuffling the queue leaves a render already running alone."
  (supernote-test--with-viewer '(:prefetch 2 :defer t)
    (setq supernote-test--responses
          (list (cons "manifest" (list :status 0 :stderr ""
                                       :json (supernote-test--manifest)))))
    (supernote-test--flush)
    (supernote-test--flush)
    ;; A prefetch is now in flight; scheduling again must not start a second.
    (setq supernote-view--jobs (list (cons 'prefetch 'in-flight)))
    (setq supernote-test--log nil)
    (supernote-view--prefetch-schedule)
    (should-not supernote-test--log)
    (should supernote-view--prefetch-queue)))

(ert-deftest supernote-view-test-prefetch-stops-at-the-last-page ()
  "Prefetching never runs off the end of the note."
  (supernote-test--with-viewer
      (list :prefetch 2
            :manifest (supernote-test--manifest
                       '(page_count . 2)
                       '(pages . (((page_index . 0) (display_page . 1))
                                  ((page_index . 1) (display_page . 2))))))
    ;; One page ahead exists, so exactly one speculative render happens.
    (should (= 2 (cl-count "render" supernote-test--log :test #'equal)))
    (should (supernote-view--cached-artifact 1))
    (should-not supernote-view--prefetch-queue))
  ;; From the last page only the page behind is left, and it is already in
  ;; hand after reading forward to get there.
  (supernote-test--with-viewer '(:prefetch 2)
    (supernote-view-last-page)
    (setq supernote-test--log nil)
    (supernote-view--prefetch-schedule)
    (should-not supernote-test--log)))

(ert-deftest supernote-view-test-prefetched-page-appears-without-a-round-trip ()
  "Entering an already-rendered page shows it at once, with no placeholder."
  (supernote-test--with-viewer '(:prefetch 2)
    (should (supernote-view--cached-artifact 1))
    (setq supernote-test--log nil)
    (supernote-view-next-page)
    (should (= 1 supernote-view--page))
    ;; No `render' for the page being entered: it was already in hand.  The one
    ;; call that does happen is the next page being fetched ahead.
    (should (equal '("render") supernote-test--log))
    (should-not supernote-view--status)
    (should-not (string-match-p "rendering page" (buffer-string)))
    (should (string-match-p " 2/5" (supernote-view--mode-line)))
    ;; And the render mode of the *entered* page is what is reported.
    (should (eq 'vector-ink supernote-view--render-mode))))

(ert-deftest supernote-view-test-uncached-page-still-shows-a-placeholder ()
  "A page that has not been rendered yet still says so while it renders."
  (supernote-test--with-viewer '(:defer t)
    (setq supernote-test--responses
          (list (cons "manifest" (list :status 0 :stderr ""
                                       :json (supernote-test--manifest)))))
    (supernote-test--flush)
    (supernote-view-goto-page 4)
    (should (string-match-p "rendering page 4" (buffer-string)))
    (should supernote-view--status)))

(ert-deftest supernote-view-test-prefetch-index-is-dropped-when-the-source-moves ()
  "Artifacts remembered for one revision are never shown for another."
  (let ((file (make-temp-file "supernote-prefetch" nil ".note")))
    (unwind-protect
        (progn
          (write-region "noteSN_FILE_VER_20260016 one" nil file nil 'silent)
          (supernote-test--with-viewer '(:prefetch 2)
            (setq supernote-view--source file)
            (supernote-view--forget-artifacts)
            (supernote-view--remember-artifact 1 (supernote-view--format)
                                               '((artifact . "/etc/hosts")
                                                 (render_mode . "vector-ink")))
            (should (supernote-view--cached-artifact 1))
            ;; The file changes underneath: every entry becomes untrustworthy.
            (set-file-times file (time-add (current-time) 120))
            (should-not (supernote-view--cached-artifact 1))))
      (delete-file file))))

(ert-deftest supernote-view-test-prefetch-is-yielded-to-the-visible-page ()
  "Turning to an unrendered page cancels speculative work first."
  (let (cancelled)
    (supernote-test--with-viewer '(:prefetch 2)
      (setq supernote-view--prefetch-queue '(3 4))
      (cl-letf (((symbol-function 'supernote-view--cancel)
                 (lambda (kind) (push kind cancelled))))
        (supernote-view-goto-page 4))
      (should (memq 'prefetch cancelled)))))

(ert-deftest supernote-view-test-navigation-boundaries ()
  "Navigation clamps at both ends instead of signalling."
  (supernote-test--with-viewer nil
    (supernote-view-previous-page)
    (should (= 0 supernote-view--page))
    (supernote-view-last-page)
    (should (= 4 supernote-view--page))
    (supernote-view-next-page)
    (should (= 4 supernote-view--page))
    (supernote-view-first-page)
    (should (= 0 supernote-view--page))
    ;; A count that overshoots lands on the last page rather than erroring.
    (supernote-view-next-page 99)
    (should (= 4 supernote-view--page))
    (supernote-view-goto-page 0)
    (should (= 0 supernote-view--page))))

(ert-deftest supernote-view-test-counts ()
  "A raw prefix argument is honoured as a repeat count."
  (supernote-test--with-viewer nil
    (supernote-view-next-page 3)
    (should (= 3 supernote-view--page))
    (supernote-view-previous-page 2)
    (should (= 1 supernote-view--page))
    ;; `G' with a count is a page number, not a repeat.
    (supernote-view-last-page 2)
    (should (= 1 supernote-view--page))
    (supernote-view-first-page 4)
    (should (= 3 supernote-view--page))))

(ert-deftest supernote-view-test-revert-preserves-and-clamps-page ()
  "A revert keeps the current page, or clamps it when the note shrank."
  (supernote-test--with-viewer nil
    (supernote-view-goto-page 4)
    (should (= 3 supernote-view--page))
    (supernote-view-revert)
    (should (= 3 supernote-view--page))
    (should-not (buffer-modified-p))
    ;; Now the note comes back with only two pages.
    (setq supernote-test--responses
          (list (cons "manifest"
                      (list :status 0 :stderr ""
                            :json (supernote-test--manifest
                                   '(page_count . 2)
                                   '(pages . (((page_index . 0) (display_page . 1))
                                              ((page_index . 1) (display_page . 2)))))))))
    (supernote-view-revert)
    (should (= 1 supernote-view--page))
    (should-not (buffer-modified-p))))


;;;; Generation tokens

(ert-deftest supernote-view-test-generation-token-drops-stale-render ()
  "A render answering for the current page but a past round is discarded.
The page guard is deliberately satisfied here, so only the generation token can
reject this callback -- delete that clause from the code and this test fails."
  (supernote-test--with-viewer '(:defer t)
    (setq supernote-test--responses
          (list (cons "manifest" (list :status 0 :stderr ""
                                       :json (supernote-test--manifest)))))
    (supernote-test--flush)
    (should (= 5 (supernote-view--page-count)))

    (supernote-view-goto-page 3)
    (let ((stale (car supernote-test--queue)))
      ;; A revert bumps the generation while leaving the page alone, so when
      ;; the in-flight answer arrives its page still matches.
      (supernote-view-revert)
      (supernote-test--flush)
      (should (= 2 supernote-view--page))
      (funcall (nth 2 stale)
               (list :status 0 :stderr ""
                     :json '((artifact . "/nonexistent/stale.svg")
                             (render_mode . "vector-ink"))))
      (should-not (equal "/nonexistent/stale.svg" supernote-view--artifact)))))

(ert-deftest supernote-view-test-generation-token-drops-stale-manifest ()
  "A manifest answering for a past round never replaces the current one."
  (supernote-test--with-viewer '(:defer t)
    (setq supernote-test--responses
          (list (cons "manifest" (list :status 0 :stderr ""
                                       :json (supernote-test--manifest)))))
    (supernote-test--flush)
    (let ((stale-callback (nth 2 (car (last supernote-test--queue)))))
      (supernote-view-revert)
      (supernote-test--flush)
      ;; Deliver the first round's manifest, describing a different note.
      (funcall stale-callback
               (list :status 0 :stderr ""
                     :json (supernote-test--manifest '(page_count . 99))))
      (should (= 5 (supernote-view--page-count))))))

(ert-deftest supernote-view-test-adopts-already-rendered-pages ()
  "Pages the manifest says are rendered are usable without a helper call.
Page artifacts are keyed by the page's own content, so this is what survives an
edit elsewhere in the note -- and what keeps a sync from re-rendering."
  (let ((manifest (supernote-test--manifest)))
    ;; The helper reports, per page, the artifact it already holds and how that
    ;; page was rendered.
    (setf (alist-get 'pages manifest)
          (list `((page_index . 0) (display_page . 1)
                  (artifact . ,supernote-test--artifact) (render_mode . "raster-fallback"))
                `((page_index . 1) (display_page . 2)
                  (artifact . nil) (render_mode . nil))
                `((page_index . 2) (display_page . 3)
                  (artifact . ,supernote-test--artifact) (render_mode . "vector-ink"))
                '((page_index . 3) (display_page . 4))
                '((page_index . 4) (display_page . 5))))
    (supernote-test--with-viewer (list :manifest manifest)
      (should (supernote-view--cached-artifact 0))
      (should-not (supernote-view--cached-artifact 1))
      (should (supernote-view--cached-artifact 2))
      ;; Page 1 was adopted, so opening cost exactly one call: the manifest.
      (should (equal '("manifest") supernote-test--log))
      (should-not supernote-view--status)
      ;; The reported mode is used rather than assumed, so `R' is not shown as `V'.
      (should (eq 'raster-fallback supernote-view--render-mode))
      (should (string-match-p " R" (supernote-view--mode-line)))
      ;; Moving to another adopted page is free and reports its own mode.
      (setq supernote-test--log nil)
      (supernote-view-goto-page 3)
      (should (eq 'vector-ink supernote-view--render-mode))
      (should (string-match-p " V" (supernote-view--mode-line)))
      (should-not supernote-test--log)
      ;; A page nobody rendered still goes to the helper.
      (supernote-view-goto-page 2)
      (should (equal '("render") supernote-test--log)))))

(ert-deftest supernote-view-test-reload-keeps-the-page-on-screen ()
  "A reload does not blank the page, so no loading placeholder flashes.
A sync is the common reason to reload, and the replacement page is usually
already rendered, so throwing the current one away only produced a flicker."
  (supernote-test--with-viewer nil
    (should supernote-view--image)
    (let ((shown supernote-view--artifact))
      (setq supernote-test--defer t)
      (supernote-view-revert)
      ;; Nothing has come back yet: the page the reader was looking at is still
      ;; there, and the buffer says nothing about rendering.
      (should supernote-view--image)
      (should (equal shown supernote-view--artifact))
      (should-not (string-match-p "rendering page" (buffer-string)))
      (should-not (string-match-p "reading manifest" (buffer-string)))
      ;; The mode line is where the wait is admitted.
      (should (string-match-p " \\.\\.\\." (supernote-view--mode-line)))
      (setq supernote-test--defer nil)
      (supernote-test--flush)
      (should supernote-view--image)
      (should-not supernote-view--status))))

(ert-deftest supernote-view-test-failed-reload-still-reports ()
  "Keeping the page on screen must not hide a reload that failed."
  (supernote-test--with-viewer nil
    (should supernote-view--image)
    (setq supernote-test--responses
          (list (cons "manifest"
                      (list :status 4 :stderr ""
                            :json '((error . ((code . "E_PARSE")
                                              (message . "cannot parse note"))))))))
    (supernote-view-revert)
    (should supernote-view--error)
    (should-not supernote-view--image)
    (should (string-match-p "E_PARSE" (buffer-string)))))

(ert-deftest supernote-view-test-records-the-visited-file-modtime ()
  "Loading the manifest records the file's modification time.
Without it the buffer visits a file it never reads, so `auto-revert' sees a
buffer that can never be stale, and the viewer's own redisplay later trips
Emacs' \"really edit the buffer?\" supersession prompt."
  (let ((file (make-temp-file "supernote-modtime" nil ".note")))
    (unwind-protect
        (progn
          (write-region "noteSN_FILE_VER_20260016 body" nil file nil 'silent)
          (supernote-test--with-viewer nil
            (setq supernote-view--source file
                  buffer-file-name file)
            (supernote-view--load-manifest)
            (should-not (equal 0 (visited-file-modtime)))
            (should (verify-visited-file-modtime))
            ;; And it becomes honestly stale once the file really changes.
            (set-file-times file (time-add (current-time) 120))
            (should-not (verify-visited-file-modtime))
            (should (funcall (or buffer-stale-function
                                 #'buffer-stale--default-function)
                             t))))
      (delete-file file))))

(ert-deftest supernote-view-test-stale-source-is-detected ()
  "A changed source is noticed by a single stat, with no helper call."
  (let ((file (make-temp-file "supernote-stale" nil ".note")))
    (unwind-protect
        (progn
          (write-region "noteSN_FILE_VER_20260016 one" nil file nil 'silent)
          (supernote-test--with-viewer nil
            (setq supernote-view--source file)
            (supernote-view--forget-artifacts)
            (should-not (supernote-view--stale-p))
            (set-file-times file (time-add (current-time) 120))
            (should (supernote-view--stale-p))
            ;; And with no manifest yet there is nothing to be stale against.
            (let ((supernote-view--manifest nil))
              (should-not (supernote-view--stale-p)))))
      (delete-file file))))

(ert-deftest supernote-view-test-boundary-commands-notice-a-changed-note ()
  "`]]' at the last page reloads instead of reporting a boundary that moved.
The boundary test answers from `page_count' before anything renders, so a
staleness check inside the render path would never be consulted."
  (let ((file (make-temp-file "supernote-boundary" nil ".note")))
    (unwind-protect
        (progn
          (write-region "noteSN_FILE_VER_20260016 one" nil file nil 'silent)
          (supernote-test--with-viewer nil
            (setq supernote-view--source file)
            ;; Establish the baseline stat, as opening the note does.
            (supernote-view--load-manifest)
            (supernote-view-goto-page 5)
            (should (= 4 supernote-view--page))
            ;; The note grows to eight pages while nothing was looking.
            (setq supernote-test--responses
                  (list (cons "manifest"
                              (list :status 0 :stderr ""
                                    :json (supernote-test--manifest
                                           '(page_count . 8)
                                           (cons 'pages
                                                 (cl-loop for i from 0 below 8
                                                          collect `((page_index . ,i)
                                                                    (display_page . ,(1+ i))))))))))
            (set-file-times file (time-add (current-time) 120))
            (setq supernote-test--log nil)
            (supernote-view-next-page)
            ;; It reloaded rather than saying "last page" ...
            (should (member "manifest" supernote-test--log))
            (should (= 8 (supernote-view--page-count)))
            (should (= 4 supernote-view--page))
            ;; ... and the pages the note gained are now reachable.
            (supernote-view-next-page)
            (should (= 5 supernote-view--page))))
      (delete-file file))))

(ert-deftest supernote-view-test-previous-page-notices-a-shrunken-note ()
  "`[[' past the new end reloads and clamps rather than rendering a gone page."
  (let ((file (make-temp-file "supernote-shrink" nil ".note")))
    (unwind-protect
        (progn
          (write-region "noteSN_FILE_VER_20260016 one" nil file nil 'silent)
          (supernote-test--with-viewer nil
            (setq supernote-view--source file)
            ;; Establish the baseline stat, as opening the note does.
            (supernote-view--load-manifest)
            (supernote-view-goto-page 5)
            (setq supernote-test--responses
                  (list (cons "manifest"
                              (list :status 0 :stderr ""
                                    :json (supernote-test--manifest
                                           '(page_count . 2)
                                           '(pages . (((page_index . 0) (display_page . 1))
                                                      ((page_index . 1) (display_page . 2)))))))))
            (set-file-times file (time-add (current-time) 120))
            (supernote-view-previous-page)
            (should (= 2 (supernote-view--page-count)))
            (should (= 1 supernote-view--page))
            (should-not supernote-view--error)))
      (delete-file file))))

(ert-deftest supernote-view-test-outline-notices-a-changed-note ()
  "`o' rebuilds from the current titles, not the ones the note used to have."
  (let ((file (make-temp-file "supernote-outline-sync" nil ".note")))
    (unwind-protect
        (progn
          (write-region "noteSN_FILE_VER_20260016 one" nil file nil 'silent)
          (supernote-test--with-viewer nil
            (setq supernote-view--source file)
            ;; Establish the baseline stat, as opening the note does.
            (supernote-view--load-manifest)
            (should (zerop (length (alist-get 'outlines supernote-view--manifest))))
            (setq supernote-test--responses
                  (list (cons "manifest"
                              (list :status 0 :stderr ""
                                    :json (supernote-test--manifest
                                           (cons 'outlines (supernote-test--outlines)))))))
            (set-file-times file (time-add (current-time) 120))
            ;; `supernote-view-outline' selects the outline window, so the note
            ;; buffer has to be named explicitly to read its buffer-local
            ;; manifest afterwards.
            (let ((note (current-buffer)))
              (supernote-view-outline)
              (with-current-buffer note
                (should (= 3 (length (alist-get 'outlines supernote-view--manifest))))
                (with-current-buffer supernote-view--outline-buffer
                  (should (= 3 (length supernote-outline--entries))))))))
      (delete-file file))))

(ert-deftest supernote-view-test-watch-follows-the-buffer ()
  "A watch is placed on the note's directory and dropped with the buffer."
  (skip-unless (and (require 'filenotify nil t) file-notify--library))
  (let* ((directory (make-temp-file "supernote-watch" t))
         (file (expand-file-name "n.note" directory))
         watched buffer)
    (unwind-protect
        (progn
          (write-region "noteSN_FILE_VER_20260016 one" nil file nil 'silent)
          (cl-letf (((symbol-function 'supernote-view--run) #'supernote-test--run))
            (let ((supernote-test--queue nil) (supernote-test--log nil)
                  (supernote-test--defer nil)
                  (supernote-view-prefetch-count 0)
                  (supernote-view-prefetch-outline-pages 0)
                  (supernote-view-auto-sync t)
                  (supernote-test--responses
                   (list (cons "manifest" (list :status 0 :stderr ""
                                                :json (supernote-test--manifest))))))
              (setq buffer (generate-new-buffer "*supernote-watch-test*"))
              (with-current-buffer buffer
                (setq buffer-file-name file)
                (supernote-view-mode)
                (setq watched supernote-view--watch)
                ;; The watch is on the directory: Syncthing installs a new copy
                ;; with a rename, which would invalidate a watch on the file.
                (should watched)
                (should (equal supernote-view--watch-directory
                               (file-name-directory file)))
                ;; Asking again keeps the watch it already has.
                (supernote-view--watch-source)
                (should (eq watched supernote-view--watch))))))
      (when (buffer-live-p buffer)
        (let ((kill-buffer-query-functions nil))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (ignore-errors (delete-directory directory t)))
    ;; Killing the buffer took the watch with it.
    (should-not (and watched (ignore-errors (file-notify-valid-p watched))))))

(ert-deftest supernote-view-test-offscreen-change-waits-to-be-looked-at ()
  "The watcher leaves a buried note alone; using it again reloads it."
  (let ((file (make-temp-file "supernote-offscreen" nil ".note"))
        (reloads 0))
    (unwind-protect
        (progn
          (write-region "noteSN_FILE_VER_20260016 one" nil file nil 'silent)
          (supernote-test--with-viewer nil
            (setq supernote-view--source file)
            ;; Establish the baseline stat, as opening the note does.
            (supernote-view--load-manifest)
            (advice-add 'supernote-view-revert :before
                        (lambda (&rest _) (setq reloads (1+ reloads)))
                        '((name . supernote-test-count)))
            (unwind-protect
                (progn
                  (set-file-times file (time-add (current-time) 120))
                  ;; Not displayed anywhere, so nothing happens yet.
                  (should-not (get-buffer-window (current-buffer) t))
                  (supernote-view--sync-if-changed (current-buffer))
                  (should (= 0 reloads))
                  ;; The stale check is what picks it up on the next use.
                  (should (supernote-view--stale-p))
                  (should (supernote-view--ensure-fresh))
                  (should-not (supernote-view--stale-p)))
              (advice-remove 'supernote-view-revert 'supernote-test-count))))
      (delete-file file))))

(ert-deftest supernote-view-test-render-drops-answer-for-a-moved-source ()
  "An image rendered from a revision the manifest no longer describes is refused.
SPEC section 9.2 step 5 and section 10: never show a stale page as though it
were the new file."
  (let ((file (make-temp-file "supernote-moved" nil ".note"))
        (reloads 0))
    (unwind-protect
        (progn
          (write-region "noteSN_FILE_VER_20260016 first" nil file nil 'silent)
          (supernote-test--with-viewer '(:defer t)
            (setq supernote-view--source file)
            (setq supernote-test--responses
                  (list (cons "manifest"
                              (list :status 0 :stderr ""
                                    :json (supernote-test--manifest)))))
            (supernote-test--flush)
            (setq reloads (cl-count "manifest" supernote-test--log :test #'equal))
            (should (= 1 reloads))
            (let ((stale (car supernote-test--queue)))
              ;; Syncthing replaces the file while the render is in flight.
              (write-region "noteSN_FILE_VER_20260016 second revision" nil file nil 'silent)
              (set-file-times file (time-add (current-time) 120))
              (funcall (nth 2 stale)
                       (list :status 0 :stderr ""
                             :json '((artifact . "/nonexistent/other-revision.svg")
                                     (render_mode . "vector-ink"))))
              (should-not (equal "/nonexistent/other-revision.svg" supernote-view--artifact))
              ;; And it reloads rather than sitting on a stale manifest.
              (should (= 2 (cl-count "manifest" supernote-test--log :test #'equal))))))
      (delete-file file))))

(ert-deftest supernote-view-test-cancelled-jobs-reclaim-their-buffers ()
  "Cancelling a job kills the hidden buffers its sentinel would have.
Silencing the sentinel is what makes the answer obsolete, but the sentinel also
owns the cleanup, so without an explicit reclaim every superseded render would
leak a permanent pair of buffers."
  (skip-unless (supernote-view--node))
  (with-temp-buffer
    (setq supernote-view--source "/tmp/nonexistent.note")
    (let ((before (length (buffer-list))))
      ;; `sleep' stands in for a helper that has not answered yet.
      (cl-letf (((symbol-function 'supernote-view--node) (lambda () (executable-find "sleep")))
                ((symbol-function 'file-readable-p) (lambda (&rest _) t)))
        (let ((supernote-view-helper "30"))
          (supernote-view--run 'page nil #'ignore)
          (supernote-view--run 'manifest nil #'ignore)))
      (should (= 2 (length supernote-view--jobs)))
      (should (> (length (buffer-list)) before))
      (supernote-view--cancel-all)
      (should-not supernote-view--jobs)
      (should-not (cl-find-if (lambda (buffer)
                                (string-prefix-p " *supernote-render"
                                                 (buffer-name buffer)))
                              (buffer-list)))
      (should (= before (length (buffer-list)))))))

(ert-deftest supernote-view-test-oversized-response-is-refused ()
  "A helper answering with more JSON than the cap is reported, not parsed."
  (skip-unless (supernote-view--node))
  (let ((result nil))
    (with-temp-buffer
      (setq supernote-view--source "/tmp/nonexistent.note")
      (let ((supernote-view-max-response 4096)
            (supernote-view-helper "-e")
            (node (supernote-view--node)))
        (cl-letf (((symbol-function 'file-readable-p) (lambda (&rest _) t)))
          (supernote-view--run
           'page
           (list "process.stdout.write('x'.repeat(200000))")
           (lambda (r) (setq result r)))
          (with-timeout (30 (ert-fail "the helper did not finish"))
            (while (null result) (accept-process-output nil 0.05)))
          (should node)))
      (should (plist-get result :stderr))
      (should (string-match-p "more than" (plist-get result :stderr)))
      (should-not (plist-get result :json))
      ;; And it surfaces as an ordinary, actionable failure rather than being
      ;; mistaken for a valid but empty answer.
      (let ((failure (supernote-view--result-error result)))
        (should failure)
        (should (equal "E_RESPONSE" (plist-get failure :code)))))))

(ert-deftest supernote-view-test-clean-exit-without-json-is-a-failure ()
  "A helper that exits 0 having written nothing usable is not a success."
  (should-not (supernote-view--result-error
               (list :status 0 :json '((page_count . 1)) :stderr "")))
  (let ((failure (supernote-view--result-error (list :status 0 :json nil :stderr "killed"))))
    (should failure)
    (should (equal "E_RESPONSE" (plist-get failure :code)))))

(ert-deftest supernote-view-test-scrolling-is-set-up-for-an-image-buffer ()
  "The viewer opts out of the text-scrolling defaults that fight an image.
`auto-hscroll-mode' is the load-bearing one: point never leaves (point-min), so
with it on, redisplay drags a sideways-scrolled page back to column 0."
  (supernote-test--with-viewer nil
    (should-not auto-hscroll-mode)
    (should (local-variable-p 'auto-hscroll-mode))
    (should (equal 0 scroll-conservatively))
    ;; The wheel and touchpad reach the page-aware commands, not `scroll-up'.
    (should (eq #'supernote-view-scroll-up-or-next-page mwheel-scroll-up-function))
    (should (eq #'supernote-view-scroll-down-or-previous-page mwheel-scroll-down-function))
    (should (eq #'supernote-view--wheel-scroll-left mwheel-scroll-left-function))
    (should (eq #'supernote-view--wheel-scroll-right mwheel-scroll-right-function))
    (dolist (variable '(mwheel-scroll-up-function mwheel-scroll-down-function
                        mwheel-scroll-left-function mwheel-scroll-right-function))
      (should (local-variable-p variable)))
    (should mwheel-coalesce-scroll-events)))

(ert-deftest supernote-view-test-wheel-crosses-pages-like-the-keyboard ()
  "A wheel event turns the page at the boundary, as `SPC' does.
`mwheel-scroll' hands its function a line count, and calls it with no argument
at all when scrolling to the end, so both shapes have to work."
  (supernote-test--with-viewer nil
    (set-window-buffer (selected-window) (current-buffer))
    (should (= 0 supernote-view--page))
    ;; A page sized to fit cannot scroll, so one gesture is one page.
    (funcall mwheel-scroll-up-function 3)
    (should (= 1 supernote-view--page))
    (funcall mwheel-scroll-down-function 3)
    (should (= 0 supernote-view--page))
    ;; Called with no argument, the way mwheel does when it scrolls to the end.
    (should-not (condition-case error
                    (progn (funcall mwheel-scroll-up-function) nil)
                  (error error)))
    ;; Horizontal wheeling never signals, even on a page with no image yet.
    (setq supernote-view--image nil)
    (dolist (wheel (list mwheel-scroll-left-function mwheel-scroll-right-function))
      (should-not (condition-case error
                      (progn (funcall wheel 2) (funcall wheel) nil)
                    (error error))))))

(ert-deftest supernote-view-test-pixel-scroll-is-disabled-locally ()
  "Pixel-precision scrolling is taken out of this buffer, not out of Emacs."
  (let ((pixel-scroll-precision-mode t))
    (supernote-test--with-viewer nil
      (should-not pixel-scroll-precision-mode)
      (should (local-variable-p 'pixel-scroll-precision-mode))))
  ;; And the global setting is left exactly as it was found.
  (let ((pixel-scroll-precision-mode nil))
    (supernote-test--with-viewer nil
      (should-not (local-variable-p 'pixel-scroll-precision-mode)))))

(ert-deftest supernote-view-test-image-commands-ignore-a-placeholder ()
  "Horizontal motions no-op while the buffer holds text rather than an image.
`image-forward-hscroll' and `image-eol' signal `Invalid image specification'
when asked to measure a buffer with no image, and the buffer holds a
placeholder on every page turn and an error screen after every failure."
  ;; Deferred, so the render never lands and the buffer keeps its placeholder.
  (supernote-test--with-viewer '(:defer t)
    (set-window-buffer (selected-window) (current-buffer))
    (should-not supernote-view--image)
    (dolist (command (list #'supernote-view-scroll-left
                           #'supernote-view-scroll-right
                           #'supernote-view-beginning-of-line
                           #'supernote-view-end-of-line))
      (should-not (condition-case error (progn (funcall command) nil)
                    (error error))))
    ;; And a scroll must not read "cannot move" as "at the page edge" and turn
    ;; the page while only a placeholder is on screen.
    (setq supernote-test--responses
          (list (cons "manifest" (list :status 0 :stderr ""
                                       :json (supernote-test--manifest)))))
    (supernote-test--flush)
    (setq supernote-view--image nil)
    (let ((page supernote-view--page))
      (supernote-view-next-line-or-next-page)
      (supernote-view-scroll-up-or-next-page)
      (should (= page supernote-view--page)))))

(ert-deftest supernote-view-test-outline-movement-stops-on-real-entries ()
  "Outline motions never land on the blank trailing line or signal."
  (supernote-test--with-viewer
      (list :manifest (supernote-test--manifest
                       (cons 'outlines (supernote-test--outlines))))
    (with-current-buffer (supernote-view--outline-noselect)
      (supernote-outline-last-entry)
      (should (supernote-outline--entry-at-point))
      ;; Past the end: point stays on the last entry rather than the blank line
      ;; after it, so RET still has something to follow.
      (supernote-outline-next-entry)
      (should (supernote-outline--entry-at-point))
      (should (= 3 (line-number-at-pos)))
      (supernote-outline-first-entry)
      (supernote-outline-previous-entry)
      (should (supernote-outline--entry-at-point))
      (should (= 1 (line-number-at-pos)))
      ;; Same-level motion signals a bare `error' in outline.el at the ends.
      (supernote-outline-last-entry)
      (dolist (command (list #'supernote-outline-forward-same-level
                             #'supernote-outline-backward-same-level
                             #'supernote-outline-up-heading))
        (should-not (condition-case error (progn (funcall command) nil)
                      (error error)))
        (should (supernote-outline--entry-at-point))))))

(ert-deftest supernote-view-test-cancels-obsolete-processes ()
  "A superseded request is killed rather than left to finish."
  (with-temp-buffer
    (let* ((sleeper (lambda ()
                      (make-process :name "supernote-test-sleep" :noquery t
                                    :command (list "sleep" "30"))))
           (first (funcall sleeper))
           (second (funcall sleeper)))
      (setq supernote-view--jobs (list (cons 'page first) (cons 'manifest second)))
      (supernote-view--cancel 'page)
      (should-not (process-live-p first))
      (should (process-live-p second))
      (should-not (alist-get 'page supernote-view--jobs))
      (supernote-view--cancel-all)
      (should-not (process-live-p second))
      (should-not supernote-view--jobs)
      ;; Cancelling nothing is not an error.
      (should-not (supernote-view--cancel 'page)))))


;;;; Read-only guarantees

(ert-deftest supernote-view-test-buffer-is-read-only-and-refuses-saves ()
  "The viewer never reports itself modified and refuses every save."
  (supernote-test--with-viewer nil
    (should buffer-read-only)
    (should-not (buffer-modified-p))
    (should (memq #'supernote-view--refuse-save write-contents-functions))
    (should-error (supernote-view--refuse-save) :type 'user-error)
    ;; `save-buffer' must not reach the filesystem either.
    (set-buffer-modified-p t)
    (should-error (save-buffer) :type 'user-error)))

(ert-deftest supernote-view-test-binary-contents-are-discarded ()
  "Bytes inserted by an ordinary `find-file' never survive mode activation."
  (let ((file (make-temp-file "supernote-test" nil ".note")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "noteSN_FILE_VER_20260016\0\0\0binary junk"))
          (cl-letf (((symbol-function 'supernote-view--run)
                     (lambda (&rest _) nil)))
            (let ((buffer (find-file-noselect file)))
              (unwind-protect
                  (with-current-buffer buffer
                    (should (derived-mode-p 'supernote-view-mode))
                    ;; The buffer holds the viewer's own placeholder, and not
                    ;; one byte of what `insert-file-contents' put there.
                    (should-not (string-match-p "binary junk" (buffer-string)))
                    (should-not (string-search "\0" (buffer-string)))
                    (should-not (buffer-modified-p)))
                (let ((kill-buffer-query-functions nil))
                  (with-current-buffer buffer (set-buffer-modified-p nil))
                  (kill-buffer buffer))))))
      (delete-file file))))


;;;; Errors

(ert-deftest supernote-view-test-helper-error-is-actionable ()
  "A missing helper is reported in the buffer with a repair command."
  (supernote-test--with-viewer
      (list :responses
            (list (cons "manifest"
                        (list :status -1 :json nil
                              :stderr "cannot read the helper at /nope"))))
    (should supernote-view--error)
    (let ((text (buffer-string)))
      (should (string-match-p "E_HELPER" text))
      (should (string-match-p (regexp-quote supernote-view-helper) text))
      (should (string-match-p "npm ci --prefix" text))
      (should (string-match-p "Press `r' to retry" text)))
    (should (string-match-p " !" (supernote-view--mode-line)))

    ;; `r' recovers once the helper works again.
    (setq supernote-test--responses
          (list (cons "manifest" (list :status 0 :stderr ""
                                       :json (supernote-test--manifest)))))
    (supernote-view-refresh)
    (should-not supernote-view--error)
    (should (= 5 (supernote-view--page-count)))))

(ert-deftest supernote-view-test-unknown-signature-names-the-fix ()
  "An unsupported file version explains what to update."
  (supernote-test--with-viewer
      (list :responses
            (list (cons "manifest"
                        (list :status 4 :stderr ""
                              :json '((error . ((code . "E_SIGNATURE")
                                                (message . "unrecognized signature"))))))))
    (should (string-match-p "signature" (buffer-string)))
    (should (string-match-p "pinned" (buffer-string)))))

(ert-deftest supernote-view-test-render-out-of-range-reloads-manifest ()
  "A page that vanished under us reloads the manifest and then renders."
  (let ((renders 0))
    (supernote-test--with-viewer
        (list :responses
              (list (cons "manifest"
                          (list :status 0 :stderr ""
                                :json (supernote-test--manifest
                                       '(page_count . 2)
                                       '(pages . (((page_index . 0) (display_page . 1))
                                                  ((page_index . 1) (display_page . 2)))))))
                    ;; The note shrank between the manifest and the render, so
                    ;; the first render is out of range and the retry is not.
                    (cons "render"
                          (lambda ()
                            (setq renders (1+ renders))
                            (if (= renders 1)
                                (list :status 8 :stderr ""
                                      :json '((error . ((code . "E_PAGE_RANGE")
                                                        (message . "out of range")))))
                              (list :status 0 :stderr ""
                                    :json '((artifact . "/nonexistent/page.svg")
                                            (render_mode . "vector-ink"))))))))
      (should (= 2 renders))
      (should (= 2 (supernote-view--page-count)))
      (should-not supernote-view--error)
      (should (eq 'vector-ink supernote-view--render-mode)))))

(ert-deftest supernote-view-test-render-out-of-range-does-not-spin ()
  "A helper stuck on `E_PAGE_RANGE' reports it instead of looping forever."
  (supernote-test--with-viewer
      (list :responses
            (list (cons "manifest" (list :status 0 :stderr ""
                                         :json (supernote-test--manifest)))
                  (cons "render"
                        (list :status 8 :stderr ""
                              :json '((error . ((code . "E_PAGE_RANGE")
                                                (message . "out of range"))))))))
    ;; Reaching here at all is the assertion: without the one-shot guard the
    ;; reload would start another failing render and recurse until the stack
    ;; gave out.  Exactly one reload is attempted, then the failure surfaces.
    (should (equal "E_PAGE_RANGE" (plist-get supernote-view--error :code)))
    (should (= 2 (cl-count "manifest" supernote-test--log :test #'equal)))
    (should (= 2 (cl-count "render" supernote-test--log :test #'equal)))))


;;;; Outline

(ert-deftest supernote-view-test-outline-indentation-and-levels ()
  "Indentation and `outline-level' follow the stored title level."
  (supernote-test--with-viewer
      (list :manifest (supernote-test--manifest
                       (cons 'outlines (supernote-test--outlines))))
    (let ((outline (supernote-view--outline-noselect)))
      (with-current-buffer outline
        (should (derived-mode-p 'supernote-outline-mode))
        (goto-char (point-min))
        (should (equal "" (progn (looking-at outline-regexp) (match-string 1))))
        (should (= 1 (funcall outline-level)))
        (forward-line 1)
        (should (looking-at "  \\[L2\\]"))
        (should (progn (looking-at outline-regexp) (= 2 (funcall outline-level))))
        (forward-line 1)
        (should (looking-at "    \\[L3\\]"))
        (should (progn (looking-at outline-regexp) (= 3 (funcall outline-level))))
        ;; Each line carries its own entry, wherever point lands on it.
        (goto-char (point-min))
        (should (equal "TITLE_000102700138"
                       (alist-get 'id (supernote-outline--entry-at-point))))))))

(ert-deftest supernote-view-test-outline-movement ()
  "Movement commands walk visible entries, levels and parents."
  (supernote-test--with-viewer
      (list :manifest (supernote-test--manifest
                       (cons 'outlines (supernote-test--outlines))))
    (with-current-buffer (supernote-view--outline-noselect)
      (supernote-outline-first-entry)
      (should (= 1 (line-number-at-pos)))
      (supernote-outline-next-entry)
      (should (= 2 (line-number-at-pos)))
      (supernote-outline-next-entry)
      (should (= 3 (line-number-at-pos)))
      (supernote-outline-previous-entry)
      (should (= 2 (line-number-at-pos)))
      (supernote-outline-last-entry)
      (should (= 3 (line-number-at-pos)))
      ;; From the level-3 entry, the parent is the level-2 one.
      (supernote-outline-up-heading)
      (should (= 2 (line-number-at-pos)))
      ;; Point rests on the entry text, not in the indentation.
      (should (> (current-column) 0)))))

(ert-deftest supernote-view-test-outline-move-to-current-page ()
  "`.' lands on the first entry at or after the page being shown."
  (supernote-test--with-viewer
      (list :manifest (supernote-test--manifest
                       (cons 'outlines (supernote-test--outlines))))
    (let ((note (current-buffer))
          (outline (supernote-view--outline-noselect)))
      (with-current-buffer note (supernote-view-goto-page 2))
      (with-current-buffer outline
        (supernote-outline-move-to-current-page)
        ;; Titles sit on pages 1, 2 and 4; page 2 is an exact hit.
        (should (equal "TITLE_000205000100"
                       (alist-get 'id (supernote-outline--entry-at-point)))))
      (with-current-buffer note (supernote-view-goto-page 3))
      (with-current-buffer outline
        (supernote-outline-move-to-current-page)
        ;; Nothing on page 3, so it overshoots to the next entry.
        (should (equal "TITLE_000407000200"
                       (alist-get 'id (supernote-outline--entry-at-point)))))
      (with-current-buffer note (supernote-view-goto-page 5))
      (with-current-buffer outline
        (supernote-outline-move-to-current-page)
        ;; Past every title: stay on the last one rather than falling off.
        (should (equal "TITLE_000407000200"
                       (alist-get 'id (supernote-outline--entry-at-point))))))))

(ert-deftest supernote-view-test-outline-follow-and-display ()
  "RET moves the note and selects it; SPC moves it and stays put."
  (supernote-test--with-viewer
      (list :manifest (supernote-test--manifest
                       (cons 'outlines (supernote-test--outlines))))
    (let* ((note (current-buffer))
           (outline (supernote-view--outline-noselect)))
      (set-window-buffer (selected-window) note)
      (let ((outline-window (display-buffer outline '(nil (inhibit-same-window . t)))))
        (select-window outline-window)
        (goto-char (point-min))
        (supernote-outline-last-entry)
        ;; SPC: the note turns to page 4 and the outline keeps the selection.
        (supernote-outline-display)
        (should (= 3 (with-current-buffer note supernote-view--page)))
        (should (eq outline-window (selected-window)))
        ;; RET: same page, but the note window becomes selected.
        (select-window outline-window)
        (supernote-outline-first-entry)
        (supernote-outline-follow)
        (should (= 0 (with-current-buffer note supernote-view--page)))
        (should (eq note (window-buffer (selected-window))))
        ;; `o' selects the note without touching its page.
        (select-window outline-window)
        (supernote-outline-last-entry)
        (supernote-outline-select-note-window)
        (should (eq note (window-buffer (selected-window))))
        (should (= 0 (with-current-buffer note supernote-view--page)))))))

(ert-deftest supernote-view-test-outline-follow-and-quit ()
  "M-RET turns the page and buries the outline window."
  (supernote-test--with-viewer
      (list :manifest (supernote-test--manifest
                       (cons 'outlines (supernote-test--outlines))))
    (let* ((note (current-buffer))
           (outline (supernote-view--outline-noselect)))
      (set-window-buffer (selected-window) note)
      (let ((outline-window (display-buffer outline '(nil (inhibit-same-window . t)))))
        (select-window outline-window)
        (supernote-outline-last-entry)
        (supernote-outline-follow-and-quit)
        (should (= 3 (with-current-buffer note supernote-view--page)))
        (should-not (get-buffer-window outline))))))

(ert-deftest supernote-view-test-outline-refuses-empty-line ()
  "Following where there is no entry reports it instead of burying the outline."
  (supernote-test--with-viewer
      (list :manifest (supernote-test--manifest
                       (cons 'outlines (supernote-test--outlines))))
    (with-current-buffer (supernote-view--outline-noselect)
      (goto-char (point-max))
      (let ((inhibit-read-only t)) (insert "\n"))
      (goto-char (point-max))
      (should-error (supernote-outline-follow-and-quit) :type 'user-error))))

(ert-deftest supernote-view-test-outline-without-titles ()
  "A note with no titles gets an explanatory buffer, not an error."
  (supernote-test--with-viewer nil
    (let ((outline (supernote-view--outline-noselect)))
      (should (buffer-live-p outline))
      (with-current-buffer outline
        (should (derived-mode-p 'supernote-outline-mode))
        (should (string-match-p "no title entries" (buffer-string)))
        (should (zerop (length supernote-outline--entries)))
        ;; Movement on an empty outline must not signal either.
        (should-not (condition-case error
                        (progn (supernote-outline-next-entry)
                               (supernote-outline-previous-entry)
                               nil)
                      (error error)))))))

(ert-deftest supernote-view-test-outline-thumbnail-generation ()
  "A thumbnail arriving after a refill is dropped, not drawn on the wrong row."
  (supernote-test--with-viewer
      (list :manifest (supernote-test--manifest
                       (cons 'outlines (supernote-test--outlines))))
    (let* ((note (current-buffer))
           (outline (supernote-view--outline-noselect))
           (png (make-temp-file "supernote-thumb" nil ".png"))
           marker stale)
      (unwind-protect
          (progn
            (with-current-buffer outline
              (setq marker (copy-marker (point-min))
                    stale supernote-outline--generation))
            ;; The manifest reloads with different titles while the
            ;; thumbnail is still in flight, so the outline really is rebuilt.
            (with-current-buffer note
              (setf (alist-get 'outlines supernote-view--manifest)
                    (list (car (supernote-test--outlines))))
              (supernote-view--refresh-outline))
            (with-current-buffer outline
              (should (/= stale supernote-outline--generation))
              (let ((before (buffer-string)))
                (supernote-outline--insert-thumbnail outline stale marker png)
                (should (equal before (buffer-string))))
              ;; The current generation is still accepted.
              (supernote-outline--insert-thumbnail
               outline supernote-outline--generation marker png)
              (should (get-text-property (point-min) 'display))))
        (delete-file png)))))

(ert-deftest supernote-view-test-pending-scroll-does-not-leak ()
  "A pending scroll intent never survives into an unrelated page."
  (supernote-test--with-viewer nil
    (setq supernote-view--pending-scroll (list :bottom t :hscroll 7))
    (supernote-view-goto-page 3)
    (should-not supernote-view--pending-scroll)
    ;; A failed render clears it too, so the next page starts at the top.
    (setq supernote-view--pending-scroll (list :bottom t))
    (supernote-view--fail (list :code "E_RENDER" :message "boom"))
    (should-not supernote-view--pending-scroll)))

(ert-deftest supernote-view-test-fit-preserves-the-other-axis ()
  "Fitting one dimension resets only that axis, and zoom resets neither.
`W' must not throw the reader back to the top of a page they had scrolled."
  (let (applied)
    (cl-letf (((symbol-function 'supernote-view--apply-scroll)
               (lambda (v h b) (push (list v h b) applied))))
      (supernote-test--with-viewer nil
        (supernote-view-fit-width)
        (should (equal '(nil 0 nil) (car applied)))
        (supernote-view-fit-height)
        (should (equal '(0 nil nil) (car applied)))
        (supernote-view-fit-page)
        (should (equal '(0 0 nil) (car applied)))
        ;; Zoom leaves the reader where they were on both axes, so it hands
        ;; back the window's current position rather than resetting either.
        (setq applied nil)
        (cl-letf (((symbol-function 'window-vscroll) (lambda (&rest _) 5))
                  ((symbol-function 'window-hscroll) (lambda (&rest _) 7)))
          (supernote-view-enlarge))
        (should (equal '(5 7 nil) (car applied)))))))

(ert-deftest supernote-view-test-page-change-drops-the-old-artifact ()
  "Turning the page forgets the old artifact, so a zoom cannot redraw it."
  (supernote-test--with-viewer
      (list :responses
            (list (cons "manifest" (list :status 0 :stderr ""
                                         :json (supernote-test--manifest)))
                  (cons "render" (list :status 0 :stderr ""
                                       :json `((artifact . ,supernote-test--artifact)
                                               (render_mode . "vector-ink"))))))
    (should (equal supernote-test--artifact supernote-view--artifact))
    ;; With the answer withheld, nothing from the previous page may remain.
    (setq supernote-test--defer t)
    (supernote-view-goto-page 3)
    (should-not supernote-view--artifact)
    (should-not supernote-view--image)
    ;; A zoom in this state changes the size but redraws nothing.
    (supernote-view-enlarge)
    (should (numberp supernote-view--display-size))
    (should-not supernote-view--artifact)))

(ert-deftest supernote-view-test-outline-dies-with-its-note ()
  "Killing the note takes its outline buffer and its processes with it.
The harness is deliberately not the one doing the killing here: the note buffer
is killed inside the test so that `supernote-view--kill-buffer-hook' is what is
under observation."
  (let (note outline)
    (cl-letf (((symbol-function 'supernote-view--run) #'supernote-test--run))
      (let ((supernote-test--queue nil)
            (supernote-test--defer nil)
            (supernote-test--responses
             (list (cons "manifest"
                         (list :status 0 :stderr ""
                               :json (supernote-test--manifest
                                      (cons 'outlines (supernote-test--outlines))))))))
        (setq note (generate-new-buffer "*supernote-kill-test*"))
        (with-current-buffer note
          (setq buffer-file-name "/tmp/supernote-kill-test.note")
          (supernote-view-mode)
          (setq outline (supernote-view--outline-noselect)))
        (should (buffer-live-p outline))
        (let ((kill-buffer-query-functions nil))
          (with-current-buffer note (set-buffer-modified-p nil))
          (kill-buffer note))
        (should-not (buffer-live-p note))
        (should-not (buffer-live-p outline))))))

(ert-deftest supernote-view-test-outline-is-reused-when-unchanged ()
  "`o' on an unchanged note keeps point, folding and decoded thumbnails."
  (supernote-test--with-viewer
      (list :manifest (supernote-test--manifest
                       (cons 'outlines (supernote-test--outlines))))
    (let ((outline (supernote-view--outline-noselect)))
      (with-current-buffer outline
        (supernote-outline-last-entry)
        (let ((position (point))
              (generation supernote-outline--generation))
          ;; Re-opening, and a manifest reload that changes nothing, both reuse.
          (supernote-view--outline-noselect)
          (with-current-buffer (current-buffer)
            (should (= position (point)))
            (should (= generation supernote-outline--generation)))
          (with-current-buffer supernote-outline--note-buffer
            (supernote-view--refresh-outline))
          (should (= generation supernote-outline--generation))))
      ;; A manifest whose titles actually differ does rebuild.
      (with-current-buffer (current-buffer)
        (setf (alist-get 'outlines supernote-view--manifest)
              (list (car (supernote-test--outlines))))
        (supernote-view--refresh-outline))
      (with-current-buffer outline
        (should (= 1 (length supernote-outline--entries)))))))


;;;; Evil integration

(defun supernote-test--evil-p ()
  "Non-nil when Evil is available in this Emacs."
  (and (require 'evil nil t) (fboundp 'evil-define-key*)))

(defmacro supernote-test--with-evil-buffer (buffer &rest body)
  "Display BUFFER, turn Evil on in it, and run BODY there.
`execute-kbd-macro' acts on the selected window's buffer, and Evil only picks
up an auxiliary keymap after `evil-normalize-keymaps', so both are required."
  (declare (indent 1) (debug t))
  `(progn
     (set-window-buffer (selected-window) ,buffer)
     (with-current-buffer ,buffer
       (evil-local-mode 1)
       (evil-normalize-keymaps)
       (evil-normal-state)
       ,@body)))

(ert-deftest supernote-view-test-evil-initial-state ()
  "Both modes start in normal state and never expose an editing command."
  (skip-unless (supernote-test--evil-p))
  (supernote-view--evil-setup)
  (should (memq 'supernote-view-mode evil-normal-state-modes))
  (should (memq 'supernote-outline-mode evil-normal-state-modes))
  ;; Insert-state entry points are neutralised in both maps.
  (dolist (map (list supernote-view-mode-map supernote-outline-mode-map))
    (let ((aux (evil-get-auxiliary-keymap map 'normal)))
      (should (eq #'ignore (lookup-key aux (vector 'remap 'evil-insert))))
      (should (eq #'ignore (lookup-key aux (vector 'remap 'evil-open-below)))))))

(ert-deftest supernote-view-test-evil-key-lookup ()
  "The normal-state tables from the specification are installed."
  (skip-unless (supernote-test--evil-p))
  (supernote-view--evil-setup)
  (let ((aux (evil-get-auxiliary-keymap supernote-view-mode-map 'normal)))
    (dolist (pair '(("j" . supernote-view-next-line-or-next-page)
                    ("k" . supernote-view-previous-line-or-previous-page)
                    ("]]" . supernote-view-next-page)
                    ("[[" . supernote-view-previous-page)
                    ("gj" . supernote-view-next-page)
                    ("gk" . supernote-view-previous-page)
                    ("gg" . supernote-view-first-page)
                    ("G" . supernote-view-last-page)
                    ("gr" . supernote-view-refresh)
                    ("W" . supernote-view-fit-width)
                    ("H" . supernote-view-fit-height)
                    ("P" . supernote-view-fit-page)
                    ("zi" . supernote-view-enlarge)
                    ("zo" . supernote-view-shrink)
                    ("z0" . supernote-view-scale-reset)
                    ("0" . supernote-view-scale-reset)
                    ("o" . supernote-view-outline)
                    ;; Documented by `C-h m' through the ordinary map, so they
                    ;; must not fall through to Evil's shift operators.
                    ("<" . supernote-view-first-page)
                    (">" . supernote-view-last-page)
                    ("h" . supernote-view-scroll-left)
                    ("l" . supernote-view-scroll-right)
                    ("q" . supernote-view-quit)
                    ("ZQ" . supernote-view-kill)
                    ("ZZ" . supernote-view-quit)))
      (should (eq (cdr pair) (lookup-key aux (kbd (car pair)))))))
  (let ((aux (evil-get-auxiliary-keymap supernote-outline-mode-map 'normal)))
    (dolist (pair '(("j" . supernote-outline-next-entry)
                    ("k" . supernote-outline-previous-entry)
                    ("gj" . supernote-outline-forward-same-level)
                    ("gk" . supernote-outline-backward-same-level)
                    ("gg" . supernote-outline-first-entry)
                    ("G" . supernote-outline-last-entry)
                    ("h" . supernote-outline-up-heading)
                    ("l" . supernote-outline-toggle-children)
                    ("RET" . supernote-outline-follow)
                    ("go" . supernote-outline-display)
                    ("SPC" . supernote-outline-display)
                    ("o" . supernote-outline-select-note-window)
                    ("." . supernote-outline-move-to-current-page)
                    ("M-RET" . supernote-outline-follow-and-quit)
                    (">" . supernote-outline-last-entry)
                    ("q" . quit-window)
                    ("ZQ" . quit-window)
                    ("ZZ" . supernote-outline-follow-and-quit)))
      (should (eq (cdr pair) (lookup-key aux (kbd (car pair))))))))

(ert-deftest supernote-view-test-evil-respects-scroll-preferences ()
  "`C-d'/`C-u' are bound only when this user wants Evil's half-page scroll.
Leaving `C-u' bound would take `universal-argument' away from someone who set
`evil-want-C-u-scroll' to nil, as this configuration does."
  (skip-unless (supernote-test--evil-p))
  (let ((supernote-view-mode-map (copy-keymap supernote-view-mode-map))
        (evil-want-C-u-scroll nil)
        (evil-want-C-d-scroll t))
    (supernote-view--evil-setup)
    (let ((aux (evil-get-auxiliary-keymap supernote-view-mode-map 'normal)))
      (should (eq #'supernote-view-scroll-half-up (lookup-key aux (kbd "C-d"))))
      (should-not (lookup-key aux (kbd "C-u")))))
  (let ((supernote-view-mode-map (copy-keymap supernote-view-mode-map))
        (evil-want-C-u-scroll t)
        (evil-want-C-d-scroll t))
    (supernote-view--evil-setup)
    (let ((aux (evil-get-auxiliary-keymap supernote-view-mode-map 'normal)))
      (should (eq #'supernote-view-scroll-half-down (lookup-key aux (kbd "C-u"))))))
  ;; Leave the real map as this session's settings want it.
  (supernote-view--evil-setup))

(ert-deftest supernote-view-test-evil-counts ()
  "Numeric counts reach the page commands and clamp at the boundaries."
  (skip-unless (supernote-test--evil-p))
  (supernote-view--evil-setup)
  (supernote-test--with-viewer nil
    (supernote-test--with-evil-buffer (current-buffer)
      (execute-kbd-macro (kbd "3 ] ]"))
      (should (= 3 supernote-view--page))
      (execute-kbd-macro (kbd "2 [ ["))
      (should (= 1 supernote-view--page))
      ;; `12G' is a page number, and 12 is past the end of a five-page note.
      (execute-kbd-macro (kbd "1 2 G"))
      (should (= 4 supernote-view--page))
      (execute-kbd-macro (kbd "g g"))
      (should (= 0 supernote-view--page))
      ;; A bare `]]' is one page, not twelve.
      (execute-kbd-macro (kbd "] ]"))
      (should (= 1 supernote-view--page))
      ;; `4gj' crosses four pages and stops at the last one.
      (execute-kbd-macro (kbd "4 g j"))
      (should (= 4 supernote-view--page))
      (execute-kbd-macro (kbd "] ]"))
      (should (= 4 supernote-view--page)))))

(ert-deftest supernote-view-test-evil-zero-is-both-digit-and-zoom-reset ()
  "Binding `0' to zoom reset must not break a count that contains a zero.
While a count is being read, Emacs' own `universal-argument' transient map
outranks the mode's normal-state map, so `10G' is ten and `0' on its own is
still the zoom command.  Both halves are asserted because binding `0' at all
is what makes this worth checking."
  (skip-unless (supernote-test--evil-p))
  (supernote-view--evil-setup)
  (let ((wide (supernote-test--manifest
               '(page_count . 30)
               (cons 'pages (cl-loop for i from 0 below 30
                                     collect `((page_index . ,i)
                                               (display_page . ,(1+ i))))))))
    (supernote-test--with-viewer (list :manifest wide)
      (supernote-test--with-evil-buffer (current-buffer)
        (execute-kbd-macro (kbd "1 0 G"))
        (should (= 9 supernote-view--page))
        (execute-kbd-macro (kbd "2 0 G"))
        (should (= 19 supernote-view--page))
        (execute-kbd-macro (kbd "1 2 G"))
        (should (= 11 supernote-view--page))
        ;; No count in progress: `0' is the zoom command again.
        (setq supernote-view--display-size 'fit-width)
        (execute-kbd-macro (kbd "0"))
        (should (equal 1.0 supernote-view--display-size))
        (should (= 11 supernote-view--page))))))

(ert-deftest supernote-view-test-evil-outline-counts ()
  "Counts reach the outline movement commands too."
  (skip-unless (supernote-test--evil-p))
  (supernote-view--evil-setup)
  (supernote-test--with-viewer
      (list :manifest (supernote-test--manifest
                       (cons 'outlines (supernote-test--outlines))))
    (let ((outline (supernote-view--outline-noselect)))
      (supernote-test--with-evil-buffer outline
        (goto-char (point-min))
        (execute-kbd-macro (kbd "2 j"))
        (should (= 3 (line-number-at-pos)))
        (execute-kbd-macro (kbd "g g"))
        (should (= 1 (line-number-at-pos)))
        (execute-kbd-macro (kbd "G"))
        (should (= 3 (line-number-at-pos)))))))

(ert-deftest supernote-view-test-works-without-evil ()
  "Both modes are complete through their ordinary maps.
This is the guarantee for an Emacs with no Evil at all; the assertions here
never touch an Evil symbol."
  (supernote-test--with-viewer nil
    (should (eq #'supernote-view-next-page
                (lookup-key supernote-view-mode-map (kbd "n"))))
    (should (eq #'supernote-view-previous-page
                (lookup-key supernote-view-mode-map (kbd "p"))))
    (should (eq #'supernote-view-outline
                (lookup-key supernote-view-mode-map (kbd "o"))))
    (should (eq #'supernote-view-refresh
                (lookup-key supernote-view-mode-map (kbd "r"))))
    (should (eq #'supernote-view-fit-width
                (lookup-key supernote-view-mode-map (kbd "W"))))
    (should (eq #'supernote-view-goto-page
                (lookup-key supernote-view-mode-map (kbd "M-g g"))))
    ;; And the commands themselves work when invoked directly.
    (call-interactively #'supernote-view-last-page)
    (should (= 4 supernote-view--page)))
  (with-temp-buffer
    (supernote-outline-mode)
    (should (eq #'supernote-outline-follow
                (lookup-key supernote-outline-mode-map (kbd "RET"))))
    (should (eq #'supernote-outline-display
                (lookup-key supernote-outline-mode-map (kbd "SPC"))))
    (should (eq #'supernote-outline-move-to-current-page
                (lookup-key supernote-outline-mode-map (kbd "."))))
    (should (eq #'quit-window
                (lookup-key supernote-outline-mode-map (kbd "q"))))))


;;;; The real process contract

(defun supernote-test--fixture ()
  "Read-only reference note specified by SUPERNOTE_TEST_NOTE, or nil."
  (let ((file (getenv "SUPERNOTE_TEST_NOTE")))
    (and file (file-readable-p file) file)))

(defun supernote-test--helper-ready-p ()
  "Non-nil when the Node helper can actually run."
  (and (supernote-view--node)
       (file-readable-p supernote-view-helper)
       (supernote-test--fixture)))

(ert-deftest supernote-view-test-real-manifest-and-render ()
  "The mode drives the real helper end to end and never touches the source."
  (skip-unless (supernote-test--helper-ready-p))
  (let* ((file (supernote-test--fixture))
         (before (file-attributes file))
         (cache (make-temp-file "supernote-ert-cache" t))
         (supernote-view-cache-directory cache)
         ;; See the harness: a watch and `--batch' subprocess reading do not
         ;; mix.  This test is about the render contract, not the watch.
         (supernote-view-auto-sync nil)
         (buffer nil))
    (unwind-protect
        (progn
          (setq buffer (supernote-view-file file))
          (with-current-buffer buffer
            ;; Everything is asynchronous, so wait for the manifest.
            (with-timeout (30 (ert-fail "timed out waiting for the manifest"))
              (while (null supernote-view--manifest) (accept-process-output nil 0.05)))
            (should (= 5 (supernote-view--page-count)))
            (should (equal "noteSN_FILE_VER_20260016"
                           (alist-get 'signature
                                      (alist-get 'source supernote-view--manifest))))
            (with-timeout (60 (ert-fail "timed out waiting for the page"))
              (while (null supernote-view--artifact) (accept-process-output nil 0.05)))
            (should (eq 'vector-ink supernote-view--render-mode))
            (should (file-readable-p supernote-view--artifact))
            (should (string-match-p " V" (supernote-view--mode-line)))
            ;; The outline carries the one real title in this fixture.
            (let ((outlines (alist-get 'outlines supernote-view--manifest)))
              (should (= 1 (length outlines)))
              (should (equal "TITLE_000102700138" (alist-get 'id (car outlines)))))))
      (when (buffer-live-p buffer)
        (let ((kill-buffer-query-functions nil))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory cache t))
    ;; The reference note is read-only to this suite, and stayed that way.
    (should (equal (file-attribute-size before) (file-attribute-size (file-attributes file))))
    (should (equal (file-attribute-modification-time before)
                   (file-attribute-modification-time (file-attributes file))))))

(defconst supernote-test--theme-svg
  (concat "<svg><!--sn-theme-start--><defs><style>"
          ".sn-pen-0-0-0{color:rgb(0,0,0)}"
          ".sn-pen-128-128-128{color:rgb(128,128,128)}"
          ".sn-pen-255-255-255{color:rgb(255,255,255)}"
          ".sn-marker-128-128-128{color:rgb(128,128,128)}"
          "</style></defs><!--sn-theme-end-->"
          "<path class=\"sn-pen-0-0-0\" fill=\"currentColor\" d=\"M0,0 L1,1\"/>"
          "<text fill=\"transparent\">recognized text</text></svg>"))

(ert-deftest supernote-view-test-theme-palette-and-marker-exemption ()
  "Map pen shades into a tinted theme, preserving markers and SVG geometry."
  (let* ((supernote-view-theme-highlighters nil)
         (result (supernote-view--theme-svg
                  supernote-test--theme-svg "#f0e0c0" "#102030")))
    (should (string-search ".sn-pen-0-0-0{color:inherit;opacity:1}" result))
    (should (string-search ".sn-pen-128-128-128{color:#808078;opacity:1}" result))
    (should (string-search ".sn-pen-255-255-255{color:#102030;opacity:1}" result))
    (should (string-search ".sn-marker-128-128-128{color:rgb(128,128,128);opacity:1}" result))
    (should (string-search "<feFuncR type=\"linear\" slope=\"-0.87843137\"" result))
    (should (string-suffix-p
             "<path class=\"sn-pen-0-0-0\" fill=\"currentColor\" d=\"M0,0 L1,1\"/><text fill=\"transparent\">recognized text</text></svg>"
             result))))

(ert-deftest supernote-view-test-theme-marker-opt-in-and-legacy ()
  (let ((supernote-view-theme-highlighters t))
    (should (string-search ".sn-marker-128-128-128{color:#7f7f7f;opacity:1}"
                           (supernote-view--theme-svg
                            supernote-test--theme-svg "#ffffff" "#000000"))))
  (should (equal "<svg>legacy raster</svg>"
                 (supernote-view--theme-svg "<svg>legacy raster</svg>"
                                           "#ffffff" "#000000"))))

(ert-deftest supernote-view-test-theme-refresh-without-helper-or-source-write ()
  (let ((file (make-temp-file "supernote-theme" nil ".svg")))
    (unwind-protect
        (progn
          (write-region supernote-test--theme-svg nil file nil 'silent)
          (supernote-test--with-viewer nil
            (setq supernote-view--artifact file)
            (let ((calls (length supernote-test--log))
                  (page supernote-view--page)
                  (palette '("#f0e0c0" "#102030")))
              (cl-letf (((symbol-function 'supernote-view--theme-colors)
                         (lambda () palette)))
                (supernote-view-refresh-theme)
                (should (equal (plist-get (cdr supernote-view--image) :foreground)
                               "#f0e0c0"))
                (let ((first (plist-get supernote-view--theme-cache :rendered)))
                  (supernote-view-refresh-theme)
                  (should (eq first (plist-get supernote-view--theme-cache :rendered)))
                  (setq palette '("#102030" "#f0e0c0"))
                  (run-hook-with-args 'enable-theme-functions 'test-theme)
                  (should-not (equal first (plist-get supernote-view--theme-cache :rendered))))
                (let ((supernote-view-follow-theme nil))
                  (supernote-view-refresh-theme)
                  (should (equal (plist-get (cdr supernote-view--image) :file) file))
                  (should (equal (plist-get (cdr supernote-view--image) :foreground) "black"))))
              (should (= calls (length supernote-test--log)))
              (should (= page supernote-view--page))
              (should-not (buffer-modified-p))))
          (should (equal supernote-test--theme-svg
                         (with-temp-buffer (insert-file-contents file) (buffer-string)))))
      (delete-file file))))

(ert-deftest supernote-view-test-highlighter-colors-and-opacity ()
  "Only gray/light-gray markers become translucent red/yellow."
  (let* ((supernote-view-theme-highlighters nil)
         (supernote-view-highlighter-opacity 0.4)
         (source
          (concat "<svg><!--sn-theme-start--><defs><style>"
                  (mapconcat (lambda (gray)
                               (format ".sn-marker-%d-%d-%d{color:rgb(%d,%d,%d)}"
                                       gray gray gray gray gray gray))
                             '(0 128 157 158 201 202) "")
                  ".sn-pen-158-158-158{color:rgb(158,158,158)}"
                  "</style></defs><!--sn-theme-end--></svg>")))
    (dolist (palette '(("#ffffff" "#000000") ("#000000" "#ffffff")))
      (let ((result (apply #'supernote-view--theme-svg source palette)))
        (dolist (gray '(157 158))
          (should (string-search (format ".sn-marker-%d-%d-%d{color:#ff5555;opacity:0.4}"
                                         gray gray gray) result)))
        (dolist (gray '(201 202))
          (should (string-search (format ".sn-marker-%d-%d-%d{color:#ffd84a;opacity:0.4}"
                                         gray gray gray) result)))
        (dolist (gray '(0 128))
          (should (string-search
                   (format ".sn-marker-%d-%d-%d{color:rgb(%d,%d,%d);opacity:1}"
                           gray gray gray gray gray gray) result)))
        (should-not (string-search ".sn-pen-158-158-158{color:#ff5555" result))))
    (let ((supernote-view-highlighter-colors nil))
      (should (string-search ".sn-marker-158-158-158{color:rgb(158,158,158);opacity:1}"
                             (supernote-view--theme-svg source "#ffffff" "#000000"))))))

(ert-deftest supernote-view-test-highlighter-opacity-invalidates-display-cache ()
  (let ((file (make-temp-file "supernote-marker" nil ".svg")))
    (unwind-protect
        (progn
          (write-region
           "<svg><!--sn-theme-start--><defs><style>.sn-marker-158-158-158{color:rgb(158,158,158)}</style></defs><!--sn-theme-end--></svg>"
           nil file nil 'silent)
          (with-temp-buffer
            (setq supernote-view--artifact file)
            (let* ((supernote-view-highlighter-opacity 0.4)
                   (first (supernote-view--themed-source "#ffffff" "#000000")))
              (setq supernote-view-highlighter-opacity 0.6)
              (let ((second (supernote-view--themed-source "#ffffff" "#000000")))
                (should-not (equal first second))
                (should (string-search "color:#ff5555;opacity:0.6" second))))))
      (delete-file file))))

(provide 'supernote-view-test)
;;; supernote-view-test.el ends here
