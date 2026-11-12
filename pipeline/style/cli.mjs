#!/usr/bin/env node
// Command line for the display config tool, called by bin/run.sh.
//
//   cli.mjs resolve LAYER CONFIG DATA OUT [TYPE]
//       Resolve LAYER's display config CONFIG (a .style.json) against its
//       normalised data DATA (GeoJSONSeq, read only for `breaks`) and write
//       the manifest `display` block to OUT. TYPE is the layer's LAYER_TYPE,
//       `vector` (default) or `raster`; a raster layer has no DATA (pass -).
//   cli.mjs check CONFIG...
//       Check configs without data (schema, legend, MapLibre validation);
//       `breaks` are resolved against placeholder values, and the layer
//       type is the one the config implies.
//   cli.mjs style MANIFEST OUT
//       Write the combined MapLibre style of every layer in MANIFEST that
//       has a `display` block to OUT, drawn in display order.
//
// Problems go to stderr, one per line; the exit status is 1 on any problem
// and 2 for a usage error.

import { readFileSync, renameSync, writeFileSync } from 'node:fs';
import { basename } from 'node:path';
import {
  DisplayError,
  attributeValues,
  buildStyle,
  drawOrder,
  resolveDisplay,
  styleProblems,
} from './display.mjs';

/** Writes JSON through a temp file and a rename, like the rest of the pipeline. */
function writeJson(path, value) {
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`);
  renameSync(tmp, path);
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
  const valuesOf = (attribute) => {
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
  const entries = (parsed.layers ?? []).filter((e) => e.display);
  const style = buildStyle(drawOrder(entries));
  const problems = styleProblems(style);
  if (problems.length) throw new DisplayError(problems.map((p) => `MapLibre style: ${p}`));
  writeJson(out, style);
  return 0;
}

function usage() {
  console.error(
    'usage: cli.mjs resolve LAYER CONFIG DATA OUT [vector|raster] | check CONFIG... | style MANIFEST OUT',
  );
  return 2;
}

const [command, ...args] = process.argv.slice(2);
const commands = { resolve: resolveCommand, check: checkCommand, style: styleCommand };

try {
  process.exitCode = commands[command] ? commands[command](args) : usage();
} catch (error) {
  if (!(error instanceof DisplayError)) throw error;
  for (const p of error.problems) console.error(p);
  process.exitCode = 1;
}
