/**
 * Test fixtures shared with the pipeline (test code only: it reads files
 * outside `web/`, so it is left out of the app build, see
 * `tsconfig.app.json`).
 *
 * - `expectedDisplay`: the `display` blocks the pipeline writes for the
 *   `sample` and `sample_points` layers. The pipeline's tests check its
 *   output against this same file, so the app is tested against what the
 *   pipeline really produces.
 * - `layerStyleSchema`: the shared JSON Schema.
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

export const expectedDisplay = readJson('pipeline/tests/fixtures/expected_display.json') as {
  sample: Display;
  sample_points: Display;
};

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

const parsed = parseManifest(sampleManifest()).layers;

/** The sample layers as the app reads them, in draw order. */
export const sampleLayers: readonly LayerDefinition[] = parsed;
export const sample = parsed.find((d) => d.id === 'sample') as LayerDefinition;
export const samplePoints = parsed.find((d) => d.id === 'sample_points') as LayerDefinition;
