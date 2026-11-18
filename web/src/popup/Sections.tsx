import { FeatureChart } from '../chart/FeatureChart';
import type { BlockContent, SectionContent } from './content';

/**
 * A section's description and blocks, the same in a small pop-up and a
 * dialog (its heading is drawn by the caller).
 */
export function SectionBody({ section }: { section: SectionContent }) {
  return (
    <>
      {section.description && <p>{section.description}</p>}
      {section.blocks.map((block, j) => (
        <Block key={j} block={block} />
      ))}
    </>
  );
}

/** One block: labelled values, a table, a chart, a paragraph or a list. */
export function Block({ block }: { block: BlockContent }) {
  switch (block.type) {
    case 'attributes':
      return (
        <dl className="feature-attributes">
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
        <div className="feature-table">
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
        <ul className="feature-list">
          {block.items.map((item, i) => (
            <li key={i}>{item}</li>
          ))}
        </ul>
      ) : (
        <p className="feature-empty">{block.empty}</p>
      );
  }
}
