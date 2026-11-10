import { visibilityValue } from './spec';
import { styleLayerIds } from './symbology';
import type { LayerDefinition } from './types';

/**
 * Which data layers are switched on, by layer id. Kept apart from the map
 * so it survives a basemap switch, which rebuilds every style layer.
 */
export type VisibilityState = Readonly<Record<string, boolean>>;

/** Every layer at its default visibility. */
export function initialVisibility(defs: readonly LayerDefinition[]): VisibilityState {
  return Object.fromEntries(defs.map((def) => [def.id, def.defaultVisible]));
}

/** Whether a layer is on; a layer the state does not know takes its default. */
export function isVisible(state: VisibilityState, def: LayerDefinition): boolean {
  return state[def.id] ?? def.defaultVisible;
}

/** A new state with one layer switched on or off. */
export function withVisibility(
  state: VisibilityState,
  layerId: string,
  visible: boolean,
): VisibilityState {
  return { ...state, [layerId]: visible };
}

/**
 * The layout `visibility` to set on each style layer of a definition, as
 * `[styleLayerId, value]` pairs.
 */
export function visibilityUpdates(
  def: LayerDefinition,
  visible: boolean,
): [string, 'visible' | 'none'][] {
  const value = visibilityValue(visible);
  return styleLayerIds(def.id, def.symbology).map((id) => [id, value]);
}

/**
 * The layers in the order a layer list shows them: topmost first, which is
 * the registry (draw) order reversed.
 */
export function listOrder(defs: readonly LayerDefinition[]): LayerDefinition[] {
  return [...defs].reverse();
}
