import { validateStyleMin, type StyleSpecification } from '@maplibre/maplibre-gl-style-spec';
import { describe, expect, it } from 'vitest';
import { buildPopupContent } from '../popup/content';
import { raster, sample, sampleLayers, samplePoints } from '../test/fixtures';
import { RASTER_PNG_SOURCE, RASTER_SOURCE, isCog, styleLayerIds, toMapLibre } from './spec';
import type { LayerDefinition } from './types';

const TILES = 'https://example.test/tiles/';

/** A complete style from the sample layers, as the map would end up with. */
function sampleStyle(defs: readonly LayerDefinition[] = sampleLayers): StyleSpecification {
  const built = defs.map((def) => toMapLibre(def, TILES));
  return {
    version: 8,
    sources: Object.fromEntries(built.map((b) => [b.sourceId, b.source])),
    layers: built.flatMap((b) => b.layers),
  };
}

describe('the sample layers from the manifest', () => {
  it('produce a style that passes the MapLibre style spec validator', () => {
    expect(validateStyleMin(sampleStyle())).toEqual([]);
  });

  it('draw the sample polygons first and the sample points on top, with the same ids as before', () => {
    expect(sampleLayers.map((def) => def.id)).toEqual(['sample', 'sample_points']);
    expect(sampleStyle().layers.map((layer) => layer.id)).toEqual([
      'sample-fill',
      'sample-outline',
      'sample_points-circle',
    ]);
  });

  it('keep the sample paint: YlGnBu steps on score and Okabe-Ito categories', () => {
    const [fill, outline, circle] = sampleStyle().layers;
    expect(fill).toMatchObject({
      type: 'fill',
      paint: {
        'fill-color': [
          'case',
          ['==', ['typeof', ['get', 'score']], 'number'],
          ['step', ['get', 'score'], '#a1dab4', 25, '#41b6c4', 50, '#2c7fb8', 75, '#253494'],
          '#9e9e9e',
        ],
        'fill-opacity': 0.7,
      },
    });
    expect(outline).toMatchObject({ type: 'line', paint: { 'line-color': '#ffffff', 'line-width': 0.75 } });
    expect(circle).toMatchObject({
      type: 'circle',
      paint: {
        'circle-color': [
          'match',
          ['to-string', ['get', 'category']],
          'alpha',
          '#e69f00',
          'beta',
          '#cc79a7',
          'gamma',
          '#d55e00',
          '#9e9e9e',
        ],
        'circle-radius': 6,
        'circle-stroke-color': '#ffffff',
        'circle-stroke-width': 1.5,
      },
    });
  });

  it('keep the sample legends', () => {
    expect(sample.legend.items.map((i) => i.label)).toEqual([
      '0 to 25',
      '25 to 50',
      '50 to 75',
      '75 to 100',
      'No score',
    ]);
    expect(samplePoints.legend.items.map((i) => i.label)).toEqual(['Alpha', 'Beta', 'Gamma', 'Other']);
    // Every legend colour appears in the paint.
    for (const def of sampleLayers) {
      const paint = JSON.stringify(def.layers.map((l) => l.paint));
      for (const item of def.legend.items) expect(paint).toContain(item.color);
    }
  });

  it('are shown by default', () => {
    expect(sampleLayers.map((def) => def.defaultVisible)).toEqual([true, true]);
  });

  it('give sample_points a pop-up with the name, feature id, category and count', () => {
    const { popup } = samplePoints;
    if (!popup) throw new Error('sample_points has no pop-up');
    const content = buildPopupContent(
      popup,
      { id: 12, properties: { name: 'Heron', category: 'beta', count: 1234 } },
      samplePoints.title,
    );
    expect(content).toEqual({
      title: 'Heron',
      stats: [
        { label: 'ID', value: '12' },
        { label: 'Category', value: 'beta' },
        { label: 'Count', value: '1,234' },
      ],
      charts: [],
    });
  });
});

describe('toMapLibre', () => {
  it('points the source at the archive through the pmtiles protocol', () => {
    const built = toMapLibre(sample, TILES);
    expect(built.sourceId).toBe('sample');
    expect(built.archiveUrl).toBe('https://example.test/tiles/sample.pmtiles');
    expect(built.archiveKind).toBe('pmtiles');
    expect(built.source).toEqual({
      type: 'vector',
      url: 'pmtiles://https://example.test/tiles/sample.pmtiles',
    });
  });

  it('prefixes the ids and wires every style layer to the source and source layer', () => {
    for (const def of sampleLayers) {
      const built = toMapLibre(def, TILES);
      expect(built.layers.map((layer) => layer.id)).toEqual(styleLayerIds(def));
      expect(styleLayerIds(def)).toEqual(def.layers.map((l) => `${def.id}-${l.id}`));
      for (const layer of built.layers) {
        expect(layer).toMatchObject({ source: def.id, 'source-layer': def.sourceLayer });
      }
    }
  });

  it('sets the layout visibility from the default, or from the given value', () => {
    const visibilities = (visible?: boolean) =>
      toMapLibre(sample, TILES, visible).layers.map((layer) => layer.layout?.visibility);
    expect(visibilities()).toEqual(['visible', 'visible']);
    expect(visibilities(false)).toEqual(['none', 'none']);
    const hidden = toMapLibre(sample, TILES, false);
    const style = { ...sampleStyle(), layers: hidden.layers, sources: { sample: hidden.source } };
    expect(validateStyleMin(style)).toEqual([]);
  });

  it('keeps the rest of a raw layer, including its own layout', () => {
    const labels: LayerDefinition = {
      ...sample,
      id: 'labels',
      layers: [
        {
          id: 'text',
          type: 'symbol',
          minzoom: 5,
          layout: { 'text-field': ['get', 'name'], 'text-size': 12 },
          paint: { 'text-color': '#333333' },
        },
      ],
    };
    const [layer] = toMapLibre(labels, TILES, false).layers;
    expect(layer).toEqual({
      id: 'labels-text',
      type: 'symbol',
      source: 'labels',
      'source-layer': 'sample',
      minzoom: 5,
      layout: { 'text-field': ['get', 'name'], 'text-size': 12, visibility: 'none' },
      paint: { 'text-color': '#333333' },
    });
  });
});

describe('toMapLibre for a raster layer', () => {
  it('reads the COG through the cog protocol as a raster-dem source', () => {
    const built = toMapLibre(raster, TILES);
    expect(built.archiveUrl).toBe('https://example.test/tiles/cover.cog.tif');
    expect(built.archiveKind).toBe('cog');
    expect(built.source).toEqual({
      type: 'raster-dem',
      tileSize: 256,
      url: 'cog://https://example.test/tiles/cover.cog.tif#dem',
    });
    expect(built.source).toMatchObject(RASTER_SOURCE);
  });

  it('reads a raster built as PNG tiles before COGs as grey levels 0 to 255', () => {
    const built = toMapLibre({ ...raster, file: 'cover.pmtiles' }, TILES);
    expect(built.archiveKind).toBe('pmtiles');
    expect(built.source).toEqual({
      ...RASTER_PNG_SOURCE,
      url: 'pmtiles://https://example.test/tiles/cover.pmtiles',
    });
    expect(built.source).toMatchObject({ encoding: 'custom', redFactor: 1 });
  });

  it('knows a COG by its file name', () => {
    expect(isCog('forest.cog.tif')).toBe(true);
    expect(isCog('forest.pmtiles')).toBe(false);
    expect(isCog('forest.tif')).toBe(false);
  });

  it('draws a color-relief layer with no source layer, coloured by the share covered', () => {
    const [layer, ...rest] = toMapLibre(raster, TILES, false).layers;
    expect(rest).toEqual([]);
    expect(layer).toEqual({
      id: 'cover-raster',
      type: 'color-relief',
      source: 'cover',
      layout: { visibility: 'none' },
      paint: {
        'color-relief-color': [
          'interpolate',
          ['linear'],
          ['elevation'],
          0,
          'rgba(27, 120, 55, 0)',
          255,
          'rgba(27, 120, 55, 1)',
        ],
        'color-relief-opacity': 0.7,
        resampling: 'nearest',
      },
    });
  });

  it('makes a valid style together with the vector layers', () => {
    const style = sampleStyle([raster, ...sampleLayers]);
    expect(validateStyleMin(style)).toEqual([]);
    expect(style.layers.map((l) => l.id)).toEqual([
      'cover-raster',
      'sample-fill',
      'sample-outline',
      'sample_points-circle',
    ]);
  });

  it('has a single-swatch legend in the layer colour and opacity', () => {
    expect(raster.legend).toEqual({
      kind: 'single',
      shape: 'square',
      border: 'transparent',
      opacity: 0.7,
      items: [{ color: '#1b7837', label: 'Test raster' }],
    });
  });
});
