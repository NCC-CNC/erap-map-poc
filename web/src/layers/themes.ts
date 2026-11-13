import { styleLayerId } from './spec';
import type { LayerDefinition, Legend, Theme } from './types';

/**
 * The colour theme chosen for each layer that has themes (ADR 0012), by
 * layer id. Kept apart from the map, like visibility, so it survives a
 * basemap switch, which rebuilds every style layer.
 */
export type ThemeState = Readonly<Record<string, string>>;

/**
 * The layer's theme in use: the chosen one if the layer has it, else its
 * default. Undefined for a layer without themes.
 */
export function activeTheme(state: ThemeState, def: LayerDefinition): Theme | undefined {
  const { themes } = def;
  if (!themes?.length) return undefined;
  const chosen = state[def.id];
  return (
    themes.find((t) => t.id === chosen) ?? themes.find((t) => t.id === def.defaultTheme) ?? themes[0]
  );
}

/** The legend to show: the active theme's, or the layer's own. */
export function activeLegend(state: ThemeState, def: LayerDefinition): Legend {
  return activeTheme(state, def)?.legend ?? def.legend;
}

/** A new state with one layer's theme chosen. */
export function withTheme(state: ThemeState, layerId: string, themeId: string): ThemeState {
  return { ...state, [layerId]: themeId };
}

/**
 * The paint properties a theme sets, as `[styleLayerId, property, value]`
 * with the map's (prefixed) style layer ids.
 */
export function themePaintUpdates(def: LayerDefinition, theme: Theme): [string, string, unknown][] {
  return Object.entries(theme.paint).flatMap(([layerId, paint]) =>
    Object.entries(paint).map(
      ([property, value]): [string, string, unknown] => [styleLayerId(def.id, layerId), property, value],
    ),
  );
}
