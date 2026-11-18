/**
 * The locale numbers are formatted in (pop-ups, modals, legends): the map
 * config's `locale`, from style.json's `metadata["erap:locale"]`, set when
 * style.json is read (`./layers/style.ts`). The app's own text is not
 * translated.
 */

/** The locale when the map config sets none. */
export const DEFAULT_LOCALE = 'en-CA';

let current = DEFAULT_LOCALE;

/** The locale numbers are formatted in now. */
export function numberLocale(): string {
  return current;
}

/**
 * A BCP 47 tag the browser can format numbers in, in its canonical form,
 * or null when it is not a valid tag.
 */
export function canonicalLocale(locale: string): string | null {
  try {
    return Intl.getCanonicalLocales(locale)[0] ?? null;
  } catch {
    return null;
  }
}

/** Formats numbers in `locale` from now on, or in the default for none. */
export function setNumberLocale(locale?: string): void {
  current = (locale && canonicalLocale(locale)) || DEFAULT_LOCALE;
}
