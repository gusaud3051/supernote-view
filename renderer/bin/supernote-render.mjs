#!/usr/bin/env node
// supernote-render.mjs --- CLI adapter around supernote-typescript  -*- mode: js -*-
//
// A short-lived, machine-oriented command line helper used by the Emacs
// `supernote-view-mode'.  Stdout carries exactly one JSON object and nothing
// else; every human-oriented diagnostic goes to stderr.  Exit status zero
// means the JSON on stdout is a complete, usable result.
//
// Commands:
//
//   supernote-render.mjs version
//   supernote-render.mjs manifest     --input PATH --cache-dir DIR
//   supernote-render.mjs render       --input PATH --page N --format svg|png --cache-dir DIR
//   supernote-render.mjs render-title --input PATH --title-id ID --cache-dir DIR
//
// `--page' is always zero-based; the one-based page numbers the library and
// the user interface speak are converted at the boundaries.
//
// All `.note' metadata is treated as untrusted: bounds, dimensions and
// identifiers are validated before anything is allocated or written, output
// paths are constrained to the cache root, and the source file is never
// written to, moved, or read through a shell.

import { createHash } from 'node:crypto';
import { themeSvg } from './theme-svg.mjs';
import {
  closeSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  readSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  unlinkSync,
  utimesSync,
  writeFileSync,
} from 'node:fs';
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

export const SCHEMA_VERSION = 1;
export const RENDERER_NAME = 'supernote-emacs-renderer';
/** Bump whenever the bytes or meaning of a cached artifact change.
 * 2: page and title artifacts are keyed by their own content rather than by the
 *    source file's size and mtime, so a page that did not change survives the
 *    note being edited. */
// 3: semantic pen/marker palettes and a themeable template in vector SVGs.
export const RENDERER_ABI = 3;
export const LIBRARY_NAME = 'supernote-typescript';

const HERE = dirname(fileURLToPath(import.meta.url));
const PACKAGE_ROOT = resolve(HERE, '..');

/** Read a version out of a package.json, or null when unreadable. */
function packageVersion(packageJsonPath) {
  try {
    const parsed = JSON.parse(readFileSync(packageJsonPath, 'utf8'));
    return typeof parsed.version === 'string' ? parsed.version : null;
  } catch {
    return null;
  }
}

export const RENDERER_VERSION = packageVersion(join(PACKAGE_ROOT, 'package.json')) ?? '0.0.0';
export const LIBRARY_VERSION =
  packageVersion(join(PACKAGE_ROOT, 'node_modules', LIBRARY_NAME, 'package.json')) ?? 'unknown';

// ---------------------------------------------------------------------------
// Limits
//
// Every limit exists to bound work triggered by an untrusted file, not to
// express a preference.  The corpus this was built against tops out at a
// ~97 MiB source, 1920x2560 pages and ~16 KiB title bitmaps.
// ---------------------------------------------------------------------------

export const LIMITS = {
  /** Largest source file accepted, in bytes. */
  maxInputBytes: 1024 * 1024 * 1024,
  /** Largest page edge accepted, in pixels. */
  maxPageEdge: 20000,
  /** Largest page area accepted, in pixels. */
  maxPageArea: 80 * 1000 * 1000,
  /** Largest title bitmap edge accepted, in pixels. */
  maxTitleEdge: 20000,
  /** Largest title bitmap area accepted, in pixels. */
  maxTitleArea: 16 * 1000 * 1000,
  /** Largest page count accepted. */
  maxPageCount: 100000,
  /** Largest number of outline entries carried in a manifest. */
  maxOutlines: 20000,
  /** Largest number of composited layers accepted on one page.
   * The format defines five (MAINLAYER, LAYER1-3, BGLAYER), but `LAYERSEQ' is
   * a comma-separated string from the file, so its length is attacker-chosen
   * and each entry costs a full-page RGBA buffer held concurrently. */
  maxLayersPerPage: 8,
  /** Longest metadata string copied from a note into a JSON response.
   * Values come from an unbounded `[^:<>]+' field, so without this a crafted
   * header could put hundreds of megabytes on stdout and into the cache. */
  maxMetadataChars: 256,
  /** Largest accepted `--upscale'. */
  maxUpscale: 4,
  /** Longest diagnostic this process writes to stderr, in characters. */
  maxDiagnosticChars: 4000,
};

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/**
 * Exit codes.  Each class of failure gets a distinct nonzero status so a
 * caller can react without parsing the message -- in particular so Emacs can
 * tell "the page you asked for no longer exists" (recoverable: clamp and
 * retry) from "this command line is wrong" (a bug in the caller).
 */
export const EXIT = {
  OK: 0,
  USAGE: 2,
  INPUT: 3,
  PARSE: 4,
  RENDER: 5,
  CACHE: 6,
  INTERNAL: 7,
  RANGE: 8,
  DEPENDENCY: 9,
};

/** A failure with a stable machine-readable `code' and a chosen exit status. */
export class RenderError extends Error {
  constructor(code, exitCode, message, details = undefined) {
    super(message);
    this.name = 'RenderError';
    this.code = code;
    this.exitCode = exitCode;
    this.details = details;
  }
}

const fail = (code, exitCode, message, details) => {
  throw new RenderError(code, exitCode, message, details);
};

/** Bound anything this process writes to stderr. */
function truncate(text) {
  const string = String(text ?? '');
  return string.length > LIMITS.maxDiagnosticChars
    ? `${string.slice(0, LIMITS.maxDiagnosticChars)}\n[truncated]`
    : string;
}

// ---------------------------------------------------------------------------
// Dependency loading
//
// The dependency tree is imported lazily so that `version' still answers on a
// fresh clone, and can tell the caller to run `npm ci' instead of dying with a
// module-resolution stack trace.
// ---------------------------------------------------------------------------

let libraryPromise = null;

export function loadLibrary() {
  if (libraryPromise) return libraryPromise;
  libraryPromise = (async () => {
    try {
      const [core, conversion, vectorInk, imageJs] = await Promise.all([
        import(LIBRARY_NAME),
        // `RattaRLEDecoder' is public in its own module but is not re-exported
        // from the package index; the package declares no `exports' map, so
        // this subpath import is the supported way in.
        import(`${LIBRARY_NAME}/lib/conversion.js`),
        import(`${LIBRARY_NAME}/lib/vector-ink.js`),
        import('image-js'),
      ]);
      return { ...core, conversion, vectorInk, imageJs };
    } catch (error) {
      libraryPromise = null;
      fail(
        'E_DEPENDENCIES',
        EXIT.DEPENDENCY,
        `renderer dependencies are not installed in ${PACKAGE_ROOT}`,
        { remedy: `npm ci --prefix ${PACKAGE_ROOT}`, cause: String(error?.message ?? error) },
      );
    }
  })();
  return libraryPromise;
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

const KNOWN_OPTIONS = new Set(['--input', '--page', '--format', '--cache-dir', '--title-id', '--upscale']);

/**
 * Parse `--key value' pairs strictly.  An unknown flag, a missing value, or a
 * repeated option is a usage error rather than something silently ignored.
 */
export function parseArgs(argv) {
  const options = Object.create(null);
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith('--')) fail('E_USAGE', EXIT.USAGE, `unexpected argument: ${token}`);
    if (!KNOWN_OPTIONS.has(token)) fail('E_USAGE', EXIT.USAGE, `unknown option: ${token}`);
    const name = token.slice(2);
    if (options[name] !== undefined) fail('E_USAGE', EXIT.USAGE, `repeated option: ${token}`);
    const value = argv[i + 1];
    if (value === undefined) fail('E_USAGE', EXIT.USAGE, `option ${token} requires a value`);
    options[name] = value;
    i += 1;
  }
  return options;
}

function requireOption(options, name) {
  const value = options[name];
  if (value === undefined || value === '') fail('E_USAGE', EXIT.USAGE, `missing required option --${name}`);
  return value;
}

/** Parse a zero-based, non-negative integer index from a command line value. */
export function parseIndex(raw, what) {
  if (!/^\d{1,9}$/.test(raw)) fail('E_USAGE', EXIT.USAGE, `${what} must be a non-negative integer, got: ${raw}`);
  return Number(raw);
}

function parseUpscale(raw) {
  if (raw === undefined) return 1;
  if (!/^[1-9]\d{0,2}$/.test(raw)) fail('E_USAGE', EXIT.USAGE, `--upscale must be a positive integer, got: ${raw}`);
  const value = Number(raw);
  if (value > LIMITS.maxUpscale) {
    fail('E_USAGE', EXIT.USAGE, `--upscale ${value} exceeds the maximum of ${LIMITS.maxUpscale}`);
  }
  return value;
}

const SUPPORTED_FORMATS = new Set(['svg', 'png']);

function parseFormat(raw, fallback) {
  const format = raw ?? fallback;
  if (!SUPPORTED_FORMATS.has(format)) {
    fail('E_FORMAT', EXIT.USAGE, `unsupported format: ${format} (expected svg or png)`);
  }
  return format;
}

/** The cache root used when `--cache-dir' is omitted. */
export function defaultCacheDirectory() {
  const xdg = process.env.XDG_CACHE_HOME;
  const base = xdg && isAbsolute(xdg) ? xdg : join(homedir(), '.cache');
  return join(base, 'emacs-supernote');
}

// ---------------------------------------------------------------------------
// Source validation
// ---------------------------------------------------------------------------

/** The magic every `.note' file produced by the X series starts with. */
export const NOTE_MAGIC = 'noteSN_FILE_VER_';

/**
 * Validate that `inputPath' names a readable, regular `.note' file with a
 * recognizable signature, and return its identity.
 *
 * The path is canonicalized exactly once, here.  The resolved path is what the
 * cache is keyed on, so a note reached through two different symlinks is
 * cached once; `displayPath' keeps the path the caller typed, so the user
 * still sees the name they used.
 */
export function inspectSource(inputPath) {
  const displayPath = resolve(inputPath);
  if (!/\.note$/i.test(displayPath)) {
    fail('E_INPUT_EXT', EXIT.INPUT, `input does not have a .note extension: ${displayPath}`);
  }
  let path;
  try {
    path = realpathSync(displayPath);
  } catch (error) {
    fail('E_INPUT_MISSING', EXIT.INPUT, `cannot resolve input: ${displayPath}`, { errno: error.code });
  }
  let stats;
  try {
    stats = statSync(path);
  } catch (error) {
    fail('E_INPUT_MISSING', EXIT.INPUT, `cannot stat input: ${path}`, { errno: error.code });
  }
  if (!stats.isFile()) fail('E_INPUT_NOT_FILE', EXIT.INPUT, `input is not a regular file: ${path}`);
  if (stats.size > LIMITS.maxInputBytes) {
    fail('E_INPUT_TOO_LARGE', EXIT.INPUT, `input is ${stats.size} bytes, over the ${LIMITS.maxInputBytes} byte limit`);
  }

  // Read only the magic, so an unsupported or half-written file is rejected
  // before a 100 MiB read is ever issued.
  const header = Buffer.alloc(NOTE_MAGIC.length + 8);
  let bytesRead = 0;
  let fd;
  try {
    fd = openSync(path, 'r');
    bytesRead = readSync(fd, header, 0, header.length, 0);
  } catch (error) {
    fail('E_INPUT_UNREADABLE', EXIT.INPUT, `cannot read input: ${path}`, { errno: error.code });
  } finally {
    if (fd !== undefined) closeSync(fd);
  }

  const prefix = header.subarray(0, bytesRead).toString('latin1');
  if (!prefix.startsWith(NOTE_MAGIC)) {
    fail('E_SIGNATURE', EXIT.PARSE, `input does not carry the ${NOTE_MAGIC} signature: ${path}`, {
      observed: prefix.replace(/[^\x20-\x7e]/g, '.').slice(0, 24),
    });
  }

  return {
    path,
    displayPath,
    size: stats.size,
    // Milliseconds, as an integer: the cache key must not depend on
    // sub-millisecond float noise that differs between stat calls.
    mtimeMs: Math.round(stats.mtimeMs),
  };
}

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------

const sha256 = (value) => createHash('sha256').update(value).digest('hex');

/**
 * Cache identity for one source file in one renderer build.
 *
 * The canonical source path is hashed for a directory-safe name; the file's
 * *contents* are never hashed, because doing so would mean reading ~100 MiB on
 * every page turn.  Size and mtime stand in for content identity, and because
 * they are folded into the second path component, a changed source simply
 * lands in a different directory rather than needing an explicit invalidation
 * pass that could race a concurrent reader.
 */
export function cacheIdentity(source) {
  const sourceKey = sha256(source.path).slice(0, 32);
  const stateKey = sha256(
    JSON.stringify({
      size: source.size,
      mtimeMs: source.mtimeMs,
      abi: RENDERER_ABI,
      renderer: RENDERER_VERSION,
      library: LIBRARY_VERSION,
    }),
  ).slice(0, 16);
  return { sourceKey, stateKey };
}

/**
 * Resolve `relative' inside `root', refusing anything that escapes it.
 *
 * Nothing derived from file metadata is trusted to be a well-behaved path
 * component, so the containment check is done on the resolved result rather
 * than by inspecting the input for `..'.
 */
export function resolveInCache(root, ...relative) {
  const base = resolve(root);
  const target = resolve(base, ...relative);
  if (target !== base && !target.startsWith(base + sep)) {
    fail('E_CACHE_ESCAPE', EXIT.CACHE, `refusing to write outside the cache root: ${target}`);
  }
  return target;
}

function ensureDirectory(path) {
  try {
    mkdirSync(path, { recursive: true, mode: 0o700 });
  } catch (error) {
    fail('E_CACHE', EXIT.CACHE, `cannot create cache directory: ${path}`, { errno: error.code });
  }
}

/** How long a superseded generation is left alone before being reclaimed. */
const GENERATION_GRACE_MS = 60 * 60 * 1000;

/**
 * Reclaim this source's artifacts from generations nothing is using any more.
 *
 * Deliberately conservative on two counts, because the reader is a *separate
 * process holding a path*, not a process holding an open descriptor: unlinking
 * an artifact Emacs is about to display would make a zoom silently do nothing.
 *
 *   - Only generations untouched for `GENERATION_GRACE_MS' are removed, so an
 *     artifact handed out seconds ago is never a candidate, no matter how many
 *     helpers run in between.
 *   - It runs only from `manifest', i.e. when a note is being opened or
 *     reverted, never from a `render' or `render-title' that some other
 *     session's viewer may be interleaved with.
 *
 * Abandoned atomic-write temporaries are swept on the same terms: Emacs kills
 * a superseded helper mid-write during fast navigation, which leaves a
 * `.tmp-PID-N' file behind that nothing else would ever remove.
 */
function pruneStaleGenerations(sourceDirectory, keep, now) {
  let entries;
  try {
    entries = readdirSync(sourceDirectory, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const directory = join(sourceDirectory, entry.name);
    // The content directory is not a generation: its artifacts are keyed by
    // what they contain and are deliberately shared across revisions, so they
    // are reclaimed one at a time by age rather than dropped as a set.
    if (entry.name === 'content') {
      sweepTemporaries(directory, now);
      sweepAgedArtifacts(directory, now);
      continue;
    }
    if (!/^[0-9a-f]{16}$/.test(entry.name)) continue;
    if (entry.name === keep) {
      sweepTemporaries(directory, now);
      continue;
    }
    try {
      if (now - statSync(directory).mtimeMs < GENERATION_GRACE_MS) continue;
      rmSync(directory, { recursive: true, force: true });
    } catch {
      // Keep going; a stale generation is harmless.
    }
  }
}

/** Drop content-keyed artifacts nothing has wanted for a while.
 * `touchArtifact' is what keeps a page that is read often but rarely
 * re-rendered from ageing out from under the reader. */
function sweepAgedArtifacts(directory, now) {
  let entries;
  try {
    entries = readdirSync(directory, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    if (!entry.isFile()) continue;
    if (!/^(page|title)-[0-9a-f]{32}[-.]/.test(entry.name)) continue;
    const file = join(directory, entry.name);
    try {
      if (now - statSync(file).mtimeMs < GENERATION_GRACE_MS) continue;
      unlinkSync(file);
    } catch {
      // Another process may have reclaimed it already.
    }
  }
}

/** Remove atomic-write temporaries abandoned by a killed helper. */
function sweepTemporaries(directory, now) {
  let entries;
  try {
    entries = readdirSync(directory, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    if (!entry.isFile() || !/\.tmp-\d+-\d+$/.test(entry.name)) continue;
    const file = join(directory, entry.name);
    try {
      if (now - statSync(file).mtimeMs < GENERATION_GRACE_MS) continue;
      unlinkSync(file);
    } catch {
      // Another process may have cleaned it up already.
    }
  }
}

let temporaryCounter = 0;

/**
 * Write `data' to `path' atomically.
 *
 * The temporary lands in the destination directory so the rename cannot cross
 * a filesystem boundary, and a reader either sees the previous artifact or the
 * complete new one, never a partial file.
 */
export function writeArtifactAtomically(path, data) {
  temporaryCounter += 1;
  const temporary = `${path}.tmp-${process.pid}-${temporaryCounter}`;
  try {
    writeFileSync(temporary, data, { mode: 0o600 });
    renameSync(temporary, path);
  } catch (error) {
    try {
      unlinkSync(temporary);
    } catch {
      // The temporary may never have been created; nothing to clean up.
    }
    fail('E_CACHE', EXIT.CACHE, `cannot write cache artifact: ${path}`, { errno: error.code });
  }
}

/** True when both an artifact and its sidecar exist and are nonempty. */
function cachedArtifactIsUsable(artifactPath, sidecarPath) {
  try {
    return statSync(artifactPath).size > 0 && statSync(sidecarPath).size > 0;
  } catch {
    return false;
  }
}

function readSidecar(sidecarPath) {
  try {
    return JSON.parse(readFileSync(sidecarPath, 'utf8'));
  } catch {
    return null;
  }
}

/**
 * The directories one source's cached data lives in.
 *
 * Two kinds of thing are cached, keyed differently on purpose.  The manifest
 * describes the file as a whole, so it belongs to one revision of it and lives
 * under a size-and-mtime generation.  Page and title artifacts describe one
 * page or one title, so they are keyed by that content (`pageContentKey') and
 * live in a flat `content' directory shared across revisions -- which is what
 * lets an edit to one page leave the note's other rendered pages in place.
 *
 * PRUNE reclaims what is no longer wanted; only `manifest' passes it, because
 * only `manifest' runs at a moment when no artifact path is in flight.
 */
function cacheDirectoryFor(cacheRoot, source, prune = false) {
  const { sourceKey, stateKey } = cacheIdentity(source);
  const sourceDirectory = resolveInCache(cacheRoot, sourceKey);
  const generation = resolveInCache(sourceDirectory, stateKey);
  const content = resolveInCache(sourceDirectory, 'content');
  ensureDirectory(generation);
  ensureDirectory(content);
  if (prune) pruneStaleGenerations(sourceDirectory, stateKey, Date.now());
  return { sourceDirectory, generation, content, stateKey };
}

/**
 * Note that an artifact was wanted just now.
 *
 * A content-keyed artifact does not belong to a generation that can be dropped
 * wholesale, so reclamation goes by age -- and age has to mean "since anyone
 * last wanted it", not "since it was written", or a page read every day but
 * never re-rendered would eventually be thrown away under the reader.
 */
function touchArtifact(path) {
  try {
    const now = new Date();
    utimesSync(path, now, now);
  } catch {
    // Nothing depends on this; it only shifts when the file may be reclaimed.
  }
}

// ---------------------------------------------------------------------------
// Note parsing
// ---------------------------------------------------------------------------

/**
 * Load and parse a note.
 *
 * The `Buffer' is handed to the parser as-is rather than copied into a fresh
 * `Uint8Array': `Buffer' already is one, and copying would double the peak
 * memory cost of the largest fixture for no benefit.
 */
async function loadNote(source) {
  const { SupernoteX } = await loadLibrary();
  let buffer;
  try {
    buffer = await readFile(source.path);
  } catch (error) {
    fail('E_INPUT_UNREADABLE', EXIT.INPUT, `cannot read input: ${source.path}`, { errno: error.code });
  }
  let note;
  try {
    note = new SupernoteX(buffer);
  } catch (error) {
    // A truncated or partially-written source surfaces here as a RangeError
    // from the parser's own bounds checks; it is a parse failure either way.
    fail('E_PARSE', EXIT.PARSE, `cannot parse note: ${error.message}`, { cause: error.constructor.name });
  }
  validateGeometry(note);
  return note;
}

/** Reject page geometry that would lead to an unreasonable allocation. */
export function validateGeometry(note) {
  const { pageWidth, pageHeight } = note;
  if (!Number.isInteger(pageWidth) || !Number.isInteger(pageHeight) || pageWidth <= 0 || pageHeight <= 0) {
    fail('E_DIMENSIONS', EXIT.PARSE, `note reports non-positive page size ${pageWidth}x${pageHeight}`);
  }
  if (pageWidth > LIMITS.maxPageEdge || pageHeight > LIMITS.maxPageEdge) {
    fail('E_DIMENSIONS', EXIT.PARSE, `page size ${pageWidth}x${pageHeight} exceeds the ${LIMITS.maxPageEdge}px edge limit`);
  }
  if (pageWidth * pageHeight > LIMITS.maxPageArea) {
    fail('E_DIMENSIONS', EXIT.PARSE, `page area ${pageWidth * pageHeight} exceeds the ${LIMITS.maxPageArea}px limit`);
  }
  if (!Array.isArray(note.pages)) fail('E_PARSE', EXIT.PARSE, 'note exposes no page list');
  if (note.pages.length === 0) fail('E_PARSE', EXIT.PARSE, 'note contains no pages');
  if (note.pages.length > LIMITS.maxPageCount) {
    fail('E_PARSE', EXIT.PARSE, `note reports ${note.pages.length} pages, over the ${LIMITS.maxPageCount} limit`);
  }
  // `LAYERSEQ' is split from one untrusted string and drives one concurrent
  // full-page allocation per entry, so it is bounded before anything decodes.
  note.pages.forEach((page, index) => {
    const layers = page?.LAYERSEQ;
    if (Array.isArray(layers) && layers.length > LIMITS.maxLayersPerPage) {
      fail(
        'E_DIMENSIONS',
        EXIT.PARSE,
        `page ${index} declares ${layers.length} layers, over the ${LIMITS.maxLayersPerPage} limit`,
      );
    }
  });
}

const INK_LAYERS = ['MAINLAYER', 'LAYER1', 'LAYER2', 'LAYER3', 'BGLAYER'];

/**
 * A key identifying what one page will actually render to.
 *
 * This is what makes an edit incremental: the artifact path is derived from the
 * page's own bytes, so adding a stroke to page 5 leaves every other page's key
 * -- and therefore its already-rendered artifact -- untouched.  Keying on the
 * file's size and mtime instead, as this used to, invalidated a whole note on
 * any change to it.
 *
 * Everything that can alter the rendered pixels goes in: the ink and template
 * layer bitmaps, the vector stroke record, the compositing order, the template
 * identity, and the page geometry.  Hashing those buffers is cheap even for the
 * largest note in the corpus -- 3 ms for a 97 MiB file, because only ~7 MiB of
 * it is page data -- and it happens once per manifest, not once per page turn.
 */
export function pageContentKey(note, pageIndex) {
  const page = note.pages[pageIndex];
  const hash = createHash('sha256');
  hash.update(`abi${RENDERER_ABI}\u0000${LIBRARY_VERSION}\u0000`);
  hash.update(`${note.pageWidth}x${note.pageHeight}\u0000`);
  hash.update(`${String(page?.PAGESTYLE ?? '')}\u0000${String(page?.PAGESTYLEMD5 ?? '')}\u0000`);
  hash.update(`${(Array.isArray(page?.LAYERSEQ) ? page.LAYERSEQ : []).join(',')}\u0000`);
  for (const name of INK_LAYERS) {
    const buffer = page?.[name]?.bitmapBuffer;
    // The length goes in as well, so two adjacent buffers cannot hash the same
    // as one longer one.
    hash.update(`${name}:${buffer ? buffer.length : -1}\u0000`);
    if (buffer && buffer.length) hash.update(buffer);
  }
  const strokes = page?.totalPathBuffer;
  hash.update(`TOTALPATH:${strokes ? strokes.length : -1}\u0000`);
  if (strokes && strokes.length) hash.update(strokes);
  return hash.digest('hex').slice(0, 32);
}

/** The same idea for one title's thumbnail. */
export function titleContentKey(title, rect) {
  const hash = createHash('sha256');
  hash.update(`abi${RENDERER_ABI}\u0000${LIBRARY_VERSION}\u0000`);
  hash.update(`${rect.x},${rect.y},${rect.width},${rect.height}\u0000`);
  hash.update(`${String(title?.TITLESTYLE ?? '')}\u0000`);
  const bitmap = title?.bitmapBuffer;
  hash.update(`BITMAP:${bitmap ? bitmap.length : -1}\u0000`);
  if (bitmap && bitmap.length) hash.update(bitmap);
  return hash.digest('hex').slice(0, 32);
}

/** A note's own string, truncated to something a JSON response can carry. */
function metadata(value) {
  if (typeof value !== 'string') return null;
  return value.length > LIMITS.maxMetadataChars
    ? `${value.slice(0, LIMITS.maxMetadataChars)}\u2026`
    : value;
}

// ---------------------------------------------------------------------------
// Manifest
// ---------------------------------------------------------------------------

/**
 * Parse a `TITLERECT' value.
 *
 * The library types these as a four-element tuple, but at run time the parser
 * hands back the raw `"x,y,w,h"' string; both shapes are accepted so a future
 * library change in either direction cannot break the manifest.  A rectangle
 * that is not four plausible non-negative integers is refused outright rather
 * than passed on for something downstream to trip over.
 */
export function parseRect(raw) {
  const parts = Array.isArray(raw) ? raw : String(raw ?? '').split(',');
  if (parts.length !== 4) return null;
  const [x, y, width, height] = parts.map((part) => Number(String(part).trim()));
  if (![x, y, width, height].every((value) => Number.isInteger(value))) return null;
  if (x < 0 || y < 0 || width <= 0 || height <= 0) return null;
  if (width > LIMITS.maxTitleEdge || height > LIMITS.maxTitleEdge) return null;
  if (width * height > LIMITS.maxTitleArea) return null;
  return { x, y, width, height };
}

/**
 * Decode an `ITitle.TITLESTYLE' value into thumbnail colors.
 *
 * The device stores seven decimal digits, `1BBBFFF': `BBB' is the heading
 * background's grey level and `FFF' its label's.  Both being `000' means the
 * cross-hatch background rather than a solid black one.
 *
 * Two adjustments keep the thumbnail readable, which a literal reading of the
 * style would not: a hatched heading is drawn on white, since its label ink is
 * black and a solid black fill would erase it; and a background and label that
 * are too close in grey get a forced-contrast label, since the device itself
 * recolors heading labels for contrast at display time and every stored title
 * bitmap in the corpus holds black ink regardless of its declared label color.
 */
export function parseTitleStyle(raw) {
  const digits = String(raw ?? '');
  const backgroundDigits = digits.slice(1, 4);
  const labelDigits = digits.slice(4, 7);
  if (digits.length !== 7 || !/^\d{3}$/.test(backgroundDigits) || !/^\d{3}$/.test(labelDigits)) {
    return { background: 255, ink: 0, fill: 'solid', recognized: false };
  }
  if (backgroundDigits === '000' && labelDigits === '000') {
    return { background: 255, ink: 0, fill: 'hatch', recognized: true };
  }
  const background = Math.min(255, Number(backgroundDigits));
  let ink = Math.min(255, Number(labelDigits));
  if (Math.abs(background - ink) < 32) ink = background > 127 ? 0 : 255;
  return { background, ink, fill: 'solid', recognized: true };
}

/**
 * Split a `note.titles' key into its parts.
 *
 * The footer keys these entries `TITLE_PPPPYYYYXXXX': a one-based page number
 * followed by the title's own y and x.  The page number is the only reliable
 * way to find which page a title sits on, so it is cross-checked against the
 * title's own rectangle and against the note's page count before use.
 */
export function decodeTitleKey(key, rect, pageCount) {
  if (!/^\d{12}$/.test(key)) return null;
  const pageNumber = Number(key.slice(0, 4));
  if (!Number.isInteger(pageNumber) || pageNumber < 1 || pageNumber > pageCount) return null;
  const keyY = Number(key.slice(4, 8));
  const keyX = Number(key.slice(8, 12));
  // The digits are zero-padded to four, so a coordinate over 9999 wraps; only
  // treat a mismatch as disqualifying when neither coordinate could have.
  const consistent =
    rect === null || ((rect.y < 10000 ? keyY === rect.y : true) && (rect.x < 10000 ? keyX === rect.x : true));
  return { pageIndex: pageNumber - 1, consistent };
}

/**
 * The stable identifier for one title.
 *
 * The footer is journaled, so a key can carry more than one entry; the first
 * keeps the bare `TITLE_<key>' form and any later duplicate is suffixed, so
 * every outline row addresses exactly one title.
 */
export function titleIdFor(key, index) {
  return index === 0 ? `TITLE_${key}` : `TITLE_${key}.${index}`;
}

// The duplicate index is generated by `titleIdFor' and bounded by
// `LIMITS.maxOutlines', so the accepted width follows that rather than a
// guess: a manifest must never be able to emit an id this refuses to parse.
const TITLE_ID_RE = /^TITLE_(\d{12})(?:\.(\d{1,6}))?$/;

/** Split a title id back into its key and duplicate index. */
export function parseTitleId(raw) {
  const match = TITLE_ID_RE.exec(String(raw));
  if (!match) fail('E_TITLE_ID', EXIT.USAGE, `malformed title id: ${raw}`);
  return { key: match[1], index: match[2] ? Number(match[2]) : 0 };
}

/** Normalize a page's `ORIENTATION' into a word, keeping the raw value too. */
function normalizeOrientation(raw, width, height) {
  if (raw === '1000' || raw === '1180') return 'portrait';
  if (raw === '1090' || raw === '1270') return 'landscape';
  return width > height ? 'landscape' : 'portrait';
}

/** The `artifact'/`render_mode' pair for a page, as far as the cache knows. */
function cachedPageFields(resolve, contentKey) {
  const found = resolve && contentKey ? resolve(contentKey) : null;
  return { artifact: found?.path ?? null, render_mode: found?.render_mode ?? null };
}

/** Build the schema-version-1 manifest for a parsed note.
 * RESOLVE, when given, is called with a page's content key and must return the
 * artifact path for it if one is already cached, so the caller can show an
 * unchanged page without asking for a render at all. */
export function buildManifest(note, source, resolve = null) {
  const pageCount = note.pages.length;

  const pages = note.pages.map((page, index) => {
    const contentKey = pageContentKey(note, index);
    return {
    page_index: index,
    display_page: index + 1,
    content_key: contentKey,
    ...cachedPageFields(resolve, contentKey),
    page_id: metadata(page.PAGEID),
    orientation: normalizeOrientation(page.ORIENTATION, note.pageWidth, note.pageHeight),
    orientation_raw: metadata(page.ORIENTATION),
    style: metadata(page.PAGESTYLE),
    recognition_available: Array.isArray(page.recognitionElements) && page.recognitionElements.length > 0,
    recognition_status: metadata(page.RECOGNSTATUS),
    };
  });

  const outlines = [];
  for (const [key, titles] of Object.entries(note.titles ?? {})) {
    if (!Array.isArray(titles)) continue;
    titles.forEach((title, index) => {
      if (outlines.length >= LIMITS.maxOutlines) return;
      const rect = parseRect(title.TITLERECT);
      const decoded = decodeTitleKey(key, rect, pageCount);
      if (decoded === null) return; // A title we cannot place is not shown.
      const level = Number(title.TITLELEVEL);
      outlines.push({
        id: titleIdFor(key, index),
        page_index: decoded.pageIndex,
        // Levels are one-based on the device; anything unparseable is treated
        // as a top-level entry rather than dropped.
        level: Number.isInteger(level) && level >= 1 ? level : 1,
        rect,
        style: metadata(title.TITLESTYLE),
        // Never invent text for a handwritten title.
        label: null,
        has_bitmap: title.bitmapBuffer instanceof Uint8Array && title.bitmapBuffer.length > 0,
      });
    });
  }

  // Reading order: by page, then down the page, then across.
  outlines.sort(
    (a, b) =>
      a.page_index - b.page_index ||
      (a.rect?.y ?? 0) - (b.rect?.y ?? 0) ||
      (a.rect?.x ?? 0) - (b.rect?.x ?? 0) ||
      (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
  );

  return {
    schema_version: SCHEMA_VERSION,
    renderer: {
      name: RENDERER_NAME,
      version: RENDERER_VERSION,
      abi: RENDERER_ABI,
      library: LIBRARY_NAME,
      library_version: LIBRARY_VERSION,
    },
    source: {
      path: source.path,
      display_path: source.displayPath,
      size: source.size,
      mtime_ms: source.mtimeMs,
      signature: metadata(note.signature),
      equipment: metadata(note.header?.APPLY_EQUIPMENT),
      file_id: metadata(note.header?.FILE_ID),
    },
    page_count: pageCount,
    page_size: { width: note.pageWidth, height: note.pageHeight },
    pages,
    outlines,
  };
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/**
 * Render one page to an SVG string, and report honestly which ink it used.
 *
 * This composes `prepareVectorInkPages' / `buildRenderNoteForVectorInk' /
 * `toImage' / `addSvgPage' -- all public exports -- rather than calling
 * `toSvg', which is exactly that sequence with the vector-ink decision hidden
 * inside it.  Composing it here is what makes `render_mode' truthful without
 * decoding every stroke twice: `toSvg' would repeat the whole
 * `prepareVectorInkPages' pass (200 ms on the largest fixture) just to be
 * asked afterwards what it had decided.
 *
 * The rasterized layer is flattened onto white before it is embedded.  The
 * decoded page is RGBA with a fully transparent background, which would let
 * the Emacs buffer's own background show through the paper -- black ink on a
 * dark theme.  Flattening restores the paper the device draws on; it is not a
 * color substitution, and it leaves every stroke's own color and the order of
 * the vector paths untouched.
 */
async function renderPageSvg(library, note, pageIndex, upscale) {
  const pageNumber = pageIndex + 1;
  const prepared = library.prepareVectorInkPages(note, [pageNumber], upscale);
  const vectorPage = prepared.find((page) => page.pageNumber === pageNumber);
  const useVectorInk = vectorPage?.useVectorInk === true;
  const renderNote = library.buildRenderNoteForVectorInk(note, prepared);
  const [raster] = await library.toImage(renderNote, [pageNumber], { upscale });
  if (!raster) fail('E_RENDER', EXIT.RENDER, `renderer produced no image for page ${pageIndex}`);
  const opaque = library.flattenToWhite(raster);
  const svg = library.addSvgPage(note.pages[pageIndex], opaque, opaque.width, opaque.height, {
    strokes: useVectorInk ? vectorPage.strokes : undefined,
    strokeStyles: useVectorInk ? vectorPage.styles : undefined,
    equipment: note.header?.APPLY_EQUIPMENT,
    nativePageWidth: note.pageWidth,
  });
  if (typeof svg !== 'string' || svg.length === 0) {
    fail('E_RENDER', EXIT.RENDER, `renderer produced no svg for page ${pageIndex}`);
  }
  return {
    data: Buffer.from(useVectorInk
      ? themeSvg(svg, vectorPage.strokes, vectorPage.styles, library.vectorInk)
      : svg, 'utf8'),
    renderMode: useVectorInk ? 'vector-ink' : 'raster-fallback',
    width: opaque.width,
    height: opaque.height,
  };
}

/**
 * Render one page to PNG.
 *
 * PNG is only produced when the caller explicitly asks for raster output -- it
 * is what Emacs falls back to without SVG support -- so the page keeps its own
 * rasterized ink and the mode is reported as `raster-requested', never as a
 * fallback from vector ink.
 */
async function renderPagePng(library, note, pageIndex, upscale) {
  const [raster] = await library.toImage(note, [pageIndex + 1], { upscale });
  if (!raster) fail('E_RENDER', EXIT.RENDER, `renderer produced no image for page ${pageIndex}`);
  const opaque = library.flattenToWhite(raster);
  return {
    data: Buffer.from(library.imageJs.encodePng(opaque)),
    renderMode: 'raster-requested',
    width: opaque.width,
    height: opaque.height,
  };
}

/** Composite a decoded title bitmap onto an opaque, style-aware background. */
export function compositeTitleBitmap(rgba, width, height, style) {
  const pixels = width * height;
  if (rgba.length < pixels * 4) {
    fail('E_RENDER', EXIT.RENDER, `title bitmap is ${rgba.length} bytes, expected ${pixels * 4}`);
  }
  const out = new Uint8Array(pixels * 3);
  for (let i = 0; i < pixels; i += 1) {
    const alpha = rgba[i * 4 + 3] / 255;
    const value = Math.round(style.ink * alpha + style.background * (1 - alpha));
    out[i * 3] = value;
    out[i * 3 + 1] = value;
    out[i * 3 + 2] = value;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

function rendererBlock() {
  return {
    name: RENDERER_NAME,
    version: RENDERER_VERSION,
    abi: RENDERER_ABI,
    library: LIBRARY_NAME,
    library_version: LIBRARY_VERSION,
  };
}

function commandVersion() {
  return {
    schema_version: SCHEMA_VERSION,
    renderer: rendererBlock(),
    node_version: process.version,
    formats: [...SUPPORTED_FORMATS],
    package_root: PACKAGE_ROOT,
    dependencies_installed: LIBRARY_VERSION !== 'unknown',
  };
}

async function commandManifest(options) {
  const source = inspectSource(requireOption(options, 'input'));
  const cacheRoot = options['cache-dir'] ?? defaultCacheDirectory();
  const format = parseFormat(options.format, 'svg');
  const upscale = parseUpscale(options.upscale);
  const layout = cacheDirectoryFor(cacheRoot, source, true);
  const artifact = resolveInCache(layout.generation, 'manifest.json');

  // Which of this note's pages are already rendered, in the format the caller
  // is going to ask for.  Answering here is what lets an unchanged page appear
  // with no render and no loading placeholder, including straight after an edit
  // to some other page.
  const resolveArtifact = (contentKey) => {
    const base = pageArtifactName(contentKey, format, upscale);
    const path = resolveInCache(layout.content, `${base}.${format}`);
    const sidecar = resolveInCache(layout.content, `${base}.meta.json`);
    if (!cachedArtifactIsUsable(path, sidecar)) return null;
    touchArtifact(path);
    touchArtifact(sidecar);
    // How the page was rendered travels with it, so a caller showing a page it
    // did not itself ask for can still report `vector-ink' or `raster-fallback'
    // truthfully rather than assuming.
    const meta = readSidecar(sidecar);
    return { path, render_mode: meta?.render_mode ?? null };
  };

  const cached = cachedArtifactIsUsable(artifact, artifact) ? readSidecar(artifact) : null;
  if (cached && cached.schema_version === SCHEMA_VERSION && Array.isArray(cached.pages)) {
    // The manifest is cached, but which artifacts exist is not: re-resolve.
    // The display path is not part of the cache identity either, so a note
    // reached through a different symlink reports the name the caller used.
    return {
      ...cached,
      source: { ...cached.source, display_path: source.displayPath },
      pages: cached.pages.map((page) => ({
        ...page,
        ...cachedPageFields(resolveArtifact, page.content_key),
      })),
      format,
      artifact,
      cache_hit: true,
    };
  }

  const note = await loadNote(source);
  const manifest = buildManifest(note, source, resolveArtifact);
  writeArtifactAtomically(artifact, JSON.stringify(manifest));
  return { ...manifest, format, artifact, cache_hit: false };
}

/** Artifact base name for one rendered page.
 * The page is identified by its content, so the same page in two revisions of a
 * note resolves to the same file; the render-affecting options stay in the name
 * because they change the bytes. */
function pageArtifactName(contentKey, format, upscale) {
  return `page-${contentKey}-${format}-u${upscale}`;
}

/** Artifact base name for one title thumbnail. */
function titleArtifactName(contentKey) {
  return `title-${contentKey}`;
}

async function commandRender(options) {
  const source = inspectSource(requireOption(options, 'input'));
  const cacheRoot = options['cache-dir'] ?? defaultCacheDirectory();
  const pageIndex = parseIndex(requireOption(options, 'page'), '--page');
  const format = parseFormat(options.format, 'svg');
  const upscale = parseUpscale(options.upscale);

  const layout = cacheDirectoryFor(cacheRoot, source);

  // The key comes from the page's own bytes, so the note has to be parsed to
  // learn it.  Parsing is 1-27 ms even for the largest fixture, against the
  // 500-900 ms a render costs, so this is still overwhelmingly worth it: it is
  // what lets an untouched page be served after the note was edited.
  const note = await loadNote(source);
  if (pageIndex >= note.pages.length) {
    fail('E_PAGE_RANGE', EXIT.RANGE, `page index ${pageIndex} is out of range; note has ${note.pages.length} pages`, {
      page_count: note.pages.length,
    });
  }

  const contentKey = pageContentKey(note, pageIndex);
  const base = pageArtifactName(contentKey, format, upscale);
  const artifact = resolveInCache(layout.content, `${base}.${format}`);
  const sidecar = resolveInCache(layout.content, `${base}.meta.json`);

  if (cachedArtifactIsUsable(artifact, sidecar)) {
    const meta = readSidecar(sidecar);
    if (meta && meta.schema_version === SCHEMA_VERSION) {
      touchArtifact(artifact);
      touchArtifact(sidecar);
      return { ...meta, source: source.path, artifact, cache_hit: true };
    }
  }

  const library = await loadLibrary();
  let rendered;
  try {
    rendered =
      format === 'svg'
        ? await renderPageSvg(library, note, pageIndex, upscale)
        : await renderPagePng(library, note, pageIndex, upscale);
  } catch (error) {
    if (error instanceof RenderError) throw error;
    fail('E_RENDER', EXIT.RENDER, `cannot render page ${pageIndex} as ${format}: ${error.message}`);
  }

  const meta = {
    schema_version: SCHEMA_VERSION,
    page_index: pageIndex,
    display_page: pageIndex + 1,
    content_key: contentKey,
    format,
    render_mode: rendered.renderMode,
    upscale,
    width: rendered.width,
    height: rendered.height,
    bytes: rendered.data.length,
    page_count: note.pages.length,
  };
  writeArtifactAtomically(artifact, rendered.data);
  writeArtifactAtomically(sidecar, JSON.stringify(meta));
  return { ...meta, source: source.path, artifact, cache_hit: false };
}

async function commandRenderTitle(options) {
  const source = inspectSource(requireOption(options, 'input'));
  const cacheRoot = options['cache-dir'] ?? defaultCacheDirectory();
  const titleId = requireOption(options, 'title-id');
  const format = parseFormat(options.format, 'png');
  if (format !== 'png') fail('E_FORMAT', EXIT.USAGE, 'render-title only produces png');
  // The identifier reaches the filesystem, so it is constrained to the exact
  // shape the manifest produces rather than merely sanitized.
  const { key, index } = parseTitleId(titleId);

  const layout = cacheDirectoryFor(cacheRoot, source);

  const note = await loadNote(source);
  const titles = note.titles?.[key];
  const title = Array.isArray(titles) ? titles[index] : undefined;
  if (!title) fail('E_TITLE_RANGE', EXIT.RANGE, `no such title in note: ${titleId}`);

  const rect = parseRect(title.TITLERECT);
  if (rect === null) fail('E_TITLE_RECT', EXIT.RENDER, `title ${titleId} has an unusable rectangle`);
  const { width, height } = rect;
  if (!(title.bitmapBuffer instanceof Uint8Array) || title.bitmapBuffer.length === 0) {
    fail('E_TITLE_BITMAP', EXIT.RENDER, `title ${titleId} carries no bitmap`);
  }

  const contentKey = titleContentKey(title, rect);
  const base = titleArtifactName(contentKey);
  const artifact = resolveInCache(layout.content, `${base}.png`);
  const sidecar = resolveInCache(layout.content, `${base}.meta.json`);

  if (cachedArtifactIsUsable(artifact, sidecar)) {
    const meta = readSidecar(sidecar);
    if (meta && meta.schema_version === SCHEMA_VERSION) {
      touchArtifact(artifact);
      touchArtifact(sidecar);
      return { ...meta, source: source.path, artifact, cache_hit: true };
    }
  }

  const library = await loadLibrary();
  let data;
  let style;
  try {
    const decoded = new library.conversion.RattaRLEDecoder().decode(title.bitmapBuffer, width, height);
    style = parseTitleStyle(title.TITLESTYLE);
    const composited = compositeTitleBitmap(decoded, width, height, style);
    const image = new library.imageJs.Image(width, height, {
      colorModel: library.imageJs.ImageColorModel.RGB,
      data: composited,
    });
    data = Buffer.from(library.imageJs.encodePng(image));
  } catch (error) {
    if (error instanceof RenderError) throw error;
    fail('E_TITLE_BITMAP', EXIT.RENDER, `cannot render title ${titleId}: ${error.message}`);
  }

  const decodedKey = decodeTitleKey(key, rect, note.pages.length);
  const level = Number(title.TITLELEVEL);
  const meta = {
    schema_version: SCHEMA_VERSION,
    title_id: titleId,
    content_key: contentKey,
    page_index: decodedKey?.pageIndex ?? 0,
    level: Number.isInteger(level) && level >= 1 ? level : 1,
    format: 'png',
    render_mode: 'raster-requested',
    width,
    height,
    bytes: data.length,
    style: metadata(title.TITLESTYLE),
    fill: style.fill,
  };
  writeArtifactAtomically(artifact, data);
  writeArtifactAtomically(sidecar, JSON.stringify(meta));
  return { ...meta, source: source.path, artifact, cache_hit: false };
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

const COMMANDS = {
  version: commandVersion,
  manifest: commandManifest,
  render: commandRender,
  'render-title': commandRenderTitle,
};

const USAGE = `usage:
  supernote-render.mjs version
  supernote-render.mjs manifest     --input PATH [--cache-dir DIR]
  supernote-render.mjs render       --input PATH --page N [--format svg|png] [--upscale N] [--cache-dir DIR]
  supernote-render.mjs render-title --input PATH --title-id TITLE_NNNNNNNNNNNN [--cache-dir DIR]`;

/** Write the single JSON object this process is allowed to put on stdout. */
function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

export async function main(argv) {
  const [command, ...rest] = argv;
  const handler = command === undefined ? undefined : COMMANDS[command];
  if (!handler) {
    process.stderr.write(`${USAGE}\n`);
    emit({
      schema_version: SCHEMA_VERSION,
      error: {
        code: 'E_USAGE',
        message: command === undefined ? 'missing command' : `unknown command: ${command}`,
        details: { usage: USAGE },
      },
    });
    return EXIT.USAGE;
  }
  try {
    emit(await handler(parseArgs(rest)));
    return EXIT.OK;
  } catch (error) {
    if (error instanceof RenderError) {
      process.stderr.write(truncate(`${RENDERER_NAME}: ${error.code}: ${error.message}\n`));
      emit({
        schema_version: SCHEMA_VERSION,
        error: { code: error.code, message: error.message, details: error.details ?? null },
      });
      return error.exitCode;
    }
    process.stderr.write(truncate(`${RENDERER_NAME}: unexpected failure: ${error?.stack ?? error}\n`));
    emit({
      schema_version: SCHEMA_VERSION,
      error: { code: 'E_INTERNAL', message: String(error?.message ?? error), details: null },
    });
    return EXIT.INTERNAL;
  }
}

/**
 * True when this module is the program being run.
 *
 * `process.argv[1]' is the path as invoked, while `import.meta.url' is always
 * the real path -- and the deployed helper is reached through a stow symlink
 * (for example, a package manager build symlink), so comparing
 * the two directly would make the stowed helper silently produce no output.
 */
const invokedDirectly = (() => {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
  } catch {
    return false;
  }
})();

if (invokedDirectly) {
  main(process.argv.slice(2)).then(
    (code) => {
      process.exitCode = code;
    },
    (error) => {
      process.stderr.write(truncate(`${RENDERER_NAME}: fatal: ${error?.stack ?? error}\n`));
      process.exitCode = EXIT.INTERNAL;
    },
  );
}
