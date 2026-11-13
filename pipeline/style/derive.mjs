// Calculated fields and action recommendation rules (ADR 0011): attributes
// the pipeline derives from a vector layer's own attributes at build time,
// so the web app only displays tile attributes.
//
// A calculated field (LAYER_CALCULATED in a <layer>.env, `name=expression`)
// and an action's condition (in a rules table, pipeline/layers/<table>.rules.json,
// schema pipeline/schema/action-rules.schema.json) are expressions in a
// small, SQL-like language. Each is parsed here, checked (known attributes,
// allowed functions, argument counts) and written back out as one SQLite
// expression with every attribute name quoted, every operation in
// parentheses and nothing else: no statements, subqueries, comments or
// functions outside the list below. The pipeline evaluates the result with
// GDAL's SQLite SQL dialect (`ogr2ogr -dialect SQLite`, lib/derive.sh).
//
// Pure functions, like display.mjs; cli.mjs does the I/O.

import { DisplayError, schemaProblems, schemaValidators } from './display.mjs';

/** Longest expression accepted, in characters. */
export const MAX_EXPRESSION_LENGTH = 2000;

/** Deepest nesting accepted (parentheses, operators, calls). */
const MAX_DEPTH = 64;

/** Allowed functions, by lower case name: [fewest, most] arguments. */
export const FUNCTIONS = Object.freeze({
  abs: [1, 1],
  round: [1, 2],
  // min and max with one argument would be SQL aggregates: two or more.
  min: [2, Infinity],
  max: [2, Infinity],
  coalesce: [2, Infinity],
  ifnull: [2, 2],
  nullif: [2, 2],
  iif: [3, 3],
  length: [1, 1],
  lower: [1, 1],
  upper: [1, 1],
  substr: [2, 3],
  trim: [1, 1],
  replace: [3, 3],
  instr: [2, 2],
});

/** Types for CAST(x AS type). */
const CAST_TYPES = new Set(['integer', 'real', 'text', 'numeric']);

/** Words of the language; an attribute with one of these names needs "quotes". */
const KEYWORDS = new Set([
  'and',
  'or',
  'not',
  'is',
  'null',
  'true',
  'false',
  'case',
  'when',
  'then',
  'else',
  'end',
  'between',
  'in',
  'like',
  'cast',
  'as',
]);

/** Attribute and calculated field names: as in the tiles, lower case. */
export const NAME_PATTERN = /^[a-z][a-z0-9_]{0,62}$/;

/** An expression problem; `message` is shown after the field or rule. */
export class ExpressionError extends Error {}

// ---------------------------------------------------------------------------
// Tokens

const TOKEN =
  /\s+|((?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)|('(?:[^']|'')*')|("(?:[^"]|"")*")|([A-Za-z_][A-Za-z0-9_]*)|(\|\||<=|>=|<>|!=|==|[-+*/%<>=(),])/y;

/**
 * The tokens of `text`: {t: 'num'|'str'|'name'|'qname'|'op'|'end', v, at}.
 * `qname` is a "quoted" attribute name; `at` is the character position.
 */
export function tokenize(text) {
  if (typeof text !== 'string' || !text.trim()) throw new ExpressionError('is empty');
  if (text.length > MAX_EXPRESSION_LENGTH) {
    throw new ExpressionError(`is longer than ${MAX_EXPRESSION_LENGTH} characters`);
  }
  const tokens = [];
  TOKEN.lastIndex = 0;
  while (TOKEN.lastIndex < text.length) {
    const at = TOKEN.lastIndex;
    if (text.startsWith('--', at) || text.startsWith('/*', at)) {
      throw new ExpressionError(`has a comment at character ${at + 1} (-- and /* are not allowed)`);
    }
    const m = TOKEN.exec(text);
    if (!m) {
      const ch = text[at];
      if (ch === "'" || ch === '"') {
        throw new ExpressionError(`has an unclosed ${ch} at character ${at + 1}`);
      }
      const hint = ch === ';' ? ': one expression only, no statements' : '';
      throw new ExpressionError(`has an unexpected "${ch}" at character ${at + 1}${hint}`);
    }
    if (m[1] !== undefined) tokens.push({ t: 'num', v: m[1], at });
    else if (m[2] !== undefined) tokens.push({ t: 'str', v: m[2].slice(1, -1).replaceAll("''", "'"), at });
    else if (m[3] !== undefined) tokens.push({ t: 'qname', v: m[3].slice(1, -1).replaceAll('""', '"'), at });
    else if (m[4] !== undefined) tokens.push({ t: 'name', v: m[4], at });
    else if (m[5] !== undefined) tokens.push({ t: 'op', v: m[5], at });
  }
  tokens.push({ t: 'end', v: '', at: text.length });
  return tokens;
}

// ---------------------------------------------------------------------------
// Parser: precedence climbing over SQLite's operator precedence, lowest
// first: OR; AND; NOT; = == != <> IS IN LIKE BETWEEN; < <= > >=; + -;
// * / %; ||; unary - and +.

const BINARY = {
  or: 1,
  and: 2,
  '=': 4,
  '==': 4,
  '!=': 4,
  '<>': 4,
  '<': 5,
  '<=': 5,
  '>': 5,
  '>=': 5,
  '+': 7,
  '-': 7,
  '*': 8,
  '/': 8,
  '%': 8,
  '||': 9,
};
const NOT_BP = 3;
const EQUALITY_BP = 4;
const UNARY_BP = 10;

/** Parses an expression into a tree; throws ExpressionError. */
export function parseExpression(text) {
  const tokens = tokenize(text);
  let pos = 0;
  let depth = 0;

  const peek = (o = 0) => tokens[pos + o];
  const word = (tok) => (tok.t === 'name' ? tok.v.toLowerCase() : null);
  const isWord = (tok, w) => word(tok) === w;
  const isOp = (tok, op) => tok.t === 'op' && tok.v === op;
  const where = (tok) => (tok.t === 'end' ? 'at the end' : `at character ${tok.at + 1}`);
  const show = (tok) => (tok.t === 'end' ? 'the end' : tok.t === 'str' ? `'${tok.v}'` : `"${tok.v}"`);
  const fail = (what, tok = peek()) => {
    throw new ExpressionError(`expected ${what} ${where(tok)}, found ${show(tok)}`);
  };
  const expectOp = (op) => {
    if (!isOp(peek(), op)) fail(`"${op}"`);
    pos++;
  };
  const expectWord = (w) => {
    if (!isWord(peek(), w)) fail(w.toUpperCase());
    pos++;
  };

  function expression(minBp = 0) {
    if (++depth > MAX_DEPTH) throw new ExpressionError(`is nested more than ${MAX_DEPTH} deep`);
    let left = prefix();
    for (;;) {
      const tok = peek();
      const w = word(tok);
      if (w === 'not' && ['in', 'like', 'between'].includes(word(peek(1)))) {
        if (EQUALITY_BP <= minBp) break;
        pos++;
        left = postfix(left, true);
        continue;
      }
      if (w === 'is' || w === 'in' || w === 'like' || w === 'between') {
        if (EQUALITY_BP <= minBp) break;
        left = postfix(left, false);
        continue;
      }
      const op = tok.t === 'op' ? tok.v : w === 'and' || w === 'or' ? w : null;
      const bp = op ? BINARY[op] : undefined;
      if (bp === undefined || bp <= minBp) break;
      pos++;
      left = { k: 'bin', op, l: left, r: expression(bp) };
    }
    depth--;
    return left;
  }

  // IS [NOT] x, [NOT] IN (...), [NOT] LIKE x, [NOT] BETWEEN x AND y.
  function postfix(left, not) {
    const w = word(peek());
    pos++;
    if (w === 'is') {
      let isNot = false;
      if (isWord(peek(), 'not')) {
        isNot = true;
        pos++;
      }
      return { k: 'is', not: isNot, l: left, r: expression(EQUALITY_BP) };
    }
    if (w === 'in') {
      expectOp('(');
      const items = [expression()];
      while (isOp(peek(), ',')) {
        pos++;
        items.push(expression());
      }
      expectOp(')');
      return { k: 'in', not, e: left, items };
    }
    if (w === 'like') return { k: 'like', not, e: left, pattern: expression(EQUALITY_BP) };
    const lo = expression(EQUALITY_BP);
    expectWord('and');
    const hi = expression(EQUALITY_BP);
    return { k: 'between', not, e: left, lo, hi };
  }

  function prefix() {
    const tok = peek();
    if (tok.t === 'num') {
      pos++;
      return { k: 'num', v: tok.v };
    }
    if (tok.t === 'str') {
      pos++;
      return { k: 'str', v: tok.v };
    }
    if (tok.t === 'qname') {
      pos++;
      return { k: 'attr', name: tok.v, at: tok.at };
    }
    if (isOp(tok, '(')) {
      pos++;
      const e = expression();
      expectOp(')');
      return e;
    }
    if (isOp(tok, '-') || isOp(tok, '+')) {
      pos++;
      return { k: 'unary', op: tok.v, e: expression(UNARY_BP) };
    }
    if (tok.t !== 'name') fail('a value, attribute or "("');

    const w = word(tok);
    if (w === 'not') {
      pos++;
      return { k: 'unary', op: 'NOT', e: expression(NOT_BP) };
    }
    if (w === 'null') {
      pos++;
      return { k: 'null' };
    }
    if (w === 'true' || w === 'false') {
      pos++;
      return { k: 'num', v: w === 'true' ? '1' : '0' };
    }
    if (w === 'case') return caseExpression();
    if (w === 'cast') {
      pos++;
      expectOp('(');
      const e = expression();
      expectWord('as');
      const type = word(peek());
      if (!CAST_TYPES.has(type)) fail(`a type (${[...CAST_TYPES].join(', ')})`);
      pos++;
      expectOp(')');
      return { k: 'cast', e, type };
    }
    if (isOp(peek(1), '(')) return call();
    if (KEYWORDS.has(w)) fail('a value, attribute or "("');
    pos++;
    return { k: 'attr', name: tok.v, at: tok.at };
  }

  function call() {
    const tok = peek();
    const name = tok.v.toLowerCase();
    const arity = FUNCTIONS[name];
    if (!arity) {
      throw new ExpressionError(
        `uses the function ${tok.v} at character ${tok.at + 1}, which is not allowed (functions: ${Object.keys(FUNCTIONS).join(', ')})`,
      );
    }
    pos += 2;
    const args = [];
    if (!isOp(peek(), ')')) {
      args.push(expression());
      while (isOp(peek(), ',')) {
        pos++;
        args.push(expression());
      }
    }
    expectOp(')');
    const [lo, hi] = arity;
    if (args.length < lo || args.length > hi) {
      const want = lo === hi ? `${lo}` : hi === Infinity ? `${lo} or more` : `${lo} to ${hi}`;
      throw new ExpressionError(
        `calls ${tok.v} with ${args.length} argument(s) at character ${tok.at + 1}; it takes ${want}`,
      );
    }
    return { k: 'call', fn: name, args };
  }

  function caseExpression() {
    pos++;
    let base = null;
    if (!isWord(peek(), 'when')) base = expression();
    const whens = [];
    while (isWord(peek(), 'when')) {
      pos++;
      const c = expression();
      expectWord('then');
      whens.push([c, expression()]);
    }
    if (whens.length === 0) fail('WHEN');
    let otherwise = null;
    if (isWord(peek(), 'else')) {
      pos++;
      otherwise = expression();
    }
    expectWord('end');
    return { k: 'case', base, whens, otherwise };
  }

  const tree = expression();
  if (peek().t !== 'end') fail('an operator or the end');
  return tree;
}

/** The attribute names an expression tree uses, in order of first use. */
export function attributesOf(tree) {
  const names = [];
  (function walk(node) {
    if (!node || typeof node !== 'object') return;
    if (node.k === 'attr') {
      if (!names.includes(node.name)) names.push(node.name);
      return;
    }
    for (const value of Object.values(node)) {
      if (Array.isArray(value)) value.forEach((v) => (Array.isArray(v) ? v.forEach(walk) : walk(v)));
      else walk(value);
    }
  })(tree);
  return names;
}

/** A name in double quotes for SQL. */
export function quoteName(name) {
  return `"${String(name).replaceAll('"', '""')}"`;
}

/** A text in single quotes for SQL. */
export function quoteText(text) {
  return `'${String(text).replaceAll("'", "''")}'`;
}

/**
 * SQLite text of an expression tree. `attr(name)` gives the SQL for an
 * attribute (a quoted column, or a calculated field's own SQL). Every
 * operation is in parentheses, so SQLite reads it as the tree says.
 * Division is always decimal (`7 / 2` is 3.5, not SQLite's integer 3).
 */
export function toSql(node, attr) {
  const sql = (n) => toSql(n, attr);
  switch (node.k) {
    case 'num':
      return node.v;
    case 'str':
      return quoteText(node.v);
    case 'null':
      return 'NULL';
    case 'attr':
      return attr(node.name);
    case 'unary':
      return `(${node.op} ${sql(node.e)})`;
    case 'bin': {
      const op = { '==': '=', '!=': '<>', and: 'AND', or: 'OR' }[node.op] ?? node.op;
      if (op === '/') return `((${sql(node.l)} * 1.0) / ${sql(node.r)})`;
      return `(${sql(node.l)} ${op} ${sql(node.r)})`;
    }
    case 'is':
      return `(${sql(node.l)} IS ${node.not ? 'NOT ' : ''}${sql(node.r)})`;
    case 'in':
      return `(${sql(node.e)} ${node.not ? 'NOT ' : ''}IN (${node.items.map(sql).join(', ')}))`;
    case 'like':
      return `(${sql(node.e)} ${node.not ? 'NOT ' : ''}LIKE ${sql(node.pattern)})`;
    case 'between':
      return `(${sql(node.e)} ${node.not ? 'NOT ' : ''}BETWEEN ${sql(node.lo)} AND ${sql(node.hi)})`;
    case 'call':
      return `${node.fn.toUpperCase()}(${node.args.map(sql).join(', ')})`;
    case 'cast':
      return `CAST(${sql(node.e)} AS ${node.type.toUpperCase()})`;
    case 'case': {
      const parts = ['CASE'];
      if (node.base) parts.push(sql(node.base));
      for (const [c, v] of node.whens) parts.push(`WHEN ${sql(c)} THEN ${sql(v)}`);
      if (node.otherwise) parts.push(`ELSE ${sql(node.otherwise)}`);
      parts.push('END');
      return `(${parts.join(' ')})`;
    }
    default:
      throw new Error(`unknown node ${node.k}`);
  }
}

// ---------------------------------------------------------------------------
// Calculated fields

/**
 * The calculated fields from LAYER_CALCULATED entries, `name=expression`,
 * in order. A later entry for the same name replaces the earlier one (in
 * its place); an empty expression removes it, so the map config can add,
 * change and remove fields by appending entries.
 */
export function calculatedEntries(entries) {
  const problems = [];
  const fields = new Map();
  for (const [i, entry] of entries.entries()) {
    const eq = String(entry).indexOf('=');
    const name = eq < 0 ? String(entry) : entry.slice(0, eq).trim();
    if (eq < 0 || !NAME_PATTERN.test(name)) {
      problems.push(
        `LAYER_CALCULATED[${i}] "${entry}": write name=expression, the name in lower case letters, digits and _ (starting with a letter)`,
      );
      continue;
    }
    const expression = entry.slice(eq + 1).trim();
    if (expression) fields.set(name, expression);
    else fields.delete(name);
  }
  if (problems.length) throw new DisplayError(problems);
  return [...fields].map(([name, expression]) => ({ name, expression }));
}

/** Unknown attribute message, with a hint for a case mismatch. */
function unknownAttribute(name, known) {
  const close = known.find((k) => k.toLowerCase() === String(name).toLowerCase());
  const hint = close ? `; did you mean ${close}?` : '';
  return `uses the attribute ${name}, which the layer does not have${hint} (attributes: ${known.join(', ')})`;
}

// ---------------------------------------------------------------------------
// Rules tables

/** Checks a rules table: schema, unique ids, types and condition syntax. */
export function validateRulesTable(table) {
  const { rules: validate } = schemaValidators();
  if (!validate(table)) throw new DisplayError(schemaProblems(validate.errors));
  const problems = [];
  const types = new Set();
  for (const type of table.types) {
    if (types.has(type.id)) problems.push(`types: the id ${type.id} is used twice`);
    types.add(type.id);
  }
  const ids = new Set();
  for (const [i, action] of table.actions.entries()) {
    const where = `actions[${i}] (${action.id})`;
    if (ids.has(action.id)) problems.push(`${where}: the id ${action.id} is used twice`);
    ids.add(action.id);
    if (!types.has(action.type)) {
      problems.push(`${where}: type ${action.type} is not one of types (${[...types].join(', ')})`);
    }
    try {
      parseExpression(action.condition);
    } catch (error) {
      if (!(error instanceof ExpressionError)) throw error;
      problems.push(`${where}: condition ${error.message}`);
    }
  }
  if (problems.length) throw new DisplayError(problems);
}

/** Attribute names of an action and an action type. */
export const actionAttribute = (id) => `action_${id}`;
export const reasonAttribute = (id) => `action_${id}_reason`;
export const countAttribute = (type) => `actions_${type}_count`;

/** The per-feature text of a recommended action: its title and reason. */
export const reasonText = (action) => `${action.title}: ${action.reason}`;

// ---------------------------------------------------------------------------
// The plan

/**
 * Checks a layer's calculated fields and rules table against its attributes
 * and plans the SQL that adds them. Every problem is collected and thrown
 * together as a DisplayError.
 *
 * @param {object} options
 * @param {string[]} options.fields the layer's attributes (LAYER_FIELDS
 *   output names).
 * @param {string[]} options.calculated LAYER_CALCULATED entries.
 * @param {object|null} options.rules the parsed rules table, or null.
 * @param {string} [options.rulesFile] the table's file, for messages.
 * @param {string} options.table the SQL table (layer) name of the data.
 * @returns {{sql: string, attributes: string[], calculated: Array<object>,
 *   rules: object|null}} `sql` is the SQLite statement; `attributes` the
 *   names it adds, in order; `calculated` the fields with their
 *   expressions; `rules` the types and actions with their attribute names.
 */
export function derivePlan({ fields, calculated, rules, rulesFile = 'rules table', table }) {
  const problems = [];
  const known = [...fields];
  const calc = calculatedEntries(calculated);

  for (const { name } of calc) {
    if (fields.includes(name)) {
      problems.push(`calculated field ${name}: the layer already has an attribute ${name} (LAYER_FIELDS)`);
    }
  }

  // Parse each calculated field, then write its SQL with the calculated
  // fields it uses written out in place (in parentheses), so a field may
  // use another one, in any order, but not itself.
  const trees = new Map();
  for (const { name, expression } of calc) {
    try {
      trees.set(name, parseExpression(expression));
    } catch (error) {
      if (!(error instanceof ExpressionError)) throw error;
      problems.push(`calculated field ${name}: ${error.message}`);
    }
  }
  const allNames = [...known, ...calc.map((c) => c.name)];
  const sqlOf = new Map();
  const failed = new Set(calc.map((c) => c.name).filter((name) => !trees.has(name)));
  const hasProblem = (name) => new ExpressionError(`uses ${name}, which has a problem`);
  // The SQL of calculated field NAME, reached through STACK; a problem is
  // reported once, under the field that has it.
  function calcSql(name, stack) {
    if (sqlOf.has(name)) return sqlOf.get(name);
    if (failed.has(name)) throw hasProblem(name);
    if (stack.includes(name)) {
      throw new ExpressionError(`refers to itself through ${[...stack, name].join(' -> ')}`);
    }
    try {
      const sql = toSql(trees.get(name), (attr) => attrSql(attr, [...stack, name]));
      sqlOf.set(name, sql);
      return sql;
    } catch (error) {
      if (!(error instanceof ExpressionError)) throw error;
      failed.add(name);
      problems.push(`calculated field ${name}: ${error.message}`);
      throw hasProblem(name);
    }
  }
  function attrSql(attr, stack) {
    if (calc.some((c) => c.name === attr)) return `(${calcSql(attr, stack)})`;
    if (known.includes(attr)) return quoteName(attr);
    throw new ExpressionError(unknownAttribute(attr, allNames));
  }
  for (const { name } of calc) {
    try {
      calcSql(name, []);
    } catch (error) {
      if (!(error instanceof ExpressionError)) throw error;
    }
  }

  const columns = calc
    .filter(({ name }) => sqlOf.has(name) && !failed.has(name))
    .map(({ name }) => [name, sqlOf.get(name)]);

  let rulesPlan = null;
  if (rules) {
    try {
      validateRulesTable(rules);
    } catch (error) {
      if (!(error instanceof DisplayError)) throw error;
      for (const p of error.problems) problems.push(`${rulesFile}: ${p}`);
      rules = null;
    }
  }
  if (rules) {
    const taken = new Set(allNames);
    const add = (name, sql, where) => {
      if (taken.has(name)) problems.push(`${rulesFile}: ${where} would write ${name}, which the layer already has`);
      taken.add(name);
      columns.push([name, sql]);
    };
    const flags = new Map();
    for (const [i, action] of rules.actions.entries()) {
      const where = `actions[${i}] (${action.id})`;
      let cond;
      try {
        cond = toSql(parseExpression(action.condition), (attr) => attrSql(attr, []));
      } catch (error) {
        if (!(error instanceof ExpressionError)) throw error;
        problems.push(`${rulesFile}: ${where}: condition ${error.message}`);
        continue;
      }
      const flag = `(CASE WHEN ${cond} THEN 1 ELSE 0 END)`;
      flags.set(action.id, flag);
      add(actionAttribute(action.id), flag, where);
      add(reasonAttribute(action.id), `(CASE WHEN ${cond} THEN ${quoteText(reasonText(action))} END)`, where);
    }
    for (const type of rules.types) {
      const terms = rules.actions.filter((a) => a.type === type.id && flags.has(a.id)).map((a) => flags.get(a.id));
      add(countAttribute(type.id), terms.length ? `(${terms.join(' + ')})` : '0', `type ${type.id}`);
    }
    rulesPlan = {
      types: rules.types.map((t) => ({ id: t.id, label: t.label, attribute: countAttribute(t.id) })),
      actions: rules.actions.map((a) => ({
        id: a.id,
        type: a.type,
        title: a.title,
        condition: a.condition,
        attribute: actionAttribute(a.id),
        reason_attribute: reasonAttribute(a.id),
      })),
    };
  }

  if (problems.length) throw new DisplayError(problems);
  const select = columns.map(([name, sql]) => `${sql} AS ${quoteName(name)}`);
  return {
    sql: `SELECT *, ${select.join(', ')} FROM ${quoteName(table)}`,
    attributes: columns.map(([name]) => name),
    calculated: calc,
    rules: rulesPlan,
  };
}
