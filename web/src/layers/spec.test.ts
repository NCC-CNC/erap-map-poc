import { describe, expect, it } from 'vitest';
import { sample, sampleModal } from '../test/fixtures';
import { resolveSourceUrl, styleLayerIds, toMapLibre } from './spec';

const TILES = 'https://example.test/tiles/';

describe('resolveSourceUrl', () => {
  it('resolves a relative pmtiles or cog archive against the tiles URL, keeping the fragment', () => {
    expect(resolveSourceUrl('pmtiles://sample.pmtiles', TILES)).toBe(
      'pmtiles://https://example.test/tiles/sample.pmtiles',
    );
    expect(resolveSourceUrl('cog://cover.cog.tif#dem', TILES)).toBe(
      'cog://https://example.test/tiles/cover.cog.tif#dem',
    );
    expect(resolveSourceUrl('pmtiles://sample.pmtiles', 'http://localhost:8081/erap/tiles/')).toBe(
      'pmtiles://http://localhost:8081/erap/tiles/sample.pmtiles',
    );
  });

  it('keeps an absolute archive, and resolves a plain relative URL', () => {
    const url = 'pmtiles://https://other.test/a.pmtiles';
    expect(resolveSourceUrl(url, TILES)).toBe(url);
    expect(resolveSourceUrl('tiles.json', TILES)).toBe('https://example.test/tiles/tiles.json');
  });
});

describe('toMapLibre', () => {
  it('keeps the style layers and their ids, and sets the layout visibility', () => {
    const shown = toMapLibre(sample, true);
    expect(shown.layers.map((l) => l.id)).toEqual(styleLayerIds(sample));
    expect(shown.layers.map((l) => l.layout?.visibility)).toEqual(['visible', 'visible']);
    expect(toMapLibre(sample, false).layers.map((l) => l.layout?.visibility)).toEqual(['none', 'none']);
    expect(shown.sources).toBe(sample.sources);
    // The definition itself is left as it is.
    expect(sample.layers[0]).toMatchObject({ id: 'sample-fill', source: 'sample', 'source-layer': 'sample' });
  });

  it('draws the given theme over the style layers, keeping the other paint', () => {
    const theme = sampleModal.themes![1]!;
    const [fill, outline] = toMapLibre(sampleModal, true, theme).layers;
    expect(fill!.paint).toEqual({ 'fill-color': theme.paint.fill!['fill-color'], 'fill-opacity': 0.7 });
    expect(outline!.paint).toEqual(sampleModal.layers[1]!.paint);
    // The first theme is what the style layers draw.
    expect(toMapLibre(sampleModal, true, sampleModal.themes![0]).layers[0]!.paint).toEqual(
      sampleModal.layers[0]!.paint,
    );
    expect(toMapLibre(sampleModal, true).layers[0]!.paint).toEqual(sampleModal.layers[0]!.paint);
  });
});
