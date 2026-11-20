import type { MapDefaults } from '../layers';

/** The camera to jump to when style.json has loaded. */
export interface OpeningView {
  center?: [number, number];
  zoom?: number;
}

/**
 * The opening view from style.json (the map config's view), or null to
 * stay where the map is: when there are none, or when the page URL already
 * holds a view (`#zoom/lat/lon`, kept by the map's `hash` option), which
 * wins so a shared or reloaded view is not lost.
 */
export function openingView(defaults: MapDefaults | null, hash: string): OpeningView | null {
  if (!defaults || /^#\d/.test(hash)) return null;
  const view: OpeningView = {};
  if (defaults.center) view.center = defaults.center;
  if (defaults.zoom !== undefined) view.zoom = defaults.zoom;
  return Object.keys(view).length ? view : null;
}

/** How far the map can zoom and pan. */
export interface MapLimits {
  minZoom?: number;
  maxZoom?: number;
  maxBounds?: [[number, number], [number, number]];
}

/**
 * The zoom limits and max bounds from style.json (the map config's
 * `view`), or null for none. They apply whatever the URL holds: MapLibre
 * moves a view outside them back inside.
 */
export function mapLimits(defaults: MapDefaults | null): MapLimits | null {
  if (!defaults) return null;
  const limits: MapLimits = {};
  if (defaults.minZoom !== undefined) limits.minZoom = defaults.minZoom;
  if (defaults.maxZoom !== undefined) limits.maxZoom = defaults.maxZoom;
  if (defaults.bounds) {
    const [west, south, east, north] = defaults.bounds;
    limits.maxBounds = [
      [west, south],
      [east, north],
    ];
  }
  return Object.keys(limits).length ? limits : null;
}

/** The page title when the map config sets none (as in `index.html`). */
export const DEFAULT_TITLE = 'ERAP Map';

/** The page title: the map config's `title`, or the default. */
export function pageTitle(defaults: MapDefaults | null): string {
  return defaults?.title ?? DEFAULT_TITLE;
}
