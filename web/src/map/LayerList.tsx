import { legendFor, listOrder, isVisible, type LayerDefinition, type VisibilityState } from '../layers';
import { LegendView } from './LegendView';

interface LayerListProps {
  layers: readonly LayerDefinition[];
  visibility: VisibilityState;
  /** Ids of the layers whose archive could be read; `null` while checking. */
  available: ReadonlySet<string> | null;
  onChange: (layerId: string, visible: boolean) => void;
}

/**
 * The data layers as labelled checkboxes, topmost first, each with its
 * inline legend. A layer whose archive is missing is shown disabled with a
 * short note.
 */
export function LayerList({ layers, visibility, available, onChange }: LayerListProps) {
  return (
    <fieldset className="layer-list">
      <legend>Layers</legend>
      <ul>
        {listOrder(layers).map((def) => {
          const missing = available !== null && !available.has(def.id);
          const inputId = `layer-toggle-${def.id}`;
          const noteId = `${inputId}-note`;
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
              <LegendView legend={legendFor(def.symbology, def.title)} label={`${def.title} legend`} />
            </li>
          );
        })}
      </ul>
    </fieldset>
  );
}
