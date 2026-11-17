/**
 * The basemap (ADR 0006): OpenFreeMap's keyless Positron (light, the
 * default) and Dark vector styles. Kept behind this one module so that
 * changing provider later touches one place. Each style carries its own
 * attribution, shown by MapLibre's attribution control, which must stay on.
 */

export type BasemapTheme = 'light' | 'dark';

export const BASEMAP_THEMES: readonly BasemapTheme[] = ['light', 'dark'];

export const DEFAULT_BASEMAP_THEME: BasemapTheme = 'light';

/** Style URL for each theme. */
export const BASEMAP_STYLES: Readonly<Record<BasemapTheme, string>> = {
  light: 'https://tiles.openfreemap.org/styles/positron',
  dark: 'https://tiles.openfreemap.org/styles/dark',
};

/**
 * Each style's land colour (its `background` layer), which the data layers
 * are drawn over. Legend swatches are drawn on it too, so that a
 * semi-transparent swatch looks as its layer does on the map.
 */
export const BASEMAP_GROUND: Readonly<Record<BasemapTheme, string>> = {
  light: 'rgb(242, 243, 240)',
  dark: 'rgb(12, 12, 12)',
};
