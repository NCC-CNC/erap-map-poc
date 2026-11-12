#!/usr/bin/env node
// Command line for the display config tool, called by bin/run.sh.
//
//   cli.mjs resolve LAYER CONFIG DATA OUT [TYPE]
//       Resolve LAYER's display config CONFIG (a .style.json) against its
//       normalised data DATA (GeoJSONSeq, read only for `breaks`) and write
//       the manifest `display` block to OUT. TYPE is the layer's LAYER_TYPE,
//       `vector` (default) or `raster`. DATA `-` means none: a raster
//       layer, or a vector layer whose config has no `breaks`.
//   cli.mjs check CONFIG...
//       Check configs without data (schema, legend, MapLibre validation);
//       `breaks` are resolved against placeholder values, and the layer
//       type is the one the config implies.
//   cli.mjs style MANIFEST OUT
//       Write the combined MapLibre style of every enabled layer in
//       MANIFEST that has a `display` block to OUT, drawn in display order,
//       with the opening view from the manifest's `map`.
//   cli.mjs layers MAP_CONFIG LAYERS_DIR OUT_DIR
//       Resolve the layer configs in LAYERS_DIR and the local map config
//       MAP_CONFIG (`-` for none; ADR 0009) into the effective layer set:
//       OUT_DIR/layers.json, plus a <layer>.env and <layer>.style.json in
//       OUT_DIR for each layer the map config defines or changes. See
//       layersCommand.
//
// Problems go to stderr, one per line; the exit status is 1 on any problem
// and 2 for a usage error.

import { createHash } from 'node:crypto';
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import {
  DisplayError,
  attributeValues,
  buildStyle,
  drawOrder,
  resolveDisplay,
  styleProblems,
} from './display.mjs';
import { resolveLayers, validateMapConfig } from './mapconfig.mjs';

/** Writes text through a temp file and a rename, like the rest of the pipeline. */
function writeText(path, text) {
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, text);
  renameSync(tmp, path);
}

function writeJson(path, value) {
  writeText(path, `${JSON.stringify(value, null, 2)}\n`);
}

function readJson(path, what) {
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch {
    throw new DisplayError([`cannot read ${what} ${path}`]);
  }
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new DisplayError([`${what} ${path} is not valid JSON: ${error.message}`]);
  }
}

function resolveCommand([layer, config, data, out, type = 'vector']) {
  if (!out || !['vector', 'raster'].includes(type)) return usage();
  const parsed = readJson(config, 'display config');
  let text;
  // `-`: no data, so a config with `breaks` is reported, not a crash.
  const valuesOf =
    data === '-'
      ? undefined
      : (attribute) => {
          text ??= readFileSync(data, 'utf8');
          return attributeValues(text, attribute);
        };
  writeJson(out, resolveDisplay(layer, parsed, valuesOf, type));
  return 0;
}

function checkCommand(configs) {
  if (configs.length === 0) return usage();
  let failed = 0;
  for (const config of configs) {
    const layer = basename(config).replace(/\.style\.json$/, '');
    try {
      // Placeholder data: 0 to 99, enough distinct values for any breaks.
      resolveDisplay(layer, readJson(config, 'display config'), () =>
        Array.from({ length: 100 }, (_, i) => i),
      );
      console.log(`${config}: ok`);
    } catch (error) {
      if (!(error instanceof DisplayError)) throw error;
      failed++;
      for (const p of error.problems) console.error(`${config}: ${p}`);
    }
  }
  return failed ? 1 : 0;
}

function styleCommand([manifest, out]) {
  if (!out) return usage();
  const parsed = readJson(manifest, 'manifest');
  const entries = (parsed.layers ?? []).filter((e) => e.display && e.enabled !== false);
  const style = buildStyle(drawOrder(entries), parsed.map ?? {});
  const problems = styleProblems(style);
  if (problems.length) throw new DisplayError(problems.map((p) => `MapLibre style: ${p}`));
  writeJson(out, style);
  return 0;
}

const sha256 = (text) => createHash('sha256').update(text).digest('hex');

/**
 * The layer configs in DIR: each <name>.env with its <name>.style.json.
 * `style` is null when the .style.json is missing and undefined when it is
 * not valid JSON (the build reports that).
 */
function layerConfigs(dir, origin) {
  return readdirSync(dir)
    .filter((f) => f.endsWith('.env'))
    .sort()
    .map((f) => {
      const name = f.slice(0, -'.env'.length);
      const envPath = join(dir, f);
      const stylePath = join(dir, `${name}.style.json`);
      let style = null;
      let styleText = null;
      if (existsSync(stylePath)) {
        styleText = readFileSync(stylePath, 'utf8');
        try {
          style = JSON.parse(styleText);
        } catch {
          style = undefined;
        }
      }
      const envText = readFileSync(envPath, 'utf8');
      return { name, origin, envPath, envText, stylePath, style, styleText };
    });
}

/** Problems of a DisplayError, each prefixed with `where: `. */
function prefixed(where, fn) {
  try {
    return fn();
  } catch (error) {
    if (!(error instanceof DisplayError)) throw error;
    throw new DisplayError(error.problems.map((p) => `${where}: ${p}`));
  }
}

/**
 * The `layers` command. Writes OUT_DIR/layers.json:
 *
 *   { "config": "/repo/map.config.json" or null, "map": {...} or null,
 *     "layers": [ { "name", "origin": "committed" | "local" | "config",
 *       "enabled", "env", "style", "envSource", "styleSource",
 *       "envSha256", "styleSha256", "overrides" } ] }
 *
 * `env` and `style` are the files a build reads: the source files, or the
 * ones written to OUT_DIR when the map config defines or changes the
 * layer. `envSource` and `styleSource` are the source files (null for a
 * layer defined in the map config). The hashes are of the content of `env`
 * and `style` (null for a missing .style.json), so --status sees a change
 * the map config makes.
 */
function layersCommand([configPath, layersDir, outDir]) {
  if (!outDir) return usage();
  let config = null;
  if (configPath !== '-') {
    config = readJson(configPath, 'map config');
    prefixed(configPath, () => validateMapConfig(config));
  }

  const found = existsSync(layersDir) ? layerConfigs(layersDir, 'committed') : [];
  const missing = [];
  for (const dir of config?.layerDirs ?? []) {
    const path = resolve(dirname(configPath), dir);
    if (existsSync(path) && statSync(path).isDirectory()) found.push(...layerConfigs(path, 'local'));
    else missing.push(`${configPath}: layerDirs: folder not found: ${dir} (${path})`);
  }
  if (missing.length) throw new DisplayError(missing);

  const resolved = prefixed(configPath, () => resolveLayers(config, found));

  mkdirSync(outDir, { recursive: true });
  const layers = resolved.layers.map((layer) => {
    const source = found.find((f) => f.envPath === layer.envSource);
    let env = layer.envSource;
    let envText = source?.envText;
    if (layer.envText !== null) {
      env = join(outDir, `${layer.name}.env`);
      envText = layer.envText;
      writeText(env, envText);
    }
    let style = layer.styleSource;
    let styleText = source?.styleText ?? null;
    if (layer.style !== null) {
      style = join(outDir, `${layer.name}.style.json`);
      styleText = `${JSON.stringify(layer.style, null, 2)}\n`;
      writeText(style, styleText);
    }
    return {
      name: layer.name,
      origin: layer.origin,
      enabled: layer.enabled,
      env,
      style,
      envSource: layer.envSource,
      styleSource: layer.styleSource,
      envSha256: sha256(envText),
      styleSha256: styleText === null ? null : sha256(styleText),
      overrides: layer.overrides,
    };
  });
  writeJson(join(outDir, 'layers.json'), {
    config: config ? configPath : null,
    map: resolved.map,
    layers,
  });
  return 0;
}

function usage() {
  console.error(
    'usage: cli.mjs resolve LAYER CONFIG DATA OUT [vector|raster] | check CONFIG... | style MANIFEST OUT | layers MAP_CONFIG LAYERS_DIR OUT_DIR',
  );
  return 2;
}

const [command, ...args] = process.argv.slice(2);
const commands = {
  resolve: resolveCommand,
  check: checkCommand,
  style: styleCommand,
  layers: layersCommand,
};

try {
  process.exitCode = commands[command] ? commands[command](args) : usage();
} catch (error) {
  if (!(error instanceof DisplayError)) throw error;
  for (const p of error.problems) console.error(p);
  process.exitCode = 1;
}
