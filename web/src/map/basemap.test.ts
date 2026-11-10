import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  CARTO_STYLES,
  OPENFREEMAP_STYLES,
  resolveBasemaps,
  warnIfFallback,
  withKey,
} from './basemap';

describe('withKey', () => {
  it('appends the key as ?key=', () => {
    expect(withKey(CARTO_STYLES.light, 'abc')).toBe(
      'https://basemaps.cartocdn.com/gl/positron-gl-style/style.json?key=abc',
    );
  });

  it('encodes the key', () => {
    expect(withKey(CARTO_STYLES.dark, 'a b&c')).toBe(
      'https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json?key=a+b%26c',
    );
  });
});

describe('resolveBasemaps', () => {
  it('uses CARTO Positron and Dark Matter with a key', () => {
    expect(resolveBasemaps('abc')).toEqual({
      provider: 'carto',
      styles: {
        light: 'https://basemaps.cartocdn.com/gl/positron-gl-style/style.json?key=abc',
        dark: 'https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json?key=abc',
      },
    });
  });

  it('falls back to OpenFreeMap without a key and never requests CARTO', () => {
    for (const key of ['', '   ']) {
      const basemaps = resolveBasemaps(key);
      expect(basemaps).toEqual({ provider: 'openfreemap', styles: OPENFREEMAP_STYLES });
      for (const url of Object.values(basemaps.styles)) expect(url).not.toContain('cartocdn');
    }
  });
});

describe('warnIfFallback', () => {
  afterEach(() => vi.restoreAllMocks());

  it('warns once for the fallback and never for CARTO', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    warnIfFallback(resolveBasemaps('abc'));
    expect(warn).not.toHaveBeenCalled();
    warnIfFallback(resolveBasemaps(''));
    warnIfFallback(resolveBasemaps(''));
    expect(warn).toHaveBeenCalledTimes(1);
  });
});
