// Unit tests for display.mjs. Run with `node --test` in pipeline/style (the
// pipeline test image runs them from tests/display.bats).

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import {
  DisplayError,
  attributeValues,
  buildStyle,
  colorValue,
  computeBreaks,
  deriveLegend,
  drawOrder,
  resolveDisplay,
  styleProblems,
  symbologyLayers,
  symbologyLegend,
  RASTER_SOURCE,
  configType,
  rgba,
} from '../display.mjs';

const layersDir = new URL('../../layers/', import.meta.url);
const readConfig = (name) => JSON.parse(readFileSync(new URL(`${name}.style.json`, layersDir)));
const expected = JSON.parse(
  readFileSync(new URL('../../tests/fixtures/expected_display.json', import.meta.url)),
);

/** The problems a call throws, or fails if it does not throw a DisplayError. */
function problemsOf(fn) {
  try {
    fn();
  } catch (error) {
    assert.ok(error instanceof DisplayError, `expected a DisplayError, got ${error}`);
    return error.problems;
  }
  assert.fail('expected a DisplayError');
}

const stepped = {
  type: 'stepped',
  attribute: 'score',
  stops: [
    { from: 0, color: '#111111' },
    { from: 25, color: '#222222' },
    { from: 1000, color: '#333333' },
  ],
  max: 2500,
  fallback: { color: '#999999', label: 'No score' },
};

const categorical = {
  type: 'categorical',
  attribute: 'kind',
  categories: [
    { value: 'a', color: '#aa0000', label: 'Kind A' },
    { value: 'b', color: '#00aa00', label: 'Kind B' },
  ],
  fallback: { color: '#999999' },
};

const polygon = (color) => ({
  geometry: 'polygon',
  color,
  fillOpacity: 0.5,
  outline: { color: '#ffffff', width: 1 },
});

const point = (color) => ({
  geometry: 'point',
  color,
  radius: 5,
  stroke: { color: '#000000', width: 2 },
});

const config = (extra) => ({ title: 'Test', defaultVisible: true, ...extra });

describe('sample configs', () => {
  for (const name of ['sample', 'sample_points']) {
    it(`resolves ${name} to the expected display block`, () => {
      assert.deepEqual(resolveDisplay(name, readConfig(name)), expected[name]);
    });
  }
});

describe('colorValue', () => {
  it('uses a single colour as a constant', () => {
    assert.equal(colorValue({ type: 'single', color: '#123456' }), '#123456');
  });

  it('builds a match on the attribute for categories, with the fallback last', () => {
    assert.deepEqual(colorValue(categorical), [
      'match',
      ['to-string', ['get', 'kind']],
      'a',
      '#aa0000',
      'b',
      '#00aa00',
      '#999999',
    ]);
  });

  it('builds a step on the attribute for a ramp, guarded for missing values', () => {
    assert.deepEqual(colorValue(stepped), [
      'case',
      ['==', ['typeof', ['get', 'score']], 'number'],
      ['step', ['get', 'score'], '#111111', 25, '#222222', 1000, '#333333'],
      '#999999',
    ]);
  });
});

describe('symbologyLayers', () => {
  it('draws polygons as a fill then an outline', () => {
    const layers = symbologyLayers(polygon(stepped));
    assert.deepEqual(
      layers.map((l) => [l.id, l.type]),
      [
        ['fill', 'fill'],
        ['outline', 'line'],
      ],
    );
    assert.deepEqual(layers[0].paint, { 'fill-color': colorValue(stepped), 'fill-opacity': 0.5 });
    assert.deepEqual(layers[1].paint, { 'line-color': '#ffffff', 'line-width': 1 });
  });

  it('draws points as circles with a stroke', () => {
    assert.deepEqual(symbologyLayers(point(categorical)), [
      {
        id: 'circle',
        type: 'circle',
        paint: {
          'circle-color': colorValue(categorical),
          'circle-radius': 5,
          'circle-stroke-color': '#000000',
          'circle-stroke-width': 2,
        },
      },
    ]);
  });

  for (const [label, symbology] of [
    ['single polygon', polygon({ type: 'single', color: '#123456' })],
    ['categorical polygon', polygon(categorical)],
    ['stepped polygon', polygon(stepped)],
    ['single point', point({ type: 'single', color: '#123456' })],
    ['categorical point', point(categorical)],
    ['stepped point', point(stepped)],
  ]) {
    it(`produces valid MapLibre layers for a ${label}`, () => {
      assert.ok(resolveDisplay('test', config({ symbology })));
    });
  }

  it('is caught by the MapLibre validator when the stops are out of order', () => {
    const unordered = { ...stepped, stops: [...stepped.stops].reverse() };
    const problems = problemsOf(() => resolveDisplay('test', config({ symbology: polygon(unordered) })));
    assert.match(problems.join('\n'), /MapLibre style: .*ascending/);
  });
});

describe('symbologyLegend', () => {
  it('lists ramp steps with ranges, the last up to max, then the fallback', () => {
    assert.deepEqual(symbologyLegend(polygon(stepped), 'Test'), {
      kind: 'ramp',
      shape: 'square',
      border: '#ffffff',
      opacity: 0.5,
      items: [
        { color: '#111111', label: '0 to 25' },
        { color: '#222222', label: '25 to 1,000' },
        { color: '#333333', label: '1,000 to 2,500' },
        { color: '#999999', label: 'No score' },
      ],
    });
  });

  it('lists categories, leaving out a fallback without a label', () => {
    assert.deepEqual(symbologyLegend(point(categorical), 'Test'), {
      kind: 'categories',
      shape: 'circle',
      border: '#000000',
      opacity: 1,
      items: [
        { color: '#aa0000', label: 'Kind A' },
        { color: '#00aa00', label: 'Kind B' },
      ],
    });
  });

  it('labels a single colour with the layer title unless given a label', () => {
    assert.deepEqual(symbologyLegend(point({ type: 'single', color: '#123456' }), 'Test').items, [
      { color: '#123456', label: 'Test' },
    ]);
    assert.deepEqual(
      symbologyLegend(point({ type: 'single', color: '#123456', label: 'Sites' }), 'Test').items,
      [{ color: '#123456', label: 'Sites' }],
    );
  });
});

describe('breaks', () => {
  // 1 to 10 and one outlier: equal and quantile breaks differ clearly.
  const values = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 100];

  it('computes equal interval breaks from min to max', () => {
    assert.deepEqual(computeBreaks(values, 'equal', 4), { bounds: [1, 25.75, 50.5, 75.25], max: 100 });
    assert.deepEqual(computeBreaks([0, 100], 'equal', 3), {
      bounds: [0, 33.3333333333, 66.6666666667],
      max: 100,
    });
  });

  it('computes quantile breaks at ranks floor(i * n / classes)', () => {
    // n = 11: ranks 0, 2, 5, 8.
    assert.deepEqual(computeBreaks(values, 'quantile', 4), { bounds: [1, 3, 6, 9], max: 100 });
  });

  it('ignores order in the input', () => {
    assert.deepEqual(computeBreaks([...values].reverse(), 'quantile', 4).bounds, [1, 3, 6, 9]);
  });

  it('fails without data or with too few distinct values', () => {
    assert.match(problemsOf(() => computeBreaks([], 'equal', 3))[0], /no numeric values/);
    assert.match(problemsOf(() => computeBreaks([1, 1, 1, 2], 'quantile', 4))[0], /not distinct/);
  });

  it('reads numeric values of one attribute from GeoJSONSeq', () => {
    const text = [
      { properties: { score: 3 } },
      { properties: { score: 'x' } },
      { properties: {} },
      { properties: { score: 1.5 } },
    ]
      .map((f) => JSON.stringify({ type: 'Feature', geometry: null, ...f }))
      .join('\n');
    assert.deepEqual(attributeValues(`${text}\n`, 'score'), [3, 1.5]);
  });

  it('resolves breaks into stops, colours and the legend', () => {
    const symbology = polygon({
      type: 'stepped',
      attribute: 'score',
      breaks: { method: 'quantile', classes: 4 },
      colors: ['#111111', '#222222', '#333333', '#444444'],
      fallback: { color: '#999999', label: 'No score' },
    });
    const display = resolveDisplay('test', config({ symbology }), (attribute) => {
      assert.equal(attribute, 'score');
      return values;
    });
    assert.deepEqual(display.layers[0].paint['fill-color'][2], [
      'step',
      ['get', 'score'],
      '#111111',
      3,
      '#222222',
      6,
      '#333333',
      9,
      '#444444',
    ]);
    assert.deepEqual(
      display.legend.items.map((i) => i.label),
      ['1 to 3', '3 to 6', '6 to 9', '9 to 100', 'No score'],
    );
  });

  it('needs one colour per class', () => {
    const symbology = polygon({
      type: 'stepped',
      attribute: 'score',
      breaks: { method: 'equal', classes: 3 },
      colors: ['#111111', '#222222'],
      fallback: { color: '#999999' },
    });
    assert.match(
      problemsOf(() => resolveDisplay('test', config({ symbology }), () => values))[0],
      /classes is 3 but there are 2 colors/,
    );
  });
});

describe('raw layers', () => {
  const raw = [
    {
      id: 'fill',
      type: 'fill',
      paint: {
        'fill-color': ['match', ['get', 'kind'], 'a', '#aa0000', ['b', 'c'], '#00aa00', '#999999'],
        'fill-opacity': 0.6,
      },
    },
    { id: 'edge', type: 'line', paint: { 'line-color': '#222222', 'line-width': 2 } },
    {
      id: 'label',
      type: 'symbol',
      minzoom: 6,
      layout: { 'text-field': ['get', 'name'], 'text-size': 12 },
    },
  ];

  it('keeps the layers as given and derives a legend from a match', () => {
    const display = resolveDisplay('test', config({ layers: raw, order: 5 }));
    assert.deepEqual(display.layers, raw);
    assert.equal(display.order, 5);
    assert.deepEqual(display.legend, {
      kind: 'categories',
      shape: 'square',
      border: '#222222',
      opacity: 0.6,
      items: [
        { color: '#aa0000', label: 'a' },
        { color: '#00aa00', label: 'b, c' },
      ],
    });
  });

  it('derives a ramp from a step, open at both ends', () => {
    const legend = deriveLegend(
      [
        {
          id: 'c',
          type: 'circle',
          paint: {
            'circle-color': ['step', ['get', 'n'], '#111111', 10, '#222222', 1000, '#333333'],
            'circle-stroke-color': '#ffffff',
          },
        },
      ],
      'Test',
    );
    assert.deepEqual(legend, {
      kind: 'ramp',
      shape: 'circle',
      border: '#ffffff',
      opacity: 1,
      items: [
        { color: '#111111', label: 'Below 10' },
        { color: '#222222', label: '10 to 1,000' },
        { color: '#333333', label: '1,000 or more' },
      ],
    });
  });

  it('derives a single colour from a constant, labelled with the title', () => {
    assert.deepEqual(
      deriveLegend([{ id: 'l', type: 'line', paint: { 'line-color': '#123456' } }], 'Roads'),
      { kind: 'single', shape: 'line', border: 'transparent', opacity: 1, items: [{ color: '#123456', label: 'Roads' }] },
    );
  });

  it('cannot derive from an interpolate, and then needs an explicit legend', () => {
    const layers = [
      {
        id: 'fill',
        type: 'fill',
        paint: { 'fill-color': ['interpolate', ['linear'], ['get', 'n'], 0, '#000000', 1, '#ffffff'] },
      },
    ];
    assert.equal(deriveLegend(layers, 'Test'), null);
    assert.match(
      problemsOf(() => resolveDisplay('test', config({ layers })))[0],
      /cannot derive a legend.*explicit "legend"/,
    );
    const display = resolveDisplay(
      'test',
      config({ layers, legend: { kind: 'ramp', items: [{ color: '#000000', label: 'Low' }, { color: '#ffffff', label: 'High' }] } }),
    );
    assert.deepEqual(display.legend, {
      kind: 'ramp',
      shape: 'square',
      border: 'transparent',
      opacity: 1,
      items: [
        { color: '#000000', label: 'Low' },
        { color: '#ffffff', label: 'High' },
      ],
    });
  });

  it('an explicit legend overrides the derived items but keeps its other fields', () => {
    const display = resolveDisplay(
      'test',
      config({ layers: raw, legend: { items: [{ color: '#aa0000', label: 'Kind A' }] } }),
    );
    assert.deepEqual(display.legend, {
      kind: 'categories',
      shape: 'square',
      border: '#222222',
      opacity: 0.6,
      items: [{ color: '#aa0000', label: 'Kind A' }],
    });
  });

  it('rejects duplicate ids', () => {
    const layers = [raw[0], { ...raw[1], id: 'fill' }];
    assert.match(problemsOf(() => resolveDisplay('test', config({ layers })))[0], /duplicate id fill/);
  });

  it('rejects style-spec errors through the MapLibre validator', () => {
    const layers = [{ id: 'fill', type: 'fill', paint: { 'fill-color': '#aa0000', 'fill-opacity': 'lots' } }];
    assert.match(
      problemsOf(() => resolveDisplay('test', config({ layers }))).join('\n'),
      /MapLibre style: layers\[0\]\.paint\.fill-opacity: number expected, string found/,
    );
  });
});

describe('schema checks', () => {
  it('lists every problem with its location', () => {
    const problems = problemsOf(() =>
      resolveDisplay('test', {
        title: '',
        defaultVisible: 'yes',
        colour: 'red',
        symbology: polygon(stepped),
      }),
    );
    assert.ok(problems.includes('/title must NOT have fewer than 1 characters'), problems.join('\n'));
    assert.ok(problems.includes('/defaultVisible must be boolean'), problems.join('\n'));
    assert.ok(problems.includes('(top level) must NOT have additional properties: colour'), problems.join('\n'));
  });

  it('needs exactly one of symbology and layers', () => {
    assert.ok(problemsOf(() => resolveDisplay('test', config({}))).some((p) => /symbology/.test(p)));
    const both = config({ symbology: polygon(stepped), layers: [{ id: 'x', type: 'fill' }] });
    assert.ok(problemsOf(() => resolveDisplay('test', both)).includes('/symbology is not allowed here'));
  });

  it('does not let a style layer set its own source', () => {
    const layers = [{ id: 'fill', type: 'fill', source: 'other', paint: { 'fill-color': '#000000' } }];
    assert.ok(problemsOf(() => resolveDisplay('test', config({ layers }))).includes('/layers/0/source is not allowed here'));
  });

  it('needs explicit stops or breaks with colours, not both', () => {
    const mixed = polygon({ ...stepped, breaks: { method: 'equal', classes: 3 } });
    const problems = problemsOf(() => resolveDisplay('test', config({ symbology: mixed })));
    assert.ok(problems.includes('/symbology/color must have required property \'colors\''), problems.join('\n'));
    assert.ok(problems.includes('/symbology/color/stops is not allowed here'), problems.join('\n'));
  });
});

describe('combined style', () => {
  const entries = [
    { name: 'points', file: 'points.pmtiles', display: expected.sample_points },
    { name: 'polys', file: 'polys.pmtiles', display: { ...expected.sample, defaultVisible: false } },
  ];

  it('orders layers by order, then name', () => {
    const a = { name: 'a', display: { order: 1 } };
    const b = { name: 'b', display: { order: 0 } };
    const c = { name: 'c', display: { order: 0 } };
    assert.deepEqual(drawOrder([a, c, b]).map((e) => e.name), ['b', 'c', 'a']);
  });

  it('is a valid style with pmtiles sources, prefixed ids and default visibility', () => {
    const style = buildStyle(drawOrder(entries));
    assert.deepEqual(styleProblems(style), []);
    assert.deepEqual(style.sources, {
      polys: { type: 'vector', url: 'pmtiles://polys.pmtiles' },
      points: { type: 'vector', url: 'pmtiles://points.pmtiles' },
    });
    assert.deepEqual(
      style.layers.map((l) => [l.id, l.source, l['source-layer'], l.layout.visibility]),
      [
        ['polys-fill', 'polys', 'polys', 'none'],
        ['polys-outline', 'polys', 'polys', 'none'],
        ['points-circle', 'points', 'points', 'visible'],
      ],
    );
    assert.equal(style.glyphs, undefined);
  });

  it('adds glyphs when a layer shows text', () => {
    const display = {
      ...expected.sample_points,
      layers: [{ id: 'label', type: 'symbol', layout: { 'text-field': ['get', 'name'] } }],
    };
    const style = buildStyle([{ name: 'labels', file: 'labels.pmtiles', display }]);
    assert.match(style.glyphs, /^https:\/\//);
    assert.deepEqual(styleProblems(style), []);
  });
});

describe('raster layers', () => {
  const rasterConfig = () => ({
    title: 'Cover',
    defaultVisible: true,
    order: 2,
    symbology: { geometry: 'raster', color: '#1b7837', opacity: 0.5 },
  });
  const expectedRaster = JSON.parse(
    readFileSync(new URL('../../tests/fixtures/expected_raster_display.json', import.meta.url)),
  );

  it('resolves the test config to the shared expected display', () => {
    const config = JSON.parse(
      readFileSync(new URL('../../tests/fixtures/raster.style.json', import.meta.url)),
    );
    assert.deepEqual(resolveDisplay('cover', config, undefined, 'raster'), expectedRaster);
  });

  it('expands to one color-relief layer and a single swatch, label defaulting to the title', () => {
    const display = resolveDisplay('cover', rasterConfig(), undefined, 'raster');
    assert.equal(display.layers.length, 1);
    assert.equal(display.layers[0].type, 'color-relief');
    assert.deepEqual(display.layers[0].paint['color-relief-color'].slice(3), [
      0,
      'rgba(27, 120, 55, 0)',
      1,
      'rgba(27, 120, 55, 1)',
    ]);
    assert.equal(display.layers[0].paint['color-relief-opacity'], 0.5);
    assert.deepEqual(display.legend.items, [{ color: '#1b7837', label: 'Cover' }]);
    assert.equal(display.legend.opacity, 0.5);
  });

  it('infers the type from the config, and checks it against the layer type', () => {
    assert.equal(configType(rasterConfig()), 'raster');
    assert.equal(configType(readConfig('sample')), 'vector');
    assert.ok(resolveDisplay('cover', rasterConfig()));
    assert.match(
      problemsOf(() => resolveDisplay('cover', rasterConfig(), undefined, 'vector'))[0],
      /for raster layers only/,
    );
    assert.match(
      problemsOf(() => resolveDisplay('cover', readConfig('sample'), () => [], 'raster'))[0],
      /needs "symbology" with "geometry": "raster"/,
    );
  });

  it('rejects a pop-up, a named colour and raw color-relief layers', () => {
    const withPopup = { ...rasterConfig(), popup: { title: { attribute: 'x' }, stats: [] } };
    assert.match(problemsOf(() => resolveDisplay('cover', withPopup))[0], /display only/);
    const named = rasterConfig();
    named.symbology.color = 'green';
    assert.ok(problemsOf(() => resolveDisplay('cover', named)).some((p) => p.includes('pattern')));
    const raw = {
      title: 'Raw',
      defaultVisible: true,
      layers: [{ id: 'r', type: 'color-relief' }],
      legend: { items: [{ color: '#000000', label: 'x' }] },
    };
    assert.ok(problemsOf(() => resolveDisplay('raw', raw)).length > 0);
  });

  it('gets a raster-dem source and no source layer in the combined style', () => {
    const style = buildStyle([
      { name: 'cover', file: 'cover.pmtiles', type: 'raster', display: expectedRaster },
      { name: 'polys', file: 'polys.pmtiles', type: 'vector', display: expected.sample },
    ]);
    assert.deepEqual(styleProblems(style), []);
    assert.deepEqual(style.sources.cover, { ...RASTER_SOURCE, url: 'pmtiles://cover.pmtiles' });
    assert.equal(style.layers[0].id, 'cover-raster');
    assert.equal('source-layer' in style.layers[0], false);
    assert.equal(style.layers[1]['source-layer'], 'polys');
  });

  it('writes colours as rgba()', () => {
    assert.equal(rgba('#ff8000', 0.25), 'rgba(255, 128, 0, 0.25)');
  });
});
