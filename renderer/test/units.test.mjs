// Unit tests for the pure helpers, including synthetic title hierarchies that
// the current corpus cannot exercise (every real title on this machine is
// level 1).

import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import {
  buildManifest,
  cacheIdentity,
  compositeTitleBitmap,
  decodeTitleKey,
  parseArgs,
  parseIndex,
  parseRect,
  pageContentKey,
  parseTitleStyle,
  resolveInCache,
  titleContentKey,
  validateGeometry,
} from '../bin/supernote-render.mjs';

/** Build a note-shaped object good enough for `buildManifest'. */
function syntheticNote({ pageCount = 3, titles = {} } = {}) {
  return {
    pageWidth: 1920,
    pageHeight: 2560,
    signature: 'noteSN_FILE_VER_20260016',
    header: { APPLY_EQUIPMENT: 'N5' },
    titles,
    pages: Array.from({ length: pageCount }, (_, index) => ({
      PAGEID: `PAGE${index}`,
      PAGESTYLE: 'style_5mm_dots_a5x2',
      ORIENTATION: '1000',
      RECOGNSTATUS: '0',
      recognitionElements: [],
    })),
  };
}

const source = { path: '/tmp/example.note', size: 1234, mtimeMs: 1780000000000 };

describe('parseArgs', () => {
  it('parses well-formed options', () => {
    // Spread first: the parser returns a prototype-less object on purpose, so
    // an option literally named `__proto__' cannot poison anything.
    assert.deepEqual({ ...parseArgs(['--input', 'a.note', '--page', '3']) }, { input: 'a.note', page: '3' });
  });

  it('returns a prototype-less object', () => {
    assert.equal(Object.getPrototypeOf(parseArgs(['--page', '1'])), null);
  });

  it('rejects unknown, repeated, valueless and bare arguments', () => {
    assert.throws(() => parseArgs(['--nope', 'x']), /unknown option/);
    assert.throws(() => parseArgs(['--page', '1', '--page', '2']), /repeated option/);
    assert.throws(() => parseArgs(['--page']), /requires a value/);
    assert.throws(() => parseArgs(['stray']), /unexpected argument/);
  });

  it('treats a value that looks like an option as that option value', () => {
    // `--input --page' would otherwise silently consume the next flag.
    assert.deepEqual({ ...parseArgs(['--input', '--page']) }, { input: '--page' });
  });
});

describe('parseIndex', () => {
  it('accepts zero and positive integers', () => {
    assert.equal(parseIndex('0', '--page'), 0);
    assert.equal(parseIndex('42', '--page'), 42);
  });

  it('rejects negatives, floats, and non-numeric text', () => {
    for (const bad of ['-1', '1.5', '1e3', '', ' 1', 'one', '0x10']) {
      assert.throws(() => parseIndex(bad, '--page'), /non-negative integer/, `should reject ${JSON.stringify(bad)}`);
    }
  });
});

describe('parseRect', () => {
  it('parses the runtime string form the parser actually returns', () => {
    assert.deepEqual(parseRect('138,270,208,73'), { x: 138, y: 270, width: 208, height: 73 });
  });

  it('also accepts the declared tuple form', () => {
    assert.deepEqual(parseRect(['1', '2', '3', '4']), { x: 1, y: 2, width: 3, height: 4 });
  });

  it('returns null for malformed input rather than guessing', () => {
    for (const bad of ['1,2,3', '', null, undefined, 'a,b,c,d', '1,2,3,4,5']) {
      assert.equal(parseRect(bad), null, `should reject ${JSON.stringify(bad)}`);
    }
  });
});

describe('parseTitleStyle', () => {
  it('decodes a solid background and label', () => {
    // 1BBBFFF: background grey 201, label grey 000.
    assert.deepEqual(parseTitleStyle('1201000'), { background: 201, ink: 0, fill: 'solid', recognized: true });
  });

  it('treats an all-zero style as the cross-hatch heading, drawn legibly', () => {
    // A literal reading would be black ink on a black background.
    const style = parseTitleStyle('1000000');
    assert.equal(style.fill, 'hatch');
    assert.equal(style.background, 255);
    assert.equal(style.ink, 0);
  });

  it('keeps a light label on a dark background', () => {
    assert.deepEqual(parseTitleStyle('1000254'), { background: 0, ink: 254, fill: 'solid', recognized: true });
  });

  it('forces contrast when background and label are too close', () => {
    const style = parseTitleStyle('1200210');
    assert.equal(style.background, 200);
    assert.equal(style.ink, 0, 'a dark label is needed on a light background');
    const dark = parseTitleStyle('1010020');
    assert.equal(dark.ink, 255, 'a light label is needed on a dark background');
  });

  it('falls back to black on white for an unrecognized style', () => {
    for (const bad of ['', '12345', 'abcdefg', null, undefined, '10000000']) {
      const style = parseTitleStyle(bad);
      assert.equal(style.recognized, false, `should not claim to recognize ${JSON.stringify(bad)}`);
      assert.equal(style.background, 255);
      assert.equal(style.ink, 0);
    }
  });
});

describe('decodeTitleKey', () => {
  const rect = { x: 138, y: 270, width: 208, height: 73 };

  it('reads the one-based page number out of the key', () => {
    assert.deepEqual(decodeTitleKey('000102700138', rect, 5), { pageIndex: 0, consistent: true });
    assert.deepEqual(decodeTitleKey('000511510038', { x: 38, y: 1151, width: 156, height: 49 }, 8), {
      pageIndex: 4,
      consistent: true,
    });
  });

  it('rejects a key whose page is out of range', () => {
    assert.equal(decodeTitleKey('000902700138', rect, 5), null);
    assert.equal(decodeTitleKey('000002700138', rect, 5), null);
  });

  it('rejects a malformed key', () => {
    for (const bad of ['', '0001', '00010270013X', '0001027001380']) {
      assert.equal(decodeTitleKey(bad, rect, 5), null, `should reject ${JSON.stringify(bad)}`);
    }
  });

  it('flags a key whose coordinates disagree with the rectangle', () => {
    assert.equal(decodeTitleKey('000199990001', rect, 5).consistent, false);
  });
});

describe('buildManifest', () => {
  it('preserves a synthetic level 1-3 hierarchy', () => {
    const note = syntheticNote({
      pageCount: 3,
      titles: {
        // page 1, y 0100, x 0050 -- level 1
        '000101000050': [{ TITLELEVEL: '1', TITLERECT: '50,100,300,60', TITLESTYLE: '1000000', bitmapBuffer: new Uint8Array([1]) }],
        // page 1, y 0200, x 0090 -- level 2
        '000102000090': [{ TITLELEVEL: '2', TITLERECT: '90,200,260,55', TITLESTYLE: '1201000', bitmapBuffer: new Uint8Array([1]) }],
        // page 2, y 0080, x 0120 -- level 3
        '000200800120': [{ TITLELEVEL: '3', TITLERECT: '120,80,240,50', TITLESTYLE: '1157254', bitmapBuffer: new Uint8Array([1]) }],
      },
    });
    const manifest = buildManifest(note, source);
    assert.deepEqual(
      manifest.outlines.map((o) => [o.id, o.page_index, o.level]),
      [
        ['TITLE_000101000050', 0, 1],
        ['TITLE_000102000090', 0, 2],
        ['TITLE_000200800120', 1, 3],
      ],
    );
    assert.ok(manifest.outlines.every((o) => o.label === null));
  });

  it('orders titles by page, then down and across the page', () => {
    const note = syntheticNote({
      pageCount: 2,
      titles: {
        '000209000010': [{ TITLELEVEL: '1', TITLERECT: '10,900,100,40', TITLESTYLE: '1000000', bitmapBuffer: null }],
        '000105000300': [{ TITLELEVEL: '1', TITLERECT: '300,500,100,40', TITLESTYLE: '1000000', bitmapBuffer: null }],
        '000105000100': [{ TITLELEVEL: '1', TITLERECT: '100,500,100,40', TITLESTYLE: '1000000', bitmapBuffer: null }],
        '000101000100': [{ TITLELEVEL: '1', TITLERECT: '100,100,100,40', TITLESTYLE: '1000000', bitmapBuffer: null }],
      },
    });
    assert.deepEqual(
      buildManifest(note, source).outlines.map((o) => o.id),
      ['TITLE_000101000100', 'TITLE_000105000100', 'TITLE_000105000300', 'TITLE_000209000010'],
    );
  });

  it('drops a title that cannot be placed on a page', () => {
    const note = syntheticNote({
      pageCount: 2,
      titles: {
        '000901000050': [{ TITLELEVEL: '1', TITLERECT: '50,100,300,60', TITLESTYLE: '1000000', bitmapBuffer: null }],
        garbage: [{ TITLELEVEL: '1', TITLERECT: '50,100,300,60', TITLESTYLE: '1000000', bitmapBuffer: null }],
      },
    });
    assert.deepEqual(buildManifest(note, source).outlines, []);
  });

  it('treats an unparseable level as top level rather than dropping the title', () => {
    const note = syntheticNote({
      pageCount: 1,
      titles: {
        '000101000050': [{ TITLELEVEL: 'nonsense', TITLERECT: '50,100,300,60', TITLESTYLE: '1000000', bitmapBuffer: null }],
      },
    });
    assert.equal(buildManifest(note, source).outlines[0].level, 1);
  });

  it('produces an empty outline list for a note with no titles', () => {
    const manifest = buildManifest(syntheticNote(), source);
    assert.deepEqual(manifest.outlines, []);
    assert.equal(manifest.page_count, 3);
  });

  it('records the source stat used for the cache key', () => {
    const manifest = buildManifest(syntheticNote(), source);
    assert.equal(manifest.source.size, source.size);
    assert.equal(manifest.source.mtime_ms, source.mtimeMs);
    assert.equal(manifest.renderer.abi, 3);
  });
});

describe('cacheIdentity', () => {
  it('is stable for an unchanged source', () => {
    assert.deepEqual(cacheIdentity(source), cacheIdentity({ ...source }));
  });

  it('changes when size or mtime changes, but keeps the same source key', () => {
    const bigger = cacheIdentity({ ...source, size: source.size + 1 });
    const later = cacheIdentity({ ...source, mtimeMs: source.mtimeMs + 1 });
    const base = cacheIdentity(source);
    assert.equal(bigger.sourceKey, base.sourceKey);
    assert.equal(later.sourceKey, base.sourceKey);
    assert.notEqual(bigger.stateKey, base.stateKey);
    assert.notEqual(later.stateKey, base.stateKey);
  });

  it('separates two different sources', () => {
    assert.notEqual(cacheIdentity(source).sourceKey, cacheIdentity({ ...source, path: '/tmp/other.note' }).sourceKey);
  });
});

describe('resolveInCache', () => {
  it('resolves ordinary components inside the root', () => {
    assert.equal(resolveInCache('/tmp/cache', 'abc', 'page-0000.svg'), '/tmp/cache/abc/page-0000.svg');
  });

  it('refuses components that escape the root', () => {
    assert.throws(() => resolveInCache('/tmp/cache', '..', 'escaped'), /outside the cache root/);
    assert.throws(() => resolveInCache('/tmp/cache', '../../etc/passwd'), /outside the cache root/);
    assert.throws(() => resolveInCache('/tmp/cache', '/etc/passwd'), /outside the cache root/);
  });

  it('does not treat a sibling with a shared prefix as inside the root', () => {
    assert.throws(() => resolveInCache('/tmp/cache', '../cache-evil/x'), /outside the cache root/);
  });
});

describe('compositeTitleBitmap', () => {
  const style = { background: 255, ink: 0, fill: 'hatch', recognized: true };

  it('produces three opaque channels per pixel, with no alpha left to composite', () => {
    const transparent = new Uint8Array(4 * 4); // 2x2 RGBA, fully transparent
    const out = compositeTitleBitmap(transparent, 2, 2, style);
    assert.equal(out.length, 2 * 2 * 3, 'output is RGB, so a viewer cannot see through the paper');
    for (const value of out) assert.equal(value, 255, 'transparent resolves to the background');
  });

  it('paints fully transparent pixels as the background and opaque ink as the label', () => {
    const pixels = new Uint8Array([0, 0, 0, 0, 0, 0, 0, 255]); // 2x1: clear, then black
    const out = compositeTitleBitmap(pixels, 2, 1, style);
    assert.deepEqual([...out.slice(0, 3)], [255, 255, 255], 'transparent becomes the background');
    assert.deepEqual([...out.slice(3, 6)], [0, 0, 0], 'opaque becomes the ink color');
  });

  it('blends a partially transparent pixel between ink and background', () => {
    const pixels = new Uint8Array([0, 0, 0, 128]);
    const out = compositeTitleBitmap(pixels, 1, 1, style);
    assert.equal(out[0], Math.round(255 * (1 - 128 / 255)));
  });

  it('respects an inverted style', () => {
    const pixels = new Uint8Array([0, 0, 0, 0, 0, 0, 0, 255]);
    const out = compositeTitleBitmap(pixels, 2, 1, { background: 0, ink: 254, fill: 'solid', recognized: true });
    assert.deepEqual([...out.slice(0, 3)], [0, 0, 0]);
    assert.deepEqual([...out.slice(3, 6)], [254, 254, 254]);
  });

  it('refuses a bitmap shorter than its declared size', () => {
    assert.throws(() => compositeTitleBitmap(new Uint8Array(4), 4, 4, style), /expected/);
  });
});

describe('untrusted metadata bounds', () => {
  it('truncates a note string long enough to bloat the response', () => {
    // Values come from an unbounded `[^:<>]+' field, so a crafted header could
    // otherwise put hundreds of megabytes on stdout and into the cache.
    const note = syntheticNote();
    note.header.APPLY_EQUIPMENT = 'A'.repeat(100000);
    note.pages[0].PAGEID = 'B'.repeat(100000);
    const manifest = buildManifest(note, source);
    assert.ok(manifest.source.equipment.length <= 300, manifest.source.equipment.length);
    assert.ok(manifest.pages[0].page_id.length <= 300, manifest.pages[0].page_id.length);
    assert.ok(manifest.source.equipment.endsWith('\u2026'), 'truncation is visible, not silent');
    // A normal value is untouched.
    const plain = buildManifest(syntheticNote(), source);
    assert.equal(plain.source.equipment, 'N5');
    assert.equal(plain.pages[0].page_id, 'PAGE0');
  });

  it('rejects a page that declares more layers than the format defines', () => {
    // `LAYERSEQ' is split from one untrusted string, and each entry costs a
    // full-page RGBA buffer held concurrently while the page composites.
    const note = syntheticNote();
    note.pages[0].LAYERSEQ = new Array(5000).fill('MAINLAYER');
    assert.throws(() => validateGeometry(note), /layers/);

    const ok = syntheticNote();
    ok.pages[0].LAYERSEQ = ['MAINLAYER', 'BGLAYER'];
    assert.doesNotThrow(() => validateGeometry(ok));
  });

  it('still rejects implausible page geometry and page counts', () => {
    assert.throws(() => validateGeometry({ ...syntheticNote(), pageWidth: 0 }), /non-positive/);
    assert.throws(() => validateGeometry({ ...syntheticNote(), pageWidth: 999999 }), /edge limit/);
    assert.throws(() => validateGeometry({ ...syntheticNote(), pages: [] }), /no pages/);
  });
});

describe('pageContentKey', () => {
  /** A note whose pages carry distinguishable render inputs. */
  const inked = () => {
    const note = syntheticNote({ pageCount: 3 });
    note.pages.forEach((page, index) => {
      page.LAYERSEQ = ['MAINLAYER', 'BGLAYER'];
      page.MAINLAYER = { LAYERNAME: 'MAINLAYER', bitmapBuffer: new Uint8Array([index, 1, 2, 3]) };
      page.BGLAYER = { LAYERNAME: 'BGLAYER', bitmapBuffer: new Uint8Array([9, 9]) };
      page.totalPathBuffer = new Uint8Array([index, 7, 7]);
      page.PAGESTYLEMD5 = 'md5';
    });
    return note;
  };

  it('gives each page its own key', () => {
    const note = inked();
    const keys = note.pages.map((_p, i) => pageContentKey(note, i));
    assert.equal(new Set(keys).size, 3);
    assert.ok(keys.every((key) => /^[0-9a-f]{32}$/.test(key)));
  });

  it('is stable for an unchanged page', () => {
    const note = inked();
    assert.equal(pageContentKey(note, 1), pageContentKey(inked(), 1));
  });

  it('changes only the edited page, which is what makes an edit incremental', () => {
    const before = inked();
    const keysBefore = before.pages.map((_p, i) => pageContentKey(before, i));
    // One extra stroke on page 2, as writing on the device would produce.
    const after = inked();
    after.pages[1].totalPathBuffer = new Uint8Array([1, 7, 7, 42]);
    const keysAfter = after.pages.map((_p, i) => pageContentKey(after, i));
    assert.equal(keysAfter[0], keysBefore[0], 'page 1 is untouched');
    assert.notEqual(keysAfter[1], keysBefore[1], 'page 2 changed');
    assert.equal(keysAfter[2], keysBefore[2], 'page 3 is untouched');
  });

  it('notices every input that can change the pixels', () => {
    const base = pageContentKey(inked(), 0);
    const cases = {
      ink: (n) => { n.pages[0].MAINLAYER.bitmapBuffer = new Uint8Array([5, 5, 5, 5]); },
      template: (n) => { n.pages[0].BGLAYER.bitmapBuffer = new Uint8Array([8]); },
      strokes: (n) => { n.pages[0].totalPathBuffer = new Uint8Array([0, 7, 8]); },
      style: (n) => { n.pages[0].PAGESTYLE = 'style_other'; },
      'style digest': (n) => { n.pages[0].PAGESTYLEMD5 = 'other'; },
      order: (n) => { n.pages[0].LAYERSEQ = ['BGLAYER', 'MAINLAYER']; },
      geometry: (n) => { n.pageWidth = 1080; },
    };
    for (const [what, mutate] of Object.entries(cases)) {
      const note = inked();
      mutate(note);
      assert.notEqual(pageContentKey(note, 0), base, `${what} must change the key`);
    }
  });

  it('cannot confuse two adjacent buffers with one longer one', () => {
    // The lengths are hashed alongside the bytes, so this pair must differ.
    const a = inked();
    a.pages[0].MAINLAYER.bitmapBuffer = new Uint8Array([1, 2]);
    a.pages[0].totalPathBuffer = new Uint8Array([3, 4]);
    const b = inked();
    b.pages[0].MAINLAYER.bitmapBuffer = new Uint8Array([1, 2, 3]);
    b.pages[0].totalPathBuffer = new Uint8Array([4]);
    assert.notEqual(pageContentKey(a, 0), pageContentKey(b, 0));
  });
});

describe('titleContentKey', () => {
  const rect = { x: 138, y: 270, width: 208, height: 73 };
  const title = () => ({ TITLESTYLE: '1000000', bitmapBuffer: new Uint8Array([1, 2, 3]) });

  it('is stable, and changes with the bitmap, rectangle or style', () => {
    const base = titleContentKey(title(), rect);
    assert.equal(base, titleContentKey(title(), rect));
    assert.notEqual(base, titleContentKey({ ...title(), TITLESTYLE: '1064000' }, rect));
    assert.notEqual(base, titleContentKey(title(), { ...rect, width: 209 }));
    assert.notEqual(base,
      titleContentKey({ ...title(), bitmapBuffer: new Uint8Array([1, 2, 4]) }, rect));
  });
});
