import type { StyleSpecification } from '@maplibre/maplibre-gl-style-spec';

/**
 * Placeholder basemap: the keyless OpenFreeMap Positron style. Issue #7
 * replaces this module with the CARTO basemaps (ADR 0005); nothing outside
 * this file depends on which basemap is used. The style carries its own
 * attribution, shown by the map's attribution control.
 */
export function basemapStyle(): string | StyleSpecification {
  return 'https://tiles.openfreemap.org/styles/positron';
}
