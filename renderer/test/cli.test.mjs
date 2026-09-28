// End-to-end tests for the supernote-render command line contract.

import assert from 'node:assert/strict';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  statSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, sep } from 'node:path';
import { after, before, describe, it } from 'node:test';

import { CLI, EXPECTED, FIXTURES, fixturesAvailable, makeTempDir, run, sha256File } from './helpers.mjs';

describe('optional reference corpus', { skip: !fixturesAvailable }, () => {
let cache;

before(() => {
  cache = makeTempDir('supernote-cache-');
});

describe('version', () => {
  it('returns a stable, complete JSON identity', async () => {
    const { code, json, stdout } = await run(['version']);
    assert.equal(code, 0);
    assert.equal(json.schema_version, 1);
    assert.equal(json.renderer.name, 'supernote-emacs-renderer');
    assert.equal(json.renderer.abi, 3);
    assert.equal(json.renderer.library, 'supernote-typescript');
    assert.equal(json.renderer.library_version, '0.7.1', 'the dependency must stay pinned to 0.7.1');
    assert.ok(Array.isArray(json.formats) && json.formats.includes('svg'));
    // Exactly one JSON object on stdout, and nothing else.
    assert.equal(stdout.trimEnd().split('\n').length, 1);
  });

  it('is byte-for-byte reproducible across runs', async () => {
    const first = await run(['version']);
    const second = await run(['version']);
    assert.equal(first.stdout, second.stdout);
  });
});

describe('manifest', () => {
  for (const [name, path] of Object.entries(FIXTURES)) {
    it(`parses the ${name} fixture with the expected shape`, async () => {
      const { code, json } = await run(['manifest', '--input', path, '--cache-dir', cache]);
      assert.equal(code, 0);
      assert.equal(json.schema_version, 1);
      assert.equal(json.source.path, realpathSync(path));
      assert.equal(json.source.display_path, path);
      assert.equal(json.source.signature, EXPECTED.signature);
      assert.equal(json.source.equipment, EXPECTED.equipment);
      assert.equal(json.source.size, statSync(path).size);
      assert.equal(json.page_count, EXPECTED.pageCounts[name]);
      assert.equal(json.page_size.width, EXPECTED.pageWidth);
      assert.equal(json.page_size.height, EXPECTED.pageHeight);
      assert.equal(json.pages.length, json.page_count);
      assert.equal(json.outlines.length, EXPECTED.titleCounts[name]);
    });
  }

  it('numbers pages zero-based on the wire and one-based for display', async () => {
    const { json } = await run(['manifest', '--input', FIXTURES.realAnalysis, '--cache-dir', cache]);
    json.pages.forEach((page, index) => {
      assert.equal(page.page_index, index);
      assert.equal(page.display_page, index + 1);
    });
  });

  it('reports the Real Analysis title with its stored level, rectangle and style', async () => {
    const { json } = await run(['manifest', '--input', FIXTURES.realAnalysis, '--cache-dir', cache]);
    const [outline] = json.outlines;
    assert.equal(outline.id, EXPECTED.realAnalysisTitleId);
    assert.equal(outline.page_index, 0);
    assert.equal(outline.level, 1);
    assert.deepEqual(outline.rect, { x: 138, y: 270, width: 208, height: 73 });
    assert.equal(outline.style, '1000000');
    assert.equal(outline.label, null, 'text must never be invented for a handwritten title');
  });

  it('serves a second request from cache', async () => {
    const first = await run(['manifest', '--input', FIXTURES.topology, '--cache-dir', cache]);
    const second = await run(['manifest', '--input', FIXTURES.topology, '--cache-dir', cache]);
    assert.equal(second.json.cache_hit, true);
    assert.equal(second.json.page_count, first.json.page_count);
  });
});

describe('render', () => {
  it('produces vector ink for a page with decodable stroke data', async () => {
    const { code, json } = await run([
      'render', '--input', FIXTURES.realAnalysis, '--page', '0', '--format', 'svg', '--cache-dir', cache,
    ]);
    assert.equal(code, 0);
    assert.equal(json.page_index, 0);
    assert.equal(json.display_page, 1);
    assert.equal(json.format, 'svg');
    assert.equal(json.render_mode, 'vector-ink');
    assert.equal(json.width, EXPECTED.pageWidth);
    assert.equal(json.height, EXPECTED.pageHeight);
    const svg = readFileSync(json.artifact, 'utf8');
    assert.ok(svg.startsWith('<svg'), 'artifact should be an SVG document');
    const paths = svg.match(/<path/g) ?? [];
    assert.ok(paths.length > 100, `expected real vector paths, found ${paths.length}`);
    // Geometry comes from the file's own TOTALPATH record, never from tracing
    // the bitmap: each path is the device's stored stroke contour, a closed
    // filled ring carrying the real pressure-varying width.  (A stroke with no
    // usable contour falls back to its sampled centreline, stroked at a
    // width -- that form has `stroke`/`stroke-width` instead of `fill`.)
    const first = /<path[^>]*\bd="([^"]+)"/.exec(svg);
    assert.ok(first, 'a vector page carries path geometry');
    assert.match(first[1], /^M[\d.]+,[\d.]+(?: L[\d.]+,[\d.]+){10,}.*Z/,
      'a stroke is a closed run of real coordinates, not a traced blob');
    assert.ok(/<path[^>]*\bfill="/.test(svg), 'contours are filled regions');
    // A traced bitmap would come back as Bezier outlines; these never are.
    assert.ok(!/<path[^>]*\bd="[^"]*[CSQTA]/.test(svg),
      'no Bezier curves: nothing here was produced by a raster tracer');
  });

  it('reports a raster fallback honestly when vector ink is unavailable', async () => {
    const { json } = await run([
      'render', '--input', FIXTURES.realAnalysis,
      '--page', String(EXPECTED.realAnalysisRasterPageIndex),
      '--format', 'svg', '--cache-dir', cache,
    ]);
    assert.equal(json.render_mode, 'raster-fallback');
    const svg = readFileSync(json.artifact, 'utf8');
    // Every page embeds an <image> for its template, vector ink included, so
    // that alone proves nothing.  What distinguishes a fallback is that the
    // ink was *not* turned into paths.
    assert.equal((svg.match(/<path/g) ?? []).length, 0,
      'a raster fallback leaves the ink in the bitmap');
    assert.ok(svg.includes('<image'), 'and still carries the rasterized page');
  });

  it('reports explicitly requested raster output as raster-requested', async () => {
    const { json } = await run([
      'render', '--input', FIXTURES.topology, '--page', '0', '--format', 'png', '--cache-dir', cache,
    ]);
    assert.equal(json.render_mode, 'raster-requested');
    assert.equal(json.format, 'png');
    const png = readFileSync(json.artifact);
    assert.equal(png.subarray(0, 8).toString('hex'), '89504e470d0a1a0a', 'artifact should be a PNG');
    assert.equal(png.readUInt32BE(16), EXPECTED.pageWidth);
    assert.equal(png.readUInt32BE(20), EXPECTED.pageHeight);
  });

  it('serves a repeated render from cache without re-rendering', async () => {
    const args = ['render', '--input', FIXTURES.topology, '--page', '1', '--format', 'svg', '--cache-dir', cache];
    const first = await run(args);
    assert.equal(first.json.cache_hit, false);
    const second = await run(args);
    assert.equal(second.json.cache_hit, true);
    assert.equal(second.json.artifact, first.json.artifact);
    assert.equal(second.json.render_mode, first.json.render_mode);
  });

  it('keys the cache separately per page, format and options', async () => {
    const base = ['render', '--input', FIXTURES.topology, '--cache-dir', cache];
    const svg0 = await run([...base, '--page', '0', '--format', 'svg']);
    const svg1 = await run([...base, '--page', '1', '--format', 'svg']);
    const png0 = await run([...base, '--page', '0', '--format', 'png']);
    const up0 = await run([...base, '--page', '0', '--format', 'svg', '--upscale', '2']);
    const artifacts = [svg0, svg1, png0, up0].map((result) => result.json.artifact);
    assert.equal(new Set(artifacts).size, 4, 'each distinct request needs its own artifact');
    assert.equal(up0.json.width, EXPECTED.pageWidth * 2);
    assert.equal(up0.json.height, EXPECTED.pageHeight * 2);
  });

  it('constrains every artifact to the cache root', async () => {
    const { json } = await run([
      'render', '--input', FIXTURES.topology, '--page', '0', '--format', 'svg', '--cache-dir', cache,
    ]);
    assert.ok(json.artifact.startsWith(cache + sep), `${json.artifact} escaped ${cache}`);
  });

  it('leaves no temporary files behind', async () => {
    const leftovers = [];
    const walk = (dir) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const path = join(dir, entry.name);
        if (entry.isDirectory()) walk(path);
        else if (entry.name.includes('.tmp-')) leftovers.push(path);
      }
    };
    walk(cache);
    assert.deepEqual(leftovers, [], 'atomic writes must not leave temporaries behind');
  });
});

describe('render-title', () => {
  it('renders a correctly sized, nonempty thumbnail', async () => {
    const { code, json } = await run([
      'render-title', '--input', FIXTURES.realAnalysis,
      '--title-id', EXPECTED.realAnalysisTitleId, '--cache-dir', cache,
    ]);
    assert.equal(code, 0);
    assert.equal(json.title_id, EXPECTED.realAnalysisTitleId);
    assert.equal(json.page_index, 0);
    assert.equal(json.level, 1);
    assert.equal(json.width, EXPECTED.realAnalysisTitleSize.width);
    assert.equal(json.height, EXPECTED.realAnalysisTitleSize.height);
    assert.equal(json.fill, 'hatch', 'style 1000000 is the cross-hatch heading background');
    const png = readFileSync(json.artifact);
    assert.ok(png.length > 200, `thumbnail should not be empty, got ${png.length} bytes`);
    assert.equal(png.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
    assert.equal(png.readUInt32BE(16), EXPECTED.realAnalysisTitleSize.width);
    assert.equal(png.readUInt32BE(20), EXPECTED.realAnalysisTitleSize.height);
  });

  it('serves a repeated thumbnail from cache', async () => {
    const args = [
      'render-title', '--input', FIXTURES.realAnalysis,
      '--title-id', EXPECTED.realAnalysisTitleId, '--cache-dir', cache,
    ];
    await run(args);
    const { json } = await run(args);
    assert.equal(json.cache_hit, true);
  });
});

describe('cache invalidation', () => {
  let temp;
  let copy;

  before(() => {
    temp = makeTempDir('supernote-source-');
    copy = join(temp, 'copy.note');
    copyFileSync(FIXTURES.realAnalysis, copy);
  });

  it('re-reads the manifest when the source mtime changes', async () => {
    const cacheDir = makeTempDir('supernote-cache-mtime-');
    const args = ['manifest', '--input', copy, '--cache-dir', cacheDir];
    assert.equal((await run(args)).json.cache_hit, false);
    assert.equal((await run(args)).json.cache_hit, true);

    const future = new Date(Date.now() + 60_000);
    utimesSync(copy, future, future);

    assert.equal((await run(args)).json.cache_hit, false, 'a changed mtime must re-read');
  });

  it('keeps a page artifact whose content did not change', async () => {
    // The whole point of keying a page on its own bytes: touching the file, or
    // replacing it with a revision that leaves this page alone, must not make
    // the page render again.
    const cacheDir = makeTempDir('supernote-cache-content-');
    const args = ['render', '--input', copy, '--page', '0', '--format', 'svg', '--cache-dir', cacheDir];
    const first = await run(args);
    assert.equal(first.json.cache_hit, false);
    assert.ok(first.json.content_key, 'a render reports the key it was cached under');

    const future = new Date(Date.now() + 60_000);
    utimesSync(copy, future, future);

    const afterTouch = await run(args);
    assert.equal(afterTouch.json.cache_hit, true, 'an untouched page stays rendered');
    assert.equal(afterTouch.json.artifact, first.json.artifact);
    assert.equal(afterTouch.json.content_key, first.json.content_key);
  });

  it('reports which pages are already rendered, and how', async () => {
    const cacheDir = makeTempDir('supernote-cache-report-');
    const before = await run(['manifest', '--input', copy, '--cache-dir', cacheDir]);
    assert.deepEqual(before.json.pages.map((page) => page.artifact),
      before.json.pages.map(() => null), 'nothing is rendered yet');
    assert.ok(before.json.pages.every((page) => typeof page.content_key === 'string'));

    const render = await run(['render', '--input', copy, '--page', '2', '--cache-dir', cacheDir]);
    const after = await run(['manifest', '--input', copy, '--cache-dir', cacheDir]);
    const page = after.json.pages[2];
    assert.equal(page.artifact, render.json.artifact,
      'the manifest points at the artifact the render produced');
    assert.equal(page.render_mode, render.json.render_mode,
      'and says how it was rendered, so a caller need not assume');
    // Every other page is still unrendered.
    assert.equal(after.json.pages.filter((p) => p.artifact).length, 1);
    // A different format is tracked separately.
    const asPng = await run(['manifest', '--input', copy, '--format', 'png', '--cache-dir', cacheDir]);
    assert.equal(asPng.json.pages.filter((p) => p.artifact).length, 0);
  });

  it('invalidates when the source size changes', async () => {
    const cacheDir = makeTempDir('supernote-cache-size-');
    const grown = join(temp, 'grown.note');
    copyFileSync(FIXTURES.realAnalysis, grown);
    const args = ['manifest', '--input', grown, '--cache-dir', cacheDir];
    const first = await run(args);
    assert.equal(first.json.cache_hit, false);
    assert.equal((await run(args)).json.cache_hit, true);

    // Append a byte: the size differs while the mtime may land in the same
    // millisecond, so this isolates the size half of the cache key.
    const original = readFileSync(grown);
    writeFileSync(grown, Buffer.concat([original, Buffer.from([0])]));
    const stats = statSync(grown);
    utimesSync(grown, stats.atime, first.json.source.mtime_ms / 1000);

    assert.equal((await run(args)).json.cache_hit, false, 'a changed size must invalidate');
  });
});

describe('safety', () => {
  it('never modifies or writes beside the source', async () => {
    const temp = makeTempDir('supernote-untouched-');
    const copy = join(temp, 'untouched.note');
    copyFileSync(FIXTURES.realAnalysis, copy);
    const before = { hash: sha256File(copy), stat: statSync(copy), siblings: readdirSync(temp) };

    const cacheDir = makeTempDir('supernote-cache-safety-');
    await run(['manifest', '--input', copy, '--cache-dir', cacheDir]);
    await run(['render', '--input', copy, '--page', '0', '--format', 'svg', '--cache-dir', cacheDir]);
    await run([
      'render-title', '--input', copy, '--title-id', EXPECTED.realAnalysisTitleId, '--cache-dir', cacheDir,
    ]);

    assert.equal(sha256File(copy), before.hash, 'the source must remain byte-for-byte identical');
    assert.equal(statSync(copy).mtimeMs, before.stat.mtimeMs, 'the source mtime must not change');
    assert.deepEqual(readdirSync(temp), before.siblings, 'nothing may be written beside the source');
  });

  it('works with paths containing spaces and non-ASCII characters', async () => {
    const temp = makeTempDir('supernote-unicode-');
    const dir = join(temp, 'a folder with spaces', '한글 ünïcode');
    mkdirSync(dir, { recursive: true });
    const copy = join(dir, '테스트 노트 (1).note');
    copyFileSync(FIXTURES.realAnalysis, copy);

    const cacheDir = makeTempDir('supernote-cache-unicode-');
    const manifest = await run(['manifest', '--input', copy, '--cache-dir', cacheDir]);
    assert.equal(manifest.code, 0);
    assert.equal(manifest.json.source.path, realpathSync(copy));
    assert.equal(manifest.json.source.display_path, copy);

    const render = await run(['render', '--input', copy, '--page', '0', '--format', 'svg', '--cache-dir', cacheDir]);
    assert.equal(render.code, 0);
    assert.ok(existsSync(render.json.artifact));
  });
});

describe('failure modes', () => {
  const cases = [
    {
      name: 'page index beyond the last page',
      args: () => ['render', '--input', FIXTURES.topology, '--page', '99', '--format', 'svg', '--cache-dir', cache],
      code: 8,
      error: 'E_PAGE_RANGE',
    },
    {
      name: 'unknown title id',
      args: () => ['render-title', '--input', FIXTURES.realAnalysis, '--title-id', 'TITLE_999999999999', '--cache-dir', cache],
      code: 8,
      error: 'E_TITLE_RANGE',
    },
    {
      name: 'title id shaped like a path traversal',
      args: () => ['render-title', '--input', FIXTURES.realAnalysis, '--title-id', '../../../etc/passwd', '--cache-dir', cache],
      code: 2,
      error: 'E_TITLE_ID',
    },
    {
      name: 'unsupported format',
      args: () => ['render', '--input', FIXTURES.topology, '--page', '0', '--format', 'gif', '--cache-dir', cache],
      code: 2,
      error: 'E_FORMAT',
    },
    {
      name: 'unknown option',
      args: () => ['manifest', '--input', FIXTURES.topology, '--cache-dir', cache, '--sneaky', 'x'],
      code: 2,
      error: 'E_USAGE',
    },
    {
      name: 'unknown command',
      args: () => ['frobnicate'],
      code: 2,
      error: 'E_USAGE',
    },
    {
      name: 'missing required option',
      args: () => ['render', '--input', FIXTURES.topology, '--cache-dir', cache],
      code: 2,
      error: 'E_USAGE',
    },
    {
      name: 'negative page index',
      args: () => ['render', '--input', FIXTURES.topology, '--page', '-1', '--cache-dir', cache],
      code: 2,
      error: 'E_USAGE',
    },
  ];

  for (const testCase of cases) {
    it(`fails safely on ${testCase.name}`, async () => {
      const { code, json } = await run(testCase.args(), { expectFailure: true });
      assert.equal(code, testCase.code);
      assert.equal(json.error.code, testCase.error);
      assert.ok(typeof json.error.message === 'string' && json.error.message.length > 0);
    });
  }

  it('rejects a file that does not carry the note signature', async () => {
    const temp = makeTempDir('supernote-bad-sig-');
    const bogus = join(temp, 'bogus.note');
    writeFileSync(bogus, 'this is definitely not a Supernote document');
    const { code, json } = await run(['manifest', '--input', bogus, '--cache-dir', cache], { expectFailure: true });
    assert.equal(code, 4);
    assert.equal(json.error.code, 'E_SIGNATURE');
  });

  it('rejects a truncated note without crashing', async () => {
    const temp = makeTempDir('supernote-truncated-');
    const truncated = join(temp, 'truncated.note');
    writeFileSync(truncated, readFileSync(FIXTURES.realAnalysis).subarray(0, 5000));
    const { code, json } = await run(['manifest', '--input', truncated, '--cache-dir', cache], { expectFailure: true });
    assert.equal(code, 4);
    assert.equal(json.error.code, 'E_PARSE');
  });

  it('rejects a missing input', async () => {
    const { code, json } = await run(
      ['manifest', '--input', join(makeTempDir(), 'absent.note'), '--cache-dir', cache],
      { expectFailure: true },
    );
    assert.equal(code, 3);
    assert.equal(json.error.code, 'E_INPUT_MISSING');
  });

  it('rejects a directory given as input', async () => {
    const { code, json } = await run(['manifest', '--input', dirname(CLI), '--cache-dir', cache], {
      expectFailure: true,
    });
    assert.equal(code, 3);
    assert.ok(['E_INPUT_NOT_FILE', 'E_INPUT_EXT'].includes(json.error.code));
  });

  it('still emits one parseable JSON object on every failure', async () => {
    const { json, parseError, stdout } = await run(['frobnicate'], { expectFailure: true });
    assert.equal(parseError, null, 'stdout must stay machine-parseable on failure');
    assert.ok(json.error);
    assert.equal(stdout.trimEnd().split('\n').length, 1);
  });
});

describe('display and deployment', () => {
  it('gives the page an opaque background rather than a transparent one', async () => {
    // A transparent page would let the Emacs buffer's own background show
    // through the paper, which puts black ink on a dark theme.
    const { json } = await run([
      'render', '--input', FIXTURES.realAnalysis, '--page', '0', '--format', 'svg', '--cache-dir', cache,
    ]);
    const svg = readFileSync(json.artifact, 'utf8');
    const encoded = /data:image\/png;base64,([A-Za-z0-9+/=]+)/.exec(svg);
    assert.ok(encoded, 'the page raster should be embedded in the SVG');
    const png = Buffer.from(encoded[1], 'base64');
    // IHDR colour type 2 is RGB; 6 would be RGBA, i.e. still transparent.
    assert.equal(png[25], 2, 'the embedded page raster must carry no alpha channel');

    const raster = await run([
      'render', '--input', FIXTURES.realAnalysis, '--page', '0', '--format', 'png', '--cache-dir', cache,
    ]);
    assert.equal(readFileSync(raster.json.artifact)[25], 2, 'the PNG page must be opaque too');
  });

  it('caches a note reached through a symlink exactly once', async () => {
    const temp = makeTempDir('supernote-symlink-');
    const link = join(temp, 'linked.note');
    symlinkSync(FIXTURES.topology, link);
    const cacheDir = makeTempDir('supernote-cache-symlink-');

    const direct = await run(['manifest', '--input', FIXTURES.topology, '--cache-dir', cacheDir]);
    const linked = await run(['manifest', '--input', link, '--cache-dir', cacheDir]);

    assert.equal(direct.json.cache_hit, false);
    assert.equal(linked.json.cache_hit, true, 'the canonical path is the cache identity');
    assert.equal(linked.json.source.path, realpathSync(FIXTURES.topology));
    assert.equal(linked.json.source.display_path, link, 'the caller still sees the path it used');
  });

  it('runs when invoked through a symlinked directory, as stow deploys it', async () => {
    // Package managers may symlink the renderer into a source
    // checkout, so argv[1] and the module's own URL never match directly.
    const temp = makeTempDir('supernote-stow-');
    const link = join(temp, 'stowed');
    symlinkSync(dirname(dirname(CLI)), link);
    const { code, json } = await run(['version'], { cli: join(link, 'bin', 'supernote-render.mjs') });
    assert.equal(code, 0);
    assert.equal(json.renderer.name, 'supernote-emacs-renderer');
  });

  it('defaults the cache directory when none is given', async () => {
    const home = makeTempDir('supernote-xdg-');
    const { code, json } = await run(['manifest', '--input', FIXTURES.topology], {
      env: { XDG_CACHE_HOME: home },
    });
    assert.equal(code, 0);
    assert.ok(json.artifact.startsWith(join(home, 'emacs-supernote') + sep), json.artifact);
  });

  it('does not reclaim a page artifact just because the file changed', async () => {
    // Emacs holds artifact *paths*, and a page keyed by its own content is
    // meant to outlive the note being edited, so neither a revision bump nor
    // the prune that runs with it may take one away.
    const temp = makeTempDir('supernote-prune-');
    const copy = join(temp, 'prune.note');
    copyFileSync(FIXTURES.topology, copy);
    const cacheDir = makeTempDir('supernote-cache-prune-');
    const first = await run(['render', '--input', copy, '--page', '0', '--cache-dir', cacheDir]);

    const future = new Date(Date.now() + 60_000);
    utimesSync(copy, future, future);
    // `manifest' is the command that prunes.
    await run(['manifest', '--input', copy, '--cache-dir', cacheDir]);

    assert.equal(existsSync(first.json.artifact), true,
      'the page did not change, so its render must still be there');
    const again = await run(['render', '--input', copy, '--page', '0', '--cache-dir', cacheDir]);
    assert.equal(again.json.cache_hit, true);
    assert.equal(again.json.artifact, first.json.artifact);
  });

  it('reclaims a page artifact nothing has wanted for a long time', async () => {
    const temp = makeTempDir('supernote-prune-old-');
    const copy = join(temp, 'prune.note');
    copyFileSync(FIXTURES.topology, copy);
    const cacheDir = makeTempDir('supernote-cache-prune-old-');
    const first = await run(['render', '--input', copy, '--page', '0', '--cache-dir', cacheDir]);
    const second = await run(['render', '--input', copy, '--page', '1', '--cache-dir', cacheDir]);

    // Age one of them out; leave the other recent.
    const stale = new Date(Date.now() - 3 * 60 * 60 * 1000);
    utimesSync(first.json.artifact, stale, stale);
    utimesSync(`${first.json.artifact.replace(/\.svg$/, '')}.meta.json`, stale, stale);
    await run(['manifest', '--input', copy, '--cache-dir', cacheDir]);

    assert.equal(existsSync(first.json.artifact), false, 'an unwanted artifact is reclaimed');
    assert.equal(existsSync(second.json.artifact), true, 'a recent one is kept');
  });

  it('a cache hit renews an artifact, so reading a page keeps it alive', async () => {
    const temp = makeTempDir('supernote-touch-');
    const copy = join(temp, 'touch.note');
    copyFileSync(FIXTURES.topology, copy);
    const cacheDir = makeTempDir('supernote-cache-touch-');
    const first = await run(['render', '--input', copy, '--page', '0', '--cache-dir', cacheDir]);

    const stale = new Date(Date.now() - 3 * 60 * 60 * 1000);
    utimesSync(first.json.artifact, stale, stale);
    // Reading it must move it back out of reclamation range ...
    const hit = await run(['render', '--input', copy, '--page', '0', '--cache-dir', cacheDir]);
    assert.equal(hit.json.cache_hit, true);
    assert.ok(Date.now() - statSync(first.json.artifact).mtimeMs < 60_000,
      'serving a page renews it');
    // ... so the next prune leaves it alone.
    await run(['manifest', '--input', copy, '--cache-dir', cacheDir]);
    assert.equal(existsSync(first.json.artifact), true);
  });

  it('sweeps an atomic-write temporary abandoned by a killed helper', async () => {
    const temp = makeTempDir('supernote-sweep-');
    const copy = join(temp, 'sweep.note');
    copyFileSync(FIXTURES.topology, copy);
    const cacheDir = makeTempDir('supernote-cache-sweep-');
    const { json } = await run(['render', '--input', copy, '--page', '0', '--cache-dir', cacheDir]);

    // What a helper killed mid-write leaves behind.
    const orphan = `${json.artifact}.tmp-424242-1`;
    writeFileSync(orphan, 'partial');
    const stale = new Date(Date.now() - 3 * 60 * 60 * 1000);
    utimesSync(orphan, stale, stale);
    const fresh = `${json.artifact}.tmp-424243-1`;
    writeFileSync(fresh, 'partial');

    await run(['manifest', '--input', copy, '--cache-dir', cacheDir]);
    assert.equal(existsSync(orphan), false, 'an aged temporary is swept');
    assert.equal(existsSync(fresh), true, 'a temporary another helper may still be writing is kept');
    assert.equal(existsSync(json.artifact), true);
  });

  it('reports missing dependencies with a repair command instead of a stack trace', async () => {
    // Point the module resolver at an empty tree so the dependency import
    // fails the way it would on a fresh clone, before `npm ci' has run.
    const empty = makeTempDir('supernote-nodeps-');
    mkdirSync(join(empty, 'bin'), { recursive: true });
    writeFileSync(join(empty, 'package.json'), '{"name":"x","version":"9.9.9","type":"module"}');
    copyFileSync(CLI, join(empty, 'bin', 'supernote-render.mjs'));
    copyFileSync(join(dirname(CLI), 'theme-svg.mjs'), join(empty, 'bin', 'theme-svg.mjs'));

    const version = await run(['version'], { cli: join(empty, 'bin', 'supernote-render.mjs') });
    assert.equal(version.code, 0, 'version must answer without the dependency tree');
    assert.equal(version.json.dependencies_installed, false);

    const manifest = await run(['manifest', '--input', FIXTURES.topology, '--cache-dir', cache], {
      cli: join(empty, 'bin', 'supernote-render.mjs'),
      expectFailure: true,
    });
    assert.equal(manifest.code, 9);
    assert.equal(manifest.json.error.code, 'E_DEPENDENCIES');
    assert.match(manifest.json.error.details.remedy, /^npm ci --prefix /);
  });
});

});
