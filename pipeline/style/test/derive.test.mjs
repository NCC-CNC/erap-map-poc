// Unit tests for derive.mjs, calculated fields and action rules (ADR 0011).
// Run with `node --test` in pipeline/style (tests/display.bats runs them).

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import { DisplayError } from '../display.mjs';
import {
  ExpressionError,
  calculatedEntries,
  derivePlan,
  parseExpression,
  quoteName,
  toSql,
  validateRulesTable,
} from '../derive.mjs';

/** The problems a call throws, or fails if it does not throw a DisplayError. */
function problemsOf(fn) {
  try {
    fn();
  } catch (error) {
    assert.ok(error instanceof DisplayError, `expected a DisplayError, got ${error}`);
    return error.problems;
  }
  assert.fail('expected a DisplayError');
}

/** The SQL of an expression with every attribute as a quoted column. */
const sql = (text) => toSql(parseExpression(text), quoteName);

const expressionError = (text) => {
  try {
    parseExpression(text);
  } catch (error) {
    assert.ok(error instanceof ExpressionError, `expected an ExpressionError, got ${error}`);
    return error.message;
  }
  assert.fail(`expected ${text} to be rejected`);
};

const RULES = {
  types: [
    { id: 'area_based_conservation', label: 'Area-based conservation' },
    { id: 'landscape_conservation', label: 'Landscape conservation' },
  ],
  actions: [
    {
      id: 'area_based_30x30',
      type: 'area_based_conservation',
      title: 'Area-based conservation - 30x30 goals',
      condition: 'protected_pcnt < 30',
      reason: 'recommended because current protection is less than 30%',
    },
  ],
};

describe('parseExpression and toSql', () => {
  it('quotes attributes and brackets every operation', () => {
    assert.equal(sql('intact_pcnt - protected_intact_pcnt'), '("intact_pcnt" - "protected_intact_pcnt")');
    assert.equal(sql('a + b * c'), '("a" + ("b" * "c"))');
    assert.equal(sql('(a + b) * c'), '(("a" + "b") * "c")');
    assert.equal(sql('a - b - c'), '(("a" - "b") - "c")');
  });

  it('makes division decimal', () => {
    assert.equal(sql('a / 2'), '(("a" * 1.0) / 2)');
  });

  it('follows SQL precedence for AND, OR, NOT and comparisons', () => {
    assert.equal(sql('a < 30 AND b >= 1 OR c = 2'), '((("a" < 30) AND ("b" >= 1)) OR ("c" = 2))');
    assert.equal(sql('NOT a = 1'), '(NOT ("a" = 1))');
    assert.equal(sql('a != 1 and b == 2'), '(("a" <> 1) AND ("b" = 2))');
    assert.equal(sql('-a * 2'), '((- "a") * 2)');
  });

  it('reads IS, IN, LIKE and BETWEEN, with NOT', () => {
    assert.equal(sql('a IS NULL'), '("a" IS NULL)');
    assert.equal(sql('a IS NOT NULL AND b > 0'), '(("a" IS NOT NULL) AND ("b" > 0))');
    assert.equal(sql("zone IN ('A', 'B')"), '("zone" IN (\'A\', \'B\'))');
    assert.equal(sql('a NOT IN (1, 2)'), '("a" NOT IN (1, 2))');
    assert.equal(sql("name LIKE 'Bo%'"), '("name" LIKE \'Bo%\')');
    assert.equal(sql('a BETWEEN 10 AND 20 AND b < 1'), '(("a" BETWEEN 10 AND 20) AND ("b" < 1))');
    assert.equal(sql('a NOT BETWEEN 1 AND 2'), '("a" NOT BETWEEN 1 AND 2)');
  });

  it('reads CASE, CAST, functions, text, quoted names and TRUE', () => {
    assert.equal(
      sql("CASE WHEN a < 10 THEN 'low' ELSE 'high' END"),
      "(CASE WHEN (\"a\" < 10) THEN 'low' ELSE 'high' END)",
    );
    assert.equal(sql('CASE a WHEN 1 THEN 2 END'), '(CASE "a" WHEN 1 THEN 2 END)');
    assert.equal(sql('cast(a as integer)'), 'CAST("a" AS INTEGER)');
    assert.equal(sql('round(max(a - b, 0), 2)'), 'ROUND(MAX(("a" - "b"), 0), 2)');
    assert.equal(sql("'it''s' || name"), "('it''s' || \"name\")");
    assert.equal(sql('"odd name" + "end"'), '("odd name" + "end")');
    assert.equal(sql('"say ""hi"""'), '"say ""hi"""');
    assert.equal(sql('true'), '1');
    assert.equal(sql('1.5e3 + .5'), '(1.5e3 + .5)');
  });

  it('rejects statements, comments and anything outside the language', () => {
    assert.match(expressionError('a; DROP TABLE x'), /unexpected ";".*one expression only/);
    assert.match(expressionError('a -- comment'), /comment/);
    assert.match(expressionError('a /* c */'), /comment/);
    assert.match(expressionError('a IN (SELECT b FROM t)'), /expected/);
    assert.match(expressionError('load_extension(\'x\')'), /function load_extension.*not allowed/);
    assert.match(expressionError("BlobToFile(a, '/tmp/x')"), /function BlobToFile.*not allowed/);
    assert.match(expressionError('a @ b'), /unexpected "@"/);
    assert.match(expressionError('a ['), /unexpected "\["/);
    assert.match(expressionError("'open"), /unclosed '/);
    assert.match(expressionError('"open'), /unclosed "/);
    assert.match(expressionError('a b'), /expected an operator or the end/);
    assert.match(expressionError('(a + b'), /expected "\)"/);
    assert.match(expressionError('a +'), /expected a value/);
    assert.match(expressionError('   '), /empty/);
    assert.match(expressionError('x'.repeat(2001)), /longer than 2000/);
    assert.match(expressionError('('.repeat(100) + 'a' + ')'.repeat(100)), /nested/);
    assert.match(expressionError('end + 1'), /expected a value/);
    assert.match(expressionError('cast(a as blob)'), /expected a type/);
  });

  it('checks argument counts: min and max of one would be aggregates', () => {
    assert.match(expressionError('max(a)'), /calls max with 1 argument\(s\).*2 or more/);
    assert.match(expressionError('round(a, 1, 2)'), /takes 1 to 2/);
    assert.match(expressionError('abs()'), /takes 1/);
  });
});

describe('calculatedEntries', () => {
  it('splits name=expression, replaces in place and removes on empty', () => {
    assert.deepEqual(calculatedEntries(['a=x + 1', 'b=y', 'a=x * 2', 'c=z', 'c=']), [
      { name: 'a', expression: 'x * 2' },
      { name: 'b', expression: 'y' },
    ]);
    assert.deepEqual(calculatedEntries(['eq=a = b']), [{ name: 'eq', expression: 'a = b' }]);
  });

  it('rejects entries without a name', () => {
    const problems = problemsOf(() => calculatedEntries(['no equals', 'Bad=1', '=1']));
    assert.equal(problems.length, 3);
    assert.match(problems[0], /LAYER_CALCULATED\[0\] "no equals": write name=expression/);
  });
});

describe('validateRulesTable', () => {
  it('accepts the committed ecoregion table', () => {
    const table = JSON.parse(
      readFileSync(new URL('../../layers/ecoregions.rules.json', import.meta.url), 'utf8'),
    );
    validateRulesTable(table);
  });

  it('reports schema problems, duplicate ids, unknown types and bad conditions', () => {
    assert.match(problemsOf(() => validateRulesTable({ actions: [] }))[0], /types/);
    const bad = structuredClone(RULES);
    bad.actions.push({ ...bad.actions[0] });
    bad.actions.push({ ...bad.actions[0], id: 'other', type: 'nope', condition: 'a <' });
    bad.types.push({ ...bad.types[0] });
    const problems = problemsOf(() => validateRulesTable(bad));
    assert.ok(problems.some((p) => /types: the id area_based_conservation is used twice/.test(p)));
    assert.ok(problems.some((p) => /actions\[1\].*used twice/.test(p)));
    assert.ok(problems.some((p) => /actions\[2\] \(other\): type nope is not one of types/.test(p)));
    assert.ok(problems.some((p) => /actions\[2\] \(other\): condition expected a value/.test(p)));
    const extra = { ...RULES, actions: [{ ...RULES.actions[0], colour: 'red' }] };
    assert.match(problemsOf(() => validateRulesTable(extra)).join('\n'), /additional properties: colour/);
    const badId = { ...RULES, actions: [{ ...RULES.actions[0], id: 'Bad-Id' }] };
    assert.match(problemsOf(() => validateRulesTable(badId)).join('\n'), /\/actions\/0\/id must match/);
  });
});

describe('derivePlan', () => {
  const fields = ['id', 'protected_pcnt', 'intact_pcnt', 'protected_intact_pcnt'];

  it('plans calculated fields, action flags, reasons and counts per type', () => {
    const plan = derivePlan({
      fields,
      calculated: ['unprotected_intact_pcnt=intact_pcnt - protected_intact_pcnt'],
      rules: RULES,
      table: 'ecoregions',
    });
    assert.deepEqual(plan.attributes, [
      'unprotected_intact_pcnt',
      'action_area_based_30x30',
      'action_area_based_30x30_reason',
      'actions_area_based_conservation_count',
      'actions_landscape_conservation_count',
    ]);
    const cond = '("protected_pcnt" < 30)';
    assert.equal(
      plan.sql,
      'SELECT *, ("intact_pcnt" - "protected_intact_pcnt") AS "unprotected_intact_pcnt", ' +
        `(CASE WHEN ${cond} THEN 1 ELSE 0 END) AS "action_area_based_30x30", ` +
        `(CASE WHEN ${cond} THEN 'Area-based conservation - 30x30 goals: recommended because current protection is less than 30%' END) AS "action_area_based_30x30_reason", ` +
        `((CASE WHEN ${cond} THEN 1 ELSE 0 END)) AS "actions_area_based_conservation_count", ` +
        '0 AS "actions_landscape_conservation_count" FROM "ecoregions"',
    );
    assert.deepEqual(plan.calculated, [
      { name: 'unprotected_intact_pcnt', expression: 'intact_pcnt - protected_intact_pcnt' },
    ]);
    assert.equal(plan.rules.actions[0].reason_attribute, 'action_area_based_30x30_reason');
    assert.equal(plan.rules.types[1].attribute, 'actions_landscape_conservation_count');
  });

  it('writes calculated fields used by others and by conditions out in place', () => {
    const rules = { ...RULES, actions: [{ ...RULES.actions[0], condition: 'b > 1' }] };
    const plan = derivePlan({ fields: ['x'], calculated: ['b=a * 2', 'a=x + 1'], rules, table: 't' });
    assert.match(plan.sql, /\(\(\("x" \+ 1\)\) \* 2\) AS "b"/);
    assert.ok(plan.sql.includes('CASE WHEN ((((("x" + 1)) * 2)) > 1) THEN 1'), plan.sql);
  });

  it('reports unknown attributes, cycles, clashes and bad rules together', () => {
    const rules = structuredClone(RULES);
    rules.actions[0].condition = 'Protected_pcnt < 30';
    const problems = problemsOf(() =>
      derivePlan({
        fields,
        calculated: ['a=b + 1', 'b=a + 1', 'c=nope * 2', 'id=1', 'd=c + 1', 'e=max(1)'],
        rules,
        rulesFile: 'x.rules.json',
        table: 't',
      }),
    );
    const text = problems.join('\n');
    assert.match(text, /calculated field id: the layer already has an attribute id/);
    assert.match(text, /calculated field a: refers to itself through a -> b -> a|calculated field b: refers to itself/);
    assert.match(text, /calculated field c: uses the attribute nope, which the layer does not have/);
    assert.match(text, /calculated field d: uses c, which has a problem/);
    assert.match(text, /calculated field e: calls max with 1 argument/);
    assert.match(text, /x\.rules\.json: actions\[0\] \(area_based_30x30\): condition uses the attribute Protected_pcnt.*did you mean protected_pcnt\?/);
  });

  it('reports a rule attribute that clashes with an attribute', () => {
    const problems = problemsOf(() =>
      derivePlan({ fields: ['action_area_based_30x30', 'protected_pcnt'], calculated: [], rules: RULES, table: 't' }),
    );
    assert.match(problems[0], /would write action_area_based_30x30, which the layer already has/);
  });
});
