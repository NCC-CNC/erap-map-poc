import { isVisible, type LayerDefinition, type VisibilityState } from '../layers';
import type { PopupFeature } from '../popup/content';
import { buildModalContent, type ModalContent } from './template';

/** The open modal: the layer it belongs to and what it shows. */
export interface OpenModal {
  layerId: string;
  content: ModalContent;
}

/** The modal for a clicked feature of a layer with a modal template. */
export function openModal(def: LayerDefinition, feature: PopupFeature): OpenModal | null {
  if (!def.modal) return null;
  return { layerId: def.id, content: buildModalContent(def.modal, feature, def.title) };
}

/**
 * The modal to keep open: none once its layer is hidden or gone (for
 * example after a reload of the layer list), as the pop-up does.
 */
export function keepModal(
  open: OpenModal | null,
  layers: readonly LayerDefinition[],
  visibility: VisibilityState,
): OpenModal | null {
  if (!open) return null;
  const def = layers.find((d) => d.id === open.layerId);
  return def && isVisible(visibility, def) ? open : null;
}

/**
 * The selected tab of each layer's modal, as the section's template index
 * (ADR 0012), kept while the map is open: the next feature of the layer,
 * or the modal opened again, shows the same tab when it has it.
 */
export type TabState = Readonly<Record<string, number>>;

/** `state` with `layerId`'s selected tab set to the section `index`. */
export function withTab(state: TabState, layerId: string, index: number): TabState {
  return state[layerId] === index ? state : { ...state, [layerId]: index };
}
