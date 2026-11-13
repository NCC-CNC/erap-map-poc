import {
  activeLegend,
  activeTheme,
  listOrder,
  isVisible,
  type LayerDefinition,
  type ThemeState,
  type VisibilityState,
} from '../layers';
import { LegendView } from './LegendView';

interface LayerListProps {
  /** The layers from the manifest, in draw order; `null` while loading. */
  layers: readonly LayerDefinition[] | null;
  /** A problem with the manifest to show above the list, if any. */
  problem: string | null;
  visibility: VisibilityState;
  /** Ids of the layers whose archive could be read; `null` while checking. */
  available: ReadonlySet<string> | null;
  onChange: (layerId: string, visible: boolean) => void;
  /** The colour theme chosen per layer (ADR 0012). */
  themes?: ThemeState;
  onThemeChange?: (layerId: string, themeId: string) => void;
}

/**
 * The data layers as labelled checkboxes, topmost first, each with its
 * inline legend. A layer with more than one colour theme gets a "Colour
 * by" choice above its legend, and the legend follows the theme. A layer
 * whose archive is missing is shown disabled with a short note; a missing
 * or invalid manifest is reported in a status message, and the map still
 * shows the basemap.
 */
export function LayerList({
  layers,
  problem,
  visibility,
  available,
  onChange,
  themes = {},
  onThemeChange = () => {},
}: LayerListProps) {
  return (
    <fieldset className="layer-list">
      <legend>Layers</legend>
      <p className="layer-message" role="status" hidden={!problem && layers !== null}>
        {problem ?? (layers === null ? 'Loading layers...' : '')}
      </p>
      <ul>
        {listOrder(layers ?? []).map((def) => {
          const missing = available !== null && !available.has(def.id);
          const inputId = `layer-toggle-${def.id}`;
          const noteId = `${inputId}-note`;
          const themeId = `layer-theme-${def.id}`;
          const theme = activeTheme(themes, def);
          return (
            <li key={def.id} className={missing ? 'layer-missing' : undefined}>
              <label htmlFor={inputId}>
                <input
                  id={inputId}
                  type="checkbox"
                  checked={!missing && isVisible(visibility, def)}
                  disabled={missing}
                  aria-describedby={missing ? noteId : undefined}
                  onChange={(e) => onChange(def.id, e.target.checked)}
                />
                {def.title}
              </label>
              {missing && (
                <p id={noteId} className="layer-note">
                  Not available: tiles not found.
                </p>
              )}
              {theme && def.themes && def.themes.length > 1 && (
                <div className="layer-theme">
                  <label htmlFor={themeId}>Colour by</label>
                  <select
                    id={themeId}
                    value={theme.id}
                    disabled={missing}
                    onChange={(e) => onThemeChange(def.id, e.target.value)}
                  >
                    {def.themes.map((t) => (
                      <option key={t.id} value={t.id}>
                        {t.label}
                      </option>
                    ))}
                  </select>
                </div>
              )}
              <LegendView
                legend={activeLegend(themes, def)}
                label={theme ? `${def.title} legend: ${theme.label}` : `${def.title} legend`}
              />
            </li>
          );
        })}
      </ul>
    </fieldset>
  );
}
