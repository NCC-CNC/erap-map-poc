import { describe, expect, it } from 'vitest';
import type { ChartBlock, LayerDefinition, PopupDefinition } from '../layers';
import { ecoregionsExample, raster, sample, sampleModal, samplePoints } from '../test/fixtures';
import {
  MISSING,
  MISSING_CELL,
  buildPopupContent,
  chartContent,
  clickableLayers,
  fillTemplate,
  formatNumber,
  formatValue,
  isTrue,
  placeholders,
  readValue,
  resolveFormat,
  selectedSection,
  toNumber,
} from './content';

const cedar = {
  id: 7,
  properties: {
    name: 'Cedar',
    area_ha: 12345.67,
    score: 57,
    v2020: 120,
    v2021: 180,
    v2022: 240,
    v2023: 300,
    v2024: 360,
  },
};

describe('readValue', () => {
  it('reads the feature id, not a property', () => {
    expect(readValue({ featureId: true }, { id: 3, properties: { id: 99 } })).toBe(3);
  });

  it('reads attributes and copes with no properties', () => {
    expect(readValue({ attribute: 'name' }, cedar)).toBe('Cedar');
    expect(readValue({ attribute: 'name' }, { properties: null })).toBeUndefined();
  });
});

describe('toNumber', () => {
  it('accepts finite numbers and numeric strings only', () => {
    expect(toNumber(4)).toBe(4);
    expect(toNumber('4.5')).toBe(4.5);
    expect(toNumber('')).toBeNull();
    expect(toNumber('abc')).toBeNull();
    expect(toNumber(Number.NaN)).toBeNull();
    expect(toNumber(null)).toBeNull();
    expect(toNumber(undefined)).toBeNull();
  });
});

describe('formatNumber', () => {
  it('adds thousands separators, fixed decimals and a unit', () => {
    expect(formatNumber(12345.67, { decimals: 1, suffix: 'ha' })).toBe('12,345.7 ha');
    expect(formatNumber(4000, { decimals: 1, suffix: 'ha' })).toBe('4,000.0 ha');
    expect(formatNumber(57, { suffix: '/ 100' })).toBe('57 / 100');
  });

  it('can turn grouping off', () => {
    expect(formatNumber(12345, { grouping: false })).toBe('12345');
  });
});

describe('number format presets', () => {
  it('number keeps the decimals (up to 3), integer rounds, percent has 1 decimal and %', () => {
    expect(formatNumber(12345.6, 'number')).toBe('12,345.6');
    expect(formatNumber(12345, 'number')).toBe('12,345');
    expect(formatNumber(1.23456, 'number')).toBe('1.235');
    expect(formatNumber(12345.6, 'integer')).toBe('12,346');
    expect(formatNumber(12.345, 'percent')).toBe('12.3%');
    // Without a format, a number is in the number preset.
    expect(formatNumber(12345.6)).toBe('12,345.6');
  });

  it('lets an object change a preset, and units go in suffix', () => {
    expect(formatNumber(12.345, { preset: 'percent', decimals: 2 })).toBe('12.35%');
    expect(formatNumber(1234567.8, { preset: 'integer', suffix: 'ha' })).toBe('1,234,568 ha');
    expect(formatNumber(1234.56, { decimals: 1, suffix: 'km' })).toBe('1,234.6 km');
    expect(formatNumber(1234, { preset: 'integer', grouping: false, suffix: 'ha' })).toBe('1234 ha');
    expect(resolveFormat({ preset: 'integer', suffix: 'hectares' })).toEqual({
      decimals: 0,
      grouping: true,
      suffix: 'hectares',
    });
    expect(resolveFormat({})).toEqual({ grouping: true });
    expect(resolveFormat()).toEqual({ grouping: true });
  });

  it('puts % straight after the number, other units after a space', () => {
    expect(formatNumber(5, { suffix: '%' })).toBe('5%');
    expect(formatValue('7.25', 'percent')).toBe('7.3%');
    expect(formatValue(undefined, 'percent')).toBe(MISSING);
  });
});

describe('formatValue', () => {
  it('shows text and unformatted numbers as they are', () => {
    expect(formatValue('Cedar')).toBe('Cedar');
    expect(formatValue(12345)).toBe('12345');
    expect(formatValue(true)).toBe('Yes');
  });

  it('gives missing or unusable values as not available', () => {
    for (const raw of [undefined, null, '', '  ', Number.NaN, {}]) {
      expect(formatValue(raw)).toBe(MISSING);
    }
    expect(formatValue('abc', { decimals: 1 })).toBe(MISSING);
    expect(formatValue(undefined, { suffix: 'ha' })).toBe(MISSING);
  });
});

describe('a small pop-up: the sample layer', () => {
  const popup = sample.popup!;

  it('is one section of attributes and a bar chart, from attributes and feature.id', () => {
    expect(buildPopupContent(popup, cedar, sample.title)).toEqual({
      title: 'Cedar',
      size: 'small',
      layout: 'tabs',
      sections: [
        {
          index: 0,
          tab: '',
          blocks: [
            {
              type: 'attributes',
              items: [
                { label: 'ID', value: '7' },
                { label: 'Area', value: '12,345.7 ha' },
                { label: 'Score', value: '57 / 100' },
              ],
            },
            {
              type: 'chart',
              chart: {
                type: 'bar',
                title: 'Value by year',
                labels: ['2020', '2021', '2022', '2023', '2024'],
                datasets: [{ label: 'Value', values: [120, 180, 240, 300, 360], color: '#2a9d8f' }],
                format: 'integer',
                summary: 'Value by year. Value for 2020: 120, 2021: 180, 2022: 240, 2023: 300, 2024: 360.',
              },
            },
          ],
        },
      ],
    });
  });

  it('hides missing values and falls back to the layer title', () => {
    const content = buildPopupContent(popup, { id: 2, properties: { v2021: 5 } }, sample.title);
    expect(content.title).toBe('Sample polygons');
    const [attributes, chart] = content.sections[0]!.blocks;
    expect(attributes).toEqual({ type: 'attributes', items: [{ label: 'ID', value: '2' }] });
    expect(chart?.type === 'chart' && chart.chart.datasets[0]?.values).toEqual([null, 5, null, null, null]);
    expect(buildPopupContent(popup, { properties: {} }, sample.title).sections).toEqual([]);
  });

  it('takes a line chart, a heading and a subtitle, as a dialog does', () => {
    const bar = popup.sections[0]!.blocks![1] as ChartBlock;
    const lined: PopupDefinition = {
      ...popup,
      subtitle: 'Score {score}',
      sections: [{ heading: 'Values', blocks: [{ ...bar, chart: 'line' }] }],
    };
    const content = buildPopupContent(lined, cedar, sample.title);
    expect(content.subtitle).toBe('Score 57');
    expect(content.sections[0]?.heading).toBe('Values');
    const block = content.sections[0]?.blocks[0];
    expect(block?.type === 'chart' && block.chart.type).toBe('line');
  });
});

describe('clickableLayers', () => {
  it('maps every style layer of a layer with a pop-up of either size, and skips the rest', () => {
    const noPopup: LayerDefinition = { ...sample, id: 'plain', popup: undefined };
    const targets = clickableLayers([sample, noPopup, samplePoints]);
    expect([...targets.keys()]).toEqual(['sample-fill', 'sample-outline', 'sample_points-circle']);
    expect(targets.get('sample-fill')?.popup).toBe(sample.popup);
    expect(targets.get('sample_points-circle')?.popup).toBe(samplePoints.popup);
    expect(clickableLayers([sampleModal]).get('sample-fill')?.popup?.size).toBe('dialog');
  });

  it('never makes a raster layer clickable (display only)', () => {
    expect([...clickableLayers([raster, sample]).keys()]).toEqual(['sample-fill', 'sample-outline']);
  });
});

describe('chartContent', () => {
  it('summarises the values in the chart format, with gaps for missing ones', () => {
    const block: ChartBlock = {
      type: 'chart',
      chart: 'line',
      title: 'Cover',
      valueLabel: 'Percent',
      format: 'percent',
      categories: ['A', 'B'],
      series: [{ label: 'Cover', attributes: ['a', 'b'] }],
    };
    const chart = chartContent(block, { properties: { a: 12.34, b: 'x' } });
    expect(chart?.summary).toBe(`Cover. Percent for A: 12.3%, B: ${MISSING}.`);
    expect(chart?.datasets[0]?.values).toEqual([12.34, null]);
    expect(chartContent(block, { properties: {} })).toBeNull();
  });
});

const modal = sampleModal.popup as PopupDefinition;

describe('fillTemplate', () => {
  it('fills attributes as they are, in a preset, and the feature id', () => {
    expect(fillTemplate('{name} ({$id}): {area_ha:integer} ha, {score:percent}', cedar)).toBe(
      'Cedar (7): 12,346 ha, 57.0%',
    );
    expect(placeholders('{name} and {area_ha:integer} ha and {$id}')).toEqual(['name', 'area_ha', '$id']);
  });

  it('is null when any value is missing, so the text is hidden', () => {
    expect(fillTemplate('{name} in {region}', cedar)).toBeNull();
    expect(fillTemplate('{name}', { properties: { name: '' } })).toBeNull();
    expect(fillTemplate('No placeholders', { properties: {} })).toBe('No placeholders');
  });
});

describe('isTrue', () => {
  it('reads flags as tiles hold them', () => {
    for (const yes of [true, 1, -2, 'yes', 'true', 'Recommended']) expect(isTrue(yes)).toBe(true);
    for (const no of [false, 0, Number.NaN, '', ' 0 ', 'false', 'No', null, undefined]) expect(isTrue(no)).toBe(false);
  });
});

describe('a dialog: the sample dialog pop-up', () => {
  it('fills every section from the feature', () => {
    expect(buildPopupContent(modal, cedar, sampleModal.title)).toEqual({
      title: 'Cedar',
      subtitle: 'Sample feature 7',
      size: 'dialog',
      layout: 'tabs',
      sections: [
        {
          index: 0,
          heading: 'Summary of the feature',
          tab: 'Summary',
          description: 'A made-up feature of 12,346 ha.',
          blocks: [
            {
              type: 'attributes',
              items: [
                { label: 'ID', value: '7' },
                { label: 'Area', value: '12,346 ha' },
                { label: 'Score', value: '57 / 100' },
              ],
            },
          ],
        },
        {
          index: 1,
          heading: 'Values',
          tab: 'Values',
          blocks: [
            {
              type: 'table',
              caption: 'Values by year',
              rowHeader: 'Year',
              columns: ['Value', 'Score'],
              rows: [
                { label: '2020', cells: ['120', '57.0%'] },
                { label: '2021', cells: ['180', ''] },
                { label: '2022', cells: ['240', ''] },
              ],
            },
            {
              type: 'chart',
              chart: {
                type: 'bar',
                title: 'Values, early and late',
                labels: ['First', 'Second'],
                datasets: [
                  { label: 'Early', values: [120, 180] },
                  { label: 'Late', values: [300, 360] },
                ],
                format: 'integer',
                summary:
                  'Values, early and late. Value. Early: First: 120, Second: 180; Late: First: 300, Second: 360.',
              },
            },
            {
              type: 'chart',
              chart: {
                type: 'pie',
                title: 'Share by year',
                labels: ['2020', '2024'],
                datasets: [{ label: 'Value', values: [120, 360] }],
                summary: 'Share by year. Value for 2020: 120, 2024: 360.',
              },
            },
            {
              type: 'chart',
              chart: {
                type: 'line',
                title: 'Value by year',
                labels: ['2020', '2021', '2022', '2023', '2024'],
                datasets: [{ label: 'Value', values: [120, 180, 240, 300, 360] }],
                format: 'integer',
                summary: 'Value by year. Value for 2020: 120, 2021: 180, 2022: 240, 2023: 300, 2024: 360.',
              },
            },
          ],
        },
        {
          index: 2,
          heading: 'Notes',
          tab: 'Notes',
          blocks: [
            { type: 'text', text: 'Scored 57 out of 100.' },
            { type: 'list', items: ['Has a score of 57'], empty: 'Nothing to list.' },
          ],
        },
      ],
    });
  });

  it('hides what the feature has no values for, down to whole sections', () => {
    const content = buildPopupContent(modal, { properties: { name: 'Bare' } }, sampleModal.title);
    expect(content).toEqual({ title: 'Bare', size: 'dialog', layout: 'tabs', sections: [] });
  });

  it('falls back to the layer title, and shows n/a for a missing cell in a row with values', () => {
    const content = buildPopupContent(modal, { id: 3, properties: { v2021: 5 } }, sampleModal.title);
    expect(content.title).toBe('Sample polygons');
    expect(content.subtitle).toBe('Sample feature 3');
    const table = content.sections.find((s) => s.heading === 'Values')?.blocks[0];
    expect(table).toEqual({
      type: 'table',
      caption: 'Values by year',
      rowHeader: 'Year',
      columns: ['Value', 'Score'],
      rows: [{ label: '2021', cells: ['5', ''] }],
    });
    const summary = content.sections.find((s) => s.tab === 'Summary');
    expect(summary?.blocks).toEqual([{ type: 'attributes', items: [{ label: 'ID', value: '3' }] }]);
    expect(summary?.description).toBeUndefined();

    const partial = buildPopupContent(modal, { properties: { v2020: 1, score: 9 } }, 'x');
    const row = partial.sections.find((s) => s.heading === 'Values')?.blocks[0];
    expect(row && row.type === 'table' && row.rows[0]).toEqual({ label: '2020', cells: ['1', '9.0%'] });
    const missing = buildPopupContent(modal, { properties: { v2021: 1, v2020: 'n' } }, 'x');
    const cells = missing.sections.find((s) => s.heading === 'Values')?.blocks[0];
    expect(cells && cells.type === 'table' && cells.rows).toEqual([{ label: '2021', cells: ['1', ''] }]);
    expect(MISSING_CELL).toBe('n/a');
  });

  it('a chart keeps gaps for missing values and is hidden with none', () => {
    const content = buildPopupContent(modal, { properties: { v2020: 10 } }, 'x');
    const charts = content.sections.find((s) => s.heading === 'Values')?.blocks.filter((b) => b.type === 'chart');
    expect(charts?.map((c) => c.type === 'chart' && c.chart.datasets)).toEqual([
      [
        { label: 'Early', values: [10, null] },
        { label: 'Late', values: [null, null] },
      ],
      [{ label: 'Value', values: [10, null] }],
      [{ label: 'Value', values: [10, null, null, null, null] }],
    ]);
  });

  it('a list shows its empty message when nothing applies, and is hidden without the attributes', () => {
    const notes = (properties: Record<string, unknown>) =>
      buildPopupContent(modal, { properties }, 'x').sections.find((s) => s.heading === 'Notes');
    expect(notes({ score: 0 })?.blocks).toEqual([
      { type: 'text', text: 'Scored 0 out of 100.' },
      { type: 'list', items: [], empty: 'Nothing to list.' },
    ]);
    expect(notes({ flag: 'yes', flag_reason: 'too low' })?.blocks).toEqual([
      { type: 'list', items: ['Flagged: too low'], empty: 'Nothing to list.' },
    ]);
    // A flag set but its text missing: the item is left out.
    expect(notes({ flag: 1 })?.blocks).toEqual([{ type: 'list', items: [], empty: 'Nothing to list.' }]);
    expect(notes({})).toBeUndefined();
  });
});

describe('tabs', () => {
  // Has a Summary (its id) and Notes (a flag), not Values.
  const elm = { id: 4, properties: { name: 'Elm', flag: 1, flag_reason: 'too low' } };

  it('label each shown section with its tab, else its heading, and keep its template index', () => {
    const content = buildPopupContent(modal, elm, 'x');
    expect(content.sections.map((s) => [s.index, s.tab, s.heading])).toEqual([
      [0, 'Summary', 'Summary of the feature'],
      [2, 'Notes', 'Notes'],
    ]);
  });

  it('are the default layout; scroll is kept as given', () => {
    expect(buildPopupContent(modal, cedar, 'x').layout).toBe('tabs');
    expect(buildPopupContent({ ...modal, layout: 'scroll' }, cedar, 'x').layout).toBe('scroll');
  });

  it('keep the selected section when the feature has it, else select the first shown', () => {
    const all = buildPopupContent(modal, cedar, 'x');
    const some = buildPopupContent(modal, elm, 'x');
    expect(selectedSection(all, 1)).toBe(1);
    expect(selectedSection(all, undefined)).toBe(0);
    expect(selectedSection(some, 2)).toBe(2);
    // Values (1) is hidden for this feature, and 9 is no section.
    expect(selectedSection(some, 1)).toBe(0);
    expect(selectedSection(some, 9)).toBe(0);
    expect(selectedSection(buildPopupContent(modal, { properties: {} }, 'x'), 1)).toBeUndefined();
  });
});

describe('the ecoregion dialog with calculated fields', () => {
  const example = ecoregionsExample.popup;
  const section = (properties: Record<string, unknown>, heading: string) =>
    buildPopupContent(example, { properties }, 'Ecoregions').sections.find((s) => s.heading === heading);
  const reason = 'Area-based conservation - 30x30 goals: recommended because current protection is less than 30%';

  it('lists a recommended action with its reason', () => {
    expect(section({ action_area_based_30x30: 1 }, 'Action recommendations')?.blocks).toEqual([
      { type: 'list', items: [reason], empty: 'No actions recommended by the rules so far.' },
    ]);
  });

  it('says none is recommended when the rule is false, and hides the section without rule attributes', () => {
    expect(section({ action_area_based_30x30: 0 }, 'Action recommendations')?.blocks).toEqual([
      { type: 'list', items: [], empty: 'No actions recommended by the rules so far.' },
    ]);
    expect(section({ name: 'x' }, 'Action recommendations')).toBeUndefined();
  });

  it('draws the whole ecoregion as protected, unprotected intact and unprotected modified land', () => {
    const pie = section(
      { protected_pcnt: 15.3, unprotected_intact_pcnt: 70.5, unprotected_modified_pcnt: 14.2 },
      'Opportunities',
    )?.blocks[0];
    expect(pie?.type === 'chart' && pie.chart.datasets[0]?.values).toEqual([15.3, 70.5, 14.2]);
    expect(section({ intact_pcnt: 80 }, 'Opportunities')).toBeUndefined();
  });

  it('has a colour theme on the action count', () => {
    const theme = ecoregionsExample.themes.find((t) => t.id === 'area_based_actions');
    expect(JSON.stringify(theme?.paint)).toContain('actions_area_based_conservation_count');
  });
});
