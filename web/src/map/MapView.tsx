import { useEffect, useRef } from 'react';
import { createMap } from './createMap';
import 'maplibre-gl/dist/maplibre-gl.css';

/**
 * Full-page map. MapLibre lives outside React's render tree: the map is
 * created once on mount and removed on unmount.
 */
export function MapView() {
  const container = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!container.current) return;
    const controller = new AbortController();
    const map = createMap(container.current, { signal: controller.signal });
    return () => {
      controller.abort();
      map.remove();
    };
  }, []);

  return <div ref={container} className="map" />;
}
