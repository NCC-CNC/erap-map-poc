/**
 * Test fixtures shared with the pipeline (test code only: it reads files
 * outside `web/`, so it is left out of the app build, see
 * `tsconfig.app.json`).
 *
 * - `expectedStyle`: the style.json the pipeline writes for the test
 *   layers `sample` and `sample_points` and the synthetic raster `cover`
 *   of its raster tests. The pipeline's tests check its output against
 *   this same file (`pipeline/tests/style.bats`), so the app is tested
 *   against what the pipeline really produces.
 * - `expectedModalStyle`: the same for the `sample` layer with colour
 *   themes and a click modal (`pipeline/tests/fixtures/sample_modal.yaml`,
 *   ADR 0012).
 * - `ecoregionsExample`: the themes and modal of the committed `ecoregions`
 *   layer file (`pipeline/tests/style.bats` checks they agree).
 * - `mapConfigSchema`: the map config's schema, for the basemap names.
 */
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseStyle } from '../layers/style';
import type { LayerDefinition, ModalDefinition, ThemeConfig } from '../layers/types';

// A path, not `new URL(..., import.meta.url)`: in a jsdom test Vite would
// turn that into asset imports of the whole repo.
const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const repoFile = (path: string) => resolve(repoRoot, path);
const readJson = (path: string): unknown => JSON.parse(readFileSync(repoFile(path), 'utf8'));

/** The map config's JSON Schema (design note 04). */
export const mapConfigSchema = readJson('pipeline/schema/map.schema.json') as {
  properties: { basemap: { enum: string[] } };
};

/** The tiles URL the fixtures are read against. */
export const TILES = 'http://localhost/tiles/';

/** A fresh copy of the test layers' style.json. */
export function expectedStyle(): Record<string, unknown> {
  return readJson('pipeline/tests/fixtures/expected_style.json') as Record<string, unknown>;
}

/** A fresh copy of the style.json of the sample layer with themes and a modal. */
export function expectedModalStyle(): Record<string, unknown> {
  return readJson('pipeline/tests/fixtures/expected_modal_style.json') as Record<string, unknown>;
}

const parsed = parseStyle(expectedStyle(), TILES).layers;
const byId = (defs: readonly LayerDefinition[], id: string) => defs.find((d) => d.id === id) as LayerDefinition;

/** The test layers as the app reads them, in draw order. */
export const sampleLayers: readonly LayerDefinition[] = parsed;
export const sample = byId(parsed, 'sample');
export const samplePoints = byId(parsed, 'sample_points');
/** The raster layer `cover` as the app reads it. */
export const raster = byId(parsed, 'cover');

/** The sample layer with colour themes and a click modal, as the app reads it. */
export const sampleModal = byId(parseStyle(expectedModalStyle(), TILES).layers, 'sample');

/**
 * The themes and modal of the committed ecoregion layer
 * (`pipeline/layers/ecoregions.yaml`): its modal and themes read
 * calculated fields, such as the action recommendations (ADR 0012).
 */
export const ecoregionsExample = readJson('pipeline/tests/fixtures/ecoregions_display.json') as {
  modal: ModalDefinition;
  themes: ThemeConfig[];
};
