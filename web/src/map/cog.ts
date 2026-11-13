import { cogProtocol, getCogMetadata } from '@geomatico/maplibre-cog-protocol';
import { addProtocol } from 'maplibre-gl';

let registered = false;

/**
 * Registers the `cog://` protocol with MapLibre once (ADR 0010), so a
 * raster layer's source can read its Cloud Optimized GeoTIFF with range
 * requests (`cog://<url>#dem`, see `../layers/spec.ts`).
 */
export function registerCogProtocol(): void {
  if (registered) return;
  addProtocol('cog', cogProtocol);
  registered = true;
}

/**
 * Reads a COG's header (a few range requests), failing if it is missing or
 * cannot be read, for example not in Web Mercator. The result is cached by
 * the protocol, so the map's first tiles reuse it.
 */
export async function checkCog(url: string): Promise<void> {
  await getCogMetadata(url);
}
