import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { TYPES_PATH, layerTypesFromRepo } from './layerTypes';

describe('the layer file types', () => {
  it('are up to date with pipeline/schema/layer.schema.json (npm run layer-types)', async () => {
    expect(readFileSync(TYPES_PATH, 'utf8')).toBe(await layerTypesFromRepo());
  });
});
