import { describe, expect, it } from 'vitest';
import { BASEMAP_STYLES, BASEMAP_THEMES, DEFAULT_BASEMAP_THEME } from './basemap';

describe('basemap', () => {
  it('uses the OpenFreeMap Positron and Dark styles', () => {
    expect(BASEMAP_STYLES).toEqual({
      light: 'https://tiles.openfreemap.org/styles/positron',
      dark: 'https://tiles.openfreemap.org/styles/dark',
    });
  });

  it('has a style for every theme and defaults to light', () => {
    for (const theme of BASEMAP_THEMES) expect(BASEMAP_STYLES[theme]).toMatch(/^https:\/\//);
    expect(DEFAULT_BASEMAP_THEME).toBe('light');
  });
});
