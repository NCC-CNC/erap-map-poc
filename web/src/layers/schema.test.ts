/**
 * Keeps the app's types and runtime checks in step with the shared JSON
 * Schema, `pipeline/schema/layer-style.schema.json`, which the pipeline
 * validates every display config against.
 */
import Ajv2020 from 'ajv/dist/2020';
import { describe, expect, it } from 'vitest';
import { expectedDisplay, expectedModalDisplay, expectedRasterDisplay, layerStyleSchema } from '../test/fixtures';
import { displayProblems } from './manifest';
import type {
  AttributesBlock,
  ChartBlock,
  Display,
  FormatPreset,
  Legend,
  LegendItem,
  ListBlock,
  ModalDefinition,
  ModalSection,
  NumberFormat,
  TableBlock,
  TextBlock,
  Theme,
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
    [
      'display',
      keysOf<Display>({
        title: true,
        defaultVisible: true,
        order: true,
        popup: true,
        modal: true,
        layers: true,
        legend: true,
        themes: true,
        defaultTheme: true,
      }),
    ],
    ['resolvedLegend', keysOf<Legend>({ kind: true, shape: true, border: true, opacity: true, items: true })],
    ['legendItem', keysOf<LegendItem>({ color: true, label: true, position: true })],
    ['resolvedTheme', keysOf<Theme>({ id: true, label: true, paint: true, legend: true })],
    ['modal', keysOf<ModalDefinition>({ title: true, subtitle: true, sections: true })],
    ['modalSection', keysOf<ModalSection>({ heading: true, description: true, blocks: true })],
    ['attributesBlock', keysOf<AttributesBlock>({ type: true, items: true })],
    ['tableBlock', keysOf<TableBlock>({ type: true, caption: true, rowHeader: true, columns: true, rows: true })],
    [
      'chartBlock',
      keysOf<ChartBlock>({
        type: true,
        chart: true,
        title: true,
        valueLabel: true,
        format: true,
        categories: true,
        series: true,
        colors: true,
      }),
    ],
    ['textBlock', keysOf<TextBlock>({ type: true, text: true })],
    ['listBlock', keysOf<ListBlock>({ type: true, items: true, empty: true })],
    ['popup', keysOf<PopupDefinition>({ title: true, stats: true, charts: true })],
    ['popupStat', keysOf<PopupStat>({ label: true, value: true, format: true })],
    ['popupChart', keysOf<PopupChart>({ type: true, title: true, valueLabel: true, points: true })],
    ['popupChartPoint', keysOf<PopupChartPoint>({ label: true, attribute: true })],
    ['numberFormat', keysOf<NumberFormat>({ preset: true, decimals: true, grouping: true, suffix: true })],
  ])('%s', (def, keys) => {
    expect(keys).toEqual(schemaKeys(def));
  });

  it('legend kinds and shapes', () => {
    const kinds: Record<Legend['kind'], true> = { single: true, categories: true, ramp: true, gradient: true };
    const shapes: Record<Legend['shape'], true> = { square: true, circle: true, line: true };
    const enumOf = (def: string) => (layerStyleSchema.$defs[def] as { enum: string[] }).enum.sort();
    expect(Object.keys(kinds).sort()).toEqual(enumOf('legendKind'));
    expect(Object.keys(shapes).sort()).toEqual(enumOf('legendShape'));
    const presets: Record<FormatPreset, true> = { number: true, count: true, percent: true, hectares: true, km: true };
    expect(Object.keys(presets).sort()).toEqual(enumOf('formatPreset'));
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
  [
    'a gradient legend with positions',
    (d) => {
      at(d, 'legend').kind = 'gradient';
      at(d, 'legend', 'items', 0).position = 0;
    },
  ],
  ['a format preset', (d) => (at(d, 'popup', 'stats', 1).format = 'hectares')],
  ['a format with a preset', (d) => (at(d, 'popup', 'stats', 1, 'format').preset = 'percent')],
];

/** The sample layer with themes and a modal, as the pipeline resolves it. */
const modalBase = () => structuredClone(expectedModalDisplay) as unknown as Record<string, unknown>;
const block = (d: Record<string, unknown>, section: number, index: number) =>
  at(d, 'modal', 'sections', section, 'blocks', index);

const validModal: Case[] = [
  ['the sample with themes and a modal as built', () => {}],
  ['no subtitle', (d) => delete at(d, 'modal').subtitle],
  ['a section with only a description', (d) => delete at(d, 'modal', 'sections', 0).blocks],
  ['a section with only blocks', (d) => delete at(d, 'modal', 'sections', 0).description],
  [
    'a table without caption or row header',
    (d) => {
      delete block(d, 1, 0).caption;
      delete block(d, 1, 0).rowHeader;
    },
  ],
  [
    'a doughnut with slice colours',
    (d) => {
      block(d, 1, 2).chart = 'doughnut';
      block(d, 1, 2).colors = ['#000000', '#ffffff'];
    },
  ],
  ['a list item without when', (d) => delete at(block(d, 2, 1), 'items', 0).when],
  ['one theme', (d) => (d.themes = [(d.themes as unknown[])[0]])],
];

const invalidModal: Case[] = [
  ['both a pop-up and a modal', (d) => (d.popup = structuredClone(expectedDisplay.sample.popup))],
  ['a modal without sections', (d) => (at(d, 'modal').sections = [])],
  ['a modal without a title', (d) => delete at(d, 'modal').title],
  ['a section without a heading', (d) => delete at(d, 'modal', 'sections', 0).heading],
  ['a section with neither description nor blocks', (d) => delete at(d, 'modal', 'sections', 1).blocks],
  ['a block of an unknown type', (d) => (block(d, 0, 0).type = 'map')],
  ['an attributes block without items', (d) => (block(d, 0, 0).items = [])],
  ['a table cell that is a number', (d) => (at(block(d, 1, 0), 'rows', 0).values = [1, null])],
  ['a chart of an unknown kind', (d) => (block(d, 1, 1).chart = 'radar')],
  ['a chart without series', (d) => (block(d, 1, 1).series = [])],
  ['a list without an empty message', (d) => delete block(d, 2, 1).empty],
  ['themes without a default', (d) => delete d.defaultTheme],
  ['a default without themes', (d) => delete d.themes],
  ['a theme without a legend', (d) => delete at(d, 'themes', 0).legend],
  ['a theme with empty paint', (d) => (at(d, 'themes', 0).paint = {})],
  ['a theme id with a space', (d) => (at(d, 'themes', 0).id = 'my theme')],
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
  ['a legend kind not known', (d) => (at(d, 'legend').kind = 'smooth')],
  ['a legend item position over 1', (d) => (at(d, 'legend', 'items', 0).position = 1.5)],
  ['a format preset not known', (d) => (at(d, 'popup', 'stats', 1).format = 'acres')],
  ['a preset not known in a format', (d) => (at(d, 'popup', 'stats', 1, 'format').preset = 'acres')],
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

  it.each(validModal)('valid with a modal: %s', (_, change) => {
    const display = modalBase();
    change(display);
    expect(schemaDisplay(display), JSON.stringify(schemaDisplay.errors)).toBe(true);
    expect(displayProblems(display)).toEqual([]);
  });

  it.each(invalidModal)('invalid with a modal: %s', (_, change) => {
    const display = modalBase();
    change(display);
    expect(schemaDisplay(display)).toBe(false);
    expect(displayProblems(display)).not.toEqual([]);
  });

  it('beyond the schema, checks table and chart lengths, theme ids and paint targets', () => {
    const cases: Case[] = [
      ['a row with too few values', (d) => (at(block(d, 1, 0), 'rows', 0).values = ['v2020'])],
      ['a series with too few attributes', (d) => (at(block(d, 1, 1), 'series', 0).attributes = ['v2020'])],
      ['a pie with two series', (d) => (block(d, 1, 2).series = [...(block(d, 1, 1).series as unknown[])])],
      ['a default theme that is not a theme', (d) => (d.defaultTheme = 'nope')],
      ['a repeated theme id', (d) => (at(d, 'themes', 1).id = 'score')],
      ['paint for a layer it does not have', (d) => (at(d, 'themes', 0).paint = { halo: { 'line-color': '#000' } })],
    ];
    for (const [what, change] of cases) {
      const display = modalBase();
      change(display);
      expect(displayProblems(display), what).not.toEqual([]);
    }
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
