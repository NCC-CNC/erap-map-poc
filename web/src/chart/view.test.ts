import { describe, expect, it } from 'vitest';
import { PALETTE, chartConfig, type ChartView } from './view';

const grouped: ChartView = {
  type: 'bar',
  title: 'Habitats',
  labels: ['Forest', 'Wetland'],
  datasets: [
    { label: 'Cover', values: [40.25, 10] },
    { label: 'Protected', values: [12.5, null], color: '#123456' },
  ],
  format: 'percent',
  summary: 'Habitats.',
};

const pie: ChartView = {
  type: 'pie',
  title: 'Land',
  labels: ['Intact', 'Modified'],
  datasets: [{ label: 'Share', values: [70, 30] }],
  colors: ['#00aa00'],
  summary: 'Land.',
};

type Options = {
  plugins: {
    legend: { display: boolean };
    tooltip: { callbacks: { label: (item: unknown) => string } };
  };
  scales?: unknown;
};

const options = (view: ChartView) => chartConfig(view).options as unknown as Options;

describe('chartConfig', () => {
  it('a grouped bar chart: one dataset per series, palette or own colour, a legend, axes from zero', () => {
    const config = chartConfig(grouped);
    expect(config.type).toBe('bar');
    expect(config.data.labels).toEqual(['Forest', 'Wetland']);
    expect(config.data.datasets.map((d) => [d.label, d.data, d.backgroundColor])).toEqual([
      ['Cover', [40.25, 10], PALETTE[0]],
      ['Protected', [12.5, null], '#123456'],
    ]);
    expect(options(grouped).plugins.legend.display).toBe(true);
    expect(options(grouped).scales).toEqual({ y: { beginAtZero: true } });
  });

  it('a single series bar chart has no legend', () => {
    const single = { ...grouped, datasets: [grouped.datasets[0]!] };
    expect(options(single).plugins.legend.display).toBe(false);
  });

  it('formats tooltip values with the series name, or the slice name for a pie', () => {
    const label = options(grouped).plugins.tooltip.callbacks.label;
    expect(label({ raw: 40.25, label: 'Forest', dataset: { label: 'Cover' } })).toBe('Cover: 40.3%');
    const pieLabel = options(pie).plugins.tooltip.callbacks.label;
    expect(pieLabel({ raw: 70, label: 'Intact', dataset: { label: 'Share' } })).toBe('Intact: 70');
  });

  it('a pie colours each slice, its own colours first, with a legend and no axes', () => {
    const config = chartConfig(pie);
    expect(config.data.datasets[0]?.backgroundColor).toEqual(['#00aa00', PALETTE[1]]);
    expect(options(pie).plugins.legend.display).toBe(true);
    expect(options(pie).scales).toBeUndefined();
  });
});
