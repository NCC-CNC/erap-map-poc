import {
  styleLayerIds,
  type LayerDefinition,
  type NumberFormat,
  type PopupChart,
  type PopupDefinition,
  type ValueSource,
} from '../layers';

/**
 * The parts of a clicked feature that pop-ups read. A MapLibre feature
 * fits this shape, so this module needs no MapLibre import and is easy to
 * test.
 */
export interface PopupFeature {
  /** The vector tile feature id, if the tiles have one. */
  id?: string | number;
  properties: Record<string, unknown> | null | undefined;
}

/** Shown in place of a value the feature does not have. */
export const MISSING = 'Not available';

/** Fixed locale, so numbers look the same for every viewer and in tests. */
const LOCALE = 'en-CA';

/** A stat ready to show: the label and the formatted value. */
export interface StatContent {
  label: string;
  value: string;
}

/** A chart ready to draw, with missing values as `null` (a gap). */
export interface ChartContent {
  type: PopupChart['type'];
  title: string;
  labels: string[];
  values: (number | null)[];
  /** Plain text version of the chart, for screen readers. */
  summary: string;
}

/** Everything the pop-up component shows for one feature. */
export interface PopupContent {
  title: string;
  stats: StatContent[];
  charts: ChartContent[];
}

/** Reads a value from the feature; `undefined` when it is not there. */
export function readValue(source: ValueSource, feature: PopupFeature): unknown {
  if ('featureId' in source) return feature.id;
  return feature.properties?.[source.attribute];
}

/** A finite number from a number or numeric string, otherwise `null`. */
export function toNumber(raw: unknown): number | null {
  if (typeof raw === 'number') return Number.isFinite(raw) ? raw : null;
  if (typeof raw === 'string' && raw.trim() !== '') {
    const parsed = Number(raw);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

/** Formats a number with fixed decimals, optional grouping and a unit. */
export function formatNumber(value: number, format: NumberFormat = {}): string {
  const { decimals = 0, grouping = true, suffix } = format;
  const text = new Intl.NumberFormat(LOCALE, {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
    useGrouping: grouping,
  }).format(value);
  return suffix ? `${text} ${suffix}` : text;
}

/**
 * Formats a raw value for display. With a format, the value must be a
 * number (or numeric string); without one, numbers and text are shown as
 * they are. Anything else, including empty text, shows as `MISSING`.
 */
export function formatValue(raw: unknown, format?: NumberFormat): string {
  if (format) {
    const value = toNumber(raw);
    return value === null ? MISSING : formatNumber(value, format);
  }
  if (typeof raw === 'number') return Number.isFinite(raw) ? String(raw) : MISSING;
  if (typeof raw === 'boolean') return raw ? 'Yes' : 'No';
  if (typeof raw === 'string' && raw.trim() !== '') return raw;
  return MISSING;
}

/** Builds a chart's data; `null` when the feature has none of its values. */
export function buildChart(chart: PopupChart, feature: PopupFeature): ChartContent | null {
  const labels = chart.points.map((point) => point.label);
  const values = chart.points.map((point) =>
    toNumber(readValue({ attribute: point.attribute }, feature)),
  );
  if (values.every((value) => value === null)) return null;
  const parts = labels.map(
    (label, i) => `${label}: ${formatValue(values[i] ?? undefined, { decimals: 0 })}`,
  );
  return {
    type: chart.type,
    title: chart.title,
    labels,
    values,
    summary: `${chart.title}. ${chart.valueLabel} for ${parts.join(', ')}.`,
  };
}

/**
 * Builds the pop-up content for a clicked feature from the layer's pop-up
 * definition. Missing attributes never throw: stats show `MISSING`, a
 * chart with no values is left out, and a missing title falls back to
 * `fallbackTitle`.
 */
export function buildPopupContent(
  popup: PopupDefinition,
  feature: PopupFeature,
  fallbackTitle: string,
): PopupContent {
  const title = formatValue(readValue(popup.title, feature));
  return {
    title: title === MISSING ? fallbackTitle : title,
    stats: popup.stats.map((stat) => ({
      label: stat.label,
      value: formatValue(readValue(stat.value, feature), stat.format),
    })),
    charts: (popup.charts ?? [])
      .map((chart) => buildChart(chart, feature))
      .filter((chart): chart is ChartContent => chart !== null),
  };
}

/**
 * Maps each style layer id to its layer definition, for the layers that
 * have a pop-up. These are the layers that respond to clicks.
 */
export function clickableLayers(
  defs: readonly LayerDefinition[],
): Map<string, LayerDefinition & { popup: PopupDefinition }> {
  const result = new Map<string, LayerDefinition & { popup: PopupDefinition }>();
  for (const def of defs) {
    const { popup } = def;
    if (!popup) continue;
    for (const id of styleLayerIds(def.id, def.symbology)) result.set(id, { ...def, popup });
  }
  return result;
}
