import { describe, expect, it } from 'vitest';
import type { ModalDefinition } from '../layers';
import { ecoregionsExample, sampleModal } from '../test/fixtures';
import { MISSING_CELL, buildModalContent, fillTemplate, isTrue, placeholders } from './template';

const modal = sampleModal.modal as ModalDefinition;

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

describe('fillTemplate', () => {
  it('fills attributes as they are, in a preset, and the feature id', () => {
    expect(fillTemplate('{name} ({$id}): {area_ha:hectares}, {score:percent}', cedar)).toBe(
      'Cedar (7): 12,346 ha, 57.0%',
    );
    expect(placeholders('{name} and {area_ha:hectares} and {$id}')).toEqual(['name', 'area_ha', '$id']);
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

describe('buildModalContent for the sample modal', () => {
  it('fills every section from the feature', () => {
    expect(buildModalContent(modal, cedar, sampleModal.title)).toEqual({
      title: 'Cedar',
      subtitle: 'Sample feature 7',
      sections: [
        {
          heading: 'Summary',
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
          heading: 'Values',
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
                format: 'count',
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
          ],
        },
        {
          heading: 'Notes',
          blocks: [
            { type: 'text', text: 'Scored 57 out of 100.' },
            { type: 'list', items: ['Has a score of 57'], empty: 'Nothing to list.' },
          ],
        },
      ],
    });
  });

  it('hides what the feature has no values for, down to whole sections', () => {
    const content = buildModalContent(modal, { properties: { name: 'Bare' } }, sampleModal.title);
    expect(content).toEqual({ title: 'Bare', sections: [] });
  });

  it('falls back to the layer title, and shows n/a for a missing cell in a row with values', () => {
    const content = buildModalContent(modal, { id: 3, properties: { v2021: 5 } }, sampleModal.title);
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
    const summary = content.sections.find((s) => s.heading === 'Summary');
    expect(summary?.blocks).toEqual([{ type: 'attributes', items: [{ label: 'ID', value: '3' }] }]);
    expect(summary?.description).toBeUndefined();

    const partial = buildModalContent(modal, { properties: { v2020: 1, score: 9 } }, 'x');
    const row = partial.sections.find((s) => s.heading === 'Values')?.blocks[0];
    expect(row && row.type === 'table' && row.rows[0]).toEqual({ label: '2020', cells: ['1', '9.0%'] });
    const missing = buildModalContent(modal, { properties: { v2021: 1, v2020: 'n' } }, 'x');
    const cells = missing.sections.find((s) => s.heading === 'Values')?.blocks[0];
    expect(cells && cells.type === 'table' && cells.rows).toEqual([{ label: '2021', cells: ['1', ''] }]);
    expect(MISSING_CELL).toBe('n/a');
  });

  it('a chart keeps gaps for missing values and is hidden with none', () => {
    const content = buildModalContent(modal, { properties: { v2020: 10 } }, 'x');
    const charts = content.sections.find((s) => s.heading === 'Values')?.blocks.filter((b) => b.type === 'chart');
    expect(charts?.map((c) => c.type === 'chart' && c.chart.datasets)).toEqual([
      [
        { label: 'Early', values: [10, null] },
        { label: 'Late', values: [null, null] },
      ],
      [{ label: 'Value', values: [10, null] }],
    ]);
  });

  it('a list shows its empty message when nothing applies, and is hidden without the attributes', () => {
    const notes = (properties: Record<string, unknown>) =>
      buildModalContent(modal, { properties }, 'x').sections.find((s) => s.heading === 'Notes');
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

describe('the ecoregion example modal with calculated fields and rule attributes', () => {
  const example = ecoregionsExample.modal;
  const section = (properties: Record<string, unknown>, heading: string) =>
    buildModalContent(example, { properties }, 'Ecoregions').sections.find((s) => s.heading === heading);
  const reason = 'Area-based conservation - 30x30 goals: recommended because current protection is less than 30%';

  it('lists a recommended action with its reason', () => {
    expect(
      section({ action_area_based_30x30: 1, action_area_based_30x30_reason: reason }, 'Action recommendations')
        ?.blocks,
    ).toEqual([{ type: 'list', items: [reason], empty: 'No actions recommended by the rules so far.' }]);
  });

  it('says none is recommended when the rule is false, and hides the section without rule attributes', () => {
    expect(section({ action_area_based_30x30: 0 }, 'Action recommendations')?.blocks).toEqual([
      { type: 'list', items: [], empty: 'No actions recommended by the rules so far.' },
    ]);
    expect(section({ name: 'x' }, 'Action recommendations')).toBeUndefined();
  });

  it('draws the unprotected land pie from the calculated fields', () => {
    const pie = section({ unprotected_intact_pcnt: 70.5, unprotected_modified_pcnt: 14.2 }, 'Opportunities')?.blocks[0];
    expect(pie?.type === 'chart' && pie.chart.datasets[0]?.values).toEqual([70.5, 14.2]);
    expect(section({ intact_pcnt: 80 }, 'Opportunities')).toBeUndefined();
  });

  it('has a colour theme on the action count', () => {
    expect(ecoregionsExample.symbology.themes.map((t) => t.color.attribute)).toContain(
      'actions_area_based_conservation_count',
    );
  });
});
