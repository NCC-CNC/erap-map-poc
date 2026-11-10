import { createElement } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { Popup, type Map as MapLibreMap, type MapMouseEvent } from 'maplibre-gl';
import { layerRegistry, type LayerDefinition } from '../layers';
import { buildPopupContent, clickableLayers } from '../popup/content';
import { FeaturePopup } from '../popup/FeaturePopup';

/** What `attachPopups` returns. */
export interface PopupHandlers {
  /** Removes the handlers and any open pop-up. */
  detach: () => void;
  /** Closes the open pop-up if the layer it belongs to has been hidden. */
  closeIfHidden: () => void;
}

/**
 * Opens a pop-up when a feature of a visible layer with a `popup`
 * definition is clicked, and shows a pointer cursor over such features.
 * Clicking anywhere else closes the pop-up; only one is open at a time.
 * Where features overlap, the topmost layer wins.
 *
 * The handlers are map-level `click` and `mousemove` listeners that query
 * the clickable layers present and visible at event time. Map-level
 * listeners are not part of the style, so they keep working when
 * `setBasemapStyle` replaces the style and the data layers are added again.
 */
export function attachPopups(
  map: MapLibreMap,
  layers: readonly LayerDefinition[] = layerRegistry,
): PopupHandlers {
  const targets = clickableLayers(layers);
  let current: { popup: Popup; root: Root; layerId: string } | undefined;

  const hidden = (id: string) => map.getLayoutProperty(id, 'visibility') === 'none';

  /**
   * Clickable layers in the current style and not hidden; empty before they
   * are added. MapLibre does not draw hidden layers, but this filter makes
   * sure they are never queried either.
   */
  const queryableLayers = () => [...targets.keys()].filter((id) => map.getLayer(id) && !hidden(id));

  const featuresAt = (e: MapMouseEvent) => {
    const ids = queryableLayers();
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
    const opened = { popup, root, layerId: feature.layer.id };
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

  return {
    detach: () => {
      map.off('click', onClick);
      map.off('mousemove', onMouseMove);
      close();
      map.getCanvas().style.cursor = '';
    },
    closeIfHidden: () => {
      // A layer missing while a new basemap loads is not hidden; keep the pop-up.
      if (current && map.getLayer(current.layerId) && hidden(current.layerId)) close();
    },
  };
}
