import { addProtocol } from 'maplibre-gl';
import { Protocol } from 'pmtiles';

let protocol: Protocol | undefined;

/**
 * Registers the `pmtiles://` protocol with MapLibre once and returns the
 * shared protocol instance, so archives can be added to it and reused.
 */
export function pmtilesProtocol(): Protocol {
  if (!protocol) {
    protocol = new Protocol({ metadata: true });
    addProtocol('pmtiles', protocol.tile);
  }
  return protocol;
}
