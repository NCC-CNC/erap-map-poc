import { validateStyleMin, type StyleSpecification } from '@maplibre/maplibre-gl-style-spec';
import { describe, expect, it } from 'vitest';
import { layerRegistry, toMapLibre } from './index';
import { sample } from './sample';

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
    const styleIds = layerRegistry.flatMap((def) => def.layers.map((layer) => layer.id));
    expect(new Set(ids).size).toBe(ids.length);
    expect(new Set(styleIds).size).toBe(styleIds.length);
  });

  it('includes the sample layer', () => {
    expect(layerRegistry).toContain(sample);
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
    const built = toMapLibre(sample, TILES);
    expect(built.layers.map((layer) => layer.id)).toEqual(['sample-fill', 'sample-outline']);
    for (const layer of built.layers) {
      expect(layer).toMatchObject({ source: 'sample', 'source-layer': 'sample' });
    }
  });
});
