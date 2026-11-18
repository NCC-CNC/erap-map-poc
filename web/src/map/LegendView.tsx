import type { CSSProperties } from 'react';
import type { Legend, LegendItem } from '../layers';
import { BASEMAP_GROUND } from './basemap';
import { gradientCss, swatchColor } from './legend';

/**
 * A layer's inline legend (derived from its colour expression, or given
 * in its layer file, see `../layers/legend.ts`): one swatch and label
 * per item, or, for a `gradient` legend, a colour bar with the stop values
 * under it, then any items without a position (such as no data) as
 * swatches. A swatch shows its colour at the layer's opacity over `ground`
 * (the basemap's land colour), as the map draws it, not over the panel.
 */
export function LegendView({
  legend,
  label,
  ground = BASEMAP_GROUND.light,
}: {
  legend: Legend;
  label: string;
  ground?: string;
}) {
  const swatch = (item: LegendItem) => {
    const style: CSSProperties = {
      backgroundColor: swatchColor(item.color, legend.opacity, ground),
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
              style={{ backgroundImage: gradientCss(stops, legend.opacity, ground), borderColor: legend.border }}
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
