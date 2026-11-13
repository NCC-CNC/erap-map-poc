// @vitest-environment jsdom
/**
 * The modal dialog in a DOM (jsdom): its accessible structure, focus on
 * open and return on close, the focus trap, Escape, the close button and
 * the backdrop. Charts are stubbed, as jsdom has no canvas.
 */
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ModalDefinition } from '../layers';
import { sampleModal } from '../test/fixtures';
import { FeatureModal } from './FeatureModal';
import { focusableIn, trapTarget } from './focus';
import { buildModalContent } from './template';

vi.mock('../chart/FeatureChart', () => ({
  FeatureChart: ({ view }: { view: { title: string; summary: string } }) => (
    <figure className="feature-chart">
      <figcaption>{view.title}</figcaption>
      <div role="img" aria-label={view.summary} />
    </figure>
  ),
}));

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const cedar = {
  id: 7,
  properties: { name: 'Cedar', area_ha: 12345.67, score: 57, v2020: 120, v2021: 180, v2023: 300, v2024: 360 },
};
const content = buildModalContent(sampleModal.modal as ModalDefinition, cedar, sampleModal.title);

let host: HTMLDivElement;
let root: Root;
let opener: HTMLButtonElement;

beforeEach(() => {
  opener = document.createElement('button');
  opener.textContent = 'map';
  document.body.append(opener);
  opener.focus();
  host = document.createElement('div');
  document.body.append(host);
  root = createRoot(host);
});

afterEach(() => {
  act(() => root.unmount());
  document.body.replaceChildren();
});

function render(onClose = vi.fn()) {
  act(() => root.render(<FeatureModal content={content} onClose={onClose} />));
  return onClose;
}

const dialog = () => document.querySelector<HTMLElement>('[role="dialog"]')!;
const key = (k: string, shiftKey = false) =>
  act(() => {
    document.activeElement!.dispatchEvent(new KeyboardEvent('keydown', { key: k, shiftKey, bubbles: true }));
  });

describe('FeatureModal', () => {
  it('is a modal dialog labelled by its title and described by its subtitle', () => {
    render();
    const d = dialog();
    expect(d.getAttribute('aria-modal')).toBe('true');
    const title = document.getElementById(d.getAttribute('aria-labelledby')!);
    expect(title?.tagName).toBe('H2');
    expect(title?.textContent).toBe('Cedar');
    expect(document.getElementById(d.getAttribute('aria-describedby')!)?.textContent).toBe('Sample feature 7');
  });

  it('shows every section with its heading, and the blocks as lists, tables, charts and text', () => {
    render();
    const d = dialog();
    expect([...d.querySelectorAll('h3')].map((h) => h.textContent)).toEqual(['Summary', 'Values', 'Notes']);
    expect([...d.querySelectorAll('dt')].map((dt) => dt.textContent)).toEqual(['ID', 'Area', 'Score']);
    const table = d.querySelector('table')!;
    expect(table.querySelector('caption')?.textContent).toBe('Values by year');
    expect([...table.querySelectorAll('thead th')].map((th) => [th.textContent, th.getAttribute('scope')])).toEqual([
      ['Year', 'col'],
      ['Value', 'col'],
      ['Score', 'col'],
    ]);
    expect([...table.querySelectorAll('tbody th[scope="row"]')].map((th) => th.textContent)).toEqual([
      '2020',
      '2021',
    ]);
    expect([...table.querySelectorAll('tbody tr:first-child td')].map((td) => td.textContent)).toEqual([
      '120',
      '57.0%',
    ]);
    expect([...d.querySelectorAll('figcaption')].map((f) => f.textContent)).toEqual([
      'Values, early and late',
      'Share by year',
    ]);
    expect(d.textContent).toContain('Scored 57 out of 100.');
    expect([...d.querySelectorAll('li')].map((li) => li.textContent)).toEqual(['Has a score of 57']);
  });

  it('moves focus to the close button on open, and back on close', () => {
    render();
    const close = dialog().querySelector<HTMLButtonElement>('button[aria-label="Close"]')!;
    expect(document.activeElement).toBe(close);
    act(() => root.render(<></>));
    expect(document.activeElement).toBe(opener);
  });

  it('keeps Tab and Shift+Tab inside the dialog', () => {
    render();
    const focusable = focusableIn(dialog());
    // The close button and the scrollable body.
    expect(focusable.length).toBe(2);
    const [first, last] = [focusable[0]!, focusable[1]!];
    act(() => last.focus());
    key('Tab');
    expect(document.activeElement).toBe(first);
    key('Tab', true);
    expect(document.activeElement).toBe(last);
    // Focus that has left the dialog comes back to it.
    act(() => opener.focus());
    key('Tab');
    expect(document.activeElement).toBe(first);
  });

  it('closes on Escape, on the close button and on a click on the backdrop, not inside', () => {
    const onClose = render();
    key('Escape');
    expect(onClose).toHaveBeenCalledTimes(1);
    act(() => dialog().querySelector<HTMLButtonElement>('button[aria-label="Close"]')!.click());
    expect(onClose).toHaveBeenCalledTimes(2);
    act(() => {
      dialog().dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
    });
    expect(onClose).toHaveBeenCalledTimes(2);
    act(() => {
      document.querySelector('.feature-modal-backdrop')!.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
    });
    expect(onClose).toHaveBeenCalledTimes(3);
  });

  it('stops listening for keys once closed', () => {
    const onClose = render();
    act(() => root.render(<></>));
    act(() => {
      document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    });
    expect(onClose).not.toHaveBeenCalled();
  });
});

describe('trapTarget', () => {
  it('wraps at the ends, brings outside focus in, and leaves moves inside to the browser', () => {
    const box = document.createElement('div');
    const [a, b, c] = ['a', 'b', 'c'].map((t) => {
      const button = document.createElement('button');
      button.textContent = t;
      box.append(button);
      return button;
    }) as [HTMLButtonElement, HTMLButtonElement, HTMLButtonElement];
    const outside = document.createElement('button');
    document.body.append(box, outside);
    expect(focusableIn(box)).toEqual([a, b, c]);
    expect(trapTarget([a, b, c], c, box, false)).toBe(a);
    expect(trapTarget([a, b, c], a, box, true)).toBe(c);
    expect(trapTarget([a, b, c], b, box, false)).toBeNull();
    expect(trapTarget([a, b, c], outside, box, false)).toBe(a);
    expect(trapTarget([a, b, c], outside, box, true)).toBe(c);
    expect(trapTarget([], a, box, false)).toBeNull();
  });
});
