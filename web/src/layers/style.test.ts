import { validateStyleMin } from '@maplibre/maplibre-gl-style-spec';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { buildPopupContent, formatNumber } from '../popup/content';
import { DEFAULT_LOCALE, numberLocale, setNumberLocale } from '../locale';
import {
  TILES,
  expectedModalStyle,
  expectedStyle,
  raster,
  sample,
  sampleLayers,
  sampleModal,
  samplePoints,
} from '../test/fixtures';
import { MESSAGES, StyleError, loadStyle, mapDefaults, parseStyle, styleUrl } from './style';

afterEach(() => {
  vi.restoreAllMocks();
  setNumberLocale();
});

describe("the test layers' style.json, as the pipeline writes it", () => {
  it('passes the MapLibre style spec validator', () => {
    // As a page would load it: no `erap:` key is a problem for MapLibre.
    expect(validateStyleMin(expectedStyle() as never)).toEqual([]);
    expect(validateStyleMin(expectedModalStyle() as never)).toEqual([]);
  });

  it('gives the layers in draw order, with their style layers grouped by erap:layer', () => {
    expect(sampleLayers.map((def) => def.id)).toEqual(['cover', 'sample', 'sample_points']);
    expect(sample.layers.map((l) => l.id)).toEqual(['sample-fill', 'sample-outline']);
    expect(samplePoints.layers.map((l) => l.id)).toEqual(['sample_points-circle']);
    expect(sampleLayers.map((def) => [def.type, def.order, def.defaultVisible])).toEqual([
      ['raster', 5, true],
      ['vector', 10, true],
      ['vector', 20, true],
    ]);
    expect(sample.title).toBe('Sample polygons');
  });

  it('resolves the relative sources against the tiles URL', () => {
    expect(sample.sources).toEqual({ sample: { type: 'vector', url: `pmtiles://${TILES}sample.pmtiles` } });
    expect(raster.sources).toEqual({
      cover: { type: 'raster-dem', tileSize: 256, url: `cog://${TILES}cover.cog.tif#dem` },
    });
  });

  it('keeps the explicit legends, completed from the derived ones', () => {
    expect(sample.legend?.items.map((i) => i.label)).toEqual([
      '0 to 25',
      '25 to 50',
      '50 to 75',
      '75 to 100',
      'No score',
    ]);
    expect(samplePoints.legend).toMatchObject({ kind: 'categories', shape: 'circle', border: '#ffffff' });
    expect(raster.legend).toEqual({
      kind: 'single',
      shape: 'square',
      border: 'transparent',
      opacity: 0.7,
      items: [{ color: '#1b7837', label: 'Test raster' }],
    });
  });

  it('gives sample_points a pop-up with the name, feature id, category and count', () => {
    const content = buildPopupContent(
      samplePoints.popup!,
      { id: 12, properties: { name: 'Heron', category: 'beta', count: 1234 } },
      samplePoints.title,
    );
    expect(content).toEqual({
      title: 'Heron',
      size: 'small',
      layout: 'tabs',
      sections: [
        {
          index: 0,
          tab: '',
          blocks: [
            {
              type: 'attributes',
              items: [
                { label: 'ID', value: '12' },
                { label: 'Category', value: 'beta' },
                { label: 'Count', value: '1,234' },
              ],
            },
          ],
        },
      ],
    });
    expect(raster.popup).toBeUndefined();
  });

  it('leaves out a pop-up in the old shape (stats, or a modal) until the layer is restyled', () => {
    const style = expectedStyle();
    const layers = (style.metadata as Record<string, Record<string, Record<string, unknown>>>)['erap:layers']!;
    layers.sample!.popup = { title: { attribute: 'name' }, stats: [] };
    layers.sample_points!.modal = { title: '{name}', sections: [{ heading: 'x', description: 'x' }] };
    delete layers.sample_points!.popup;
    const parsed = parseStyle(style, TILES).layers;
    expect(parsed.find((d) => d.id === 'sample')?.popup).toBeUndefined();
    expect(parsed.find((d) => d.id === 'sample_points')?.popup).toBeUndefined();
  });

  it('has no opening view without a map config', () => {
    expect(parseStyle(expectedStyle(), TILES).map).toBeNull();
  });
});

describe('colour themes from style.json (ADR 0012)', () => {
  it('reads the themes in order, the dialog pop-up as it is, and no layer legend', () => {
    expect(sampleModal.themes?.map((t) => t.id)).toEqual(['score', 'score_gradient', 'area']);
    const meta = (expectedModalStyle().metadata as Record<string, Record<string, Record<string, unknown>>>)[
      'erap:layers'
    ]!.sample!;
    expect(sampleModal.popup).toEqual(meta.popup);
    expect(sampleModal.popup?.size).toBe('dialog');
    expect(sampleModal.legend).toBeUndefined();
  });

  it('gives the first theme the style layers\' own paint for what the others set', () => {
    const [first, second, third] = sampleModal.themes!;
    expect(first!.paint).toEqual({ fill: { 'fill-color': (sampleModal.layers[0] as { paint: Record<string, unknown> }).paint['fill-color'] } });
    expect(Object.keys(second!.paint.fill!)).toEqual(['fill-color']);
    expect(third!.paint.fill!['fill-color']).not.toEqual(second!.paint.fill!['fill-color']);
  });

  it('derives a theme legend the layer file leaves out', () => {
    expect(sampleModal.themes![2]!.legend).toEqual({
      kind: 'gradient',
      shape: 'square',
      border: '#ffffff',
      opacity: 0.7,
      items: [
        { color: '#eff3ff', label: '3,948', position: 0 },
        { color: '#08519c', label: '48,515', position: 1 },
      ],
    });
    expect(sampleModal.themes![1]!.legend?.items.at(-1)).toEqual({ color: '#9e9e9e', label: 'No score' });
  });
});

describe('parseStyle', () => {
  it('rejects what is not a version 8 style', () => {
    expect(() => parseStyle({ layers: [] }, TILES)).toThrow(StyleError);
    expect(() => parseStyle({ version: 7, sources: {}, layers: [] }, TILES)).toThrow(StyleError);
    expect(() => parseStyle(null, TILES)).toThrow(StyleError);
  });

  it('says when no layer is built', () => {
    expect(parseStyle({ version: 8, sources: {}, layers: [] }, TILES)).toEqual({
      layers: [],
      problem: MESSAGES.empty,
      map: null,
    });
  });

  it('leaves out a style layer without erap:layer, and defaults what erap:layers lacks', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const style = expectedStyle();
    (style.layers as unknown[]).push({ id: 'stray', type: 'background' });
    delete (style.metadata as Record<string, unknown>)['erap:layers'];
    const { layers } = parseStyle(style, TILES);
    expect(layers.map((d) => d.id)).toEqual(['cover', 'sample', 'sample_points']);
    expect(layers[1]).toMatchObject({ title: 'sample', order: 0, defaultVisible: false, type: 'vector' });
    expect(layers[0]!.type).toBe('raster');
    // Derived from the step, without the case fallback, which has no label.
    expect(layers[1]!.legend?.items.map((i) => i.label)).toEqual(['Below 25', '25 to 50', '50 to 75', '75 or more']);
    expect(warn).toHaveBeenCalledOnce();
  });

  it('reads the opening view and basemap', () => {
    const style: Record<string, unknown> = { ...expectedStyle(), center: [-100, 55], zoom: 4 };
    (style.metadata as Record<string, unknown>)['erap:basemap'] = 'dark';
    expect(parseStyle(style, TILES).map).toEqual({ center: [-100, 55], zoom: 4, basemap: 'dark' });
  });

  it('reads the zoom limits, bounds, title and locale, and formats numbers in that locale', () => {
    const style = expectedStyle() as Record<string, unknown>;
    Object.assign(style.metadata as Record<string, unknown>, {
      'erap:view': { minzoom: 2, maxzoom: 12, bounds: [-141, 41.5, -52, 84] },
      'erap:title': 'Carte de conservation',
      'erap:locale': 'fr-ca',
    });
    expect(parseStyle(style, TILES).map).toEqual({
      minZoom: 2,
      maxZoom: 12,
      bounds: [-141, 41.5, -52, 84],
      title: 'Carte de conservation',
      locale: 'fr-CA',
    });
    expect(numberLocale()).toBe('fr-CA');
    const want = new Intl.NumberFormat('fr-CA', { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(1234.5);
    expect(formatNumber(1234.5, { decimals: 1 })).toBe(want);
    expect(want).not.toBe('1,234.5');

    // A style without one goes back to the default.
    parseStyle(expectedStyle(), TILES);
    expect(numberLocale()).toBe(DEFAULT_LOCALE);
    expect(formatNumber(1234.5, { decimals: 1 })).toBe('1,234.5');
  });
});

describe('mapDefaults', () => {
  it('leaves out values that are not valid', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    expect(mapDefaults({ center: [200, 0], zoom: 40, metadata: { 'erap:basemap': 'neon' } })).toBeNull();
    expect(warn).toHaveBeenCalledTimes(3);
    expect(mapDefaults({ zoom: 2 })).toEqual({ zoom: 2 });
    expect(
      mapDefaults({
        metadata: {
          'erap:view': { minzoom: 30, maxzoom: -1, bounds: [10, 0, -10, 5] },
          'erap:title': '',
          'erap:locale': 'not a locale!',
        },
      }),
    ).toBeNull();
    expect(warn).toHaveBeenCalledTimes(8);
    // maxzoom below a valid minzoom is left out.
    expect(mapDefaults({ metadata: { 'erap:view': { minzoom: 5, maxzoom: 3 } } })).toEqual({ minZoom: 5 });
  });
});

describe('loadStyle', () => {
  const respond = (body: unknown, init?: ResponseInit) =>
    vi.fn(async () => new Response(typeof body === 'string' ? body : JSON.stringify(body), init));

  it('fetches style.json from the tiles folder, revalidating', async () => {
    const fetch = respond(expectedStyle());
    const result = await loadStyle(TILES, { fetch });
    expect(fetch).toHaveBeenCalledWith(styleUrl(TILES), expect.objectContaining({ cache: 'no-cache' }));
    expect(styleUrl(TILES)).toBe(`${TILES}style.json`);
    expect(result.layers.map((d) => d.id)).toEqual(['cover', 'sample', 'sample_points']);
    expect(result.problem).toBeNull();
  });

  it('reports a missing or unreadable style.json, without throwing', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    expect((await loadStyle(TILES, { fetch: respond('', { status: 404 }) })).problem).toBe(MESSAGES.missing);
    const offline = vi.fn(async () => {
      throw new TypeError('offline');
    });
    expect((await loadStyle(TILES, { fetch: offline })).problem).toBe(MESSAGES.missing);
    expect((await loadStyle(TILES, { fetch: respond('{nope') })).problem).toBe(MESSAGES.invalid);
    expect((await loadStyle(TILES, { fetch: respond({ version: 8 }) })).problem).toBe(MESSAGES.invalid);
  });

  it('gives nothing when aborted', async () => {
    const controller = new AbortController();
    controller.abort();
    const fetch = vi.fn(async () => {
      throw new DOMException('aborted', 'AbortError');
    });
    expect(await loadStyle(TILES, { fetch, signal: controller.signal })).toEqual({
      layers: [],
      problem: null,
      map: null,
    });
  });
});
