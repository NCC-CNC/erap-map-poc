/**
 * Keeps the app's types and runtime checks in step with the shared JSON
 * Schema, `pipeline/schema/layer-style.schema.json`, which the pipeline
 * validates every display config against.
 */
import Ajv2020 from 'ajv/dist/2020';
import { describe, expect, it } from 'vitest';
import { expectedDisplay, expectedRasterDisplay, layerStyleSchema } from '../test/fixtures';
import { displayProblems } from './manifest';
import type {
  Display,
  Legend,
  LegendItem,
  NumberFormat,
  PopupChart,
  PopupChartPoint,
  PopupDefinition,
  PopupStat,
} from './types';

// Same options as the pipeline (pipeline/style/display.mjs).
const ajv = new Ajv2020({ allErrors: true, strict: true, strictRequired: false });
ajv.addSchema(layerStyleSchema);
const schemaDisplay = ajv.getSchema(`${layerStyleSchema.$id}#/$defs/display`)!;

/**
 * Every key of `T`, as a record the compiler checks: leaving a key out, or
 * adding one `T` does not have, is a type error.
 */
const keysOf = <T>(record: { [K in keyof Required<T>]: true }) => Object.keys(record).sort();

const schemaKeys = (def: string) => Object.keys(layerStyleSchema.$defs[def]?.properties ?? {}).sort();

describe('the TypeScript types have the schema properties', () => {
  it.each([
    ['display', keysOf<Display>({ title: true, defaultVisible: true, order: true, popup: true, layers: true, legend: true })],
    ['resolvedLegend', keysOf<Legend>({ kind: true, shape: true, border: true, opacity: true, items: true })],
    ['legendItem', keysOf<LegendItem>({ color: true, label: true })],
    ['popup', keysOf<PopupDefinition>({ title: true, stats: true, charts: true })],
    ['popupStat', keysOf<PopupStat>({ label: true, value: true, format: true })],
    ['popupChart', keysOf<PopupChart>({ type: true, title: true, valueLabel: true, points: true })],
    ['popupChartPoint', keysOf<PopupChartPoint>({ label: true, attribute: true })],
    ['numberFormat', keysOf<NumberFormat>({ decimals: true, grouping: true, suffix: true })],
  ])('%s', (def, keys) => {
    expect(keys).toEqual(schemaKeys(def));
  });

  it('legend kinds and shapes', () => {
    const kinds: Record<Legend['kind'], true> = { single: true, categories: true, ramp: true };
    const shapes: Record<Legend['shape'], true> = { square: true, circle: true, line: true };
    const enumOf = (def: string) => (layerStyleSchema.$defs[def] as { enum: string[] }).enum.sort();
    expect(Object.keys(kinds).sort()).toEqual(enumOf('legendKind'));
    expect(Object.keys(shapes).sort()).toEqual(enumOf('legendShape'));
  });
});

type Case = [string, (d: Record<string, unknown>) => void];

const base = () => structuredClone(expectedDisplay.sample) as unknown as Record<string, unknown>;
const at = (d: Record<string, unknown>, ...path: (string | number)[]): Record<string, unknown> =>
  path.reduce<unknown>((o, k) => (o as Record<string | number, unknown>)[k], d) as Record<string, unknown>;

const valid: Case[] = [
  ['the sample polygons as built', () => {}],
  ['no pop-up', (d) => delete d.popup],
  ['a negative order', (d) => (d.order = -5)],
  [
    'raw layers of every vector type',
    (d) =>
      (d.layers = ['fill', 'line', 'symbol', 'circle', 'heatmap', 'fill-extrusion'].map((type) => ({
        id: `l-${type}.1`,
        type,
        minzoom: 3,
      }))),
  ],
  ['a line legend', (d) => (at(d, 'legend').shape = 'line')],
  ['a stat without format', (d) => delete at(d, 'popup', 'stats', 2).format],
  ['a line chart', (d) => (at(d, 'popup', 'charts', 0).type = 'line')],
];

const invalid: Case[] = [
  ['an unknown key', (d) => (d.colour = 'red')],
  ['no title', (d) => delete d.title],
  ['an empty title', (d) => (d.title = '')],
  ['defaultVisible as text', (d) => (d.defaultVisible = 'yes')],
  ['a fractional order', (d) => (d.order = 1.5)],
  ['no style layers', (d) => (d.layers = [])],
  ['a style layer with its own source', (d) => (at(d, 'layers', 0).source = 'x')],
  ['a style layer with a source layer', (d) => (at(d, 'layers', 0)['source-layer'] = 'x')],
  ['a raster style layer', (d) => (at(d, 'layers', 0).type = 'raster')],
  ['a style layer id with a space', (d) => (at(d, 'layers', 0).id = 'my fill')],
  ['a style layer without an id', (d) => delete at(d, 'layers', 0).id],
  ['a legend kind not known', (d) => (at(d, 'legend').kind = 'gradient')],
  ['a legend shape not known', (d) => (at(d, 'legend').shape = 'star')],
  ['legend opacity over 1', (d) => (at(d, 'legend').opacity = 2)],
  ['a legend without items', (d) => (at(d, 'legend').items = [])],
  ['a legend item without a label', (d) => delete at(d, 'legend', 'items', 0).label],
  ['a legend without its border', (d) => delete at(d, 'legend').border],
  ['a pop-up without stats', (d) => delete at(d, 'popup').stats],
  ['a pop-up title of both kinds', (d) => (at(d, 'popup').title = { attribute: 'name', featureId: true })],
  ['featureId false', (d) => (at(d, 'popup', 'stats', 0).value = { featureId: false })],
  ['negative decimals', (d) => (at(d, 'popup', 'stats', 1, 'format').decimals = -1)],
  ['grouping as text', (d) => (at(d, 'popup', 'stats', 1, 'format').grouping = 'yes')],
  ['an unknown chart type', (d) => (at(d, 'popup', 'charts', 0).type = 'pie')],
  ['a chart without points', (d) => (at(d, 'popup', 'charts', 0).points = [])],
  ['a chart point without an attribute', (d) => delete at(d, 'popup', 'charts', 0, 'points', 0).attribute],
];

describe('the runtime checks agree with the schema', () => {
  it('on the pipeline output', () => {
    for (const display of [expectedDisplay.sample, expectedDisplay.sample_points]) {
      expect(schemaDisplay(display)).toBe(true);
      expect(displayProblems(display)).toEqual([]);
    }
  });

  it.each(valid)('valid: %s', (_, change) => {
    const display = base();
    change(display);
    expect(schemaDisplay(display), JSON.stringify(schemaDisplay.errors)).toBe(true);
    expect(displayProblems(display)).toEqual([]);
  });

  it.each(invalid)('invalid: %s', (_, change) => {
    const display = base();
    change(display);
    expect(schemaDisplay(display)).toBe(false);
    expect(displayProblems(display)).not.toEqual([]);
  });

  it('beyond the schema, rejects repeated style layer ids, as the pipeline does', () => {
    const display = base();
    display.layers = [
      { id: 'a', type: 'fill' },
      { id: 'a', type: 'line' },
    ];
    expect(schemaDisplay(display)).toBe(true);
    expect(displayProblems(display)).toEqual(['display.layers[1].id a is used twice']);
  });
});

describe('the raster display', () => {
  it('as the pipeline builds it passes the schema and the app check', () => {
    const display = structuredClone(expectedRasterDisplay);
    expect(schemaDisplay(display), JSON.stringify(schemaDisplay.errors)).toBe(true);
    expect(displayProblems(display, 'display', 'raster')).toEqual([]);
  });

  it('with a vector style layer fails the app check for a raster layer', () => {
    const display = structuredClone(expectedRasterDisplay) as unknown as Record<string, unknown>;
    display.layers = [{ id: 'fill', type: 'fill' }];
    expect(schemaDisplay(display)).toBe(true);
    expect(displayProblems(display, 'display', 'raster')).not.toEqual([]);
  });
});
