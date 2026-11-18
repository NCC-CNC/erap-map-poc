/**
 * Keeps the app's reading of style.json's view and basemap in step with
 * the map config's JSON Schema (design note 04). The committed map configs
 * are checked against the schema in CI, with the pipeline image's jv.
 */
import { describe, expect, it } from 'vitest';
import { BASEMAP_THEMES } from '../map/basemap';
import { mapConfigSchema } from '../test/fixtures';
import { BASEMAP_NAMES, mapDefaults } from './style';

describe('the map config schema', () => {
  it('names the basemaps the app has', () => {
    const names = mapConfigSchema.properties.basemap.enum;
    expect([...BASEMAP_NAMES].sort()).toEqual([...names].sort());
    expect([...BASEMAP_THEMES].sort()).toEqual([...names].sort());
  });

  it('gives a view and basemap the app reads as they are', () => {
    // The pipeline writes the map config's view as the style's `center`
    // and `zoom`, its basemap as `erap:basemap` (pipeline/lib/style.sh).
    const style = { center: [-96, 60], zoom: 3, metadata: { 'erap:basemap': 'light' } };
    expect(mapDefaults(style)).toEqual({ center: [-96, 60], zoom: 3, basemap: 'light' });
  });
});
