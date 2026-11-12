// Unit tests for mapconfig.mjs, the local map config (ADR 0009). Run with
// `node --test` in pipeline/style (tests/display.bats runs them).

import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { describe, it } from 'node:test';
import { DisplayError } from '../display.mjs';
import {
  applyDisplayOverride,
  envAssignment,
  mergePatch,
  overrideEnvLines,
  pick,
  resolveLayers,
  shellQuote,
  validateMapConfig,
  BUILD_KEYS,
  DISPLAY_KEYS,
} from '../mapconfig.mjs';

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

const style = (title = 'Alpha') => ({
  title,
  defaultVisible: true,
  order: 1,
  symbology: {
    geometry: 'polygon',
    color: { type: 'single', color: '#123456' },
    fillOpacity: 0.5,
    outline: { color: '#ffffff', width: 1 },
  },
});

/** Layer configs as cli.mjs finds them in a layers dir. */
const found = (...names) =>
  names.map((name) => ({
    name,
    origin: 'committed',
    envPath: `/layers/${name}.env`,
    envText: 'LAYER_INPUT=a.geojson\n',
    stylePath: `/layers/${name}.style.json`,
    style: style(name),
  }));

describe('mergePatch (RFC 7396)', () => {
  it('merges objects key by key, replaces lists and removes null keys', () => {
    const target = { a: { b: 1, c: [1, 2], d: 'x' }, e: 1 };
    assert.deepEqual(mergePatch(target, { a: { b: 2, c: [3], d: null }, f: true }), {
      a: { b: 2, c: [3] },
      e: 1,
      f: true,
    });
    assert.deepEqual(target, { a: { b: 1, c: [1, 2], d: 'x' }, e: 1 }, 'target is not changed');
  });

  it('replaces a non-object with an object and anything with a non-object', () => {
    assert.deepEqual(mergePatch({ a: 1 }, { a: { b: 1 } }), { a: { b: 1 } });
    assert.equal(mergePatch({ a: 1 }, 'x'), 'x');
  });
});

describe('settings as bash', () => {
  it('quotes any text safely', () => {
    assert.equal(shellQuote("it's $(x) `y`"), "'it'\\''s $(x) `y`'");
    const out = execFileSync('bash', ['-c', `printf %s ${shellQuote("it's $(x) `y` \\ \"z\"")}`]);
    assert.equal(out.toString(), "it's $(x) `y` \\ \"z\"");
  });

  it('writes texts, numbers and lists', () => {
    assert.equal(envAssignment('LAYER_MAX_ZOOM', 10), "LAYER_MAX_ZOOM='10'");
    assert.equal(envAssignment('LAYER_FIELDS', ['id', 'NAME:name']), "LAYER_FIELDS=('id' 'NAME:name')");
    assert.deepEqual(problemsOf(() => envAssignment('PATH', 'x')), ['invalid setting name PATH']);
  });

  it('puts input first, as LAYER_INPUT', () => {
    assert.deepEqual(overrideEnvLines({ env: { LAYER_MAX_ZOOM: 6 }, input: 'b.gpkg', title: 'x' }), [
      "LAYER_INPUT='b.gpkg'",
      "LAYER_MAX_ZOOM='6'",
    ]);
  });

  it('splits build keys from display keys', () => {
    const override = { input: 'x', title: 'T', style: {} };
    assert.deepEqual(pick(override, BUILD_KEYS), { input: 'x' });
    assert.deepEqual(pick(override, DISPLAY_KEYS), { title: 'T', style: {} });
    assert.equal(pick({ title: 'T' }, BUILD_KEYS), null);
  });
});

describe('validateMapConfig', () => {
  it('accepts a full config', () => {
    validateMapConfig({
      $schema: './pipeline/schema/map-config.schema.json',
      map: { center: [-96, 60], zoom: 3, basemap: 'dark' },
      enabled: ['alpha', 'beta'],
      disabled: ['beta'],
      layerDirs: ['pipeline/layers.local'],
      localLayers: { gamma: { env: { LAYER_INPUT: 'g.geojson', LAYER_FIELDS: ['id'] }, style: style() } },
      overrides: { alpha: { input: 'a2.geojson', env: { LAYER_MAX_ZOOM: 6 }, title: 'A', order: 2, defaultVisible: false, style: { symbology: null } } },
    });
    validateMapConfig({});
  });

  it('reports unknown keys, bad names, bad values and a LAYER_INPUT in env', () => {
    const problems = problemsOf(() =>
      validateMapConfig({
        layer: [],
        enabled: ['Bad Name'],
        map: { center: [200, 0], basemap: 'satellite' },
        overrides: { alpha: { env: { LAYER_INPUT: 'x', PATH: '/bin' } }, beta: {} },
      }),
    );
    const text = problems.join('\n');
    assert.match(text, /must NOT have additional properties: layer/);
    assert.match(text, /\/enabled\/0 must match pattern/);
    assert.match(text, /\/map\/center\/0 must be <= 180/);
    assert.match(text, /\/map\/basemap must be equal to one of the allowed values: light, dark/);
    assert.match(text, /\/overrides\/alpha\/env must NOT be valid/);
    assert.match(text, /\/overrides\/alpha\/env property name must be valid/);
    assert.match(text, /\/overrides\/beta must NOT have fewer than 1 properties/);
  });

  it('checks a local layer against the display config schema', () => {
    const { title: _t, ...untitled } = style();
    const problems = problemsOf(() =>
      validateMapConfig({ localLayers: { gamma: { env: { LAYER_MIN_ZOOM: 0 }, style: untitled } } }),
    );
    assert.ok(problems.includes("/localLayers/gamma/env must have required property 'LAYER_INPUT'"), problems.join('\n'));
    assert.ok(problems.includes("/localLayers/gamma/style must have required property 'title'"), problems.join('\n'));
  });
});

describe('resolveLayers', () => {
  it('without a config: every layer, enabled, as it is', () => {
    const { map, layers } = resolveLayers(null, found('beta', 'alpha'));
    assert.equal(map, null);
    assert.deepEqual(
      layers.map((l) => [l.name, l.origin, l.enabled, l.envText, l.style, l.overrides]),
      [
        ['alpha', 'committed', true, null, null, null],
        ['beta', 'committed', true, null, null, null],
      ],
    );
  });

  it('selects with enabled, then disabled', () => {
    const enabled = (config) =>
      resolveLayers(config, found('a', 'b', 'c')).layers.filter((l) => l.enabled).map((l) => l.name);
    assert.deepEqual(enabled({ enabled: ['a', 'b'] }), ['a', 'b']);
    assert.deepEqual(enabled({ disabled: ['b'] }), ['a', 'c']);
    assert.deepEqual(enabled({ enabled: ['a', 'b'], disabled: ['a'] }), ['b']);
    assert.deepEqual(enabled({ enabled: [] }), []);
  });

  it('names every unknown layer, with the layers there are', () => {
    const problems = problemsOf(() =>
      resolveLayers({ enabled: ['a', 'x'], disabled: ['y'], overrides: { z: { title: 'Z' } } }, found('a', 'b')),
    );
    assert.deepEqual(problems, [
      'enabled: no layer named x (layers: a, b)',
      'disabled: no layer named y (layers: a, b)',
      'overrides: no layer named z (layers: a, b)',
    ]);
  });

  it('applies display overrides: the style patch, then title, order and visibility', () => {
    const { layers } = resolveLayers(
      {
        overrides: {
          alpha: {
            title: 'Mine',
            defaultVisible: false,
            style: { title: 'Patched', order: 5, symbology: { outline: { color: '#000000' } } },
          },
        },
      },
      found('alpha'),
    );
    const [alpha] = layers;
    assert.equal(alpha.envText, null, 'no settings changed');
    assert.equal(alpha.style.title, 'Mine');
    assert.equal(alpha.style.order, 5);
    assert.equal(alpha.style.defaultVisible, false);
    assert.deepEqual(alpha.style.symbology.outline, { color: '#000000', width: 1 });
    assert.equal(alpha.style.symbology.fillOpacity, 0.5);
  });

  it('adds input and env after the .env, so they win', () => {
    const { layers } = resolveLayers(
      { overrides: { alpha: { input: "o'ther.geojson", env: { LAYER_FIELDS: ['id', 'b:c'] } } } },
      found('alpha'),
    );
    assert.equal(
      layers[0].envText,
      "LAYER_INPUT=a.geojson\n\n# Overrides from the map config.\nLAYER_INPUT='o'\\''ther.geojson'\nLAYER_FIELDS=('id' 'b:c')\n",
    );
    assert.equal(layers[0].style, null, 'display not changed');
  });

  it('rejects a patch that makes the display config invalid', () => {
    const problems = problemsOf(() =>
      resolveLayers(
        { overrides: { alpha: { style: { symbology: { geometry: 'triangle' } } } } },
        found('alpha'),
      ),
    );
    assert.ok(
      problems.some((p) => p.startsWith('overrides.alpha: /symbology/geometry must be equal to one of the allowed values')),
      problems.join('\n'),
    );
  });

  it('defines local-only layers, which may also be overridden', () => {
    const { layers } = resolveLayers(
      {
        localLayers: { gamma: { env: { LAYER_INPUT: 'g.geojson', LAYER_MIN_ZOOM: 0 }, style: style('Gamma') } },
        overrides: { gamma: { title: 'G2' } },
      },
      found('alpha'),
    );
    const gamma = layers.find((l) => l.name === 'gamma');
    assert.equal(gamma.origin, 'config');
    assert.equal(gamma.envSource, null);
    assert.match(gamma.envText, /^LAYER_INPUT='g.geojson'$/m);
    assert.match(gamma.envText, /^LAYER_MIN_ZOOM='0'$/m);
    assert.equal(gamma.style.title, 'G2');
  });

  it('refuses a local-only layer with a committed name', () => {
    const local = { ...found('alpha')[0], origin: 'local', envPath: '/local/alpha.env' };
    assert.deepEqual(problemsOf(() => resolveLayers({}, [...found('alpha'), local])), [
      'layer alpha is in both /layers/alpha.env and /local/alpha.env: a local-only layer needs its own name (use "overrides" to change a committed layer)',
    ]);
    const problems = problemsOf(() =>
      resolveLayers({ localLayers: { alpha: { env: { LAYER_INPUT: 'x' }, style: style() } } }, found('alpha')),
    );
    assert.match(problems[0], /^localLayers\.alpha: layer alpha already exists in \/layers\/alpha\.env/);
  });

  it('needs a .style.json to apply display overrides to', () => {
    const [alpha] = found('alpha');
    assert.deepEqual(
      problemsOf(() => resolveLayers({ overrides: { alpha: { title: 'x' } } }, [{ ...alpha, style: null }])),
      ['overrides.alpha: alpha has no .style.json to apply the display overrides to'],
    );
  });

  it('leaves the source config objects unchanged', () => {
    const configs = found('alpha');
    const before = structuredClone(configs);
    resolveLayers({ overrides: { alpha: { style: { symbology: { fillOpacity: 0.9 } } } } }, configs);
    assert.deepEqual(configs, before);
  });

  it('applyDisplayOverride without an override is a copy', () => {
    const s = style();
    assert.deepEqual(applyDisplayOverride(s), s);
    assert.notEqual(applyDisplayOverride(s), s);
  });
});
