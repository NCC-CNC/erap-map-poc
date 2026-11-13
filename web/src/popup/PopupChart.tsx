import { useMemo } from 'react';
import { FeatureChart } from '../chart/FeatureChart';
import type { ChartContent } from './content';

const COLOR = '#2a9d8f';

/** A pop-up chart: one series, no legend, drawn by `FeatureChart`. */
export function PopupChart({ chart }: { chart: ChartContent }) {
  const view = useMemo(
    () => ({
      type: chart.type,
      title: chart.title,
      labels: chart.labels,
      datasets: [{ label: chart.title, values: chart.values, color: COLOR }],
      summary: chart.summary,
    }),
    [chart],
  );
  return <FeatureChart view={view} />;
}
