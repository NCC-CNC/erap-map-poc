/**
 * The basemap, kept behind this one module (ADR 0005) so that changing
 * provider later touches one place.
 *
 * With a CARTO API key the map uses CARTO's Positron (light, the default)
 * and Dark Matter (dark) vector styles, with the key on the style URL.
 * Without a key it falls back to OpenFreeMap's keyless Positron and Dark
 * styles instead of requesting CARTO, which would return watermarked tiles.
 * Each style carries its own attribution, shown by MapLibre's attribution
 * control, which must stay on.
 */

export type BasemapTheme = 'light' | 'dark';

export const BASEMAP_THEMES: readonly BasemapTheme[] = ['light', 'dark'];

export const DEFAULT_BASEMAP_THEME: BasemapTheme = 'light';

export type BasemapProvider = 'carto' | 'openfreemap';

/** CARTO vector style URLs, without the key. */
export const CARTO_STYLES: Readonly<Record<BasemapTheme, string>> = {
  light: 'https://basemaps.cartocdn.com/gl/positron-gl-style/style.json',
  dark: 'https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json',
};

/** Keyless OpenFreeMap style URLs, used when there is no CARTO key. */
export const OPENFREEMAP_STYLES: Readonly<Record<BasemapTheme, string>> = {
  light: 'https://tiles.openfreemap.org/styles/positron',
  dark: 'https://tiles.openfreemap.org/styles/dark',
};

export interface Basemaps {
  provider: BasemapProvider;
  /** Style URL for each theme. */
  styles: Readonly<Record<BasemapTheme, string>>;
}

/** Appends the API key to a CARTO style URL as `?key=`. */
export function withKey(styleUrl: string, key: string): string {
  const url = new URL(styleUrl);
  url.searchParams.set('key', key);
  return url.href;
}

/**
 * Chooses the basemap styles for a CARTO API key. An empty or blank key
 * selects the keyless OpenFreeMap fallback; CARTO is never requested
 * without a key.
 */
export function resolveBasemaps(cartoApiKey: string): Basemaps {
  const key = cartoApiKey.trim();
  if (!key) return { provider: 'openfreemap', styles: OPENFREEMAP_STYLES };
  return {
    provider: 'carto',
    styles: {
      light: withKey(CARTO_STYLES.light, key),
      dark: withKey(CARTO_STYLES.dark, key),
    },
  };
}

let warned = false;

/**
 * Logs, once per page load, that the keyless fallback basemap is in use.
 * Does nothing for the CARTO provider.
 */
export function warnIfFallback(basemaps: Basemaps): void {
  if (basemaps.provider !== 'openfreemap' || warned) return;
  warned = true;
  console.warn(
    'No CARTO API key in config.json (cartoApiKey); using the keyless OpenFreeMap basemap instead. ' +
      'Set CARTO_API_KEY to use the CARTO basemaps (ADR 0005).',
  );
}
