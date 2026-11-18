import type { LayerSpecification, SourceSpecification } from '@maplibre/maplibre-gl-style-spec';
import type * as LayerFile from './layer.generated';

/**
 * The app's names for the layer file shapes it reads from style.json's
 * `metadata["erap:layers"]`. They are generated from
 * `pipeline/schema/layer.schema.json` (`./layer.generated.ts`, design
 * note 04), so they cannot drift from what the pipeline writes.
 */
export type {
  AttributesBlock,
  ChartBlock,
  Color,
  Format,
  FormatPreset,
  Block,
  ListBlock,
  NumberFormat,
  PopupLayout,
  PopupSize,
  Section,
  TableBlock,
  Template,
  TextBlock,
  ValueSource,
} from './layer.generated';

/**
 * What a click on a feature of the layer shows: a small pop-up at the
 * click or a dialog, of sections of blocks.
 */
export type PopupDefinition = LayerFile.Popup;
/** One labelled value in an attributes block. */
export type PopupStat = LayerFile.Stat;
/** One series of a chart block. */
export type ChartSeries = LayerFile.ChartBlock['series'][number];
/** One legend entry: a swatch and its label. */
export type LegendItem = LayerFile.LegendItem;
/** A legend as a layer file gives it: only `items` is required. */
export type LegendConfig = LayerFile.Legend;
/** A colour theme as a layer file gives it: the first has no `paint`. */
export type ThemeConfig = LayerFile.Theme;

/**
 * One map layer's entry in style.json's `metadata["erap:layers"]`, as the
 * pipeline writes it (`pipeline/lib/style.sh`).
 */
export interface LayerMetadata {
  title?: string;
  type?: LayerType;
  order?: number;
  visible?: boolean;
  legend?: LegendConfig;
  themes?: ThemeConfig[];
  popup?: PopupDefinition;
}

/** A legend ready to show: an explicit one completed from the derived one. */
export interface Legend {
  /**
   * `ramp` for classes of a number, `gradient` for a continuous colour
   * ramp, `categories` for categories, `single` for one colour.
   */
  kind: NonNullable<LegendConfig['kind']>;
  /** Swatch shape: `square` for fills, `circle` for points, `line` for lines. */
  shape: NonNullable<LegendConfig['shape']>;
  /** Swatch border: the outline or stroke colour. */
  border: string;
  /** Swatch opacity, matching the map. */
  opacity: number;
  items: LegendItem[];
}

/**
 * One colour theme (ADR 0012), ready to apply: the paint properties to set
 * on its style layers, by the id in the layer file (without the `<layer>-`
 * prefix), and its legend. Every theme of a layer sets the same
 * properties (the first theme's are the style layers' own), so switching
 * from any theme to any other leaves nothing behind.
 */
export interface Theme {
  id: string;
  /** The name in the "Colour by" list. */
  label: string;
  paint: Record<string, Record<string, unknown>>;
  /** Undefined when there is neither an explicit nor a derived legend. */
  legend?: Legend;
}

/**
 * The kind of data layer: `vector` tiles in a .pmtiles archive, or a
 * `raster` layer whose COG (.cog.tif) holds the share covered as grey
 * levels, drawn through a `raster-dem` source (ADR 0008 and 0010).
 */
export type LayerType = 'vector' | 'raster';

/** Everything the map needs to know about one data layer. */
export interface LayerDefinition {
  /** The layer name: the `erap:layer` of its style layers. */
  id: string;
  type: LayerType;
  /** Human-readable name, for legends and layer controls. */
  title: string;
  /** Whether the layer is shown when the app opens. */
  defaultVisible: boolean;
  /** Draw order: higher is drawn on top. */
  order: number;
  /** Its sources, by id, with URLs resolved against the tiles URL. */
  sources: Record<string, SourceSpecification>;
  /** Its style layers in draw order (last on top), with their ids on the map. */
  layers: LayerSpecification[];
  /** The legend of a layer without themes; undefined when there is none. */
  legend?: Legend;
  popup?: PopupDefinition;
  /** Colour themes, when the layer has them; `layers` draw the first. */
  themes?: Theme[];
}

/** A basemap theme the map config may open with (ADR 0006). */
export type BasemapName = 'light' | 'dark';

/**
 * The map's settings from the map config, as style.json has them: its
 * `center` and `zoom`, and `metadata["erap:basemap"]`, `["erap:view"]`
 * (`minzoom`, `maxzoom`, `bounds`), `["erap:title"]` and
 * `["erap:locale"]`. Each is optional; the app's own default applies where
 * one is not set.
 */
export interface MapDefaults {
  /** Opening centre, `[longitude, latitude]`. */
  center?: [number, number];
  /** Opening zoom. */
  zoom?: number;
  /** Opening basemap. */
  basemap?: BasemapName;
  /** The furthest out the map can zoom. */
  minZoom?: number;
  /** The furthest in the map can zoom. */
  maxZoom?: number;
  /** `[west, south, east, north]`: the map cannot be panned outside them. */
  bounds?: [number, number, number, number];
  /** The map's name, the page title. */
  title?: string;
  /** The locale numbers are formatted in, a BCP 47 tag such as `fr-CA`. */
  locale?: string;
}
