// Numerical/logic reference for CoachMeCore's RuleEngine decision order.
//
// Mirrors RuleEngine.evaluate(...) exactly. Verifies the precedence that keeps
// the app honest:
//   1. definition mismatch   (a range authored against an older metric definition)
//   2. applicability         (phase / club / view)
//   3. data quality          (never judge a value we could not measure)
//   4. range comparison      (in / out, with the deviation)
// and that "out of range" is reported as a deviation from THIS COACH's range,
// never as a correctness verdict.
//
// Run: node tools/reference/verify_rules.mjs

let pass = 0, fail = 0;
const log = [];

function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  ok ? pass++ : fail++;
  log.push(`${ok ? 'PASS' : 'FAIL'}  ${name.padEnd(62)} = ${JSON.stringify(actual)}`);
}

const CURRENT_HASH = 'a1b2c3d4e5f60718';

function evaluate(rule, outcome, phase, club, view, metricViews = ['faceOn', 'downTheLine', 'unknown']) {
  // 1. definition binding
  if (rule.metricDefinitionHash !== CURRENT_HASH) {
    return { kind: 'definitionMismatch' };
  }
  // 2. applicability
  if (!rule.phases.includes(phase)) return { kind: 'notApplicable', reason: 'phaseMismatch' };
  if (!rule.clubs.includes(club)) return { kind: 'notApplicable', reason: 'clubMismatch' };
  if (!rule.views.includes(view)) return { kind: 'notApplicable', reason: 'viewMismatch' };
  // 3. the metric's own stated camera conditions
  if (!metricViews.includes(view)) return { kind: 'notApplicable', reason: 'viewMismatch' };
  // 4. data quality
  if (outcome.kind !== 'value') return { kind: 'dataQualityInsufficient', reason: outcome.reason };
  // 5. range
  const hasRange = rule.lowerBound !== null || rule.upperBound !== null;
  if (!hasRange) return { kind: 'noReferenceRange' };
  const v = outcome.value;
  if (rule.lowerBound !== null && v < rule.lowerBound) {
    return { kind: 'outOfRange', deviation: +(rule.lowerBound - v).toFixed(6), direction: 'below' };
  }
  if (rule.upperBound !== null && v > rule.upperBound) {
    return { kind: 'outOfRange', deviation: +(v - rule.upperBound).toFixed(6), direction: 'above' };
  }
  return { kind: 'inRange', value: v };
}

const baseRule = {
  metricDefinitionHash: CURRENT_HASH,
  phases: ['top'],
  clubs: ['driver', 'iron'],
  views: ['faceOn', 'downTheLine'],
  lowerBound: 150,
  upperBound: 175,
};
const value = (v) => ({ kind: 'value', value: v });
const unavailable = (reason) => ({ kind: 'unavailable', reason });

console.log('CoachMeCore rule engine — decision reference\n');

// --- Range comparison, including boundaries ---------------------------------
check('value inside range', evaluate(baseRule, value(160), 'top', 'driver', 'faceOn'),
  { kind: 'inRange', value: 160 });
check('value exactly on lower bound is IN range', evaluate(baseRule, value(150), 'top', 'driver', 'faceOn'),
  { kind: 'inRange', value: 150 });
check('value exactly on upper bound is IN range', evaluate(baseRule, value(175), 'top', 'driver', 'faceOn'),
  { kind: 'inRange', value: 175 });
check('value below lower bound', evaluate(baseRule, value(142.5), 'top', 'driver', 'faceOn'),
  { kind: 'outOfRange', deviation: 7.5, direction: 'below' });
check('value above upper bound', evaluate(baseRule, value(180), 'top', 'driver', 'faceOn'),
  { kind: 'outOfRange', deviation: 5, direction: 'above' });

// --- One-sided ranges --------------------------------------------------------
check('lower-bound-only rule, value above',
  evaluate({ ...baseRule, upperBound: null }, value(400), 'top', 'driver', 'faceOn'),
  { kind: 'inRange', value: 400 });
check('upper-bound-only rule, value below',
  evaluate({ ...baseRule, lowerBound: null }, value(-20), 'top', 'driver', 'faceOn'),
  { kind: 'inRange', value: -20 });

// --- No range configured -----------------------------------------------------
check('no bounds at all -> noReferenceRange',
  evaluate({ ...baseRule, lowerBound: null, upperBound: null }, value(160), 'top', 'driver', 'faceOn'),
  { kind: 'noReferenceRange' });

// --- Applicability gates -----------------------------------------------------
check('phase not covered by rule',
  evaluate(baseRule, value(160), 'impact', 'driver', 'faceOn'),
  { kind: 'notApplicable', reason: 'phaseMismatch' });
check('club not covered by rule',
  evaluate(baseRule, value(160), 'top', 'putter', 'faceOn'),
  { kind: 'notApplicable', reason: 'clubMismatch' });
check('view not covered by rule',
  evaluate(baseRule, value(160), 'top', 'driver', 'unknown'),
  { kind: 'notApplicable', reason: 'viewMismatch' });
check("metric's own view restriction blocks an otherwise-matching rule",
  evaluate({ ...baseRule, views: ['faceOn', 'downTheLine', 'unknown'] },
    value(160), 'top', 'driver', 'unknown', ['faceOn']),
  { kind: 'notApplicable', reason: 'viewMismatch' });

// --- Data quality ------------------------------------------------------------
for (const reason of ['lowVisibility', 'degenerateGeometry', 'worldLandmarksMissing',
                      'addressReferenceMissing', 'multiplePeople', 'noPersonDetected']) {
  check(`unavailable(${reason}) is never judged`,
    evaluate(baseRule, unavailable(reason), 'top', 'driver', 'faceOn'),
    { kind: 'dataQualityInsufficient', reason });
}

// --- Precedence --------------------------------------------------------------
check('stale definition beats everything else',
  evaluate({ ...baseRule, metricDefinitionHash: 'OLDHASH00000000' },
    unavailable('lowVisibility'), 'impact', 'putter', 'unknown'),
  { kind: 'definitionMismatch' });
check('applicability is checked before data quality',
  evaluate(baseRule, unavailable('lowVisibility'), 'impact', 'driver', 'faceOn'),
  { kind: 'notApplicable', reason: 'phaseMismatch' });
check('data quality is checked before the range',
  evaluate(baseRule, unavailable('multiplePeople'), 'top', 'driver', 'faceOn'),
  { kind: 'dataQualityInsufficient', reason: 'multiplePeople' });

// --- The engine never emits a correctness verdict ----------------------------
const allKinds = new Set();
for (const o of [value(1), value(160), value(999), unavailable('lowVisibility')]) {
  for (const p of ['top', 'impact']) {
    for (const c of ['driver', 'putter']) {
      for (const v of ['faceOn', 'unknown']) {
        allKinds.add(evaluate(baseRule, o, p, c, v).kind);
      }
    }
  }
}
const forbidden = [...allKinds].filter((k) => /wrong|incorrect|error|bad|fault|score/i.test(k));
check('no verdict-like outcome kind is ever produced', forbidden, []);
log.push(`INFO  outcome kinds observed: ${[...allKinds].sort().join(', ')}`);

// --- Side resolution ---------------------------------------------------------
const resolveSide = (ruleSide, handedness) => ({
  leadArm: handedness === 'rightHanded' ? 'left' : 'right',
  trailArm: handedness === 'rightHanded' ? 'right' : 'left',
  left: 'left', right: 'right', bilateral: null,
}[ruleSide]);
check('leadArm rule on a right-handed player resolves to left',
  resolveSide('leadArm', 'rightHanded'), 'left');
check('trailArm rule on a left-handed player resolves to left',
  resolveSide('trailArm', 'leftHanded'), 'left');
check('bilateral rule resolves to no side', resolveSide('bilateral', 'rightHanded'), null);

console.log(log.join('\n'));
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
