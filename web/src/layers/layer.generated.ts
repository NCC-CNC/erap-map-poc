/* Generated from pipeline/schema/layer.schema.json by web/vite/layerTypes.ts
 * (npm run layer-types). Do not edit by hand. */

/**
 * An attribute name in the source data, as it is there.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "sourceField".
 */
export type SourceField = string;
/**
 * An output attribute name: lower case letters, digits and _.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "name".
 */
export type Name = string;
/**
 * Attributes to keep, in order: a name keeps the attribute as it is; a one-key map `{source_name: output_name}` renames it.
 *
 * @minItems 1
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "fieldList".
 */
export type FieldList = (
  | Name
  | {
      [k: string]: Name;
    }
)[];
/**
 * A short id, unique within the layer, such as `fill`.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "styleId".
 */
export type StyleId = string;
/**
 * A CSS colour, as MapLibre accepts it, for example #2c7fb8.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "color".
 */
export type Color = string;
/**
 * "Colour by" choices in the layer panel. The first is what `layers` draw (it has no `paint`); each other one replaces paint properties of some style layers.
 *
 * @minItems 2
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "themes".
 */
export type Themes = Theme[];
/**
 * Text with placeholders: `{attribute}` as it is, `{attribute:preset}` in a format preset, `{$id}` the feature id.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "template".
 */
export type Template = string;
/**
 * `small` (default): one section in a pop-up at the click; `dialog`: sections in a dialog over the map.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "popupSize".
 */
export type PopupSize = 'small' | 'dialog';
/**
 * How a dialog shows its sections: `tabs` (default), one at a time; `scroll`, all in one scrolling dialog.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "popupLayout".
 */
export type PopupLayout = 'tabs' | 'scroll';
/**
 * One block of a pop-up section.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "block".
 */
export type Block = AttributesBlock | TableBlock | ChartBlock | TextBlock | ListBlock;
/**
 * Where a value comes from: a tile attribute, or the feature id.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "valueSource".
 */
export type ValueSource =
  | {
      attribute: Attribute;
    }
  | {
      featureId: true;
    };
/**
 * A tile attribute name.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "attribute".
 */
export type Attribute = string;
/**
 * How a number is shown: a preset name or a number format. Without one, values are shown as they are.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "format".
 */
export type Format = FormatPreset | NumberFormat;
/**
 * A named number format, in the map's locale with thousands separators: `number` (decimals as the value has them, up to 3), `integer` (0 decimals), `percent` (a value 0 to 100: 1 decimal and %). Units go in `suffix`.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "formatPreset".
 */
export type FormatPreset = 'number' | 'integer' | 'percent';
/**
 * The attribute for one value, or null for an empty cell.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "cellAttribute".
 */
export type CellAttribute = Attribute | null;

/**
 * One map layer: pipeline/layers/<layer>.yaml. The layer name is the file name. `source`, `fields` and `processing` say how it is built; `display` how it is drawn. Design note 04.
 */
export interface LayerFile {
  /**
   * Layer name shown in the layer panel.
   */
  title: string;
  /**
   * Switched on when the map opens. Default false.
   */
  visible?: boolean;
  /**
   * Draw order: higher on top and first in the layer panel; ties by layer name. Default 0.
   */
  order?: number;
  source: Source;
  fields?: Fields;
  processing: Processing;
  display: Display;
}
/**
 * The source settings, none required (a map config override sets only some).
 */
export interface Source {
  /**
   * The dataset: a path under RAW_DIR, an absolute path, or a GDAL /vsi path. Anything GDAL opens; a .zip is read in place.
   */
  path?: string;
  /**
   * Vector only: the layer inside the dataset (a geodatabase or GeoPackage). Default the first.
   */
  layer?: string;
  id?: SourceField;
  /**
   * The source CRS, for example EPSG:3347, for data without a usable one.
   */
  srs?: string;
  /**
   * Vector only: the attribute encoding, for example ISO-8859-1, for a shapefile without a .cpg.
   */
  encoding?: string;
  /**
   * Raster only: the source nodata value, for a raster that declares none or the wrong one.
   */
  nodata?: number | ('nan' | 'NaN');
  /**
   * Vector only: attributes added from non-spatial tables (a CSV, or a table in a dataset), matched by key.
   *
   * @minItems 1
   */
  joins?: Join[];
}
/**
 * One join: rows of `path` (and `layer`) whose `on` attribute equals the source's `on` attribute.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "join".
 */
export interface Join {
  /**
   * The table: a path under RAW_DIR or an absolute path.
   */
  path: string;
  /**
   * The table inside the dataset. Default the first.
   */
  layer?: string;
  on: SourceField;
  fields?: FieldList;
}
/**
 * Vector only: the attributes in the tiles. Everything else is dropped.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "fields".
 */
export interface Fields {
  keep?: FieldList;
  /**
   * New attributes: name to a SQLite expression on the kept attributes (output names), run by ogr2ogr -dialect SQLite. A comparison gives 1 or 0, as for an action recommendation.
   */
  calculated?: {
    [k: string]: string;
  };
}
/**
 * The processing settings, none required (a map config override sets only some).
 */
export interface Processing {
  /**
   * The preset. `default`: lines and polygons, simplified below the max zoom only. `coverage`: polygons that tile the land without overlaps; shared borders kept identical, the smallest dropped first when a tile is full, and the zooms below the max generalised (small parts dropped, borders simplified). `points`: every point at every zoom. `raster`: a binary raster, a Web Mercator COG, display only. Default `default`.
   */
  profile?: 'default' | 'coverage' | 'points' | 'raster';
  /**
   * Lowest zoom built. Default 0.
   */
  minzoom?: number;
  /**
   * Highest zoom built; the map overzooms past it. For a raster, also its resolution (z12 is about 20 to 27 m across Canada), at most 14.
   */
  maxzoom?: number;
  /**
   * Coverage only: below the max zoom, drop polygon parts smaller than this many screen pixels (each feature keeps its largest part). Default 4.
   */
  min_part_px?: number;
  /**
   * Coverage only: below the max zoom, simplify borders by this many screen pixels; 0 for none. Default 1.
   */
  simplify_px?: number;
  /**
   * Vector only: the drop guard fails the build if a polygon whose largest part covers this many screen pixels is missing from a zoom. Default 1.
   */
  min_visible_px?: number;
  /**
   * Raster only: how many evenly spaced shares of cover (0 to 255) the COG keeps, 2 to 256. Fewer compress better. Default 256.
   */
  grey_levels?: number;
  /**
   * Advanced, vector only: extra tippecanoe arguments, added after the preset's, for layers the presets do not fit (dense points, detailed lines, large polygon sets), such as `--drop-densest-as-needed`. Each is one argument starting with `--`, its value after `=`. A change makes the layer stale.
   *
   * @minItems 1
   */
  tippecanoe?: string[];
}
/**
 * How the layer is drawn and what a click shows.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "display".
 */
export interface Display {
  /**
   * MapLibre style layers, in draw order (last on top), as they will appear in style.json. The pipeline adds `source`, `source-layer` and the `<layer>-` id prefix.
   *
   * @minItems 1
   */
  layers: StyleLayer[];
  themes?: Themes;
  legend?: Legend;
  popup?: Popup;
}
/**
 * A MapLibre style layer without `source` and `source-layer`. Paint, layout and filter are checked against the MapLibre style spec by the web app's tests.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "styleLayer".
 */
export interface StyleLayer {
  id: StyleId;
  /**
   * The MapLibre layer type. A binary raster is a `color-relief` layer on the COG.
   */
  type:
    | 'fill'
    | 'line'
    | 'symbol'
    | 'circle'
    | 'heatmap'
    | 'fill-extrusion'
    | 'raster'
    | 'hillshade'
    | 'color-relief';
  /**
   * A MapLibre filter expression.
   */
  filter?: unknown[];
  /**
   * Hidden below this zoom.
   */
  minzoom?: number;
  /**
   * Hidden from this zoom.
   */
  maxzoom?: number;
  /**
   * MapLibre layout properties.
   */
  layout?: {
    [k: string]: unknown;
  };
  /**
   * MapLibre paint properties.
   */
  paint?: {
    [k: string]: unknown;
  };
  /**
   * Free-form data, kept as it is.
   */
  metadata?: {
    [k: string]: unknown;
  };
}
/**
 * One colour theme.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "theme".
 */
export interface Theme {
  id: StyleId;
  /**
   * The name in the "Colour by" list.
   */
  label: string;
  /**
   * Style layer id to the paint properties this theme sets on it.
   */
  paint?: {
    [k: string]: {
      [k: string]: unknown;
    };
  };
  legend?: Legend;
}
/**
 * A legend, used as it is. Parts left out are taken from the derived legend.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "legend".
 */
export interface Legend {
  /**
   * `ramp` for classes of a number, `gradient` for a continuous ramp, `categories`, or `single` for one colour.
   */
  kind?: 'single' | 'categories' | 'ramp' | 'gradient';
  /**
   * Swatch shape: `square` for fills, `circle` for points, `line` for lines.
   */
  shape?: 'square' | 'circle' | 'line';
  border?: Color;
  /**
   * Swatch opacity.
   */
  opacity?: number;
  /**
   * The swatches, in order.
   *
   * @minItems 1
   */
  items: LegendItem[];
}
/**
 * One swatch.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "legendItem".
 */
export interface LegendItem {
  color: Color;
  /**
   * Its text.
   */
  label: string;
  /**
   * In a `gradient` legend, where the colour sits on the bar, 0 to 1. Items without one show as separate swatches.
   */
  position?: number;
}
/**
 * What a click on a feature shows, filled from its attributes: a small pop-up at the click or a dialog. Without one the layer is not clickable.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "popup".
 */
export interface Popup {
  title: Template;
  subtitle?: Template;
  size?: PopupSize;
  layout?: PopupLayout;
  /**
   * The sections, in order.
   *
   * @minItems 1
   */
  sections: Section[];
}
/**
 * An optional heading and description, then blocks. Hidden when every block is.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "section".
 */
export interface Section {
  /**
   * Section heading; required in a dialog.
   */
  heading?: string;
  /**
   * A shorter tab label in a dialog; default the heading. Tab labels are unique.
   */
  tab?: string;
  description?: Template;
  /**
   * The blocks, in order.
   *
   * @minItems 1
   */
  blocks?: Block[];
}
/**
 * Labelled values. Items without a value are hidden, and the block with none left.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "attributesBlock".
 */
export interface AttributesBlock {
  type: 'attributes';
  /**
   * The values.
   *
   * @minItems 1
   */
  items: Stat[];
}
/**
 * A labelled value.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "stat".
 */
export interface Stat {
  /**
   * Its label.
   */
  label: string;
  value: ValueSource;
  format?: Format;
}
/**
 * A number format: a `preset` (default `number`), changed by `decimals`, `grouping` and `suffix`.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "numberFormat".
 */
export interface NumberFormat {
  preset?: FormatPreset;
  /**
   * Decimal places, always shown.
   */
  decimals?: number;
  /**
   * Thousands separators.
   */
  grouping?: boolean;
  /**
   * Unit after the number, after a space (`%` directly), such as `ha` or `km`.
   */
  suffix?: string;
}
/**
 * A table of rows by columns; each row gives one attribute per column. Rows with no values are hidden, and the table with none left.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "tableBlock".
 */
export interface TableBlock {
  type: 'table';
  /**
   * Table caption.
   */
  caption?: string;
  /**
   * Heading of the row label column.
   */
  rowHeader?: string;
  /**
   * The columns.
   *
   * @minItems 1
   */
  columns: {
    /**
     * Column heading.
     */
    label: string;
    format?: Format;
  }[];
  /**
   * The rows.
   *
   * @minItems 1
   */
  rows: {
    /**
     * Row label.
     */
    label: string;
    /**
     * One attribute per column.
     *
     * @minItems 1
     */
    values: CellAttribute[];
  }[];
}
/**
 * A Chart.js chart over `categories`. `bar` and `line` take one or more series (several make a grouped bar chart or several lines, with a legend); `pie` and `doughnut` exactly one. Each series gives one attribute per category. Hidden with no values.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "chartBlock".
 */
export interface ChartBlock {
  type: 'chart';
  /**
   * Chart type.
   */
  chart: 'bar' | 'line' | 'pie' | 'doughnut';
  /**
   * Heading above the chart.
   */
  title: string;
  /**
   * What the values are, for the accessible summary.
   */
  valueLabel: string;
  format?: Format;
  /**
   * Bar, point or slice labels.
   *
   * @minItems 1
   */
  categories: string[];
  /**
   * The series.
   *
   * @minItems 1
   */
  series: {
    /**
     * Series name.
     */
    label: string;
    /**
     * One attribute per category.
     *
     * @minItems 1
     */
    attributes: CellAttribute[];
    color?: Color;
  }[];
  /**
   * Slice colours of a pie or doughnut, one per category.
   *
   * @minItems 1
   */
  colors?: Color[];
}
/**
 * A paragraph; hidden when a placeholder has no value.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "textBlock".
 */
export interface TextBlock {
  type: 'text';
  text: Template;
}
/**
 * A bulleted list, such as recommended actions. An item shows when its `when` attribute is true (not 0, empty, false or no) and its placeholders have values; with none, `empty` shows.
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "listBlock".
 */
export interface ListBlock {
  type: 'list';
  /**
   * The items.
   *
   * @minItems 1
   */
  items: {
    text: Template;
    when?: Attribute;
  }[];
  /**
   * Shown when no item applies.
   */
  empty: string;
}
/**
 * The source settings, none required (a map config override sets only some).
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "sourceSettings".
 */
export interface SourceSettings {
  /**
   * The dataset: a path under RAW_DIR, an absolute path, or a GDAL /vsi path. Anything GDAL opens; a .zip is read in place.
   */
  path?: string;
  /**
   * Vector only: the layer inside the dataset (a geodatabase or GeoPackage). Default the first.
   */
  layer?: string;
  id?: SourceField;
  /**
   * The source CRS, for example EPSG:3347, for data without a usable one.
   */
  srs?: string;
  /**
   * Vector only: the attribute encoding, for example ISO-8859-1, for a shapefile without a .cpg.
   */
  encoding?: string;
  /**
   * Raster only: the source nodata value, for a raster that declares none or the wrong one.
   */
  nodata?: number | ('nan' | 'NaN');
  /**
   * Vector only: attributes added from non-spatial tables (a CSV, or a table in a dataset), matched by key.
   *
   * @minItems 1
   */
  joins?: Join[];
}
/**
 * The source settings, none required (a map config override sets only some).
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "source".
 */
export interface Source1 {
  /**
   * The dataset: a path under RAW_DIR, an absolute path, or a GDAL /vsi path. Anything GDAL opens; a .zip is read in place.
   */
  path?: string;
  /**
   * Vector only: the layer inside the dataset (a geodatabase or GeoPackage). Default the first.
   */
  layer?: string;
  id?: SourceField;
  /**
   * The source CRS, for example EPSG:3347, for data without a usable one.
   */
  srs?: string;
  /**
   * Vector only: the attribute encoding, for example ISO-8859-1, for a shapefile without a .cpg.
   */
  encoding?: string;
  /**
   * Raster only: the source nodata value, for a raster that declares none or the wrong one.
   */
  nodata?: number | ('nan' | 'NaN');
  /**
   * Vector only: attributes added from non-spatial tables (a CSV, or a table in a dataset), matched by key.
   *
   * @minItems 1
   */
  joins?: Join[];
}
/**
 * The processing settings, none required (a map config override sets only some).
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "processingSettings".
 */
export interface ProcessingSettings {
  /**
   * The preset. `default`: lines and polygons, simplified below the max zoom only. `coverage`: polygons that tile the land without overlaps; shared borders kept identical, the smallest dropped first when a tile is full, and the zooms below the max generalised (small parts dropped, borders simplified). `points`: every point at every zoom. `raster`: a binary raster, a Web Mercator COG, display only. Default `default`.
   */
  profile?: 'default' | 'coverage' | 'points' | 'raster';
  /**
   * Lowest zoom built. Default 0.
   */
  minzoom?: number;
  /**
   * Highest zoom built; the map overzooms past it. For a raster, also its resolution (z12 is about 20 to 27 m across Canada), at most 14.
   */
  maxzoom?: number;
  /**
   * Coverage only: below the max zoom, drop polygon parts smaller than this many screen pixels (each feature keeps its largest part). Default 4.
   */
  min_part_px?: number;
  /**
   * Coverage only: below the max zoom, simplify borders by this many screen pixels; 0 for none. Default 1.
   */
  simplify_px?: number;
  /**
   * Vector only: the drop guard fails the build if a polygon whose largest part covers this many screen pixels is missing from a zoom. Default 1.
   */
  min_visible_px?: number;
  /**
   * Raster only: how many evenly spaced shares of cover (0 to 255) the COG keeps, 2 to 256. Fewer compress better. Default 256.
   */
  grey_levels?: number;
  /**
   * Advanced, vector only: extra tippecanoe arguments, added after the preset's, for layers the presets do not fit (dense points, detailed lines, large polygon sets), such as `--drop-densest-as-needed`. Each is one argument starting with `--`, its value after `=`. A change makes the layer stale.
   *
   * @minItems 1
   */
  tippecanoe?: string[];
}
/**
 * The processing settings, none required (a map config override sets only some).
 *
 * This interface was referenced by `LayerFile`'s JSON-Schema
 * via the `definition` "processing".
 */
export interface Processing1 {
  /**
   * The preset. `default`: lines and polygons, simplified below the max zoom only. `coverage`: polygons that tile the land without overlaps; shared borders kept identical, the smallest dropped first when a tile is full, and the zooms below the max generalised (small parts dropped, borders simplified). `points`: every point at every zoom. `raster`: a binary raster, a Web Mercator COG, display only. Default `default`.
   */
  profile?: 'default' | 'coverage' | 'points' | 'raster';
  /**
   * Lowest zoom built. Default 0.
   */
  minzoom?: number;
  /**
   * Highest zoom built; the map overzooms past it. For a raster, also its resolution (z12 is about 20 to 27 m across Canada), at most 14.
   */
  maxzoom?: number;
  /**
   * Coverage only: below the max zoom, drop polygon parts smaller than this many screen pixels (each feature keeps its largest part). Default 4.
   */
  min_part_px?: number;
  /**
   * Coverage only: below the max zoom, simplify borders by this many screen pixels; 0 for none. Default 1.
   */
  simplify_px?: number;
  /**
   * Vector only: the drop guard fails the build if a polygon whose largest part covers this many screen pixels is missing from a zoom. Default 1.
   */
  min_visible_px?: number;
  /**
   * Raster only: how many evenly spaced shares of cover (0 to 255) the COG keeps, 2 to 256. Fewer compress better. Default 256.
   */
  grey_levels?: number;
  /**
   * Advanced, vector only: extra tippecanoe arguments, added after the preset's, for layers the presets do not fit (dense points, detailed lines, large polygon sets), such as `--drop-densest-as-needed`. Each is one argument starting with `--`, its value after `=`. A change makes the layer stale.
   *
   * @minItems 1
   */
  tippecanoe?: string[];
}
