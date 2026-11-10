import { createElement } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { Popup, type Map as MapLibreMap, type MapMouseEvent } from 'maplibre-gl';
import { layerRegistry, type LayerDefinition } from '../layers';
import { buildPopupContent, clickableLayers } from '../popup/content';
import { FeaturePopup } from '../popup/FeaturePopup';

/**
 * Opens a pop-up when a feature of a layer with a `popup` definition is
 * clicked, and shows a pointer cursor over such features. Clicking anywhere
 * else closes the pop-up; only one is open at a time.
 *
 * The handlers are map-level `click` and `mousemove` listeners that query
 * the clickable layers present at event time. Map-level listeners are not
 * part of the style, so they keep working when `setBasemapStyle` replaces
 * the style and the data layers are added again.
 *
 * @returns a function that removes the handlers and any open pop-up.
 */
export function attachPopups(
  map: MapLibreMap,
  layers: readonly LayerDefinition[] = layerRegistry,
): () => void {
  const targets = clickableLayers(layers);
  let current: { popup: Popup; root: Root } | undefined;

  /** Clickable layers in the current style; empty before they are added. */
  const presentLayers = () => [...targets.keys()].filter((id) => map.getLayer(id));

  const featuresAt = (e: MapMouseEvent) => {
    const ids = presentLayers();
    return ids.length ? map.queryRenderedFeatures(e.point, { layers: ids }) : [];
  };

  const close = () => current?.popup.remove();

  const onClick = (e: MapMouseEvent) => {
    close();
    // Topmost feature first.
    const feature = featuresAt(e)[0];
    const def = feature && targets.get(feature.layer.id);
    if (!feature || !def) return;

    const container = document.createElement('div');
    const root = createRoot(container);
    const content = buildPopupContent(def.popup, feature, def.title);
    root.render(createElement(FeaturePopup, { content }));

    const popup = new Popup({ closeOnClick: false, maxWidth: '320px' })
      .setLngLat(e.lngLat)
      .setDOMContent(container);
    const opened = { popup, root };
    popup.on('close', () => {
      // Unmounting destroys the chart instances. Deferred, as the pop-up can
      // close during a React commit (MapView's cleanup), where a synchronous
      // unmount of another root is not allowed.
      queueMicrotask(() => root.unmount());
      if (current === opened) current = undefined;
    });
    current = opened;
    popup.addTo(map);
  };

  let pointer = false;
  const onMouseMove = (e: MapMouseEvent) => {
    const over = featuresAt(e).length > 0;
    if (over === pointer) return;
    pointer = over;
    map.getCanvas().style.cursor = over ? 'pointer' : '';
  };

  map.on('click', onClick);
  map.on('mousemove', onMouseMove);

  return () => {
    map.off('click', onClick);
    map.off('mousemove', onMouseMove);
    close();
    map.getCanvas().style.cursor = '';
  };
}
