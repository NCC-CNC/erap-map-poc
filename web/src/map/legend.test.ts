import { describe, expect, it } from 'vitest';
import { BASEMAP_GROUND, BASEMAP_THEMES } from './basemap';
import { gradientCss, swatchColor } from './legend';

describe('swatchColor', () => {
  it('mixes the colour at the layer opacity over the basemap ground', () => {
    expect(swatchColor('#08519c', 0.6, BASEMAP_GROUND.light)).toBe(
      'color-mix(in srgb, #08519c 60%, rgb(242, 243, 240))',
    );
    expect(swatchColor('#d95f02', 0.7, BASEMAP_GROUND.dark)).toBe(
      'color-mix(in srgb, #d95f02 70%, rgb(12, 12, 12))',
    );
  });

  it('keeps an opaque colour, or one without an opacity, as is', () => {
    expect(swatchColor('#c51b7d', 1, BASEMAP_GROUND.light)).toBe('#c51b7d');
    expect(swatchColor('#c51b7d', undefined, BASEMAP_GROUND.light)).toBe('#c51b7d');
  });

  it('rounds the percentage and clamps a negative opacity', () => {
    expect(swatchColor('#000', 1 / 3, '#fff')).toBe('color-mix(in srgb, #000 33.3%, #fff)');
    expect(swatchColor('#000', -1, '#fff')).toBe('color-mix(in srgb, #000 0%, #fff)');
  });
});

describe('BASEMAP_GROUND', () => {
  it('has a land colour for every basemap theme', () => {
    for (const theme of BASEMAP_THEMES) expect(BASEMAP_GROUND[theme]).toMatch(/^rgb\(/);
  });
});

describe('gradientCss with an opacity', () => {
  it('mixes each stop over the ground', () => {
    expect(
      gradientCss(
        [
          { color: '#000', label: '0', position: 0 },
          { color: '#fff', label: '100', position: 1 },
        ],
        0.5,
        '#888',
      ),
    ).toBe(
      'linear-gradient(to right, color-mix(in srgb, #000 50%, #888) 0%, color-mix(in srgb, #fff 50%, #888) 100%)',
    );
  });
});
