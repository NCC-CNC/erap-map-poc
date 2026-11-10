import type {
  CircleLayerSpecification,
  ExpressionSpecification,
  FillLayerSpecification,
  LineLayerSpecification,
} from '@maplibre/maplibre-gl-style-spec';

/**
 * Symbology: one description of how a layer is drawn, from which both the
 * MapLibre style layers (`styleLayers`) and the legend (`legendFor`) are
 * generated. Never write a legend by hand next to a style; extend these
 * types instead.
 */

/** CSS colour, as MapLibre accepts it, for example `#2c7fb8`. */
export type Color = string;

/** Colour used for features that match no category or have no value. */
export interface Fallback {
  color: Color;
  /** Legend label; without one the fallback is left out of the legend. */
  label?: string;
}

/** Every feature in one colour. */
export interface SingleColor {
  type: 'single';
  color: Color;
  /** Legend label; defaults to the layer title. */
  label?: string;
}

/** One colour per value of a text attribute (MapLibre `match`). */
export interface CategoricalColor {
  type: 'categorical';
  attribute: string;
  categories: { value: string; color: Color; label: string }[];
  fallback: Fallback;
}

/**
 * Colour classes on a numeric attribute (MapLibre `step`). A class runs
 * from its `from` (inclusive) up to the next class's `from` (exclusive);
 * the last class runs to `max`, which is used for the legend only. Values
 * below the first `from` take the first colour; features without a numeric
 * value take the fallback colour.
 */
export interface SteppedColor {
  type: 'stepped';
  attribute: string;
  /** In ascending `from` order. */
  stops: { from: number; color: Color }[];
  max: number;
  fallback: Fallback;
}

export type ColorRule = SingleColor | CategoricalColor | SteppedColor;

/** Polygons: a fill coloured by `color` with a thin outline. */
export interface PolygonSymbology {
  geometry: 'polygon';
  color: ColorRule;
  /** Fill opacity, 0 to 1. */
  fillOpacity: number;
  outline: { color: Color; width: number };
}

/** Points: circles coloured by `color` with a contrasting stroke. */
export interface PointSymbology {
  geometry: 'point';
  color: ColorRule;
  /** Circle radius in pixels. */
  radius: number;
  stroke: { color: Color; width: number };
}

export type Symbology = PolygonSymbology | PointSymbology;

type WithoutSource<T> = T extends unknown ? Omit<T, 'source' | 'source-layer'> : never;

/**
 * A generated MapLibre style layer. `source` and `source-layer` are filled
 * in from the layer definition by `toMapLibre`, so they are left out here.
 */
export type StyleLayer = WithoutSource<
  FillLayerSpecification | LineLayerSpecification | CircleLayerSpecification
>;

/** The MapLibre colour value (a constant or an expression) for a rule. */
export function colorValue(rule: ColorRule): Color | ExpressionSpecification {
  switch (rule.type) {
    case 'single':
      return rule.color;
    case 'categorical': {
      const pairs = rule.categories.flatMap((c) => [c.value, c.color]);
      return [
        'match',
        ['to-string', ['get', rule.attribute]],
        ...pairs,
        rule.fallback.color,
      ] as ExpressionSpecification;
    }
    case 'stepped': {
      const [first, ...rest] = rule.stops;
      if (!first) throw new Error(`Stepped colour on "${rule.attribute}" has no stops.`);
      const value: ExpressionSpecification = ['get', rule.attribute];
      const step = [
        'step',
        value,
        first.color,
        ...rest.flatMap((s) => [s.from, s.color]),
      ] as ExpressionSpecification;
      return ['case', ['==', ['typeof', value], 'number'], step, rule.fallback.color];
    }
  }
}

/** Style layer ids for a layer, in draw order (last on top). */
export function styleLayerIds(layerId: string, symbology: Symbology): string[] {
  return symbology.geometry === 'polygon'
    ? [`${layerId}-fill`, `${layerId}-outline`]
    : [`${layerId}-circle`];
}

/** Generates the MapLibre style layers for a layer, in draw order. */
export function styleLayers(layerId: string, symbology: Symbology): StyleLayer[] {
  const color = colorValue(symbology.color);
  if (symbology.geometry === 'polygon') {
    const [fillId, outlineId] = styleLayerIds(layerId, symbology) as [string, string];
    return [
      {
        id: fillId,
        type: 'fill',
        paint: { 'fill-color': color, 'fill-opacity': symbology.fillOpacity },
      },
      {
        id: outlineId,
        type: 'line',
        paint: { 'line-color': symbology.outline.color, 'line-width': symbology.outline.width },
      },
    ];
  }
  const [circleId] = styleLayerIds(layerId, symbology) as [string];
  return [
    {
      id: circleId,
      type: 'circle',
      paint: {
        'circle-color': color,
        'circle-radius': symbology.radius,
        'circle-stroke-color': symbology.stroke.color,
        'circle-stroke-width': symbology.stroke.width,
      },
    },
  ];
}

/** One legend entry: a swatch and its label. */
export interface LegendItem {
  color: Color;
  label: string;
}

/** Everything a legend shows for one layer. */
export interface Legend {
  /** `ramp` for stepped classes, `categories` for categories, `single` for one colour. */
  kind: 'single' | 'categories' | 'ramp';
  /** Swatch shape, matching the geometry. */
  shape: 'square' | 'circle';
  /** Swatch border: the outline or stroke colour. */
  border: Color;
  /** Swatch fill opacity, matching the map. */
  opacity: number;
  items: LegendItem[];
}

/** Number shown in a range label, with thousands separators. */
function formatBound(value: number): string {
  return new Intl.NumberFormat('en-CA').format(value);
}

function legendItems(rule: ColorRule, title: string): LegendItem[] {
  const fallback = (f: Fallback): LegendItem[] => (f.label ? [{ color: f.color, label: f.label }] : []);
  switch (rule.type) {
    case 'single':
      return [{ color: rule.color, label: rule.label ?? title }];
    case 'categorical':
      return [
        ...rule.categories.map((c) => ({ color: c.color, label: c.label })),
        ...fallback(rule.fallback),
      ];
    case 'stepped':
      return [
        ...rule.stops.map((stop, i) => ({
          color: stop.color,
          label: `${formatBound(stop.from)} to ${formatBound(rule.stops[i + 1]?.from ?? rule.max)}`,
        })),
        ...fallback(rule.fallback),
      ];
  }
}

const LEGEND_KIND = { single: 'single', categorical: 'categories', stepped: 'ramp' } as const;

/** Generates the legend for a layer from the same symbology as its style. */
export function legendFor(symbology: Symbology, title: string): Legend {
  const polygon = symbology.geometry === 'polygon';
  return {
    kind: LEGEND_KIND[symbology.color.type],
    shape: polygon ? 'square' : 'circle',
    border: polygon ? symbology.outline.color : symbology.stroke.color,
    opacity: polygon ? symbology.fillOpacity : 1,
    items: legendItems(symbology.color, title),
  };
}
