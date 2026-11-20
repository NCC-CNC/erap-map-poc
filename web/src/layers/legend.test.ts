import type { LayerSpecification } from '@maplibre/maplibre-gl-style-spec';
import { describe, expect, it } from 'vitest';
import { colorItems, deriveLegend, formatBound, resolveLegend } from './legend';

const fill = (color: unknown, extra: Record<string, unknown> = {}) =>
  ({ id: 'x-fill', type: 'fill', source: 'x', paint: { 'fill-color': color, ...extra } }) as LayerSpecification;
const line = (color: string) =>
  ({ id: 'x-outline', type: 'line', source: 'x', paint: { 'line-color': color } }) as LayerSpecification;

describe('legends from colour expressions', () => {
  it('a single colour, labelled with the title', () => {
    expect(colorItems('#c51b7d', 'Protected')).toEqual({
      kind: 'single',
      items: [{ color: '#c51b7d', label: 'Protected' }],
    });
  });

  it('a match: one category per value, the fallback left out', () => {
    expect(colorItems(['match', ['get', 'c'], 'a', '#111', ['b', 'c'], '#222', '#999'], 't')).toEqual({
      kind: 'categories',
      items: [
        { color: '#111', label: 'a' },
        { color: '#222', label: 'b, c' },
      ],
    });
  });

  it('a step: classes between the stops, inside a case guard', () => {
    const step = ['step', ['get', 'n'], '#a', 10, '#b', 1000, '#c'];
    expect(colorItems(['case', ['has', 'n'], step, '#grey'], 't')).toEqual({
      kind: 'ramp',
      items: [
        { color: '#a', label: 'Below 10' },
        { color: '#b', label: '10 to 1,000' },
        { color: '#c', label: '1,000 or more' },
      ],
    });
  });

  it('an interpolate: a gradient with positions, labels rounded to the range', () => {
    expect(colorItems(['interpolate', ['linear'], ['get', 'n'], 0, '#a', 0.5, '#b', 2, '#c'], 't')).toEqual({
      kind: 'gradient',
      items: [
        { color: '#a', label: '0', position: 0 },
        { color: '#b', label: '0.5', position: 0.25 },
        { color: '#c', label: '2', position: 1 },
      ],
    });
    expect(formatBound(1234.5678, 5000)).toBe('1,235');
    expect(formatBound(1.23456, 5)).toBe('1.23');
  });

  it('nothing for what is not simple enough', () => {
    expect(colorItems(['get', 'colour'], 't')).toBeNull();
    expect(colorItems(['step', ['get', 'n'], '#a', ['get', 'm'], '#b'], 't')).toBeNull();
    expect(colorItems(['interpolate', ['linear'], ['get', 'n'], 1, '#a', 1, '#b'], 't')).toBeNull();
    expect(colorItems(['match', ['get', 'c'], 'a', ['get', 'x'], '#999'], 't')).toBeNull();
    expect(colorItems(42, 't')).toBeNull();
  });
});

describe('deriveLegend', () => {
  it('a fill: square swatches at its opacity, bordered by the outline', () => {
    expect(deriveLegend([fill('#c51b7d', { 'fill-opacity': 0.6 }), line('#8e0152')], 'PA')).toEqual({
      kind: 'single',
      shape: 'square',
      border: '#8e0152',
      opacity: 0.6,
      items: [{ color: '#c51b7d', label: 'PA' }],
    });
  });

  it('a circle: round swatches bordered by the stroke', () => {
    const circle = {
      id: 'p',
      type: 'circle',
      source: 'p',
      paint: { 'circle-color': '#e69f00', 'circle-stroke-color': '#fff' },
    } as LayerSpecification;
    expect(deriveLegend([circle], 'Points')).toMatchObject({ shape: 'circle', border: '#fff', opacity: 1 });
  });

  it('a color-relief raster: a gradient of the share covered', () => {
    const relief = {
      id: 'r',
      type: 'color-relief',
      source: 'r',
      paint: {
        'color-relief-color': ['interpolate', ['linear'], ['elevation'], 0, 'rgba(0,0,0,0)', 255, '#1b7837'],
        'color-relief-opacity': 0.7,
      },
    } as unknown as LayerSpecification;
    expect(deriveLegend([relief], 'Forest')).toMatchObject({ kind: 'gradient', shape: 'square', opacity: 0.7 });
  });

  it('none without a colour layer or a simple colour', () => {
    expect(deriveLegend([{ id: 's', type: 'symbol', source: 's' } as LayerSpecification], 't')).toBeNull();
    expect(deriveLegend([fill(['get', 'c'])], 't')).toBeNull();
  });
});

describe('resolveLegend', () => {
  it('an explicit legend keeps its items and takes what it leaves out from the derived one', () => {
    const items = [{ color: '#c51b7d', label: 'Protected and conserved areas' }];
    expect(resolveLegend({ items }, [fill('#c51b7d', { 'fill-opacity': 0.6 }), line('#8e0152')], 'PA')).toEqual({
      kind: 'single',
      shape: 'square',
      border: '#8e0152',
      opacity: 0.6,
      items,
    });
    expect(resolveLegend({ items, kind: 'categories', opacity: 1 }, [fill(['get', 'c'])], 'PA')).toEqual({
      kind: 'categories',
      shape: 'square',
      border: 'transparent',
      opacity: 1,
      items,
    });
  });

  it('the derived legend without an explicit one; none with neither', () => {
    expect(resolveLegend(undefined, [fill('#123')], 'T')?.items).toEqual([{ color: '#123', label: 'T' }]);
    expect(resolveLegend(undefined, [fill(['get', 'c'])], 'T')).toBeUndefined();
  });
});
