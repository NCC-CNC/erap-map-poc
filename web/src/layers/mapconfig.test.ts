/**
 * Keeps the app's reading of the manifest's `map` in step with the local
 * map config's JSON Schema (ADR 0009), and checks the committed example
 * config against it.
 */
import Ajv2020 from 'ajv/dist/2020';
import { describe, expect, it } from 'vitest';
import { BASEMAP_THEMES } from '../map/basemap';
import { layerStyleSchema, mapConfigExample, mapConfigSchema } from '../test/fixtures';
import { BASEMAP_NAMES, mapDefaults } from './manifest';

// Same options as the pipeline (pipeline/style/display.mjs).
const ajv = new Ajv2020({ allErrors: true, strict: true, strictRequired: false });
ajv.addSchema(layerStyleSchema);
ajv.addSchema(mapConfigSchema);
const validate = ajv.getSchema(mapConfigSchema.$id)!;

describe('the local map config schema', () => {
  it('accepts the committed example, map.config.example.json', () => {
    expect(validate(mapConfigExample), JSON.stringify(validate.errors)).toBe(true);
  });

  it('names the basemaps the app has', () => {
    const names = mapConfigSchema.properties.map.properties.basemap.enum;
    expect([...BASEMAP_NAMES].sort()).toEqual([...names].sort());
    expect([...BASEMAP_THEMES].sort()).toEqual([...names].sort());
  });

  it('gives a map the app reads as it is', () => {
    const { map } = mapConfigExample as { map: unknown };
    expect(mapDefaults(map)).toEqual(map);
  });
});
