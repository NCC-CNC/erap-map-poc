import type { PopupContent } from './content';
import { SectionBody } from './Sections';

/**
 * A small pop-up's body for one clicked feature, shown in a MapLibre
 * pop-up at the click: the title, the subtitle, then its section with the
 * same blocks as a dialog.
 */
export function FeaturePopup({ content }: { content: PopupContent }) {
  return (
    <div className="feature-popup">
      <h2>{content.title}</h2>
      {content.subtitle && <p className="feature-popup-subtitle">{content.subtitle}</p>}
      {content.sections.map((section) => (
        <section key={section.index}>
          {section.heading && <h3>{section.heading}</h3>}
          <SectionBody section={section} />
        </section>
      ))}
    </div>
  );
}
