import type { ChartConfiguration, TooltipItem } from 'chart.js';
import type { Format } from '../layers';
import { formatNumber } from '../popup/content';

/**
 * A chart ready to draw from one clicked feature: bar or line charts with
 * one or more series (several make a grouped bar chart with a legend),
 * and pie or doughnut charts of one series. Missing values are `null`.
 */
export interface ChartView {
  type: 'bar' | 'line' | 'pie' | 'doughnut';
  /** Heading above the chart. */
  title: string;
  /** The categories: the x axis, or the slices. */
  labels: string[];
  datasets: { label: string; values: (number | null)[]; color?: string }[];
  /** Slice colours of a pie or doughnut, one per label. */
  colors?: string[];
  /** Number format of the values in tooltips. */
  format?: Format;
  /** Plain text version of the chart, for screen readers. */
  summary: string;
}

/**
 * Default series and slice colours: the Okabe-Ito palette, which stays
 * distinguishable with the common colour vision deficiencies. Order: blue,
 * orange, bluish green, reddish purple, sky blue, vermillion, yellow, grey.
 */
export const PALETTE: readonly string[] = [
  '#0072b2',
  '#e69f00',
  '#009e73',
  '#cc79a7',
  '#56b4e9',
  '#d55e00',
  '#f0e442',
  '#999999',
];

const colorAt = (i: number) => PALETTE[i % PALETTE.length] as string;

/** Whether the chart shows slices (pie or doughnut) rather than axes. */
export const isRound = (view: ChartView) => view.type === 'pie' || view.type === 'doughnut';

/**
 * The Chart.js configuration for a view: no animation, a series legend
 * only when there is more than one series (or slices), axes from zero for
 * bars and lines, and tooltips in the view's number format.
 */
export function chartConfig(view: ChartView): ChartConfiguration {
  const round = isRound(view);
  const datasets = view.datasets.map((dataset, i) => {
    const color = dataset.color ?? colorAt(i);
    if (round) {
      return {
        label: dataset.label,
        data: dataset.values,
        backgroundColor: view.labels.map((_, j) => view.colors?.[j] ?? colorAt(j)),
        borderColor: '#ffffff',
        borderWidth: 1,
      };
    }
    return { label: dataset.label, data: dataset.values, backgroundColor: color, borderColor: color };
  });
  const format = (value: number) => (view.format ? formatNumber(value, view.format) : String(value));
  return {
    type: view.type,
    data: { labels: view.labels, datasets },
    options: {
      animation: false,
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: round || view.datasets.length > 1, position: 'bottom' },
        tooltip: {
          callbacks: {
            label: (item: TooltipItem<'bar' | 'line' | 'pie' | 'doughnut'>) => {
              const value = typeof item.raw === 'number' ? format(item.raw) : String(item.raw);
              const name = round ? item.label : item.dataset.label;
              return name ? `${name}: ${value}` : value;
            },
          },
        },
      },
      ...(round ? {} : { scales: { y: { beginAtZero: true } } }),
    },
  } as ChartConfiguration;
}
