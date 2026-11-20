/**
 * Generates `src/layers/layer.generated.ts`, the TypeScript types of a
 * layer file, from its JSON Schema, `pipeline/schema/layer.schema.json`
 * (design note 04): the app reads the same shapes from style.json's
 * `erap:layers` metadata. `layerTypes.test.ts` checks the committed file is
 * up to date. After a schema change, write it again with
 * `npm run layer-types` (in web/).
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { compile, type JSONSchema } from 'json-schema-to-typescript';

export const SCHEMA_PATH = fileURLToPath(new URL('../../pipeline/schema/layer.schema.json', import.meta.url));
export const TYPES_PATH = fileURLToPath(new URL('../src/layers/layer.generated.ts', import.meta.url));

const BANNER = `/* Generated from pipeline/schema/layer.schema.json by web/vite/layerTypes.ts
 * (npm run layer-types). Do not edit by hand. */`;

type Schema = Record<string, unknown>;

const isSchema = (v: unknown): v is Schema => typeof v === 'object' && v !== null && !Array.isArray(v);

/** Keywords that only constrain values further, with no TypeScript form. */
const CONSTRAINTS = ['if', 'then', 'else', 'not', 'prefixItems'];

/**
 * One part of the schema in the form the generator turns into plain
 * types: an `allOf` of `if`/`then` pairs that each pick a `$ref` (a block
 * by its `type`) becomes a union of those; other `allOf`, `anyOf` of
 * `required` lists and the keywords in CONSTRAINTS are dropped; a `$ref`
 * keeps no sibling keywords, so it names the shared type rather than a
 * copy of it.
 */
function simplify(node: unknown): unknown {
  if (Array.isArray(node)) return node.map(simplify);
  if (!isSchema(node)) return node;
  if (typeof node.$ref === 'string') return { $ref: node.$ref };
  const allOf = Array.isArray(node.allOf) ? node.allOf.filter(isSchema) : [];
  const picks = allOf.map((part) => (isSchema(part.then) ? part.then.$ref : undefined));
  if (picks.length && picks.every((ref) => typeof ref === 'string')) {
    return { description: node.description, oneOf: picks.map(($ref) => ({ $ref })) };
  }
  const out: Schema = {};
  for (const [key, value] of Object.entries(node)) {
    if (key === 'allOf' || CONSTRAINTS.includes(key)) continue;
    if (key === 'anyOf' && Array.isArray(value) && value.every((v) => isSchema(v) && Object.keys(v).join() === 'required')) {
      continue;
    }
    // Property names and $defs keys are names, not schemas: simplify their values.
    out[key] =
      (key === 'properties' || key === '$defs') && isSchema(value)
        ? Object.fromEntries(Object.entries(value).map(([k, v]) => [k, simplify(v)]))
        : simplify(value);
  }
  return out;
}

/**
 * The schema to generate from: simplified (see `simplify`), with a
 * `title` on each `$defs` entry so each becomes a type of that name.
 */
function forTypes(schema: Schema): Schema {
  const simple = simplify(schema) as Schema;
  const defs = Object.fromEntries(
    Object.entries(simple.$defs as Record<string, Schema>).map(([name, def]) => [
      name,
      { ...def, title: name.charAt(0).toUpperCase() + name.slice(1) },
    ]),
  );
  return { ...simple, title: 'LayerFile', $defs: defs };
}

/** The TypeScript source for the layer file schema. */
export async function layerTypes(schema: Schema): Promise<string> {
  return compile(forTypes(schema) as JSONSchema, 'LayerFile', {
    bannerComment: BANNER,
    ignoreMinAndMaxItems: true,
    unreachableDefinitions: true,
    format: true,
    style: { singleQuote: true, printWidth: 110 },
  });
}

/** The types from the schema in the repo. */
export async function layerTypesFromRepo(): Promise<string> {
  return layerTypes(JSON.parse(readFileSync(SCHEMA_PATH, 'utf8')) as Schema);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  writeFileSync(TYPES_PATH, await layerTypesFromRepo());
  console.log(`wrote ${TYPES_PATH}`);
}
