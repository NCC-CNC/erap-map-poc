import { useEffect, useRef } from 'react';
import { chartConfig, isRound, type ChartView } from './view';

/**
 * A small Chart.js chart with a heading. Chart.js is loaded on first use.
 * The chart is created on mount and destroyed on unmount (when the pop-up
 * or modal closes), so no instance leaks. The canvas carries the text
 * summary for screen readers, so the chart reads the same while loading.
 */
export function FeatureChart({ view }: { view: ChartView }) {
  const canvas = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    let instance: { destroy: () => void } | undefined;
    let cancelled = false;
    void import('./register').then(({ Chart }) => {
      if (cancelled || !canvas.current) return;
      instance = new Chart(canvas.current, chartConfig(view));
    });
    return () => {
      cancelled = true;
      instance?.destroy();
    };
  }, [view]);

  return (
    <figure className="feature-chart">
      <figcaption>{view.title}</figcaption>
      <div
        className={`feature-chart-canvas${isRound(view) ? ' feature-chart-round' : ''}${
          view.datasets.length > 1 ? ' feature-chart-legend' : ''
        }`}
      >
        <canvas ref={canvas} role="img" aria-label={view.summary}>
          {view.summary}
        </canvas>
      </div>
    </figure>
  );
}
