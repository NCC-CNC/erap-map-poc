import { describe, expect, it } from 'vitest';
import { DEFAULT_TITLE, mapLimits, openingView, pageTitle } from './view';

describe('openingView', () => {
  it('is the config view when the URL has none', () => {
    expect(openingView({ center: [-80, 45], zoom: 5, basemap: 'dark' }, '')).toEqual({ center: [-80, 45], zoom: 5 });
    expect(openingView({ zoom: 4 }, '#')).toEqual({ zoom: 4 });
  });

  it('keeps a view already in the URL', () => {
    expect(openingView({ center: [-80, 45], zoom: 5 }, '#3/60/-96')).toBeNull();
  });

  it('is null with no view in the defaults', () => {
    expect(openingView(null, '')).toBeNull();
    expect(openingView({ basemap: 'dark' }, '')).toBeNull();
  });
});

describe('mapLimits', () => {
  it('gives the zoom limits and the bounds as MapLibre takes them', () => {
    expect(mapLimits({ minZoom: 2, maxZoom: 12, bounds: [-141, 41.5, -52, 84] })).toEqual({
      minZoom: 2,
      maxZoom: 12,
      maxBounds: [
        [-141, 41.5],
        [-52, 84],
      ],
    });
    expect(mapLimits({ maxZoom: 10, zoom: 3 })).toEqual({ maxZoom: 10 });
  });

  it('is null with none', () => {
    expect(mapLimits(null)).toBeNull();
    expect(mapLimits({ center: [-80, 45], zoom: 5 })).toBeNull();
  });
});

describe('pageTitle', () => {
  it("is the map config's title, else the default", () => {
    expect(pageTitle({ title: 'Conservation map' })).toBe('Conservation map');
    expect(pageTitle({ zoom: 3 })).toBe(DEFAULT_TITLE);
    expect(pageTitle(null)).toBe('ERAP Map');
  });
});
