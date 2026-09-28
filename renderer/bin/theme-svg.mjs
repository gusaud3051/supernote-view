// Semantic SVG colors.  Keep artifacts independent of the editor's theme:
// the viewer replaces only the marked definitions, never the ink geometry.
export function themeSvg(svg, strokes, styles, vectorInk) {
  const primitives = vectorInk.buildVectorInkPrimitives(strokes, styles);
  const roles = new Map();
  strokes.forEach((stroke, i) => {
    const style = styles[i];
    // White cover-up strokes must follow paper, including white markers.
    const role = style?.tier === 'marker' && vectorInk.greyLevel(style.color) < 250
      ? 'marker' : 'pen';
    if (stroke.points) roles.set(stroke.points, role);
    for (const ring of stroke.contour ?? []) roles.set(ring, role);
  });
  const palette = new Map();
  function colorAttribute(attribute, color, role) {
    const match = /^rgb\((\d+),\s*(\d+),\s*(\d+)\)$/.exec(color);
    const rgb = color === 'white' ? [255, 255, 255] : match?.slice(1).map(Number);
    if (!rgb || rgb.some((v) => v > 255)) return `${attribute}="${color}"`;
    const name = `sn-${role}-${rgb.join('-')}`;
    palette.set(name, `rgb(${rgb.join(',')})`);
    return `class="${name}" ${attribute}="currentColor"`;
  }
  // The pinned library emits one path/rect per primitive, in compositor order.
  // Annotate that order rather than guessing the pen type from its shade.
  let index = 0;
  svg = svg.replace(/(<image\b[^>]*\/>)([\s\S]*)(<\/svg>)/, (_, image, ink, end) => {
    ink = ink.replace(/<(path|rect)\b[^>]*\/>/g, (element) => {
      const primitive = primitives[index++];
      if (!primitive) throw new Error('SVG primitive count mismatch');
      const role = roles.get(primitive.points ?? primitive.rings?.[0]) ?? 'pen';
      return element.replace(/\b(fill|stroke)="(rgb\([^"]+\)|white)"/g,
        (_, attribute, color) => colorAttribute(attribute, color, role));
    });
    return image.replace('<image ', '<image filter="url(#sn-template)" ') + ink + end;
  });
  if (index !== primitives.length) throw new Error('SVG primitive count mismatch');
  // Heading hatch patterns have their own white paper and ink colors.
  svg = svg.replace(/<defs>([\s\S]*?)<\/defs>/g, (_, defs) =>
    `<defs>${defs.replace(/\b(fill|stroke)="(rgb\([^"]+\)|white)"/g,
      (_, attribute, color) => colorAttribute(attribute, color, 'pen'))}</defs>`);
  const rules = [...palette].map(([name, color]) => `.${name}{color:${color}}`).join('');
  const definitions = '<!--sn-theme-start--><defs><style>' + rules + '</style>' +
    '<filter id="sn-template" color-interpolation-filters="sRGB" x="0" y="0" width="100%" height="100%">' +
    '<feComponentTransfer><feFuncR type="linear" slope="1" intercept="0"/>' +
    '<feFuncG type="linear" slope="1" intercept="0"/>' +
    '<feFuncB type="linear" slope="1" intercept="0"/></feComponentTransfer></filter>' +
    '</defs><!--sn-theme-end-->';
  return svg.replace(/(<svg\b[^>]*>)/, `$1${definitions}`);
}
