/**
 * Runtime configuration, read from `/config.json` when the app starts, so
 * the same build works in every environment. In the deployed app nginx
 * writes the file at container start from environment variables (#8); in
 * development the Vite dev server serves it (see `web/vite/serveConfig.ts`).
 */
export interface RuntimeConfig {
  /** CARTO basemap API key; an empty string means no key (ADR 0005). */
  cartoApiKey: string;
}

export const EMPTY_CONFIG: RuntimeConfig = { cartoApiKey: '' };

/**
 * Reads a runtime config from parsed JSON. Anything that is not an object
 * with a string `cartoApiKey` counts as no key; whitespace is trimmed.
 */
export function parseRuntimeConfig(json: unknown): RuntimeConfig {
  if (typeof json !== 'object' || json === null || Array.isArray(json)) return EMPTY_CONFIG;
  const { cartoApiKey } = json as Record<string, unknown>;
  return { cartoApiKey: typeof cartoApiKey === 'string' ? cartoApiKey.trim() : '' };
}

/** URL of the runtime config file, relative to the app's base URL. */
export function configUrl(baseUrl: string, pageUrl: string): string {
  return new URL(`${baseUrl}config.json`, pageUrl).href;
}

export interface LoadConfigOptions {
  /** Defaults to `<BASE_URL>config.json` resolved against the page URL. */
  url?: string;
  signal?: AbortSignal;
  fetch?: typeof fetch;
}

/**
 * Fetches and parses the runtime config. A missing file, a failed request
 * or invalid JSON all give the empty config, so the app still starts (with
 * the keyless fallback basemap). An abort is passed on to the caller.
 */
export async function loadRuntimeConfig(options: LoadConfigOptions = {}): Promise<RuntimeConfig> {
  const {
    url = configUrl(import.meta.env.BASE_URL, window.location.href),
    signal,
    fetch: fetchFn = fetch,
  } = options;
  try {
    const response = await fetchFn(url, { signal, cache: 'no-store' });
    if (!response.ok) return EMPTY_CONFIG;
    return parseRuntimeConfig(await response.json());
  } catch (error) {
    if (signal?.aborted) throw error;
    return EMPTY_CONFIG;
  }
}
