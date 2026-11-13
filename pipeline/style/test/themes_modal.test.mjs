// Unit tests for colour themes, the interpolated colour rule, number format
// presets and the click modal template (ADR 0012). Run with `node --test`
// in pipeline/style (the pipeline test image runs them from
// tests/display.bats).

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import {
  DisplayError,
  colorValue,
  modalProblems,
  resolveDisplay,
  ruleNeedsData,
  symbologyLegend,
  templateProblems,
} from '../display.mjs';

const fixture = (name) => new URL(`../../tests/fixtures/${name}`, import.meta.url);
const readJson = (name) => JSON.parse(readFileSync(fixture(name), 'utf8'));

/** Numeric values of an attribute in the sample fixture (a FeatureCollection). */
const sampleValues = (attribute) =>
  readJson('sample.geojson')
    .features.map((f) => f.properties[attribute])
    .filter((v) => typeof v === 'number');

function problemsOf(fn) {
  try {
    fn();
  } catch (error) {
    assert.ok(error instanceof DisplayError, `expected a DisplayError, got ${error}`);
    return error.problems;
  }
  assert.fail('expected a DisplayError');
}

const polygon = (extra) => ({
  title: 'Test',
  defaultVisible: true,
  symbology: {
    geometry: 'polygon',
    fillOpacity: 0.5,
    outline: { color: '#ffffff', width: 1 },
    ...extra,
  },
});

const gradient = {
  type: 'interpolated',
  attribute: 'score',
  stops: [
    { value: 0, color: '#f7fbff' },
    { value: 25, color: '#6baed6' },
    { value: 100, color: '#08306b' },
  ],
  fallback: { color: '#9e9e9e', label: 'No data' },
};

const single = (color) => ({ type: 'single', color });

describe('interpolated colour rule', () => {
  it('is a linear interpolate on the attribute, guarded for missing values', () => {
    assert.deepEqual(colorValue(gradient), [
      'case',
      ['==', ['typeof', ['get', 'score']], 'number'],
      ['interpolate', ['linear'], ['get', 'score'], 0, '#f7fbff', 25, '#6baed6', 100, '#08306b'],
      '#9e9e9e',
    ]);
  });

  it('has a gradient legend with each stop at its position, then the labelled fallback', () => {
    const legend = symbologyLegend(polygon({ color: gradient }).symbology, 'Test');
    assert.equal(legend.kind, 'gradient');
    assert.deepEqual(legend.items, [
      { color: '#f7fbff', label: '0', position: 0 },
      { color: '#6baed6', label: '25', position: 0.25 },
      { color: '#08306b', label: '100', position: 1 },
      { color: '#9e9e9e', label: 'No data' },
    ]);
  });

  it('spreads colors evenly from the data minimum to maximum when no range is given', () => {
    const rule = { type: 'interpolated', attribute: 'score', colors: ['#000000', '#888888', '#ffffff'], fallback: { color: '#999999' } };
    assert.equal(ruleNeedsData(rule), true);
    const display = resolveDisplay('t', polygon({ color: rule }), () => [10, 30, 50, 'x']);
    const ramp = display.layers[0].paint['fill-color'][2];
    assert.deepEqual(ramp, ['interpolate', ['linear'], ['get', 'score'], 10, '#000000', 30, '#888888', 50, '#ffffff']);
  });

  it('rounds gradient labels to suit the range', () => {
    const rule = { type: 'interpolated', attribute: 'wtw', colors: ['#000000', '#888888', '#ffffff'], min: 0, fallback: { color: '#999999' } };
    const labels = (values) =>
      resolveDisplay('t', polygon({ color: rule }), () => values).legend.items.map((i) => i.label);
    assert.deepEqual(labels([0, 79.93]), ['0', '40', '79.9']);
    assert.deepEqual(labels([0, 1234.5]), ['0', '617', '1,235']);
    assert.deepEqual(labels([0, 0.5]), ['0', '0.25', '0.5']);
  });

  it('takes a given min and max over the data', () => {
    const rule = { type: 'interpolated', attribute: 'score', colors: ['#000000', '#ffffff'], min: 0, max: 100, fallback: { color: '#999999' } };
    assert.equal(ruleNeedsData(rule), false);
    const display = resolveDisplay('t', polygon({ color: rule }));
    assert.deepEqual(display.legend.items.map((i) => i.label), ['0', '100']);
  });

  it('fails with stops out of order, without data, or with no range', () => {
    const backwards = { ...gradient, stops: [gradient.stops[1], gradient.stops[0]] };
    assert.match(problemsOf(() => resolveDisplay('t', polygon({ color: backwards })))[0], /ascending/);
    const fromData = { type: 'interpolated', attribute: 'score', colors: ['#000000', '#ffffff'], fallback: { color: '#999999' } };
    assert.deepEqual(problemsOf(() => resolveDisplay('t', polygon({ color: fromData }))), ['breaks need the layer data']);
    assert.match(problemsOf(() => resolveDisplay('t', polygon({ color: fromData }), () => [5, 5]))[0], /must be above min/);
  });

  it('cannot mix stops with colors (schema)', () => {
    const both = { ...gradient, colors: ['#000000', '#ffffff'] };
    assert.ok(problemsOf(() => resolveDisplay('t', polygon({ color: both }))).length > 0);
  });
});

describe('colour themes', () => {
  const themes = [
    { id: 'a', label: 'Theme A', color: single('#111111') },
    { id: 'b', label: 'Theme B', color: gradient },
  ];

  it('resolves each theme to its paint and legend; layers and legend are the default theme', () => {
    const display = resolveDisplay('t', polygon({ themes, defaultTheme: 'b' }));
    assert.equal(display.defaultTheme, 'b');
    assert.deepEqual(display.themes.map((t) => [t.id, t.label, Object.keys(t.paint)]), [
      ['a', 'Theme A', ['fill']],
      ['b', 'Theme B', ['fill']],
    ]);
    assert.equal(display.themes[0].paint.fill['fill-color'], '#111111');
    assert.deepEqual(display.layers[0].paint['fill-color'], colorValue(gradient));
    assert.deepEqual(display.legend, display.themes[1].legend);
    // A single colour theme's legend is labelled with the theme's label.
    assert.equal(display.themes[0].legend.items[0].label, 'Theme A');
  });

  it('defaults to the first theme', () => {
    const display = resolveDisplay('t', polygon({ themes }));
    assert.equal(display.defaultTheme, 'a');
    assert.equal(display.layers[0].paint['fill-color'], '#111111');
  });

  it('colours points by circle-color', () => {
    const config = {
      title: 'Points',
      defaultVisible: true,
      symbology: { geometry: 'point', radius: 4, stroke: { color: '#ffffff', width: 1 }, themes },
    };
    const display = resolveDisplay('p', config);
    assert.deepEqual(Object.keys(display.themes[1].paint.circle), ['circle-color']);
    assert.equal(display.themes[1].legend.shape, 'circle');
  });

  it('takes a theme legend over the derived one', () => {
    const withLegend = [themes[0], { ...themes[1], legend: { items: [{ color: '#08306b', label: 'High' }] } }];
    const display = resolveDisplay('t', polygon({ themes: withLegend }));
    assert.deepEqual(display.themes[1].legend.items, [{ color: '#08306b', label: 'High' }]);
    assert.equal(display.themes[1].legend.kind, 'gradient');
  });

  it('resolves breaks per theme from the data, and names the theme in problems', () => {
    const breaks = {
      type: 'stepped',
      attribute: 'score',
      breaks: { method: 'equal', classes: 2 },
      colors: ['#000000', '#ffffff'],
      fallback: { color: '#999999' },
    };
    const display = resolveDisplay('t', polygon({ themes: [themes[0], { id: 'c', label: 'C', color: breaks }] }), () => [0, 10]);
    assert.deepEqual(display.themes[1].legend.items.map((i) => i.label), ['0 to 5', '5 to 10']);
    const bad = { ...breaks, colors: ['#000000', '#888888', '#ffffff'] };
    assert.deepEqual(
      problemsOf(() => resolveDisplay('t', polygon({ themes: [{ id: 'c', label: 'C', color: bad }] }), () => [0, 10])),
      ['symbology.themes[0] (c).color: breaks.classes is 2 but there are 3 colors'],
    );
  });

  it('rejects repeated ids, an unknown default, a top-level legend, and color with themes', () => {
    const repeated = [themes[0], { ...themes[1], id: 'a' }];
    assert.deepEqual(problemsOf(() => resolveDisplay('t', polygon({ themes: repeated }))), [
      'symbology.themes: duplicate id a',
    ]);
    assert.match(problemsOf(() => resolveDisplay('t', polygon({ themes, defaultTheme: 'z' })))[0], /no theme z/);
    const legend = { ...polygon({ themes }), legend: { items: [{ color: '#000000', label: 'x' }] } };
    assert.match(problemsOf(() => resolveDisplay('t', legend))[0], /not used with symbology.themes/);
    assert.ok(problemsOf(() => resolveDisplay('t', polygon({ themes, color: single('#000000') }))).length > 0);
    assert.ok(problemsOf(() => resolveDisplay('t', polygon({ color: single('#000000'), defaultTheme: 'a' }))).length > 0);
  });
});

describe('number format presets', () => {
  it('a stat format may be a preset name or an object with a preset', () => {
    const config = {
      ...polygon({ color: single('#000000') }),
      popup: {
        title: { attribute: 'name' },
        stats: [
          { label: 'A', value: { attribute: 'a' }, format: 'percent' },
          { label: 'B', value: { attribute: 'b' }, format: { preset: 'hectares', decimals: 1 } },
        ],
      },
    };
    assert.deepEqual(resolveDisplay('t', config).popup, config.popup);
  });

  it('rejects an unknown preset', () => {
    const config = {
      ...polygon({ color: single('#000000') }),
      popup: { title: { attribute: 'name' }, stats: [{ label: 'A', value: { attribute: 'a' }, format: 'acres' }] },
    };
    assert.ok(problemsOf(() => resolveDisplay('t', config)).length > 0);
  });
});

describe('modal template', () => {
  const modal = (sections) => ({ title: '{name}', sections });
  const withModal = (m) => ({ ...polygon({ color: single('#000000') }), modal: m });

  it('the sample modal fixture resolves to the expected display block', () => {
    const display = resolveDisplay('sample', readJson('sample_modal.style.json'), sampleValues);
    assert.deepEqual(display, readJson('expected_modal_display.json'));
  });

  it('is copied into the display as it is', () => {
    const m = modal([{ heading: 'Notes', description: 'About {name}.' }]);
    assert.deepEqual(resolveDisplay('t', withModal(m)).modal, m);
  });

  it('a layer cannot have both a pop-up and a modal, and a raster layer has neither', () => {
    const both = { ...withModal(modal([{ heading: 'A', description: 'x' }])), popup: { title: { attribute: 'n' }, stats: [] } };
    assert.ok(problemsOf(() => resolveDisplay('t', both)).length > 0);
    const raster = {
      title: 'R',
      defaultVisible: true,
      symbology: { geometry: 'raster', color: '#00aa00', opacity: 1 },
      modal: modal([{ heading: 'A', description: 'x' }]),
    };
    assert.deepEqual(problemsOf(() => resolveDisplay('r', raster, undefined, 'raster')), [
      'modal: raster layers are display only and cannot have a modal',
    ]);
  });

  it('a section needs a description or blocks (schema)', () => {
    assert.ok(problemsOf(() => resolveDisplay('t', withModal(modal([{ heading: 'Empty' }])))).length > 0);
  });

  it('checks table rows and chart series against their columns and categories', () => {
    const m = modal([
      {
        heading: 'Data',
        blocks: [
          { type: 'table', columns: [{ label: 'A' }, { label: 'B' }], rows: [{ label: 'r', values: ['a'] }] },
          {
            type: 'chart',
            chart: 'pie',
            title: 'Pie',
            valueLabel: 'V',
            categories: ['x', 'y'],
            series: [
              { label: 's', attributes: ['a', 'b'] },
              { label: 't', attributes: ['a'] },
            ],
            colors: ['#000000'],
          },
        ],
      },
    ]);
    assert.deepEqual(modalProblems(m), [
      'modal.sections[0].blocks[0].rows[0]: 1 values for 2 columns',
      'modal.sections[0].blocks[1].series[1]: 1 attributes for 2 categories',
      'modal.sections[0].blocks[1]: a pie chart takes exactly one series',
      'modal.sections[0].blocks[1].colors: 1 colours for 2 categories',
    ]);
    assert.equal(problemsOf(() => resolveDisplay('t', withModal(m))).length, 4);
  });

  it('checks placeholders', () => {
    assert.deepEqual(templateProblems('{name} in {area_ha:hectares}, id {$id}', 'x'), []);
    assert.deepEqual(templateProblems('{name:acres}', 'x'), [
      'x: {name:acres}: unknown format preset acres (number, count, percent, hectares, km)',
    ]);
    assert.match(templateProblems('{two words}', 'x')[0], /not a valid placeholder/);
    assert.match(templateProblems('open { brace', 'x')[0], /unmatched/);
    const m = modal([{ heading: 'A', blocks: [{ type: 'list', items: [{ text: '{bad name}' }], empty: 'None' }] }]);
    assert.match(modalProblems(m)[0], /^modal.sections\[0\].blocks\[0\].items\[0\].text:/);
  });

  it('takes a layout and short tab labels, copied as they are', () => {
    for (const layout of ['tabs', 'scroll']) {
      const m = { ...modal([{ heading: 'Direct threats', tab: 'Threats', description: 'x' }]), layout };
      assert.deepEqual(resolveDisplay('t', withModal(m)).modal, m);
    }
  });

  it('rejects a layout not known and an empty tab label (schema)', () => {
    const layout = { ...modal([{ heading: 'A', description: 'x' }]), layout: 'accordion' };
    assert.ok(problemsOf(() => resolveDisplay('t', withModal(layout))).length > 0);
    const empty = modal([{ heading: 'A', tab: '', description: 'x' }]);
    assert.ok(problemsOf(() => resolveDisplay('t', withModal(empty))).length > 0);
  });

  it('in the tabs layout, rejects two sections with the same tab label', () => {
    const sections = [
      { heading: 'Threats', description: 'x' },
      { heading: 'Direct threats', tab: 'Threats', description: 'y' },
      { heading: 'Threats', tab: 'Other', description: 'z' },
    ];
    const problem =
      'modal.sections[1]: tab label "Threats" is also used by modal.sections[0] (give one a different "tab")';
    assert.deepEqual(modalProblems(modal(sections)), [problem]);
    assert.deepEqual(modalProblems({ ...modal(sections), layout: 'tabs' }), [problem]);
    assert.deepEqual(problemsOf(() => resolveDisplay('t', withModal(modal(sections)))), [problem]);
    // The scroll layout shows no tabs, so labels may repeat.
    assert.deepEqual(modalProblems({ ...modal(sections), layout: 'scroll' }), []);
  });
});

describe('the ecoregions example config', () => {
  it('passes the check', () => {
    const config = readJson('ecoregions.example.style.json');
    const display = resolveDisplay('ecoregions', config, () => Array.from({ length: 100 }, (_, i) => i));
    assert.ok(display.modal);
    assert.ok(display.themes.length > 1);
  });
});
