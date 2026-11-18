// Numerical reference for CoachMeCore's geometry.
//
// This file re-implements the exact formulas in
// CoachMeCore/Sources/CoachMeCore/Geometry/*.swift and runs them on fixed test
// vectors. It exists because the Swift toolchain is not available on this
// machine: it proves the *formulas and expected numbers* are right, so the
// Swift XCTest cases can assert against values that were actually computed
// rather than values that were guessed.
//
// It does NOT prove the Swift code compiles or that the app runs.
// Run: node tools/reference/verify_geometry.mjs

const EPS = 1e-6;

const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const scale = (v, s) => [v[0] * s, v[1] * s, v[2] * s];
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a, b) => [
  a[1] * b[2] - a[2] * b[1],
  a[2] * b[0] - a[0] * b[2],
  a[0] * b[1] - a[1] * b[0],
];
const len = (v) => Math.hypot(v[0], v[1], v[2]);
const mid = (a, b) => [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2];
const norm = (v) => {
  const l = len(v);
  return l > EPS ? scale(v, 1 / l) : null;
};
const deg = (r) => (r * 180) / Math.PI;
const rad = (d) => (d * Math.PI) / 180;

// --- AngleMath ---------------------------------------------------------------

function unsignedAngleDegrees(u, v) {
  const un = norm(u), vn = norm(v);
  if (!un || !vn) return null;
  return deg(Math.acos(Math.min(1, Math.max(-1, dot(un, vn)))));
}

function interiorAngleDegrees(vertex, a, b) {
  return unsignedAngleDegrees(sub(a, vertex), sub(b, vertex));
}

function projectedOntoPlane(v, axis) {
  const n = norm(axis);
  if (!n) return null;
  const p = sub(v, scale(n, dot(v, n)));
  return len(p) > EPS ? p : null;
}

function signedRotationDegrees(reference, current, axis) {
  const n = norm(axis);
  if (!n) return null;
  const rp = projectedOntoPlane(reference, n), cp = projectedOntoPlane(current, n);
  if (!rp || !cp) return null;
  const r = norm(rp), c = norm(cp);
  return deg(Math.atan2(dot(cross(r, c), n), Math.min(1, Math.max(-1, dot(r, c)))));
}

// --- TorsoFrame --------------------------------------------------------------

function makeTorsoFrame(leftHip, rightHip, leftShoulder, rightShoulder) {
  const origin = mid(leftHip, rightHip);
  const shoulderCentre = mid(leftShoulder, rightShoulder);
  const upRaw = sub(shoulderCentre, origin);
  const up = norm(upRaw);
  if (!up) return null;
  const lateralRaw = projectedOntoPlane(sub(rightHip, leftHip), up);
  const lateral = lateralRaw && norm(lateralRaw);
  if (!lateral) return null;
  const forward = norm(cross(up, lateral));
  if (!forward) return null;
  return { origin, up, lateral, forward, torsoLength: len(upRaw) };
}

function localise(frame, point) {
  if (frame.torsoLength <= EPS) return null;
  const d = sub(point, frame.origin);
  return [
    dot(d, frame.lateral) / frame.torsoLength,
    dot(d, frame.forward) / frame.torsoLength,
    dot(d, frame.up) / frame.torsoLength,
  ];
}

// --- Rigid transforms, used for the invariance checks ------------------------

function rotateAboutAxis(v, axisRaw, degrees) {
  const k = norm(axisRaw);
  const t = rad(degrees);
  // Rodrigues' rotation formula
  return add(
    add(scale(v, Math.cos(t)), scale(cross(k, v), Math.sin(t))),
    scale(k, dot(k, v) * (1 - Math.cos(t)))
  );
}

// --- Harness -----------------------------------------------------------------

let pass = 0, fail = 0;
const results = [];

function check(name, actual, expected, tol = 1e-9) {
  let ok;
  if (expected === null) {
    ok = actual === null;
  } else if (Array.isArray(expected)) {
    ok = Array.isArray(actual) && actual.length === expected.length &&
         actual.every((a, i) => Math.abs(a - expected[i]) <= tol);
  } else {
    ok = actual !== null && Math.abs(actual - expected) <= tol;
  }
  ok ? pass++ : fail++;
  const shown = Array.isArray(actual) ? `[${actual.map((n) => n.toFixed(6)).join(', ')}]`
              : actual === null ? 'null' : actual.toFixed(6);
  results.push(`${ok ? 'PASS' : 'FAIL'}  ${name.padEnd(58)} = ${shown}`);
  return ok;
}

console.log('CoachMeCore geometry — numerical reference\n');

// 1. Elbow interior angle: known right angle.
//    shoulder above elbow, wrist to the side of elbow.
check('elbow interior, perpendicular limbs -> 90',
  interiorAngleDegrees([0, 0, 0], [0, 1, 0], [1, 0, 0]), 90);

// 2. Fully extended limb -> 180.
check('elbow interior, collinear extended -> 180',
  interiorAngleDegrees([0, 0, 0], [0, 1, 0], [0, -1, 0]), 180);

// 3. Folded limb -> 0.
check('elbow interior, folded back on itself -> 0',
  interiorAngleDegrees([0, 0, 0], [0, 1, 0], [0, 2, 0]), 0);

// 4. A realistic slightly-bent elbow: 3-4-5 style geometry.
//    shoulder (0,0,0), elbow (0,-1,0), wrist (0.5, -1.866, 0) -> 150 deg interior.
const bentWrist = [Math.sin(rad(30)) * 1, -1 - Math.cos(rad(30)) * 1, 0];
check('elbow interior, 30 deg flexion -> 150',
  interiorAngleDegrees([0, -1, 0], [0, 0, 0], bentWrist), 150, 1e-9);
check('flexion conversion 180 - interior -> 30',
  180 - interiorAngleDegrees([0, -1, 0], [0, 0, 0], bentWrist), 30, 1e-9);

// 5. Degenerate: coincident points must return null, never 0 or NaN.
check('elbow interior, wrist coincident with elbow -> null',
  interiorAngleDegrees([0, 0, 0], [0, 1, 0], [0, 0, 0]), null);
check('unsigned angle, zero-length vector -> null',
  unsignedAngleDegrees([0, 0, 0], [1, 0, 0]), null);

// 6. Upper arm vs torso. Torso long axis points from shoulder centre DOWN to hip
//    centre; an arm hanging straight down is 0 deg.
const shoulderCentre = [0, 1, 0], hipCentre = [0, 0, 0];
const torsoDown = sub(hipCentre, shoulderCentre);
check('upper arm hanging straight down -> 0',
  unsignedAngleDegrees([0, -1, 0], torsoDown), 0);
check('upper arm horizontal -> 90',
  unsignedAngleDegrees([1, 0, 0], torsoDown), 90);
check('upper arm straight up -> 180',
  unsignedAngleDegrees([0, 1, 0], torsoDown), 180);

// 7. Between upper arms.
check('both upper arms parallel -> 0',
  unsignedAngleDegrees([0, -1, 0], [0, -1, 0]), 0);
check('upper arms opposed -> 180',
  unsignedAngleDegrees([1, 0, 0], [-1, 0, 0]), 180);

// 8. Signed rotation about the trunk axis.
//    Trunk axis = +Y. Address shoulder line along +X. Rotate 45 deg about +Y.
const axis = [0, 1, 0];
const addressShoulderLine = [1, 0, 0];
const rotated45 = rotateAboutAxis(addressShoulderLine, axis, 45);
check('signed rotation, +45 about trunk axis',
  signedRotationDegrees(addressShoulderLine, rotated45, axis), 45, 1e-9);
check('signed rotation, -60 about trunk axis',
  signedRotationDegrees(addressShoulderLine, rotateAboutAxis(addressShoulderLine, axis, -60), axis), -60, 1e-9);
check('signed rotation, identity -> 0',
  signedRotationDegrees(addressShoulderLine, addressShoulderLine, axis), 0, 1e-9);

// 9. Tilt must NOT be read as rotation: tilt the shoulder line within the plane
//    containing the trunk axis. Its projection onto the transverse plane is
//    unchanged, so rotation stays 0.
const tiltedNoRotation = norm([1, 0.6, 0]); // same X-Z projection direction as +X
check('pure tilt about lateral axis -> 0 rotation',
  signedRotationDegrees(addressShoulderLine, tiltedNoRotation, axis), 0, 1e-9);

// 10. A shoulder line pointing straight along the trunk axis carries no
//     rotational information -> null, not 0.
check('shoulder line parallel to trunk axis -> null',
  signedRotationDegrees(addressShoulderLine, [0, 1, 0], axis), null);

// 11. Rotation invariance. Apply one rigid rotation to the address reference,
//     the current vector AND the axis: the measured rotation must not change.
const R = (v) => rotateAboutAxis(rotateAboutAxis(v, [1, 0, 0], 37), [0, 0, 1], -22);
const beforeInvariance = signedRotationDegrees(addressShoulderLine, rotated45, axis);
const afterInvariance = signedRotationDegrees(R(addressShoulderLine), R(rotated45), R(axis));
check('signed rotation invariant under whole-body rotation',
  afterInvariance, beforeInvariance, 1e-9);

// 12. Interior angles invariant under translation and rotation.
const sh = [0.1, 0.4, -0.2], el = [0.15, 0.1, -0.1], wr = [0.4, -0.1, 0.05];
const baseElbow = interiorAngleDegrees(el, sh, wr);
const T = (v) => add(v, [3.7, -1.2, 0.9]);
check('elbow angle invariant under translation',
  interiorAngleDegrees(T(el), T(sh), T(wr)), baseElbow, 1e-9);
check('elbow angle invariant under rotation',
  interiorAngleDegrees(R(el), R(sh), R(wr)), baseElbow, 1e-9);
results.push(`INFO  realistic elbow test vector interior angle          = ${baseElbow.toFixed(6)}`);

// 13. Torso frame: orthonormality and handedness.
const lh = [-0.15, 0, 0], rh = [0.15, 0, 0];
const ls = [-0.2, 0.55, 0.02], rs = [0.2, 0.55, -0.02];
const tf = makeTorsoFrame(lh, rh, ls, rs);
check('torso frame lateral is unit length', len(tf.lateral), 1, 1e-12);
check('torso frame up is unit length', len(tf.up), 1, 1e-12);
check('torso frame lateral perpendicular to up', dot(tf.lateral, tf.up), 0, 1e-12);
check('torso frame forward perpendicular to up', dot(tf.forward, tf.up), 0, 1e-12);
check('torso frame forward perpendicular to lateral', dot(tf.forward, tf.lateral), 0, 1e-12);
results.push(`INFO  torso length for test subject                       = ${tf.torsoLength.toFixed(6)}`);

// 14. Body-referenced wrist position removes whole-body translation.
const wrist = [0.35, 0.15, 0.1];
const localBefore = localise(tf, wrist);
const tfMoved = makeTorsoFrame(T(lh), T(rh), T(ls), T(rs));
const localAfterTranslation = localise(tfMoved, T(wrist));
check('wrist body-referenced position invariant under translation',
  localAfterTranslation, localBefore, 1e-9);

// And under whole-body rotation.
const tfRotated = makeTorsoFrame(R(lh), R(rh), R(ls), R(rs));
check('wrist body-referenced position invariant under rotation',
  localise(tfRotated, R(wrist)), localBefore, 1e-9);

// But it MUST change when the arm actually moves relative to the body.
const wristMoved = [0.35, 0.35, 0.1];
const localMoved = localise(tf, wristMoved);
const changed = Math.abs(localMoved[2] - localBefore[2]) > 0.05;
(changed ? pass++ : fail++);
results.push(`${changed ? 'PASS' : 'FAIL'}  ${'wrist local position changes when arm moves'.padEnd(58)} = ` +
  `[${localBefore.map((n) => n.toFixed(4)).join(', ')}] -> [${localMoved.map((n) => n.toFixed(4)).join(', ')}]`);

// 15. Image-space path DOES include whole-body translation (the distinction the
//     product must never blur).
const imgBefore = wrist, imgAfter = T(wrist);
const imageMoved = len(sub(imgAfter, imgBefore)) > 0.5;
(imageMoved ? pass++ : fail++);
results.push(`${imageMoved ? 'PASS' : 'FAIL'}  ${'image path DOES shift under whole-body translation'.padEnd(58)} = ` +
  `${len(sub(imgAfter, imgBefore)).toFixed(6)}`);

// 16. Handedness -> lead/trail mapping.
const leadSide = (h) => (h === 'rightHanded' ? 'left' : 'right');
const trailSide = (h) => (h === 'rightHanded' ? 'right' : 'left');
const mapOK = leadSide('rightHanded') === 'left' && trailSide('rightHanded') === 'right'
           && leadSide('leftHanded') === 'right' && trailSide('leftHanded') === 'left';
(mapOK ? pass++ : fail++);
results.push(`${mapOK ? 'PASS' : 'FAIL'}  ${'handedness -> lead/trail arm mapping'.padEnd(58)} = ` +
  `RH lead=${leadSide('rightHanded')}, LH lead=${leadSide('leftHanded')}`);

// 17. Shoulder-hip separation follows its stated definition.
const shoulderRot = signedRotationDegrees([1, 0, 0], rotateAboutAxis([1, 0, 0], axis, 90), axis);
const hipRot = signedRotationDegrees([1, 0, 0], rotateAboutAxis([1, 0, 0], axis, 35), axis);
check('separation = shoulder rotation - hip rotation', shoulderRot - hipRot, 55, 1e-9);

console.log(results.join('\n'));
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
