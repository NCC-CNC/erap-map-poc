import type { CSSProperties } from 'react';
import type { Legend } from '../layers';

/**
 * A layer's inline legend: one swatch and label per item, from the legend
 * the pipeline resolved for the layer (derived from its style, or given
 * explicitly in its display config).
 */
export function LegendView({ legend, label }: { legend: Legend; label: string }) {
  return (
    <ul className={`layer-legend layer-legend-${legend.kind}`} aria-label={label}>
      {legend.items.map((item) => {
        const style: CSSProperties = {
          backgroundColor: item.color,
          opacity: legend.opacity,
          borderColor: legend.border,
        };
        return (
          <li key={item.label}>
            <span
              className={`layer-legend-swatch layer-legend-${legend.shape}`}
              style={style}
              aria-hidden="true"
            />
            {item.label}
          </li>
        );
      })}
    </ul>
  );
}
