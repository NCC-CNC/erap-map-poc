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

/**
 * A named number format (schema `$defs/formatPreset`): `number` and
 * `count` (0 decimals, thousands separators), `percent` (a value already 0
 * to 100: 1 decimal, then `%`), `hectares` (0 decimals, `ha`) and `km`
 * (1 decimal, `km`).
 */
export type FormatPreset = 'number' | 'count' | 'percent' | 'hectares' | 'km';

/** How a number is shown. Text values are shown as they are. */
export interface NumberFormat {
  /** A preset to start from; the fields below change it. */
  preset?: FormatPreset;
  /** Decimal places, always shown. Defaults to 0 (or the preset's). */
  decimals?: number;
  /** Thousands separators. Defaults to true. */
  grouping?: boolean;
  /** Unit after the number, separated by a space, for example `ha`. */
  suffix?: string;
}

/** A number format: a preset name or a `NumberFormat` (schema `$defs/format`). */
export type Format = FormatPreset | NumberFormat;

/** One labelled value in the pop-up. */
export interface PopupStat {
  /** Plain-language label, for example `Area`, not the attribute name. */
  label: string;
  value: ValueSource;
  /** Number formatting; without it numbers are shown as they are. */
  format?: Format;
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
  /**
   * In a `gradient` legend, where the colour sits on the bar, 0 to 1. An
   * item without one (a no data colour) is a separate swatch.
   */
  position?: number;
}

/** Everything a legend shows for one layer, as resolved by the pipeline. */
export interface Legend {
  /**
   * `ramp` for classes of a number, `gradient` for a continuous colour
   * ramp, `categories` for categories, `single` for one colour.
   */
  kind: 'single' | 'categories' | 'ramp' | 'gradient';
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

/**
 * One colour theme of a layer (ADR 0012), as the pipeline resolved it: the
 * paint properties to set on its style layers (by configured id) and its
 * legend. The "Colour by" choice in the layer panel switches between them.
 */
export interface Theme {
  id: string;
  /** The name in the "Colour by" list. */
  label: string;
  /** Style layer id (as configured) to paint property names and values. */
  paint: Record<string, Record<string, unknown>>;
  legend: Legend;
}

/**
 * Text with attribute placeholders: `{attribute}`, `{attribute:preset}`
 * (a number format preset) and `{$id}` (the feature id).
 */
export type Template = string;

/** A list of labelled values, as in a pop-up. */
export interface AttributesBlock {
  type: 'attributes';
  items: PopupStat[];
}

/** A table of categories (rows) by attributes (columns). */
export interface TableBlock {
  type: 'table';
  caption?: string;
  /** Heading of the row label column. */
  rowHeader?: string;
  columns: { label: string; format?: Format }[];
  /** One attribute per column, or null for an empty cell. */
  rows: { label: string; values: (string | null)[] }[];
}

/** One series of a modal chart: one attribute (or null) per category. */
export interface ChartSeries {
  label: string;
  attributes: (string | null)[];
  color?: Color;
}

/** A bar (one or more series), pie or doughnut chart. */
export interface ChartBlock {
  type: 'chart';
  chart: 'bar' | 'pie' | 'doughnut';
  title: string;
  /** What the values are, for the accessible summary. */
  valueLabel: string;
  format?: Format;
  categories: string[];
  series: ChartSeries[];
  /** Slice colours of a pie or doughnut, one per category. */
  colors?: Color[];
}

/** A paragraph with placeholders. */
export interface TextBlock {
  type: 'text';
  text: Template;
}

/** A bulleted list of items from attributes, with a message for none. */
export interface ListBlock {
  type: 'list';
  /** An item shows when `when` (if given) is true and its text has every value. */
  items: { text: Template; when?: string }[];
  empty: string;
}

export type ModalBlock = AttributesBlock | TableBlock | ChartBlock | TextBlock | ListBlock;

/** A section of the modal: a heading, optional text and blocks. */
export interface ModalSection {
  heading: string;
  /** A shorter label for the section's tab (default: the heading). */
  tab?: string;
  description?: Template;
  blocks?: ModalBlock[];
}

/** How the modal shows its sections: a tab each (the default), or all in one scroll. */
export type ModalLayout = 'tabs' | 'scroll';

/**
 * Click details in a modal dialog (ADR 0012): one template per layer,
 * filled from the clicked feature's tile attributes.
 */
export interface ModalDefinition {
  title: Template;
  subtitle?: Template;
  layout?: ModalLayout;
  sections: ModalSection[];
}

/** The `display` block of a manifest entry (schema `$defs/display`). */
export interface Display {
  title: string;
  defaultVisible: boolean;
  order: number;
  popup?: PopupDefinition;
  modal?: ModalDefinition;
  layers: StyleLayer[];
  legend: Legend;
  themes?: Theme[];
  defaultTheme?: string;
}

/**
 * The kind of data layer, the manifest entry's `type`: `vector` tiles in a
 * .pmtiles archive, or a `raster` layer whose COG (.cog.tif) holds the
 * share covered as grey levels, drawn through a `raster-dem` source (ADR
 * 0008 and 0010).
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
  modal?: ModalDefinition;
  /**
   * Colour themes, when the layer has them; `layers` and `legend` are then
   * those of `defaultTheme`.
   */
  themes?: Theme[];
  defaultTheme?: string;
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
