import type { PopupContent } from './content';
import { PopupChart } from './PopupChart';

/** The pop-up body for one clicked feature: heading, stats and charts. */
export function FeaturePopup({ content }: { content: PopupContent }) {
  return (
    <div className="feature-popup">
      <h2>{content.title}</h2>
      {content.stats.length > 0 && (
        <dl>
          {content.stats.map((stat) => (
            <div key={stat.label}>
              <dt>{stat.label}</dt>
              <dd>{stat.value}</dd>
            </div>
          ))}
        </dl>
      )}
      {content.charts.map((chart) => (
        <PopupChart key={chart.title} chart={chart} />
      ))}
    </div>
  );
}
