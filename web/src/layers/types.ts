import type { LayerSpecification } from '@maplibre/maplibre-gl-style-spec';

/**
 * The shapes here mirror the shared JSON Schema,
 * `pipeline/schema/layer-style.schema.json` (`$defs`); `schema.test.ts`
 * checks they stay in step. The pipeline resolves each layer's
 * `<layer>.style.json` into the `display` block of its `manifest.json`
 * entry, which `./manifest.ts` reads into a `LayerDefinition`.
 */

/** CSS colour, as MapLibre accepts it, for example `#2c7fb8`. */
export type Color = string;

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
 * the content lives in the layer's display config and the map code stays
 * generic.
 */
export interface PopupDefinition {
  /** Pop-up heading; falls back to the layer title when missing. */
  title: ValueSource;
  stats: PopupStat[];
  charts?: PopupChart[];
}

/** One legend entry: a swatch and its label. */
export interface LegendItem {
  color: Color;
  label: string;
}

/** Everything a legend shows for one layer, as resolved by the pipeline. */
export interface Legend {
  /** `ramp` for classes of a number, `categories` for categories, `single` for one colour. */
  kind: 'single' | 'categories' | 'ramp';
  /** Swatch shape: `square` for fills, `circle` for points, `line` for lines. */
  shape: 'square' | 'circle' | 'line';
  /** Swatch border: the outline or stroke colour. */
  border: Color;
  /** Swatch opacity, matching the map. */
  opacity: number;
  items: LegendItem[];
}

type WithoutSource<T> = T extends unknown ? Omit<T, 'source' | 'source-layer'> : never;

/**
 * A MapLibre style layer as given in the display config: without `source`
 * and `source-layer` (filled in by `toMapLibre`), and with its id as
 * configured, before the `<layer>-` prefix is added.
 */
export type StyleLayer = WithoutSource<Exclude<LayerSpecification, { type: 'background' }>>;

/** The `display` block of a manifest entry (schema `$defs/display`). */
export interface Display {
  title: string;
  defaultVisible: boolean;
  order: number;
  popup?: PopupDefinition;
  layers: StyleLayer[];
  legend: Legend;
}

/**
 * The kind of data layer, the manifest entry's `type`: `vector` tiles, or a
 * `raster` layer whose archive holds the cover fraction as grey PNG tiles,
 * drawn through a `raster-dem` source (ADR 0008).
 */
export type LayerType = 'vector' | 'raster';

/** Everything the map needs to know about one data layer. */
export interface LayerDefinition {
  /** The manifest layer name; also the MapLibre source id and id prefix. */
  id: string;
  /** Vector or raster; decides the MapLibre source. */
  type: LayerType;
  /** Human-readable name, for legends and layer controls. */
  title: string;
  /** Archive file name under `/tiles/`, as written by the pipeline. */
  file: string;
  /** Vector tile layer name inside the archive (tippecanoe `-l`); unused for a raster layer. */
  sourceLayer: string;
  /** Whether the layer is shown when the app opens. */
  defaultVisible: boolean;
  /** Draw order: higher is drawn on top. */
  order: number;
  /** Style layers in draw order (last on top), ids as configured. */
  layers: StyleLayer[];
  legend: Legend;
  popup?: PopupDefinition;
}

/** A basemap theme the map config may open with (ADR 0006, ADR 0009). */
export type BasemapName = 'light' | 'dark';

/**
 * How the map opens, from the local map config (ADR 0009) through the
 * manifest's `map`. Each field is optional; the app's own default applies
 * where one is not set.
 */
export interface MapDefaults {
  /** Opening centre, `[longitude, latitude]`. */
  center?: [number, number];
  /** Opening zoom. */
  zoom?: number;
  /** Opening basemap. */
  basemap?: BasemapName;
}
