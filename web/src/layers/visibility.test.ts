import { describe, expect, it } from 'vitest';
import { raster, sample, samplePoints } from '../test/fixtures';
import type { LayerDefinition } from './types';
import {
  initialVisibility,
  isVisible,
  listOrder,
  visibilityUpdates,
  withVisibility,
} from './visibility';

const hiddenByDefault: LayerDefinition = { ...sample, id: 'off', defaultVisible: false };

describe('visibility state', () => {
  it('starts every layer at its default', () => {
    expect(initialVisibility([sample, hiddenByDefault])).toEqual({ sample: true, off: false });
  });

  it('switches one layer without changing the others or the old state', () => {
    const before = initialVisibility([sample, samplePoints]);
    const after = withVisibility(before, 'sample', false);
    expect(after).toEqual({ sample: false, sample_points: true });
    expect(before).toEqual({ sample: true, sample_points: true });
    expect(isVisible(after, sample)).toBe(false);
    expect(isVisible(after, samplePoints)).toBe(true);
  });

  it('falls back to the default for a layer the state does not know', () => {
    expect(isVisible({}, sample)).toBe(true);
    expect(isVisible({}, hiddenByDefault)).toBe(false);
  });
});

describe('visibilityUpdates', () => {
  it('covers every style layer of the definition', () => {
    expect(visibilityUpdates(sample, false)).toEqual([
      ['sample-fill', 'none'],
      ['sample-outline', 'none'],
    ]);
    expect(visibilityUpdates(samplePoints, true)).toEqual([['sample_points-circle', 'visible']]);
  });
});

describe('listOrder', () => {
  it('puts the topmost layer first without changing the input', () => {
    const defs = [sample, samplePoints];
    expect(listOrder(defs).map((d) => d.id)).toEqual(['sample_points', 'sample']);
    expect(defs.map((d) => d.id)).toEqual(['sample', 'sample_points']);
  });
});

describe('visibility of a raster layer', () => {
  it('switches its one color-relief layer', () => {
    expect(visibilityUpdates(raster, false)).toEqual([['cover-raster', 'none']]);
    expect(isVisible(withVisibility({}, 'cover', false), raster)).toBe(false);
  });
});
