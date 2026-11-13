import type { CSSProperties } from 'react';
import type { Legend, LegendItem } from '../layers';
import { gradientCss } from './legend';

/**
 * A layer's inline legend, as the pipeline resolved it (derived from its
 * style, or given explicitly in its display config): one swatch and label
 * per item, or, for a `gradient` legend, a colour bar with the stop values
 * under it, then any items without a position (such as no data) as
 * swatches.
 */
export function LegendView({ legend, label }: { legend: Legend; label: string }) {
  const swatch = (item: LegendItem) => {
    const style: CSSProperties = {
      backgroundColor: item.color,
      opacity: legend.opacity,
      borderColor: legend.border,
    };
    return (
      <li key={item.label}>
        <span className={`layer-legend-swatch layer-legend-${legend.shape}`} style={style} aria-hidden="true" />
        {item.label}
      </li>
    );
  };

  if (legend.kind === 'gradient') {
    const stops = legend.items.filter((item) => item.position !== undefined);
    const others = legend.items.filter((item) => item.position === undefined);
    const first = stops[0];
    const last = stops[stops.length - 1];
    return (
      <ul className="layer-legend layer-legend-gradient" aria-label={label}>
        {first && last && (
          <li className="layer-legend-bar-item">
            <span className="visually-hidden">
              {`Colour gradient from ${first.label} to ${last.label}`}
            </span>
            <span
              className="layer-legend-bar"
              style={{ backgroundImage: gradientCss(stops), opacity: legend.opacity, borderColor: legend.border }}
              aria-hidden="true"
            />
            <span className="layer-legend-ticks" aria-hidden="true">
              {stops.map((item) => (
                <span key={item.label} style={{ left: `${(item.position as number) * 100}%` }}>
                  {item.label}
                </span>
              ))}
            </span>
          </li>
        )}
        {others.map(swatch)}
      </ul>
    );
  }

  return (
    <ul className={`layer-legend layer-legend-${legend.kind}`} aria-label={label}>
      {legend.items.map(swatch)}
    </ul>
  );
}
