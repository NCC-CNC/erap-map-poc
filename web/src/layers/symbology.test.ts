import {
  validateStyleMin,
  type LayerSpecification,
  type StyleSpecification,
} from '@maplibre/maplibre-gl-style-spec';
import { describe, expect, it } from 'vitest';
import { sample } from './sample';
import { samplePoints } from './samplePoints';
import {
  colorValue,
  legendFor,
  styleLayerIds,
  styleLayers,
  type CategoricalColor,
  type PointSymbology,
  type PolygonSymbology,
  type SteppedColor,
  type Symbology,
} from './symbology';

const stepped: SteppedColor = {
  type: 'stepped',
  attribute: 'score',
  stops: [
    { from: 0, color: '#111111' },
    { from: 25, color: '#222222' },
    { from: 1000, color: '#333333' },
  ],
  max: 2500,
  fallback: { color: '#999999', label: 'No score' },
};

const categorical: CategoricalColor = {
  type: 'categorical',
  attribute: 'kind',
  categories: [
    { value: 'a', color: '#aa0000', label: 'Kind A' },
    { value: 'b', color: '#00aa00', label: 'Kind B' },
  ],
  fallback: { color: '#999999' },
};

const polygon = (color: PolygonSymbology['color']): PolygonSymbology => ({
  geometry: 'polygon',
  color,
  fillOpacity: 0.5,
  outline: { color: '#ffffff', width: 1 },
});

const point = (color: PointSymbology['color']): PointSymbology => ({
  geometry: 'point',
  color,
  radius: 5,
  stroke: { color: '#000000', width: 2 },
});

/** A style holding the generated layers on one vector source, validated as a whole. */
function validate(symbology: Symbology) {
  const style: StyleSpecification = {
    version: 8,
    sources: { src: { type: 'vector', tiles: ['https://example.test/{z}/{x}/{y}.pbf'] } },
    layers: styleLayers('test', symbology).map(
      (layer) => ({ ...layer, source: 'src', 'source-layer': 'test' }) as LayerSpecification,
    ),
  };
  return validateStyleMin(style);
}

describe('colorValue', () => {
  it('uses a single colour as a constant', () => {
    expect(colorValue({ type: 'single', color: '#123456' })).toBe('#123456');
  });

  it('builds a match on the attribute for categories, with the fallback last', () => {
    expect(colorValue(categorical)).toEqual([
      'match',
      ['to-string', ['get', 'kind']],
      'a',
      '#aa0000',
      'b',
      '#00aa00',
      '#999999',
    ]);
  });

  it('builds a step on the attribute for a ramp, guarded for missing values', () => {
    expect(colorValue(stepped)).toEqual([
      'case',
      ['==', ['typeof', ['get', 'score']], 'number'],
      ['step', ['get', 'score'], '#111111', 25, '#222222', 1000, '#333333'],
      '#999999',
    ]);
  });

  it('rejects a ramp with no stops', () => {
    expect(() => colorValue({ ...stepped, stops: [] })).toThrow(/no stops/);
  });
});

describe('styleLayers', () => {
  it('draws polygons as a fill then an outline', () => {
    const layers = styleLayers('test', polygon(stepped));
    expect(layers.map((l) => [l.id, l.type])).toEqual([
      ['test-fill', 'fill'],
      ['test-outline', 'line'],
    ]);
    expect(layers[0]?.paint).toEqual({ 'fill-color': colorValue(stepped), 'fill-opacity': 0.5 });
    expect(layers[1]?.paint).toEqual({ 'line-color': '#ffffff', 'line-width': 1 });
  });

  it('draws points as circles with a stroke', () => {
    const layers = styleLayers('test', point(categorical));
    expect(layers).toEqual([
      {
        id: 'test-circle',
        type: 'circle',
        paint: {
          'circle-color': colorValue(categorical),
          'circle-radius': 5,
          'circle-stroke-color': '#000000',
          'circle-stroke-width': 2,
        },
      },
    ]);
  });

  it('matches styleLayerIds', () => {
    for (const s of [polygon(stepped), point(categorical)]) {
      expect(styleLayers('test', s).map((l) => l.id)).toEqual(styleLayerIds('test', s));
    }
  });

  it.each([
    ['single polygon', polygon({ type: 'single', color: '#123456' })],
    ['categorical polygon', polygon(categorical)],
    ['stepped polygon', polygon(stepped)],
    ['single point', point({ type: 'single', color: '#123456' })],
    ['categorical point', point(categorical)],
    ['stepped point', point(stepped)],
    ['sample', sample.symbology],
    ['sample_points', samplePoints.symbology],
  ])('produces valid MapLibre layers for a %s', (_, symbology) => {
    expect(validate(symbology)).toEqual([]);
  });

  it('is caught by the validator when the stops are out of order', () => {
    const unordered = { ...stepped, stops: [...stepped.stops].reverse() };
    expect(validate(polygon(unordered))).not.toEqual([]);
  });
});

describe('legendFor', () => {
  it('lists ramp steps with ranges, the last up to max, then the fallback', () => {
    expect(legendFor(polygon(stepped), 'Test')).toEqual({
      kind: 'ramp',
      shape: 'square',
      border: '#ffffff',
      opacity: 0.5,
      items: [
        { color: '#111111', label: '0 to 25' },
        { color: '#222222', label: '25 to 1,000' },
        { color: '#333333', label: '1,000 to 2,500' },
        { color: '#999999', label: 'No score' },
      ],
    });
  });

  it('lists categories, leaving out a fallback without a label', () => {
    expect(legendFor(point(categorical), 'Test')).toEqual({
      kind: 'categories',
      shape: 'circle',
      border: '#000000',
      opacity: 1,
      items: [
        { color: '#aa0000', label: 'Kind A' },
        { color: '#00aa00', label: 'Kind B' },
      ],
    });
  });

  it('labels a single colour with the layer title unless given a label', () => {
    expect(legendFor(point({ type: 'single', color: '#123456' }), 'Test').items).toEqual([
      { color: '#123456', label: 'Test' },
    ]);
    expect(
      legendFor(point({ type: 'single', color: '#123456', label: 'Sites' }), 'Test').items,
    ).toEqual([{ color: '#123456', label: 'Sites' }]);
  });

  it('uses the same colours as the paint of the sample layers', () => {
    const sampleLegend = legendFor(sample.symbology, sample.title);
    expect(sampleLegend.items.map((i) => i.label)).toEqual([
      '0 to 25',
      '25 to 50',
      '50 to 75',
      '75 to 100',
      'No score',
    ]);
    const pointsLegend = legendFor(samplePoints.symbology, samplePoints.title);
    expect(pointsLegend.items.map((i) => i.label)).toEqual(['Alpha', 'Beta', 'Gamma', 'Other']);
    // Every legend colour appears in the generated paint expression.
    for (const [def, legend] of [
      [sample, sampleLegend],
      [samplePoints, pointsLegend],
    ] as const) {
      const paint = JSON.stringify(colorValue(def.symbology.color));
      for (const item of legend.items) expect(paint).toContain(item.color);
    }
  });
});
