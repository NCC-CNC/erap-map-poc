import { validateStyleMin, type StyleSpecification } from '@maplibre/maplibre-gl-style-spec';
import { describe, expect, it } from 'vitest';
import { buildPopupContent } from '../popup/content';
import { layerRegistry, styleLayerIds, toMapLibre } from './index';
import { sample } from './sample';
import { samplePoints } from './samplePoints';

const TILES = 'https://example.test/tiles/';

/** A complete style from the registry, as the map would end up with. */
function registryStyle(): StyleSpecification {
  const built = layerRegistry.map((def) => toMapLibre(def, TILES));
  return {
    version: 8,
    sources: Object.fromEntries(built.map((b) => [b.sourceId, b.source])),
    layers: built.flatMap((b) => b.layers),
  };
}

describe('layer registry', () => {
  it('produces a style that passes the MapLibre style spec validator', () => {
    expect(validateStyleMin(registryStyle())).toEqual([]);
  });

  it('has unique layer and style layer ids', () => {
    const ids = layerRegistry.map((def) => def.id);
    const styleIds = layerRegistry.flatMap((def) => styleLayerIds(def.id, def.symbology));
    expect(new Set(ids).size).toBe(ids.length);
    expect(new Set(styleIds).size).toBe(styleIds.length);
  });

  it('draws the sample polygons first and the sample points on top', () => {
    expect(layerRegistry.map((def) => def.id)).toEqual(['sample', 'sample_points']);
    expect(layerRegistry).toEqual([sample, samplePoints]);
    expect(registryStyle().layers.map((layer) => layer.id)).toEqual([
      'sample-fill',
      'sample-outline',
      'sample_points-circle',
    ]);
  });

  it('shows both sample layers by default', () => {
    expect(layerRegistry.map((def) => def.defaultVisible)).toEqual([true, true]);
  });
});

describe('toMapLibre', () => {
  it('points the source at the archive through the pmtiles protocol', () => {
    const built = toMapLibre(sample, TILES);
    expect(built.sourceId).toBe('sample');
    expect(built.archiveUrl).toBe('https://example.test/tiles/sample.pmtiles');
    expect(built.source).toEqual({
      type: 'vector',
      url: 'pmtiles://https://example.test/tiles/sample.pmtiles',
    });
  });

  it('wires every style layer to the source and source layer', () => {
    for (const def of layerRegistry) {
      const built = toMapLibre(def, TILES);
      expect(built.layers.map((layer) => layer.id)).toEqual(styleLayerIds(def.id, def.symbology));
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
    const style = { ...registryStyle(), layers: hidden.layers, sources: { sample: hidden.source } };
    expect(validateStyleMin(style)).toEqual([]);
  });
});

describe('sample_points pop-up', () => {
  it('shows the name, feature id, category and count', () => {
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
