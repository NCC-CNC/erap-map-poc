import type { Symbology } from './symbology';

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
  /**
   * How the layer is drawn. The MapLibre style layers and the legend are
   * both generated from this (see `./symbology.ts`), so they cannot drift.
   */
  symbology: Symbology;
  /** Whether the layer is shown when the app opens. */
  defaultVisible: boolean;
  popup?: PopupDefinition;
}
