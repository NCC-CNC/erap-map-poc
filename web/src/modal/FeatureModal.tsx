import { useEffect, useId, useRef } from 'react';
import { FeatureChart } from '../chart/FeatureChart';
import { focusableIn, trapTarget } from './focus';
import type { BlockContent, ModalContent } from './template';

/**
 * Click details in an accessible modal dialog (ADR 0012): `role="dialog"`
 * with `aria-modal`, labelled by its title. Focus moves to the close
 * button on open, stays inside while open (Tab and Shift+Tab cycle) and
 * returns to where it was on close. Escape, the close button and a click
 * on the backdrop close it. The body scrolls, so long content and small
 * screens work; on a narrow screen the dialog fills the screen.
 */
export function FeatureModal({ content, onClose }: { content: ModalContent; onClose: () => void }) {
  const dialog = useRef<HTMLDivElement>(null);
  const closeButton = useRef<HTMLButtonElement>(null);
  const titleId = useId();
  const subtitleId = useId();
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

  return (
    <div
      className="feature-modal-backdrop"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div
        ref={dialog}
        className="feature-modal"
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
        {/* Focusable so the keyboard can scroll it. */}
        <div className="feature-modal-body" tabIndex={0}>
          {content.sections.map((section, i) => (
            <section key={i} aria-labelledby={`${titleId}-s${i}`}>
              <h3 id={`${titleId}-s${i}`}>{section.heading}</h3>
              {section.description && <p>{section.description}</p>}
              {section.blocks.map((block, j) => (
                <Block key={j} block={block} />
              ))}
            </section>
          ))}
        </div>
      </div>
    </div>
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
