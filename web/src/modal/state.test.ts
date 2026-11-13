import { describe, expect, it } from 'vitest';
import { sample, sampleModal, samplePoints } from '../test/fixtures';
import { keepModal, openModal, withTab } from './state';

const feature = { id: 2, properties: { name: 'Birch', score: 74 } };

describe('the open modal', () => {
  it('opens for a layer with a modal template, not for one with a pop-up', () => {
    const open = openModal(sampleModal, feature);
    expect(open?.layerId).toBe('sample');
    expect(open?.content.title).toBe('Birch');
    expect(openModal(sample, feature)).toBeNull();
  });

  it('stays open while its layer is visible', () => {
    const open = openModal(sampleModal, feature);
    expect(keepModal(open, [sampleModal, samplePoints], {})).toBe(open);
    expect(keepModal(open, [sampleModal], { sample: true, sample_points: false })).toBe(open);
  });

  it('closes when its layer is hidden or no longer in the layer list', () => {
    const open = openModal(sampleModal, feature);
    expect(keepModal(open, [sampleModal], { sample: false })).toBeNull();
    expect(keepModal(open, [samplePoints], {})).toBeNull();
    expect(keepModal(null, [sampleModal], {})).toBeNull();
  });
});

describe('the selected modal tab', () => {
  it('is kept per layer, and the state only changes when the tab does', () => {
    const one = withTab({}, 'sample', 2);
    expect(one).toEqual({ sample: 2 });
    expect(withTab(one, 'sample', 2)).toBe(one);
    expect(withTab(one, 'other', 0)).toEqual({ sample: 2, other: 0 });
    expect(withTab(one, 'sample', 1)).toEqual({ sample: 1 });
  });
});
