import type { LegendItem } from '../layers';

/**
 * The colour a legend swatch shows: `color` at the layer's `opacity` over
 * `ground`, the basemap's land colour, as the map draws it. Without this a
 * semi-transparent swatch sits on the white panel and looks lighter than
 * the same fill on the map. A colour without an opacity, or fully opaque,
 * is returned as is.
 */
export function swatchColor(color: string, opacity: number | undefined, ground: string): string {
  if (opacity === undefined || opacity >= 1) return color;
  const percent = Math.round(Math.max(0, opacity) * 1000) / 10;
  return `color-mix(in srgb, ${color} ${percent}%, ${ground})`;
}

/**
 * The CSS `linear-gradient` for a gradient legend's bar: each item with a
 * `position` as a colour stop, in order, each at `opacity` over `ground`
 * when they are given (see `swatchColor`).
 */
export function gradientCss(items: readonly LegendItem[], opacity?: number, ground = '#fff'): string {
  const stops = items
    .filter((item) => item.position !== undefined)
    .map(
      (item) =>
        `${swatchColor(item.color, opacity, ground)} ${Math.round((item.position as number) * 1000) / 10}%`,
    );
  return `linear-gradient(to right, ${stops.join(', ')})`;
}
