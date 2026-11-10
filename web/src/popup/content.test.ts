import { describe, expect, it } from 'vitest';
import type { LayerDefinition, PopupChart } from '../layers';
import { sample } from '../layers/sample';
import {
  MISSING,
  buildChart,
  buildPopupContent,
  clickableLayers,
  formatNumber,
  formatValue,
  readValue,
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
    expect(formatNumber(57.4, { suffix: '/ 100' })).toBe('57 / 100');
  });

  it('can turn grouping off', () => {
    expect(formatNumber(12345, { grouping: false })).toBe('12345');
  });
});

describe('formatValue', () => {
  it('shows text and unformatted numbers as they are', () => {
    expect(formatValue('Cedar')).toBe('Cedar');
    expect(formatValue(12345)).toBe('12345');
    expect(formatValue(true)).toBe('Yes');
  });

  it('shows missing or unusable values as not available', () => {
    for (const raw of [undefined, null, '', '  ', Number.NaN, {}]) {
      expect(formatValue(raw)).toBe(MISSING);
    }
    expect(formatValue('abc', { decimals: 1 })).toBe(MISSING);
    expect(formatValue(undefined, { suffix: 'ha' })).toBe(MISSING);
  });
});

describe('buildChart', () => {
  const chart: PopupChart = {
    type: 'bar',
    title: 'Value by year',
    valueLabel: 'Value',
    points: [
      { label: '2020', attribute: 'v2020' },
      { label: '2021', attribute: 'v2021' },
    ],
  };

  it('builds labels, values and a text summary', () => {
    expect(buildChart(chart, cedar)).toEqual({
      type: 'bar',
      title: 'Value by year',
      labels: ['2020', '2021'],
      values: [120, 180],
      summary: 'Value by year. Value for 2020: 120, 2021: 180.',
    });
  });

  it('leaves gaps for missing values', () => {
    const built = buildChart(chart, { properties: { v2021: 5 } });
    expect(built?.values).toEqual([null, 5]);
    expect(built?.summary).toBe(`Value by year. Value for 2020: ${MISSING}, 2021: 5.`);
  });

  it('returns null when no value is present', () => {
    expect(buildChart(chart, { properties: {} })).toBeNull();
  });
});

describe('buildPopupContent for the sample layer', () => {
  const popup = sample.popup!;

  it('builds the title, stats and chart from attributes and feature.id', () => {
    expect(buildPopupContent(popup, cedar, sample.title)).toEqual({
      title: 'Cedar',
      stats: [
        { label: 'ID', value: '7' },
        { label: 'Area', value: '12,345.7 ha' },
        { label: 'Score', value: '57 / 100' },
      ],
      charts: [
        {
          type: 'bar',
          title: 'Value by year',
          labels: ['2020', '2021', '2022', '2023', '2024'],
          values: [120, 180, 240, 300, 360],
          summary:
            'Value by year. Value for 2020: 120, 2021: 180, 2022: 240, 2023: 300, 2024: 360.',
        },
      ],
    });
  });

  it('copes with a feature that has no id and no attributes', () => {
    expect(buildPopupContent(popup, { properties: {} }, sample.title)).toEqual({
      title: 'Sample polygons',
      stats: [
        { label: 'ID', value: MISSING },
        { label: 'Area', value: MISSING },
        { label: 'Score', value: MISSING },
      ],
      charts: [],
    });
  });
});

describe('clickableLayers', () => {
  it('maps every style layer of a layer with a pop-up, and skips the rest', () => {
    const noPopup: LayerDefinition = {
      ...sample,
      id: 'plain',
      popup: undefined,
      layers: [{ id: 'plain-fill', type: 'fill', paint: {} }],
    };
    const targets = clickableLayers([sample, noPopup]);
    expect([...targets.keys()]).toEqual(['sample-fill', 'sample-outline']);
    expect(targets.get('sample-fill')?.popup).toBe(sample.popup);
  });
});
