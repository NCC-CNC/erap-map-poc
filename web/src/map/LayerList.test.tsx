// @vitest-environment jsdom
/**
 * The layer panel's "Colour by" choice and gradient legends (ADR 0011), in
 * a DOM (jsdom).
 */
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ThemeState } from '../layers';
import { sample, sampleModal } from '../test/fixtures';
import { LayerList } from './LayerList';
import { gradientCss } from './legend';

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let host: HTMLDivElement;
let root: Root;

beforeEach(() => {
  host = document.createElement('div');
  document.body.append(host);
  root = createRoot(host);
});

afterEach(() => {
  act(() => root.unmount());
  document.body.replaceChildren();
});

function render(themes: ThemeState, onThemeChange = vi.fn(), layers = [sampleModal]) {
  act(() =>
    root.render(
      <LayerList
        layers={layers}
        problem={null}
        visibility={{}}
        available={null}
        onChange={() => {}}
        themes={themes}
        onThemeChange={onThemeChange}
      />,
    ),
  );
  return onThemeChange;
}

const select = () => host.querySelector<HTMLSelectElement>('#layer-theme-sample');

describe('Colour by', () => {
  it('lists the themes, labelled, on the active one', () => {
    render({});
    const s = select()!;
    expect(host.querySelector(`label[for="${s.id}"]`)?.textContent).toBe('Colour by');
    expect([...s.options].map((o) => [o.value, o.textContent])).toEqual([
      ['score', 'Score (classes)'],
      ['score_gradient', 'Score (gradient)'],
      ['area', 'Area (ha)'],
    ]);
    expect(s.value).toBe('score');
    expect(host.querySelector('.layer-legend')?.getAttribute('aria-label')).toBe(
      'Sample polygons legend: Score (classes)',
    );
  });

  it('reports a choice, and shows the chosen theme with its gradient legend', () => {
    const onThemeChange = render({});
    act(() => {
      select()!.value = 'area';
      select()!.dispatchEvent(new Event('change', { bubbles: true }));
    });
    expect(onThemeChange).toHaveBeenCalledWith('sample', 'area');

    render({ sample: 'score_gradient' });
    expect(select()!.value).toBe('score_gradient');
    const legend = host.querySelector('.layer-legend')!;
    expect(legend.classList.contains('layer-legend-gradient')).toBe(true);
    expect(legend.textContent).toContain('Colour gradient from 0 to 100');
    expect([...legend.querySelectorAll('.layer-legend-ticks span')].map((s) => s.textContent)).toEqual([
      '0',
      '50',
      '100',
    ]);
    // The fallback, which has no position, is a swatch of its own.
    expect([...legend.querySelectorAll(':scope > li')].map((li) => li.textContent)).toContain('No score');
  });

  it('is not offered for a layer without themes', () => {
    render({}, vi.fn(), [sample]);
    expect(select()).toBeNull();
    expect(host.querySelector('.layer-legend')?.getAttribute('aria-label')).toBe('Sample polygons legend');
  });
});

describe('gradientCss', () => {
  it('places each positioned colour, skipping the rest', () => {
    expect(
      gradientCss([
        { color: '#000', label: '0', position: 0 },
        { color: '#888', label: '33', position: 1 / 3 },
        { color: '#fff', label: '100', position: 1 },
        { color: '#999', label: 'No data' },
      ]),
    ).toBe('linear-gradient(to right, #000 0%, #888 33.3%, #fff 100%)');
  });
});
