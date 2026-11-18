/**
 * Keeps the app's reading of the manifest's `map` in step with the map
 * config's JSON Schema (design note 04). The committed map configs are
 * checked against the schema in CI, with the pipeline image's jv.
 */
import { describe, expect, it } from 'vitest';
import { BASEMAP_THEMES } from '../map/basemap';
import { mapConfigSchema } from '../test/fixtures';
import { BASEMAP_NAMES, mapDefaults } from './manifest';

describe('the map config schema', () => {
  it('names the basemaps the app has', () => {
    const names = mapConfigSchema.properties.basemap.enum;
    expect([...BASEMAP_NAMES].sort()).toEqual([...names].sort());
    expect([...BASEMAP_THEMES].sort()).toEqual([...names].sort());
  });

  it('gives a map the app reads as it is', () => {
    // The pipeline writes the map config's view and basemap as the
    // manifest's `map` (pipeline/lib/layerfile.sh).
    const map = { center: [-96, 60], zoom: 3, basemap: 'light' };
    expect(mapDefaults(map)).toEqual(map);
  });
});
