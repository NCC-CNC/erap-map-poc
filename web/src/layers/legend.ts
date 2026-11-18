import type { LayerSpecification } from '@maplibre/maplibre-gl-style-spec';
import type { Legend, LegendConfig, LegendItem } from './types';

/**
 * Legends from the colour expressions of a layer's style layers (design
 * note 04, decision 4): the colour of the first fill, fill-extrusion,
 * circle, line or color-relief layer, when it is a constant (`single`), a
 * `match` (`categories`), a `step` (`ramp`) or an `interpolate`
 * (`gradient`) with constant colours, optionally inside a
 * `['case', test, <expression>, fallback]` guard for missing values (the
 * fallback has no label, so it is left out). A layer whose legend needs
 * more, such as labels that are not in the expression, gives it in its
 * layer file, and any part it leaves out comes from the derived legend.
 */

/** Paint properties read for a derived legend, per style layer type. */
const COLOR_PAINT: Readonly<Record<string, string>> = {
  fill: 'fill-color',
  'fill-extrusion': 'fill-extrusion-color',
  circle: 'circle-color',
  line: 'line-color',
  'color-relief': 'color-relief-color',
};
const OPACITY_PAINT: Readonly<Record<string, string>> = {
  fill: 'fill-opacity',
  'fill-extrusion': 'fill-extrusion-opacity',
  circle: 'circle-opacity',
  line: 'line-opacity',
  'color-relief': 'color-relief-opacity',
};
const SHAPE: Readonly<Record<string, Legend['shape']>> = {
  fill: 'square',
  'fill-extrusion': 'square',
  circle: 'circle',
  line: 'line',
  'color-relief': 'square',
};

const LOCALE = 'en-CA';

const isColor = (v: unknown): v is string => typeof v === 'string' && v.length > 0;

/**
 * A number in a legend label, with thousands separators. With `span`, the
 * range of a gradient, rounded to suit it (0 decimals from 100 up, 1 from
 * 10, 2 from 1, else 3).
 */
export function formatBound(value: number, span?: number): string {
  if (span === undefined) return new Intl.NumberFormat(LOCALE).format(value);
  const decimals = span >= 100 ? 0 : span >= 10 ? 1 : span >= 1 ? 2 : 3;
  return new Intl.NumberFormat(LOCALE, { maximumFractionDigits: decimals }).format(value);
}

/** Legend kind and items from a colour value, or null if not simple enough. */
export function colorItems(
  value: unknown,
  title: string,
): { kind: Legend['kind']; items: LegendItem[] } | null {
  if (isColor(value)) return { kind: 'single', items: [{ color: value, label: title }] };
  if (!Array.isArray(value)) return null;
  const [op, ...args] = value as unknown[];
  if (op === 'case' && args.length === 3 && isColor(args[2])) return colorItems(args[1], title);
  if (op === 'match') {
    // ['match', input, label1, colour1, ..., fallback]
    const pairs = args.slice(1, -1);
    if (pairs.length < 2 || pairs.length % 2 !== 0) return null;
    const items: LegendItem[] = [];
    for (let i = 0; i < pairs.length; i += 2) {
      const label = pairs[i];
      const color = pairs[i + 1];
      if (!isColor(color)) return null;
      items.push({ color, label: Array.isArray(label) ? label.join(', ') : String(label) });
    }
    return { kind: 'categories', items };
  }
  if (op === 'step') {
    // ['step', input, colour0, stop1, colour1, ..., stopN, colourN]
    const [, base, ...rest] = args;
    if (!isColor(base) || rest.length < 2 || rest.length % 2 !== 0) return null;
    const stops: { from: number; color: string }[] = [];
    for (let i = 0; i < rest.length; i += 2) {
      const from = rest[i];
      const color = rest[i + 1];
      if (typeof from !== 'number' || !isColor(color)) return null;
      stops.push({ from, color });
    }
    const items: LegendItem[] = [{ color: base, label: `Below ${formatBound(stops[0]!.from)}` }];
    stops.forEach((stop, i) => {
      const next = stops[i + 1];
      items.push({
        color: stop.color,
        label: next
          ? `${formatBound(stop.from)} to ${formatBound(next.from)}`
          : `${formatBound(stop.from)} or more`,
      });
    });
    return { kind: 'ramp', items };
  }
  if (op === 'interpolate' || op === 'interpolate-hcl' || op === 'interpolate-lab') {
    // ['interpolate', interpolation, input, stop1, colour1, ..., stopN, colourN]
    const rest = args.slice(2);
    if (rest.length < 4 || rest.length % 2 !== 0) return null;
    const stops: { at: number; color: string }[] = [];
    for (let i = 0; i < rest.length; i += 2) {
      const at = rest[i];
      const color = rest[i + 1];
      if (typeof at !== 'number' || !isColor(color)) return null;
      stops.push({ at, color });
    }
    const min = stops[0]!.at;
    const span = stops[stops.length - 1]!.at - min;
    if (!(span > 0)) return null;
    return {
      kind: 'gradient',
      items: stops.map(({ at, color }) => ({
        color,
        label: formatBound(at, span),
        position: (at - min) / span,
      })),
    };
  }
  return null;
}

type Paint = Record<string, unknown> | undefined;
const paintOf = (layer: LayerSpecification): Paint => (layer as { paint?: Paint }).paint;

/**
 * The legend derived from style layers (see the module comment), or null
 * when it cannot be. `title` labels a single colour.
 */
export function deriveLegend(layers: readonly LayerSpecification[], title: string): Legend | null {
  const main = layers.find((l) => COLOR_PAINT[l.type]);
  if (!main) return null;
  const paint = paintOf(main);
  const derived = colorItems(paint?.[COLOR_PAINT[main.type]!], title);
  if (!derived) return null;
  const opacity = paint?.[OPACITY_PAINT[main.type]!];
  let border = 'transparent';
  if (main.type === 'circle' && isColor(paint?.['circle-stroke-color'])) {
    border = paint['circle-stroke-color'];
  } else if (main.type === 'fill') {
    const outline = layers.find((l) => l.type === 'line' && isColor(paintOf(l)?.['line-color']));
    const outlineColor = outline && paintOf(outline)?.['line-color'];
    if (isColor(outlineColor)) border = outlineColor;
    else if (isColor(paint?.['fill-outline-color'])) border = paint['fill-outline-color'];
  }
  return {
    kind: derived.kind,
    shape: SHAPE[main.type] ?? 'square',
    border,
    opacity: typeof opacity === 'number' ? opacity : 1,
    items: derived.items,
  };
}

/**
 * The legend to show: the explicit one, if any, with the parts it leaves
 * out from the derived one (or defaults), else the derived one; undefined
 * when there is neither.
 */
export function resolveLegend(
  explicit: LegendConfig | undefined,
  layers: readonly LayerSpecification[],
  title: string,
): Legend | undefined {
  const derived = deriveLegend(layers, title);
  if (!explicit) return derived ?? undefined;
  return {
    kind: explicit.kind ?? derived?.kind ?? 'categories',
    shape: explicit.shape ?? derived?.shape ?? SHAPE[layers[0]?.type ?? ''] ?? 'square',
    border: explicit.border ?? derived?.border ?? 'transparent',
    opacity: explicit.opacity ?? derived?.opacity ?? 1,
    items: explicit.items,
  };
}
