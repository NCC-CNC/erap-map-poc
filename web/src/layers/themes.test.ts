import { describe, expect, it } from 'vitest';
import { sample, sampleModal } from '../test/fixtures';
import { activeLegend, activeTheme, themePaintUpdates, withTheme } from './themes';

describe('colour themes (ADR 0012)', () => {
  it('the active theme is the chosen one, else the first; none without themes', () => {
    expect(activeTheme({}, sampleModal)?.id).toBe('score');
    expect(activeTheme({ sample: 'area' }, sampleModal)?.id).toBe('area');
    expect(activeTheme({ sample: 'gone' }, sampleModal)?.id).toBe('score');
    expect(activeTheme({ sample: 'area' }, sample)).toBeUndefined();
  });

  it('the legend follows the theme', () => {
    expect(activeLegend({}, sampleModal)).toBe(sampleModal.themes![0]!.legend);
    const gradient = activeLegend({ sample: 'score_gradient' }, sampleModal);
    expect(gradient?.kind).toBe('gradient');
    expect(gradient?.items.map((i) => i.position)).toEqual([0, 0.5, 1, undefined]);
    expect(activeLegend({}, sample)).toBe(sample.legend);
  });

  it('withTheme sets one layer and keeps the others', () => {
    expect(withTheme({ other: 'x' }, 'sample', 'area')).toEqual({ other: 'x', sample: 'area' });
  });

  it('a theme sets its paint on the prefixed style layers; back to the first restores the style', () => {
    const [first, , area] = sampleModal.themes!;
    expect(themePaintUpdates(sampleModal, area!)).toEqual([
      ['sample-fill', 'fill-color', area!.paint.fill!['fill-color']],
    ]);
    const original = (sampleModal.layers[0] as { paint: Record<string, unknown> }).paint['fill-color'];
    expect(themePaintUpdates(sampleModal, first!)).toEqual([['sample-fill', 'fill-color', original]]);
  });
});
