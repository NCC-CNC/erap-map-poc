// @vitest-environment jsdom
/**
 * The small pop-up in a DOM (jsdom): the same blocks as a dialog
 * (`./Sections.tsx`) under the title. Charts are stubbed, as jsdom has no
 * canvas.
 */
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { PopupDefinition } from '../layers';
import { sample, sampleModal, samplePoints } from '../test/fixtures';
import { buildPopupContent, type PopupFeature } from './content';
import { FeaturePopup } from './FeaturePopup';

vi.mock('../chart/FeatureChart', () => ({
  FeatureChart: ({ view }: { view: { type: string; title: string; summary: string } }) => (
    <figure className="feature-chart" data-type={view.type}>
      <figcaption>{view.title}</figcaption>
      <div role="img" aria-label={view.summary} />
    </figure>
  ),
}));

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

function render(popup: PopupDefinition, feature: PopupFeature, title: string) {
  act(() => root.render(<FeaturePopup content={buildPopupContent(popup, feature, title)} />));
}

const rows = () =>
  [...host.querySelectorAll('.feature-attributes > div')].map((d) => [
    d.querySelector('dt')?.textContent,
    d.querySelector('dd')?.textContent,
  ]);

describe('FeaturePopup', () => {
  it('shows the title, the labelled values and the chart of the sample layer', () => {
    render(sample.popup!, { id: 3, properties: { name: 'Cedar', area_ha: 24757.5, score: 10, v2020: 259 } }, sample.title);
    expect(host.querySelector('h2')?.textContent).toBe('Cedar');
    expect(rows()).toEqual([
      ['ID', '3'],
      ['Area', '24,757.5 ha'],
      ['Score', '10 / 100'],
    ]);
    const chart = host.querySelector('figure');
    expect(chart?.dataset.type).toBe('bar');
    expect(chart?.querySelector('figcaption')?.textContent).toBe('Value by year');
    // No heading or subtitle in a section without them.
    expect(host.querySelector('h3')).toBeNull();
    expect(host.querySelector('.feature-popup-subtitle')).toBeNull();
  });

  it('shows the points layer values, a count in the integer format', () => {
    render(samplePoints.popup!, { id: 12, properties: { name: 'Heron', category: 'beta', count: 1234 } }, 'x');
    expect(rows()).toEqual([
      ['ID', '12'],
      ['Category', 'beta'],
      ['Count', '1,234'],
    ]);
  });

  it('draws any block of a dialog section: a table, a line chart, text and a list', () => {
    const values = (sampleModal.popup as PopupDefinition).sections;
    const popup: PopupDefinition = {
      title: '{name}',
      subtitle: 'Feature {$id}',
      sections: [
        {
          heading: 'Values',
          description: 'Scored {score}.',
          blocks: [...values[1]!.blocks!.filter((b) => b.type !== 'chart' || b.chart === 'line'), ...values[2]!.blocks!],
        },
      ],
    };
    render(popup, { id: 7, properties: { name: 'Cedar', score: 57, v2020: 120, v2021: 180 } }, 'x');
    expect(host.querySelector('.feature-popup-subtitle')?.textContent).toBe('Feature 7');
    expect(host.querySelector('h3')?.textContent).toBe('Values');
    expect([...host.querySelectorAll('tbody tr')].map((r) => r.textContent)).toEqual(['202012057.0%', '2021180']);
    expect([...host.querySelectorAll('figure')].map((f) => (f as HTMLElement).dataset.type)).toEqual(['line']);
    expect([...host.querySelectorAll('p')].map((p) => p.textContent)).toEqual([
      'Feature 7',
      'Scored 57.',
      'Scored 57 out of 100.',
    ]);
    expect(host.querySelector('.feature-list li')?.textContent).toBe('Has a score of 57');
  });
});
