import type { ChartView } from '../chart/view';
import type {
  ChartBlock,
  FormatPreset,
  ListBlock,
  ModalBlock,
  ModalDefinition,
  TableBlock,
  Template,
} from '../layers';
import {
  MISSING,
  formatValue,
  readValue,
  toNumber,
  type PopupFeature,
  type StatContent,
} from '../popup/content';

/**
 * Fills a layer's modal template (ADR 0012) from a clicked feature's tile
 * attributes. Display only: values are shown as the tiles hold them, in
 * the configured formats; nothing is calculated here (calculated fields
 * come from the pipeline). Anything the feature lacks is hidden rather
 * than shown empty, as the template is shared by every feature.
 */

/** A missing value in a table cell. */
export const MISSING_CELL = 'n/a';

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
  heading: string;
  description?: string;
  blocks: BlockContent[];
}

/** Everything the modal shows for one feature. */
export interface ModalContent {
  title: string;
  subtitle?: string;
  sections: SectionContent[];
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
    block.categories.map((c, i) => `${c}: ${formatValue(values[i] ?? undefined, block.format ?? {})}`).join(', ');
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
export function blockContent(block: ModalBlock, feature: PopupFeature): BlockContent | null {
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
 * Builds the modal content for a clicked feature. A title with a missing
 * value falls back to `fallbackTitle` (the layer title); a subtitle,
 * description or text with one is hidden; a section with blocks is hidden
 * when none of them has anything to show, and one without blocks when its
 * description is hidden.
 */
export function buildModalContent(
  modal: ModalDefinition,
  feature: PopupFeature,
  fallbackTitle: string,
): ModalContent {
  const subtitle = modal.subtitle ? fillTemplate(modal.subtitle, feature) : null;
  const sections = modal.sections.flatMap((section): SectionContent[] => {
    const description = section.description ? fillTemplate(section.description, feature) : null;
    const blocks = (section.blocks ?? [])
      .map((block) => blockContent(block, feature))
      .filter((block) => block !== null);
    const shown = section.blocks ? blocks.length > 0 : description !== null;
    if (!shown) return [];
    return [{ heading: section.heading, ...(description !== null ? { description } : {}), blocks }];
  });
  return {
    title: fillTemplate(modal.title, feature) ?? fallbackTitle,
    ...(subtitle !== null ? { subtitle } : {}),
    sections,
  };
}
