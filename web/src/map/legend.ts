import type { LegendItem } from '../layers';

/**
 * The CSS `linear-gradient` for a gradient legend's bar: each item with a
 * `position` as a colour stop, in order.
 */
export function gradientCss(items: readonly LegendItem[]): string {
  const stops = items
    .filter((item) => item.position !== undefined)
    .map((item) => `${item.color} ${Math.round((item.position as number) * 1000) / 10}%`);
  return `linear-gradient(to right, ${stops.join(', ')})`;
}
