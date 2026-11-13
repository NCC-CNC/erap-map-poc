// @vitest-environment jsdom
/**
 * The modal dialog in a DOM (jsdom): its accessible structure, the tabs
 * (WAI-ARIA tabs pattern) and the scroll layout, focus on open and return
 * on close, the focus trap, Escape, the close button and the backdrop.
 * Charts are stubbed, as jsdom has no canvas.
 */
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ModalDefinition } from '../layers';
import type { PopupFeature } from '../popup/content';
import { sampleModal } from '../test/fixtures';
import { FeatureModal } from './FeatureModal';
import { focusableIn, trapTarget } from './focus';
import { buildModalContent, type ModalContent } from './template';

vi.mock('../chart/FeatureChart', () => ({
  FeatureChart: ({ view }: { view: { title: string; summary: string } }) => (
    <figure className="feature-chart">
      <figcaption>{view.title}</figcaption>
      <div role="img" aria-label={view.summary} />
    </figure>
  ),
}));

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const modal = sampleModal.modal as ModalDefinition;
const cedar = {
  id: 7,
  properties: { name: 'Cedar', area_ha: 12345.67, score: 57, v2020: 120, v2021: 180, v2023: 300, v2024: 360 },
};
const contentOf = (feature: PopupFeature, layout?: ModalDefinition['layout']) =>
  buildModalContent(layout ? { ...modal, layout } : modal, feature, sampleModal.title);
const content = contentOf(cedar);

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

function render(onClose = vi.fn(), shown: ModalContent = content) {
  act(() => root.render(<FeatureModal content={shown} onClose={onClose} />));
  return onClose;
}

const dialog = () => document.querySelector<HTMLElement>('[role="dialog"]')!;
const tabs = () => [...document.querySelectorAll<HTMLButtonElement>('[role="tab"]')];
const tab = (label: string) => tabs().find((t) => t.textContent === label)!;
const selected = () => tabs().filter((t) => t.getAttribute('aria-selected') === 'true').map((t) => t.textContent);
const panel = () => document.querySelector<HTMLElement>('[role="tabpanel"]')!;
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

  it('in the scroll layout, shows every section with its heading, and the blocks as lists, tables, charts and text', () => {
    render(vi.fn(), contentOf(cedar, 'scroll'));
    const d = dialog();
    expect(d.classList).toContain('feature-modal-scroll');
    expect(d.querySelector('[role="tablist"]')).toBeNull();
    expect([...d.querySelectorAll('h3')].map((h) => h.textContent)).toEqual([
      'Summary of the feature',
      'Values',
      'Notes',
    ]);
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
    render(vi.fn(), contentOf(cedar, 'scroll'));
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

describe('FeatureModal tabs', () => {
  it('are the default: a tab list after the title, one tab per section, the first selected', () => {
    render();
    const d = dialog();
    expect(d.classList).toContain('feature-modal-tabs');
    const list = d.querySelector('[role="tablist"]')!;
    expect(list.getAttribute('aria-label')).toBe('Sections');
    expect(tabs().map((t) => t.textContent)).toEqual(['Summary', 'Values', 'Notes']);
    expect(selected()).toEqual(['Summary']);
    // A roving tabindex: only the selected tab is in the Tab order.
    expect(tabs().map((t) => t.tabIndex)).toEqual([0, -1, -1]);
  });

  it('show only the selected section, in a panel labelled by its tab and controlled by it', () => {
    render();
    expect(document.querySelectorAll('[role="tabpanel"]').length).toBe(1);
    const p = panel();
    const summary = tab('Summary');
    expect(summary.getAttribute('aria-controls')).toBe(p.id);
    expect(tab('Values').hasAttribute('aria-controls')).toBe(false);
    expect(document.getElementById(p.getAttribute('aria-labelledby')!)).toBe(summary);
    expect(p.tabIndex).toBe(0);
    // A tab label shorter than the heading: the heading shows in the panel.
    expect([...p.querySelectorAll('h3')].map((h) => h.textContent)).toEqual(['Summary of the feature']);
    expect(p.textContent).toContain('A made-up feature of 12,346 ha.');
    expect([...p.querySelectorAll('dt')].map((dt) => dt.textContent)).toEqual(['ID', 'Area', 'Score']);
    expect(p.querySelector('table')).toBeNull();
  });

  it('switch on a click', () => {
    render();
    act(() => tab('Values').click());
    expect(selected()).toEqual(['Values']);
    expect(tabs().map((t) => t.tabIndex)).toEqual([-1, 0, -1]);
    const p = panel();
    expect(tab('Values').getAttribute('aria-controls')).toBe(p.id);
    expect(document.getElementById(p.getAttribute('aria-labelledby')!)).toBe(tab('Values'));
    // The tab already says "Values": no heading repeats it.
    expect(p.querySelector('h3')).toBeNull();
    expect(p.querySelector('table caption')?.textContent).toBe('Values by year');
    expect([...p.querySelectorAll('figcaption')].map((f) => f.textContent)).toEqual([
      'Values, early and late',
      'Share by year',
    ]);
    expect(p.querySelector('dt')).toBeNull();
  });

  it('move and select with the arrow keys, Home and End, wrapping at the ends', () => {
    render();
    act(() => tab('Summary').focus());
    const step = (k: string, label: string) => {
      key(k);
      expect(selected()).toEqual([label]);
      expect(document.activeElement).toBe(tab(label));
    };
    step('ArrowRight', 'Values');
    step('ArrowRight', 'Notes');
    step('ArrowRight', 'Summary');
    step('ArrowLeft', 'Notes');
    step('Home', 'Summary');
    step('End', 'Notes');
    expect(panel().textContent).toContain('Scored 57 out of 100.');
    // Other keys are left alone.
    key('ArrowDown');
    expect(selected()).toEqual(['Notes']);
  });

  it('keep Tab in the dialog: the close button, the selected tab, then the panel', () => {
    render();
    act(() => tab('Values').click());
    const focusable = focusableIn(dialog());
    expect(focusable).toEqual([dialog().querySelector('button[aria-label="Close"]'), tab('Values'), panel()]);
    act(() => panel().focus());
    key('Tab');
    expect(document.activeElement).toBe(focusable[0]);
    key('Tab', true);
    expect(document.activeElement).toBe(panel());
  });

  it('are made for the sections the feature has only, and with one section there is no tab list', () => {
    // Summary (the id) and Notes (a flag), not Values.
    render(vi.fn(), contentOf({ id: 4, properties: { flag: 1, flag_reason: 'too low' } }));
    expect(tabs().map((t) => t.textContent)).toEqual(['Summary', 'Notes']);
    act(() => root.render(<FeatureModal content={contentOf({ properties: { v2021: 5 } })} onClose={vi.fn()} />));
    const d = dialog();
    expect(d.classList).toContain('feature-modal-tabs');
    expect(d.querySelector('[role="tablist"]')).toBeNull();
    expect(d.querySelector('[role="tabpanel"]')).toBeNull();
    expect([...d.querySelectorAll('h3')].map((h) => h.textContent)).toEqual(['Values']);
    expect(d.querySelector('table')).not.toBeNull();
  });

  it('keep the selected tab for the next feature when it has that section, else show the first', () => {
    render();
    act(() => tab('Notes').click());
    const birch = { id: 2, properties: { name: 'Birch', score: 74 } };
    act(() => root.render(<FeatureModal content={contentOf(birch)} onClose={vi.fn()} />));
    expect(selected()).toEqual(['Notes']);
    expect(panel().textContent).toContain('Scored 74 out of 100.');
    // No Notes for this feature: the first tab, until one with Notes again.
    const bare = { id: 3, properties: { v2020: 1, v2021: 2 } };
    act(() => root.render(<FeatureModal content={contentOf(bare)} onClose={vi.fn()} />));
    expect(selected()).toEqual(['Summary']);
    act(() => root.render(<FeatureModal content={contentOf(birch)} onClose={vi.fn()} />));
    expect(selected()).toEqual(['Notes']);
  });

  it('follow the tab given by the map, and report a new choice to it', () => {
    const onTabChange = vi.fn();
    act(() => root.render(<FeatureModal content={content} onClose={vi.fn()} tab={1} onTabChange={onTabChange} />));
    expect(selected()).toEqual(['Values']);
    act(() => tab('Notes').click());
    expect(onTabChange).toHaveBeenCalledWith(2);
    // Controlled: the map decides.
    expect(selected()).toEqual(['Values']);
    act(() => root.render(<FeatureModal content={content} onClose={vi.fn()} tab={2} onTabChange={onTabChange} />));
    expect(selected()).toEqual(['Notes']);
    act(() => tab('Notes').focus());
    key('Home');
    expect(onTabChange).toHaveBeenLastCalledWith(0);
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

  it('leaves out elements taken out of the Tab order', () => {
    const box = document.createElement('div');
    const [a, b] = ['a', 'b'].map((t) => {
      const button = document.createElement('button');
      button.textContent = t;
      box.append(button);
      return button;
    }) as [HTMLButtonElement, HTMLButtonElement];
    b.tabIndex = -1;
    document.body.append(box);
    expect(focusableIn(box)).toEqual([a]);
  });
});
