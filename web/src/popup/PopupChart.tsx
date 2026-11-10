import { useEffect, useRef } from 'react';
import {
  BarController,
  BarElement,
  CategoryScale,
  Chart,
  LinearScale,
  LineController,
  LineElement,
  PointElement,
  Tooltip,
} from 'chart.js';
import type { ChartContent } from './content';

// Only what pop-up charts use (ADR 0003): bar and line charts on a category
// x axis and a linear y axis, with tooltips. No legend, as each chart has
// one series and a heading.
Chart.register(
  BarController,
  BarElement,
  LineController,
  LineElement,
  PointElement,
  CategoryScale,
  LinearScale,
  Tooltip,
);

const COLOR = '#2a9d8f';

/**
 * A small Chart.js chart. The chart is created on mount and destroyed on
 * unmount (which happens when the pop-up closes), so no instance leaks.
 */
export function PopupChart({ chart }: { chart: ChartContent }) {
  const canvas = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    if (!canvas.current) return;
    const instance = new Chart(canvas.current, {
      type: chart.type,
      data: {
        labels: chart.labels,
        datasets: [
          {
            label: chart.title,
            data: chart.values,
            backgroundColor: COLOR,
            borderColor: COLOR,
          },
        ],
      },
      options: {
        animation: false,
        responsive: true,
        maintainAspectRatio: false,
        scales: { y: { beginAtZero: true } },
      },
    });
    return () => instance.destroy();
  }, [chart]);

  return (
    <figure className="feature-popup-chart">
      <figcaption>{chart.title}</figcaption>
      <div className="feature-popup-chart-canvas">
        <canvas ref={canvas} role="img" aria-label={chart.summary}>
          {chart.summary}
        </canvas>
      </div>
    </figure>
  );
}
