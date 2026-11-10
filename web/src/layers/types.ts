import type {
  CircleLayerSpecification,
  FillLayerSpecification,
  LineLayerSpecification,
} from '@maplibre/maplibre-gl-style-spec';

type WithoutSource<T> = T extends unknown ? Omit<T, 'source' | 'source-layer'> : never;

/**
 * A MapLibre style layer as written in a layer definition. `source` and
 * `source-layer` are filled in from the definition, so they are left out
 * here. Add more layer types to the union as they are needed.
 */
export type StyleLayer = WithoutSource<
  FillLayerSpecification | LineLayerSpecification | CircleLayerSpecification
>;

/**
 * Placeholder for the pop-up shown when a feature is clicked. The real shape
 * (fields, formatting, charts) is defined with the pop-ups in issue #10.
 */
export interface PopupDefinition {
  title: string;
}

/** Everything the map needs to know about one data layer. */
export interface LayerDefinition {
  /** Unique id; also used as the MapLibre source id. */
  id: string;
  /** Human-readable name, for legends and layer controls. */
  title: string;
  /** Archive file name under `/tiles/`, as written by the pipeline. */
  file: string;
  /** Vector tile layer name inside the archive (tippecanoe `-l`). */
  sourceLayer: string;
  /** Style layers, drawn in order. Their ids must be unique across the map. */
  layers: StyleLayer[];
  popup?: PopupDefinition;
}
