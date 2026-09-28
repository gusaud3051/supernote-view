import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { addSvgPage } from 'supernote-typescript';
import * as vectorInk from 'supernote-typescript/lib/vector-ink.js';
import { themeSvg } from '../bin/theme-svg.mjs';

const line = (x) => ({ points: [{ x, y: 1 }, { x: x + 10, y: 10 }] });
const style = (tier, color = 'rgb(128, 128, 128)') => ({ shape: 'path', tier, color, width: 5 });
function render(strokes, styles) {
  const svg = addSvgPage({}, new Uint8Array([1, 2, 3]), 100, 100,
    { strokes, strokeStyles: styles, includeText: false });
  return themeSvg(svg, strokes, styles, vectorInk);
}

describe('semantic theme SVG', () => {
  it('distinguishes a marker from a pen of exactly the same color', () => {
    const svg = render([line(0), line(20)], [style('pen'), style('marker')]);
    assert.match(svg, /class="sn-pen-128-128-128" stroke="currentColor"/);
    assert.match(svg, /class="sn-marker-128-128-128" stroke="currentColor"/);
    assert.match(svg, /\.sn-marker-128-128-128\{color:rgb\(128,128,128\)\}/);
    assert.match(svg, /<image filter="url\(#sn-template\)"/);
    assert.match(svg, /color-interpolation-filters="sRGB"/);
  });
  it('preserves compositor ordering when a highlighter is moved below ink', () => {
    const svg = render([line(0), line(0)], [style('pen', 'rgb(0, 0, 0)'), style('marker')]);
    const elements = [...svg.matchAll(/<path[^>]*class="([^"]+)"/g)].map((m) => m[1]);
    assert.deepEqual(elements, ['sn-marker-128-128-128', 'sn-pen-0-0-0']);
  });
  it('themes white marker cover-up strokes as paper', () => {
    assert.match(render([line(0)], [style('marker', 'rgb(254, 254, 254)')]),
      /class="sn-pen-254-254-254"/);
  });
  it('classifies filled contours as well as centerlines', () => {
    const stroke = { ...line(0), contour: [[{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 5, y: 5 }]] };
    assert.match(render([stroke], [style('marker')]),
      /class="sn-marker-128-128-128" fill="currentColor"/);
  });
  it('themes heading hatch paper and ink without changing invisible text', () => {
    const svg = render([line(0)], [{ shape: 'rect', fill: 'hatch', color: 'rgb(0, 0, 0)' }]);
    assert.match(svg, /<rect[^>]*class="sn-pen-255-255-255" fill="currentColor"/);
    assert.match(svg, /<line[^>]*class="sn-pen-0-0-0" stroke="currentColor"/);
  });
});
