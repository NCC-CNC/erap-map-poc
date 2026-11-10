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
 * Where a pop-up value comes from: a tile attribute (a feature property),
 * or the vector tile feature id, which MapLibre exposes as `feature.id`
 * rather than as a property.
 */
export type ValueSource = { attribute: string } | { featureId: true };

/** How a number is shown. Text values are shown as they are. */
export interface NumberFormat {
  /** Decimal places, always shown. Defaults to 0. */
  decimals?: number;
  /** Thousands separators. Defaults to true. */
  grouping?: boolean;
  /** Unit after the number, separated by a space, for example `ha`. */
  suffix?: string;
}

/** One labelled value in the pop-up. */
export interface PopupStat {
  /** Plain-language label, for example `Area`, not the attribute name. */
  label: string;
  value: ValueSource;
  /** Number formatting; without it numbers are shown as they are. */
  format?: NumberFormat;
}

/** One point of a chart: an x-axis label and the attribute holding its value. */
export interface PopupChartPoint {
  label: string;
  attribute: string;
}

/** A small chart built from numeric attributes of the clicked feature. */
export interface PopupChart {
  type: 'bar' | 'line';
  /** Heading shown above the chart, also used in its accessible label. */
  title: string;
  /** What the values are, for the accessible summary, for example `Value`. */
  valueLabel: string;
  points: PopupChartPoint[];
}

/**
 * The pop-up shown when a feature of the layer is clicked. Declarative, so
 * the content lives in the layer file and the map code stays generic.
 */
export interface PopupDefinition {
  /** Pop-up heading; falls back to the layer title when missing. */
  title: ValueSource;
  stats: PopupStat[];
  charts?: PopupChart[];
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
