/**
 * Test fixtures shared with the pipeline (test code only: it reads files
 * outside `web/`, so it is left out of the app build, see
 * `tsconfig.app.json`).
 *
 * - `expectedDisplay`: the `display` blocks the pipeline writes for the
 *   `sample` and `sample_points` layers. The pipeline's tests check its
 *   output against this same file, so the app is tested against what the
 *   pipeline really produces.
 * - `expectedRasterDisplay`: the same for the synthetic raster layer of the
 *   pipeline's raster tests (`pipeline/tests/raster.bats`).
 * - `layerStyleSchema`: the shared JSON Schema.
 * - `mapConfigSchema` and `mapConfigExample`: the local map config's schema
 *   and the committed example (ADR 0009).
 */
import { readFileSync } from 'node:fs';
import { parseManifest } from '../layers/manifest';
import type { Display, LayerDefinition } from '../layers/types';

const repoFile = (path: string) => new URL(`../../../${path}`, import.meta.url);
const readJson = (path: string): unknown => JSON.parse(readFileSync(repoFile(path), 'utf8'));

export const layerStyleSchema = readJson('pipeline/schema/layer-style.schema.json') as {
  $id: string;
  $defs: Record<string, { properties?: Record<string, unknown> }>;
};

/** The local map config's JSON Schema (ADR 0009). */
export const mapConfigSchema = readJson('pipeline/schema/map-config.schema.json') as {
  $id: string;
  properties: { map: { properties: { basemap: { enum: string[] } } } };
};

/** The committed example map config, `map.config.example.json`. */
export const mapConfigExample = readJson('map.config.example.json');

export const expectedDisplay = readJson('pipeline/tests/fixtures/expected_display.json') as {
  sample: Display;
  sample_points: Display;
};

export const expectedRasterDisplay = readJson(
  'pipeline/tests/fixtures/expected_raster_display.json',
) as Display;

/** A manifest as the pipeline writes it for the two sample layers. */
export function sampleManifest() {
  return {
    updated_at: '2026-01-01T00:00:00Z',
    layers: [
      { name: 'sample', file: 'sample.pmtiles', display: structuredClone(expectedDisplay.sample) },
      {
        name: 'sample_points',
        file: 'sample_points.pmtiles',
        display: structuredClone(expectedDisplay.sample_points),
      },
    ],
  };
}

/** The manifest entry the pipeline writes for a raster layer `cover`. */
export function rasterEntry() {
  return {
    name: 'cover',
    file: 'cover.cog.tif',
    type: 'raster',
    format: 'cog',
    display: structuredClone(expectedRasterDisplay),
  };
}

const parsed = parseManifest(sampleManifest()).layers;

/** The sample layers as the app reads them, in draw order. */
export const sampleLayers: readonly LayerDefinition[] = parsed;
export const sample = parsed.find((d) => d.id === 'sample') as LayerDefinition;
export const samplePoints = parsed.find((d) => d.id === 'sample_points') as LayerDefinition;

/** The raster layer `cover` as the app reads it. */
export const raster = parseManifest({ layers: [rasterEntry()] }).layers[0] as LayerDefinition;
