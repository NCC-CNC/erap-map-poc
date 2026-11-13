import { describe, expect, it } from 'vitest';
import { expectedModalDisplay, sample, sampleModal } from '../test/fixtures';
import { toMapLibre } from './spec';
import { activeLegend, activeTheme, themePaintUpdates, withTheme } from './themes';

const BASE = 'http://localhost/tiles/';

describe('colour themes as the app reads them (ADR 0011)', () => {
  it('the manifest gives the themes and the default', () => {
    expect(sampleModal.themes?.map((t) => t.id)).toEqual(['score', 'score_gradient', 'area']);
    expect(sampleModal.defaultTheme).toBe('score');
    expect(sampleModal.modal).toEqual(expectedModalDisplay.modal);
    expect(sampleModal.popup).toBeUndefined();
  });

  it('the active theme is the chosen one, else the default; none without themes', () => {
    expect(activeTheme({}, sampleModal)?.id).toBe('score');
    expect(activeTheme({ sample: 'area' }, sampleModal)?.id).toBe('area');
    expect(activeTheme({ sample: 'gone' }, sampleModal)?.id).toBe('score');
    expect(activeTheme({ sample: 'area' }, sample)).toBeUndefined();
  });

  it('the legend follows the theme', () => {
    expect(activeLegend({}, sampleModal)).toEqual(sampleModal.legend);
    const gradient = activeLegend({ sample: 'score_gradient' }, sampleModal);
    expect(gradient.kind).toBe('gradient');
    expect(gradient.items.map((i) => i.position)).toEqual([0, 0.5, 1, undefined]);
    expect(activeLegend({}, sample)).toBe(sample.legend);
  });

  it('withTheme sets one layer and keeps the others', () => {
    expect(withTheme({ other: 'x' }, 'sample', 'area')).toEqual({ other: 'x', sample: 'area' });
  });

  it('a theme sets its paint on the prefixed style layers', () => {
    const theme = sampleModal.themes![2]!;
    expect(themePaintUpdates(sampleModal, theme)).toEqual([
      ['sample-fill', 'fill-color', theme.paint.fill!['fill-color']],
    ]);
  });

  it('toMapLibre draws the given theme over the layers, keeping the other paint', () => {
    const theme = sampleModal.themes![1]!;
    const fill = toMapLibre(sampleModal, BASE, true, 'score_gradient').layers[0]!;
    expect(fill.paint).toEqual({ 'fill-color': theme.paint.fill!['fill-color'], 'fill-opacity': 0.7 });
    // Without a theme, or an unknown one: the layers as given (the default).
    expect(toMapLibre(sampleModal, BASE).layers[0]!.paint).toEqual(sampleModal.layers[0]!.paint);
    expect(toMapLibre(sampleModal, BASE, true, 'nope').layers[0]!.paint).toEqual(sampleModal.layers[0]!.paint);
    // The outline has no theme paint and is unchanged.
    expect(toMapLibre(sampleModal, BASE, true, 'area').layers[1]!.paint).toEqual(sampleModal.layers[1]!.paint);
  });
});
