/**
 * Keyboard focus helpers for the modal dialog: Tab and Shift+Tab cycle
 * through the dialog's own controls and never leave it (a focus trap).
 */

const FOCUSABLE = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(', ');

/** The elements in `container` that Tab reaches, in order. */
export function focusableIn(container: HTMLElement): HTMLElement[] {
  return [...container.querySelectorAll<HTMLElement>(FOCUSABLE)].filter((el) => !el.hidden);
}

/**
 * Where Tab (or Shift+Tab with `back`) should move focus to keep it in the
 * dialog: from the last control to the first, from the first back to the
 * last, and from anywhere outside the dialog to its first (or last)
 * control. Null when the browser's own move stays inside.
 */
export function trapTarget(
  focusable: readonly HTMLElement[],
  active: Element | null,
  container: HTMLElement,
  back: boolean,
): HTMLElement | null {
  const first = focusable[0];
  const last = focusable[focusable.length - 1];
  if (!first || !last) return null;
  if (!active || !container.contains(active)) return back ? last : first;
  if (back && active === first) return last;
  if (!back && active === last) return first;
  return null;
}
