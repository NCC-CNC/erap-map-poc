import { describe, expect, it } from 'vitest';
import { openingView } from './view';

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
