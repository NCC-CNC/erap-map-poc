import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { expectedDisplay, expectedRasterDisplay, rasterEntry, sampleManifest } from '../test/fixtures';
import {
  MESSAGES,
  ManifestError,
  displayProblems,
  loadManifest,
  manifestUrl,
  mapDefaults,
  parseManifest,
} from './manifest';

beforeEach(() => {
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('parseManifest', () => {
  it('reads each entry into a layer definition', () => {
    const { layers, problem } = parseManifest(sampleManifest());
    expect(problem).toBeNull();
    expect(layers[0]).toEqual({
      id: 'sample',
      type: 'vector',
      title: 'Sample polygons',
      file: 'sample.pmtiles',
      sourceLayer: 'sample',
      defaultVisible: true,
      order: 10,
      layers: expectedDisplay.sample.layers,
      legend: expectedDisplay.sample.legend,
      popup: expectedDisplay.sample.popup,
    });
    expect(layers[1]?.id).toBe('sample_points');
  });

  it('puts the layers in draw order: ascending order, then name', () => {
    const manifest = sampleManifest();
    const [polys, points] = manifest.layers as [
      (typeof manifest.layers)[0],
      (typeof manifest.layers)[0],
    ];
    polys.display.order = 30;
    const other = { ...structuredClone(points), name: 'another' };
    manifest.layers.push(other);
    expect(parseManifest(manifest).layers.map((d) => d.id)).toEqual([
      'another',
      'sample_points',
      'sample',
    ]);
  });

  it('leaves out invalid and repeated entries, says how many, and keeps the rest', () => {
    const manifest = sampleManifest() as { layers: unknown[] };
    manifest.layers.push(
      { name: 'old', file: 'old.pmtiles' },
      { name: 'Bad Name', file: 'x.pmtiles', display: expectedDisplay.sample },
      { name: 'sample', file: 'sample.pmtiles', display: expectedDisplay.sample },
      'nonsense',
    );
    const { layers, problem } = parseManifest(manifest);
    expect(layers.map((d) => d.id)).toEqual(['sample', 'sample_points']);
    expect(problem).toBe(MESSAGES.skipped(4));
    expect(problem).toBe('4 layers in manifest.json could not be read and are not shown.');
    expect(console.warn).toHaveBeenCalledWith(expect.stringContaining('display is missing'));
  });

  it('says when no layers have been built', () => {
    expect(parseManifest({ layers: [] })).toEqual({ layers: [], problem: MESSAGES.empty, map: null });
  });

  it('throws when there is no layers list', () => {
    expect(() => parseManifest({})).toThrow(ManifestError);
    expect(() => parseManifest(null)).toThrow(ManifestError);
    expect(() => parseManifest({ layers: {} })).toThrow(ManifestError);
  });

  it('does not let an entry point the archive somewhere else', () => {
    const manifest = sampleManifest();
    manifest.layers[0]!.file = 'https://elsewhere.test/x.pmtiles';
    expect(parseManifest(manifest).layers.map((d) => d.id)).toEqual(['sample_points']);
  });
});

describe('displayProblems', () => {
  it('accepts the pipeline output', () => {
    expect(displayProblems(expectedDisplay.sample)).toEqual([]);
    expect(displayProblems(expectedDisplay.sample_points)).toEqual([]);
  });

  it('names each problem', () => {
    const display = {
      ...structuredClone(expectedDisplay.sample),
      title: '',
      extra: 1,
      layers: [
        { id: 'fill', type: 'fill', source: 'other' },
        { id: 'fill', type: 'raster' },
      ],
    };
    expect(displayProblems(display)).toEqual([
      'display.extra is not allowed',
      'display.title must be text',
      'display.layers[0] must not set its source',
      'display.layers[1].type is not a vector layer type',
      'display.layers[1].id fill is used twice',
    ]);
  });
});

describe('loadManifest', () => {
  const url = manifestUrl('https://example.test/tiles/');
  const respond = (body: unknown, status = 200) =>
    vi.fn<typeof fetch>(async () =>
      new Response(typeof body === 'string' ? body : JSON.stringify(body), { status }),
    );

  it('fetches tiles/manifest.json, revalidating every time', async () => {
    const fetchFn = respond(sampleManifest());
    const result = await loadManifest(url, { fetch: fetchFn });
    expect(url).toBe('https://example.test/tiles/manifest.json');
    expect(fetchFn).toHaveBeenCalledWith(url, expect.objectContaining({ cache: 'no-cache' }));
    expect(result.layers.map((d) => d.id)).toEqual(['sample', 'sample_points']);
    expect(result.problem).toBeNull();
  });

  it('gives no layers and a message when the manifest is missing', async () => {
    expect(await loadManifest(url, { fetch: respond('Not found', 404) })).toEqual({
      layers: [],
      problem: MESSAGES.missing,
      map: null,
    });
    const offline = vi.fn<typeof fetch>(async () => {
      throw new TypeError('Failed to fetch');
    });
    expect(await loadManifest(url, { fetch: offline })).toEqual({
      layers: [],
      problem: MESSAGES.missing,
      map: null,
    });
  });

  it('gives no layers and a message when the manifest is not valid', async () => {
    for (const body of ['{"layers": [', { layers: 'none' }]) {
      expect(await loadManifest(url, { fetch: respond(body) })).toEqual({
        layers: [],
        problem: MESSAGES.invalid,
        map: null,
      });
    }
  });

  it('gives nothing, and no message, once aborted', async () => {
    const controller = new AbortController();
    const fetchFn = vi.fn<typeof fetch>(async () => {
      controller.abort();
      throw new DOMException('Aborted', 'AbortError');
    });
    expect(await loadManifest(url, { fetch: fetchFn, signal: controller.signal })).toEqual({
      layers: [],
      problem: null,
      map: null,
    });
  });
});

describe('raster layers', () => {
  it('reads a raster entry: type raster, its color-relief layer and no pop-up', () => {
    const { layers, problem } = parseManifest({ layers: [rasterEntry()] });
    expect(problem).toBeNull();
    expect(layers).toEqual([
      {
        id: 'cover',
        type: 'raster',
        title: 'Test raster',
        file: 'cover.pmtiles',
        sourceLayer: 'cover',
        defaultVisible: true,
        order: 5,
        layers: expectedRasterDisplay.layers,
        legend: expectedRasterDisplay.legend,
      },
    ]);
    expect(layers[0]?.layers.map((l) => l.type)).toEqual(['color-relief']);
  });

  it('draws a raster and vector layers together in display order', () => {
    const manifest = sampleManifest() as { layers: unknown[] };
    manifest.layers.push(rasterEntry());
    expect(parseManifest(manifest).layers.map((d) => `${d.id}:${d.type}`)).toEqual([
      'cover:raster',
      'sample:vector',
      'sample_points:vector',
    ]);
  });

  it('reads an entry without a type as vector, as written before raster layers', () => {
    const [entry] = sampleManifest().layers;
    expect('type' in entry!).toBe(false);
    expect(parseManifest({ layers: [entry] }).layers[0]?.type).toBe('vector');
  });

  it('leaves out an unknown type, and a display that does not match the type', () => {
    const vectorDisplayAsRaster = { ...rasterEntry(), display: structuredClone(expectedDisplay.sample) };
    const rasterDisplayAsVector = { ...rasterEntry(), type: 'vector' };
    const { layers, problem } = parseManifest({
      layers: [{ ...rasterEntry(), type: 'grid' }, vectorDisplayAsRaster, rasterDisplayAsVector],
    });
    expect(layers).toEqual([]);
    expect(problem).toBe(MESSAGES.skipped(3));
  });

  it('names the raster problems', () => {
    expect(displayProblems(expectedRasterDisplay, 'display', 'raster')).toEqual([]);
    const display = {
      ...structuredClone(expectedRasterDisplay),
      layers: [{ id: 'fill', type: 'fill' }],
      popup: structuredClone(expectedDisplay.sample.popup),
    };
    expect(displayProblems(display, 'display', 'raster')).toEqual([
      'display.layers[0].type is not a raster layer type',
      'display.popup is not allowed on a raster layer',
    ]);
    expect(displayProblems(expectedRasterDisplay)).toEqual([
      'display.layers[0].type is not a vector layer type',
    ]);
  });
});

describe('map config (ADR 0009)', () => {
  it('leaves out disabled entries quietly', () => {
    const manifest = sampleManifest() as { layers: Record<string, unknown>[] };
    manifest.layers[0]!.enabled = false;
    manifest.layers[1]!.enabled = true;
    manifest.layers.push({ name: 'Bad Name', enabled: false });
    const { layers, problem } = parseManifest(manifest);
    expect(layers.map((d) => d.id)).toEqual(['sample_points']);
    expect(problem).toBeNull();
    expect(console.warn).not.toHaveBeenCalled();
  });

  it('says when every built layer is turned off', () => {
    const manifest = sampleManifest() as { layers: Record<string, unknown>[] };
    for (const entry of manifest.layers) entry.enabled = false;
    expect(parseManifest(manifest)).toEqual({ layers: [], problem: MESSAGES.allDisabled, map: null });
  });

  it('reads the map view and basemap', () => {
    const manifest = { ...sampleManifest(), map: { center: [-80.5, 45.25], zoom: 5.5, basemap: 'dark' } };
    expect(parseManifest(manifest).map).toEqual({ center: [-80.5, 45.25], zoom: 5.5, basemap: 'dark' });
    expect(parseManifest(sampleManifest()).map).toBeNull();
  });

  it('drops map fields that are not valid, keeping the rest', () => {
    expect(mapDefaults({ center: [200, 0], zoom: 30, basemap: 'satellite' })).toEqual({});
    expect(mapDefaults({ center: [-80, 45, 3], zoom: 2 })).toEqual({ zoom: 2 });
    expect(mapDefaults('north')).toBeNull();
    expect(console.warn).toHaveBeenCalledTimes(5);
  });
});
