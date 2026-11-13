// The local map config (ADR 0009): map.config.json, git-ignored, on top of
// the committed layer configs in pipeline/layers/. It selects the layers,
// overrides their source, settings and display, adds local-only layers and
// sets the map's opening view. The schema is
// pipeline/schema/map-config.schema.json.
//
// Pure functions, like display.mjs; cli.mjs reads the files and writes the
// resolved layer set.

import { isAbsolute, resolve } from 'node:path';
import { DisplayError, resolveDisplay, schemaProblems, schemaValidators } from './display.mjs';

/** Override keys that change the tiles: the layer must be rebuilt. */
export const BUILD_KEYS = Object.freeze(['input', 'env', 'calculated', 'rules']);

/** Override keys that change only the display: `--style-only` is enough. */
export const DISPLAY_KEYS = Object.freeze(['title', 'order', 'defaultVisible', 'style']);

/** Checks a map config against its JSON Schema; throws DisplayError. */
export function validateMapConfig(config) {
  const { mapConfig: validate } = schemaValidators();
  if (!validate(config)) throw new DisplayError(schemaProblems(validate.errors));
}

const isObject = (v) => typeof v === 'object' && v !== null && !Array.isArray(v);

/**
 * JSON merge patch (RFC 7396): `patch` over `target`. Objects merge key by
 * key, `null` removes a key, anything else (lists included) replaces.
 */
export function mergePatch(target, patch) {
  if (!isObject(patch)) return structuredClone(patch);
  const result = isObject(target) ? structuredClone(target) : {};
  for (const [key, value] of Object.entries(patch)) {
    if (value === null) delete result[key];
    else result[key] = mergePatch(result[key], value);
  }
  return result;
}

/** A word in single quotes for bash, safe whatever it holds. */
export function shellQuote(text) {
  return `'${String(text).replaceAll("'", "'\\''")}'`;
}

/** One bash assignment of a LAYER_* setting: text, number or list of texts. */
export function envAssignment(key, value) {
  if (!/^LAYER_[A-Z][A-Z0-9_]*$/.test(key)) throw new DisplayError([`invalid setting name ${key}`]);
  if (Array.isArray(value)) return `${key}=(${value.map(shellQuote).join(' ')})`;
  return `${key}=${shellQuote(value)}`;
}

/**
 * The settings of an override as bash lines: `input` first, as LAYER_INPUT,
 * then `env`, then `calculated` (ADR 0011), appended to LAYER_CALCULATED as
 * `name=expression` entries (a later entry for a name replaces the
 * layer's, an empty one, from null, removes it), and `rules`, as
 * LAYER_RULES: the rules table's path relative to `configDir` (the map
 * config's folder), made absolute, or empty (null) for none.
 */
export function overrideEnvLines(override = {}, configDir = '.') {
  const lines = [];
  if (override.input !== undefined) lines.push(envAssignment('LAYER_INPUT', override.input));
  for (const [key, value] of Object.entries(override.env ?? {})) {
    lines.push(envAssignment(key, value));
  }
  const calculated = Object.entries(override.calculated ?? {});
  if (calculated.length) {
    const entries = calculated.map(([name, expr]) => shellQuote(`${name}=${expr ?? ''}`));
    lines.push(`LAYER_CALCULATED+=(${entries.join(' ')})`);
  }
  if (override.rules !== undefined) {
    const path = override.rules === null ? '' : override.rules;
    lines.push(envAssignment('LAYER_RULES', path && !isAbsolute(path) ? resolve(configDir, path) : path));
  }
  return lines;
}

/** The part of an override with the given keys, or null if none is set. */
export function pick(override, keys) {
  const part = Object.fromEntries(
    keys.filter((k) => override?.[k] !== undefined).map((k) => [k, override[k]]),
  );
  return Object.keys(part).length ? part : null;
}

/** A display config with an override's display keys applied. */
export function applyDisplayOverride(style, override = {}) {
  let result = override.style ? mergePatch(style, override.style) : structuredClone(style);
  for (const key of ['title', 'order', 'defaultVisible']) {
    if (override[key] !== undefined) result = { ...result, [key]: override[key] };
  }
  return result;
}

/** Checks a resolved display config as `cli.mjs check` does; throws DisplayError. */
function checkDisplay(name, style) {
  // Placeholder data, 0 to 99, for `breaks`; the real ones come at build time.
  resolveDisplay(name, style, () => Array.from({ length: 100 }, (_, i) => i));
}

/**
 * Resolves the committed layers and the map config into the effective layer
 * set. Every problem is collected and thrown together as a DisplayError.
 *
 * @param {object|null} config the parsed map config, or null for none.
 * @param {Array<{name: string, origin: 'committed'|'local', envPath: string,
 *   envText: string, stylePath: string, style: object|null|undefined}>} found
 *   the layer configs found in the committed layers dir and in the config's
 *   `layerDirs` (`style` null when the .style.json is missing, undefined
 *   when it is not valid JSON, which the build reports).
 * @param {string} [configDir] the map config's folder, for the relative
 *   rules table paths in its overrides.
 * @returns {{map: object|null, layers: Array<object>}} each layer with
 *   `name`, `origin` (committed, local or config), `enabled`, `envSource`
 *   and `styleSource` (the files it comes from; null for a layer defined
 *   in the config), `envText` and `style` (the effective settings and
 *   display config, or null when they are the source files as they are)
 *   and `overrides` (as applied, or null), in name order.
 */
export function resolveLayers(config, found, configDir = '.') {
  const problems = [];
  const layers = new Map();
  for (const f of found) {
    const other = layers.get(f.name);
    if (other) {
      problems.push(
        `layer ${f.name} is in both ${other.envSource} and ${f.envPath}: a local-only layer needs its own name (use "overrides" to change a committed layer)`,
      );
      continue;
    }
    layers.set(f.name, {
      name: f.name,
      origin: f.origin,
      enabled: true,
      envSource: f.envPath,
      styleSource: f.stylePath,
      sourceStyle: f.style,
      envText: null,
      style: null,
      overrides: null,
    });
  }
  if (!config) return finish();

  for (const [name, def] of Object.entries(config.localLayers ?? {})) {
    if (layers.has(name)) {
      problems.push(
        `localLayers.${name}: layer ${name} already exists in ${layers.get(name).envSource}: use "overrides" to change it, or another name`,
      );
      continue;
    }
    const envText = [
      `# Layer ${name}, from localLayers in the map config.`,
      ...Object.entries(def.env).map(([k, v]) => envAssignment(k, v)),
      '',
    ].join('\n');
    layers.set(name, {
      name,
      origin: 'config',
      enabled: true,
      envSource: null,
      styleSource: null,
      sourceStyle: def.style,
      envText,
      style: def.style,
      overrides: null,
    });
  }

  const known = () => [...layers.keys()].sort().join(', ') || 'none';
  const unknown = (where, name) => {
    if (layers.has(name)) return false;
    problems.push(`${where}: no layer named ${name} (layers: ${known()})`);
    return true;
  };

  if (config.enabled) {
    const wanted = new Set(config.enabled.filter((n) => !unknown('enabled', n)));
    for (const layer of layers.values()) layer.enabled = wanted.has(layer.name);
  }
  for (const name of config.disabled ?? []) {
    if (!unknown('disabled', name)) layers.get(name).enabled = false;
  }

  for (const [name, override] of Object.entries(config.overrides ?? {})) {
    if (unknown('overrides', name)) continue;
    const layer = layers.get(name);
    layer.overrides = override;
    const lines = overrideEnvLines(override, configDir);
    if (lines.length) {
      const base = layer.envText ?? found.find((f) => f.name === name).envText;
      layer.envText = [
        base.replace(/\n*$/, ''),
        '',
        '# Overrides from the map config.',
        ...lines,
        '',
      ].join('\n');
    }
    if (pick(override, DISPLAY_KEYS)) {
      if (layer.sourceStyle === null) {
        problems.push(`overrides.${name}: ${name} has no .style.json to apply the display overrides to`);
      } else if (layer.sourceStyle === undefined) {
        problems.push(`overrides.${name}: ${layer.styleSource} is not valid JSON`);
      } else {
        layer.style = applyDisplayOverride(layer.sourceStyle, override);
      }
    }
  }

  // The display configs the map config made or changed are checked now, so
  // a bad patch fails before anything is built.
  for (const layer of layers.values()) {
    if (!layer.style) continue;
    try {
      checkDisplay(layer.name, layer.style);
    } catch (error) {
      if (!(error instanceof DisplayError)) throw error;
      const where = layer.origin === 'config' ? `localLayers.${layer.name}.style` : `overrides.${layer.name}`;
      for (const p of error.problems) problems.push(`${where}: ${p}`);
    }
  }
  return finish();

  function finish() {
    if (problems.length) throw new DisplayError(problems);
    return {
      map: config?.map ?? null,
      layers: [...layers.values()]
        .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
        .map(({ sourceStyle: _unused, ...layer }) => layer),
    };
  }
}
