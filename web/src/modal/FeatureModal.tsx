import { useEffect, useId, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from 'react';
import { FeatureChart } from '../chart/FeatureChart';
import { focusableIn, trapTarget } from './focus';
import { selectedSection, type BlockContent, type ModalContent, type SectionContent } from './template';

/** Keys that move between tabs (WAI-ARIA tabs pattern, horizontal). */
const TAB_KEYS = ['ArrowLeft', 'ArrowRight', 'Home', 'End'];

/**
 * Click details in an accessible modal dialog (ADR 0012): `role="dialog"`
 * with `aria-modal`, labelled by its title. Focus moves to the close
 * button on open, stays inside while open (Tab and Shift+Tab cycle) and
 * returns to where it was on close. Escape, the close button and a click
 * on the backdrop close it.
 *
 * In the `tabs` layout (the default) each section the feature has values
 * for is a tab (WAI-ARIA tabs pattern: one tab in the Tab order, arrow
 * keys, Home and End move between them and select), shown one at a time
 * in a dialog of fixed size whose panel scrolls; with one section there
 * are no tabs. The selected tab is a section's template index: `tab` and
 * `onTabChange` let the map keep it from one feature of a layer to the
 * next (without them the dialog keeps it itself). In the `scroll` layout
 * every section is shown in one body that scrolls. On a narrow screen the
 * dialog fills the screen.
 */
export function FeatureModal({
  content,
  onClose,
  tab,
  onTabChange,
}: {
  content: ModalContent;
  onClose: () => void;
  tab?: number;
  onTabChange?: (index: number) => void;
}) {
  const dialog = useRef<HTMLDivElement>(null);
  const closeButton = useRef<HTMLButtonElement>(null);
  const tabButtons = useRef(new Map<number, HTMLButtonElement>());
  const titleId = useId();
  const subtitleId = useId();
  const [ownTab, setOwnTab] = useState<number>();
  const wanted = onTabChange ? tab : ownTab;
  const select = onTabChange ?? setOwnTab;
  // Read by the key handler, so a new onClose does not re-run the effect.
  const close = useRef(onClose);
  useEffect(() => {
    close.current = onClose;
  }, [onClose]);

  useEffect(() => {
    const previous = document.activeElement;
    closeButton.current?.focus();
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        close.current();
      } else if (e.key === 'Tab' && dialog.current) {
        const target = trapTarget(focusableIn(dialog.current), document.activeElement, dialog.current, e.shiftKey);
        if (target) {
          e.preventDefault();
          target.focus();
        }
      }
    };
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('keydown', onKeyDown);
      if (previous instanceof HTMLElement && previous.isConnected) previous.focus();
    };
  }, []);

  const tabbed = content.layout === 'tabs' && content.sections.length > 1;
  const active = selectedSection(content, wanted);
  const shown = content.sections.find((s) => s.index === active);
  const tabId = (index: number) => `${titleId}-tab${index}`;
  const panelId = `${titleId}-panel`;

  const onTabKeyDown = (e: ReactKeyboardEvent) => {
    if (!TAB_KEYS.includes(e.key)) return;
    const order = content.sections.map((s) => s.index);
    const at = Math.max(0, order.indexOf(active ?? -1));
    const next = {
      ArrowLeft: order[(at - 1 + order.length) % order.length],
      ArrowRight: order[(at + 1) % order.length],
      Home: order[0],
      End: order[order.length - 1],
    }[e.key];
    if (next === undefined) return;
    e.preventDefault();
    select(next);
    tabButtons.current.get(next)?.focus();
  };

  return (
    <div
      className="feature-modal-backdrop"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div
        ref={dialog}
        className={`feature-modal feature-modal-${content.layout}`}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={content.subtitle ? subtitleId : undefined}
      >
        <header className="feature-modal-header">
          <div>
            <h2 id={titleId}>{content.title}</h2>
            {content.subtitle && <p id={subtitleId}>{content.subtitle}</p>}
          </div>
          <button ref={closeButton} type="button" className="feature-modal-close" aria-label="Close" onClick={onClose}>
            <span aria-hidden="true">×</span>
          </button>
        </header>
        {tabbed && shown ? (
          <>
            <div className="feature-modal-tablist" role="tablist" aria-label="Sections" onKeyDown={onTabKeyDown}>
              {content.sections.map((section) => {
                const selected = section.index === active;
                return (
                  <button
                    key={section.index}
                    ref={(el) => {
                      if (el) tabButtons.current.set(section.index, el);
                      else tabButtons.current.delete(section.index);
                    }}
                    type="button"
                    role="tab"
                    id={tabId(section.index)}
                    className="feature-modal-tab"
                    aria-selected={selected}
                    // Only the selected tab's panel is in the page.
                    aria-controls={selected ? panelId : undefined}
                    tabIndex={selected ? 0 : -1}
                    onClick={() => select(section.index)}
                  >
                    {section.tab}
                  </button>
                );
              })}
            </div>
            {/* A new panel per tab, so it opens scrolled to the top. Focusable so the keyboard can scroll it. */}
            <div
              key={shown.index}
              id={panelId}
              className="feature-modal-body"
              role="tabpanel"
              aria-labelledby={tabId(shown.index)}
              tabIndex={0}
            >
              {/* The tab names the panel; a longer heading is shown too. */}
              {shown.heading !== shown.tab && <h3>{shown.heading}</h3>}
              <SectionBody section={shown} />
            </div>
          </>
        ) : (
          // Focusable so the keyboard can scroll it.
          <div className="feature-modal-body" tabIndex={0}>
            {content.sections.map((section) => (
              <section key={section.index} aria-labelledby={`${titleId}-s${section.index}`}>
                <h3 id={`${titleId}-s${section.index}`}>{section.heading}</h3>
                <SectionBody section={section} />
              </section>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function SectionBody({ section }: { section: SectionContent }) {
  return (
    <>
      {section.description && <p>{section.description}</p>}
      {section.blocks.map((block, j) => (
        <Block key={j} block={block} />
      ))}
    </>
  );
}

function Block({ block }: { block: BlockContent }) {
  switch (block.type) {
    case 'attributes':
      return (
        <dl className="feature-modal-attributes">
          {block.items.map((item, i) => (
            <div key={i}>
              <dt>{item.label}</dt>
              <dd>{item.value}</dd>
            </div>
          ))}
        </dl>
      );
    case 'table':
      return (
        <div className="feature-modal-table">
          <table>
            {block.caption && <caption>{block.caption}</caption>}
            <thead>
              <tr>
                <th scope="col">{block.rowHeader ?? ''}</th>
                {block.columns.map((column, i) => (
                  <th key={i} scope="col">
                    {column}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {block.rows.map((row, i) => (
                <tr key={i}>
                  <th scope="row">{row.label}</th>
                  {row.cells.map((cell, j) => (
                    <td key={j}>{cell}</td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      );
    case 'chart':
      return <FeatureChart view={block.chart} />;
    case 'text':
      return <p>{block.text}</p>;
    case 'list':
      return block.items.length ? (
        <ul className="feature-modal-list">
          {block.items.map((item, i) => (
            <li key={i}>{item}</li>
          ))}
        </ul>
      ) : (
        <p className="feature-modal-empty">{block.empty}</p>
      );
  }
}
