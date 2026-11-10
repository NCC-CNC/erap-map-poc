import { useState, type ReactNode } from 'react';

/** Below this width the panel starts collapsed, to keep the map in view. */
const NARROW = '(max-width: 600px)';

/**
 * The map controls (basemap and layers) in one collapsible panel. A native
 * `details` element, so it is keyboard and screen reader friendly as is.
 */
export function MapPanel({ children }: { children: ReactNode }) {
  const [open, setOpen] = useState(() => !window.matchMedia?.(NARROW).matches);
  return (
    <details
      className="map-panel"
      open={open}
      onToggle={(e) => setOpen(e.currentTarget.open)}
    >
      <summary>Map layers</summary>
      <div className="map-panel-body">{children}</div>
    </details>
  );
}
