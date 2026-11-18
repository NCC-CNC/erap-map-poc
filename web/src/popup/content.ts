import type { ChartView } from '../chart/view';
import {
  styleLayerIds,
  type Block,
  type ChartBlock,
  type Format,
  type FormatPreset,
  type LayerDefinition,
  type ListBlock,
  type NumberFormat,
  type PopupDefinition,
  type PopupLayout,
  type PopupSize,
  type TableBlock,
  type Template,
  type ValueSource,
} from '../layers';
import { numberLocale } from '../locale';

/**
 * Fills a layer's pop-up (`display.popup`, a small pop-up or a dialog;
 * ADR 0012) from a clicked feature's tile attributes. Both sizes are built
 * here and drawn by the same blocks (`./Sections.tsx`). Display only:
 * values are shown as the tiles hold them, in the configured formats;
 * nothing is calculated here (calculated fields come from the pipeline).
 * Anything the feature lacks is hidden rather than shown empty, as the
 * template is shared by every feature.
 */

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

/** What `formatValue` gives for a value the feature does not have. */
export const MISSING = 'Not available';

/** A missing value in a table cell. */
export const MISSING_CELL = 'n/a';

/** A labelled value ready to show. */
export interface StatContent {
  label: string;
  value: string;
}

/** A block ready to show. */
export type BlockContent =
  | { type: 'attributes'; items: StatContent[] }
  | {
      type: 'table';
      caption?: string;
      rowHeader?: string;
      columns: string[];
      rows: { label: string; cells: string[] }[];
    }
  | { type: 'chart'; chart: ChartView }
  | { type: 'text'; text: string }
  | { type: 'list'; items: string[]; empty: string };

/** A section ready to show: only the blocks the feature has values for. */
export interface SectionContent {
  /** Its position in the template, the same for every feature of the layer. */
  index: number;
  heading?: string;
  /** The label of its tab in a dialog: the section's `tab`, else its heading. */
  tab: string;
  description?: string;
  blocks: BlockContent[];
}

/** Everything a pop-up or dialog shows for one feature. */
export interface PopupContent {
  title: string;
  subtitle?: string;
  size: PopupSize;
  /** How a dialog shows its sections; `tabs` for a small pop-up. */
  layout: PopupLayout;
  sections: SectionContent[];
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

/**
 * The number format presets (schema `$defs/formatPreset`): `number` keeps
 * the value's decimals (up to 3), `integer` rounds to none, `percent`
 * shows a value already 0 to 100 with 1 decimal and `%`. Units go in a
 * format's `suffix`.
 */
export const FORMAT_PRESETS: Readonly<Record<FormatPreset, Readonly<NumberFormat>>> = {
  number: { grouping: true },
  integer: { decimals: 0, grouping: true },
  percent: { decimals: 1, grouping: true, suffix: '%' },
};

/** A format as a plain `NumberFormat`: its preset's settings (default `number`), then its own. */
export function resolveFormat(format: Format = 'number'): NumberFormat {
  if (typeof format === 'string') return { ...FORMAT_PRESETS[format] };
  const { preset = 'number', ...own } = format;
  return { ...FORMAT_PRESETS[preset], ...own };
}

/**
 * Formats a number in the map's locale with optional fixed decimals,
 * grouping and a unit: a unit follows after a space, except `%`, which
 * follows directly.
 */
export function formatNumber(value: number, format?: Format): string {
  const { decimals, grouping = true, suffix } = resolveFormat(format);
  const text = new Intl.NumberFormat(numberLocale(), {
    ...(decimals === undefined ? {} : { minimumFractionDigits: decimals, maximumFractionDigits: decimals }),
    useGrouping: grouping,
  }).format(value);
  if (!suffix) return text;
  return suffix === '%' ? `${text}%` : `${text} ${suffix}`;
}

/**
 * Formats a raw value for display. With a format, the value must be a
 * number (or numeric string); without one, numbers and text are shown as
 * they are. Anything else, including empty text, is `MISSING`.
 */
export function formatValue(raw: unknown, format?: Format): string {
  if (format) {
    const value = toNumber(raw);
    return value === null ? MISSING : formatNumber(value, format);
  }
  if (typeof raw === 'number') return Number.isFinite(raw) ? String(raw) : MISSING;
  if (typeof raw === 'boolean') return raw ? 'Yes' : 'No';
  if (typeof raw === 'string' && raw.trim() !== '') return raw;
  return MISSING;
}

const PLACEHOLDER = /\{([^{}:]*)(?::([^{}]*))?\}/g;

const raw = (name: string, feature: PopupFeature): unknown =>
  name === '$id' ? feature.id : feature.properties?.[name];

/** The attributes a template's placeholders read (`$id` for the feature id). */
export function placeholders(text: Template): string[] {
  return [...text.matchAll(PLACEHOLDER)].map((m) => m[1] as string);
}

/**
 * A template with each placeholder replaced by its value: as it is for
 * `{name}`, in the preset for `{name:preset}`. Null when any value is
 * missing, so the text is hidden rather than shown with a gap.
 */
export function fillTemplate(text: Template, feature: PopupFeature): string | null {
  let missing = false;
  const filled = text.replace(PLACEHOLDER, (_, name: string, preset?: string) => {
    const value = formatValue(raw(name, feature), preset as FormatPreset | undefined);
    if (value === MISSING) missing = true;
    return value;
  });
  return missing ? null : filled;
}

/**
 * Whether an attribute value counts as true for a list item's `when`:
 * true, a number other than 0, or text other than empty, `0`, `false` or
 * `no` (any case).
 */
export function isTrue(value: unknown): boolean {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return Number.isFinite(value) && value !== 0;
  if (typeof value === 'string') return !['', '0', 'false', 'no'].includes(value.trim().toLowerCase());
  return false;
}

const present = (value: unknown) => value !== undefined && value !== null;

function tableContent(block: TableBlock, feature: PopupFeature): BlockContent | null {
  const rows = block.rows
    .map((row) => {
      let any = false;
      const cells = row.values.map((attribute, i) => {
        if (attribute === null) return '';
        const value = formatValue(feature.properties?.[attribute], block.columns[i]?.format);
        if (value === MISSING) return MISSING_CELL;
        any = true;
        return value;
      });
      return any ? { label: row.label, cells } : null;
    })
    .filter((row) => row !== null);
  if (rows.length === 0) return null;
  return {
    type: 'table',
    ...(block.caption ? { caption: block.caption } : {}),
    ...(block.rowHeader ? { rowHeader: block.rowHeader } : {}),
    columns: block.columns.map((c) => c.label),
    rows,
  };
}

/** A chart's data and its text summary; null when it has no values. */
export function chartContent(block: ChartBlock, feature: PopupFeature): ChartView | null {
  const datasets = block.series.map((series) => ({
    label: series.label,
    values: series.attributes.map((a) => (a === null ? null : toNumber(feature.properties?.[a]))),
    ...(series.color ? { color: series.color } : {}),
  }));
  if (datasets.every((d) => d.values.every((v) => v === null))) return null;
  const listed = (values: (number | null)[]) =>
    block.categories.map((c, i) => `${c}: ${formatValue(values[i] ?? undefined, block.format ?? 'number')}`).join(', ');
  const summary =
    datasets.length === 1
      ? `${block.title}. ${block.valueLabel} for ${listed(datasets[0]!.values)}.`
      : `${block.title}. ${block.valueLabel}. ${datasets.map((d) => `${d.label}: ${listed(d.values)}`).join('; ')}.`;
  return {
    type: block.chart,
    title: block.title,
    labels: block.categories,
    datasets,
    ...(block.colors ? { colors: block.colors } : {}),
    ...(block.format ? { format: block.format } : {}),
    summary,
  };
}

function listContent(block: ListBlock, feature: PopupFeature): BlockContent | null {
  const read = block.items.flatMap((item) => [
    ...(item.when ? [item.when] : []),
    ...placeholders(item.text),
  ]);
  // None of the attributes in the tiles at all: nothing to say, not "none".
  if (!read.some((name) => present(raw(name, feature)))) return null;
  const items = block.items
    .filter((item) => !item.when || isTrue(feature.properties?.[item.when]))
    .map((item) => fillTemplate(item.text, feature))
    .filter((text) => text !== null);
  return { type: 'list', items, empty: block.empty };
}

/** A block ready to show, or null when the feature has nothing for it. */
export function blockContent(block: Block, feature: PopupFeature): BlockContent | null {
  switch (block.type) {
    case 'attributes': {
      const items = block.items
        .map((item) => ({ label: item.label, value: formatValue(readValue(item.value, feature), item.format) }))
        .filter((item) => item.value !== MISSING);
      return items.length ? { type: 'attributes', items } : null;
    }
    case 'table':
      return tableContent(block, feature);
    case 'chart': {
      const chart = chartContent(block, feature);
      return chart ? { type: 'chart', chart } : null;
    }
    case 'text': {
      const text = fillTemplate(block.text, feature);
      return text === null ? null : { type: 'text', text };
    }
    case 'list':
      return listContent(block, feature);
  }
}

/**
 * Builds what a pop-up or dialog shows for a clicked feature. A title
 * with a missing value falls back to `fallbackTitle` (the layer title); a
 * subtitle, description or text with one is hidden; a section with blocks
 * is hidden when none of them has anything to show, and one without
 * blocks when its description is hidden.
 */
export function buildPopupContent(
  popup: PopupDefinition,
  feature: PopupFeature,
  fallbackTitle: string,
): PopupContent {
  const subtitle = popup.subtitle ? fillTemplate(popup.subtitle, feature) : null;
  const sections = popup.sections.flatMap((section, index): SectionContent[] => {
    const description = section.description ? fillTemplate(section.description, feature) : null;
    const blocks = (section.blocks ?? [])
      .map((block) => blockContent(block, feature))
      .filter((block) => block !== null);
    const shown = section.blocks ? blocks.length > 0 : description !== null;
    if (!shown) return [];
    return [
      {
        index,
        ...(section.heading ? { heading: section.heading } : {}),
        tab: section.tab ?? section.heading ?? '',
        ...(description !== null ? { description } : {}),
        blocks,
      },
    ];
  });
  return {
    title: fillTemplate(popup.title, feature) ?? fallbackTitle,
    ...(subtitle !== null ? { subtitle } : {}),
    size: popup.size ?? 'small',
    layout: popup.layout ?? 'tabs',
    sections,
  };
}

/**
 * The section whose tab is selected, by its template `index`: `wanted`
 * when this feature shows that section, else the first shown; undefined
 * with none. Keeps the reader's tab from one feature of a layer to the next.
 */
export function selectedSection(content: PopupContent, wanted: number | undefined): number | undefined {
  const shown = content.sections.find((s) => s.index === wanted) ?? content.sections[0];
  return shown?.index;
}

/**
 * Maps each style layer id to its layer definition, for the layers that
 * have a pop-up (ADR 0012). These are the layers that respond to clicks.
 */
export function clickableLayers(defs: readonly LayerDefinition[]): Map<string, LayerDefinition> {
  const result = new Map<string, LayerDefinition>();
  for (const def of defs) {
    if (!def.popup) continue;
    for (const id of styleLayerIds(def)) result.set(id, def);
  }
  return result;
}
