import type { MapDefaults } from '../layers';

/** The camera to jump to when the manifest has loaded. */
export interface OpeningView {
  center?: [number, number];
  zoom?: number;
}

/**
 * The opening view from the map config's defaults (ADR 0009), or null to
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
