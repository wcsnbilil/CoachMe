import XCTest
@testable import CoachMeCore

/// Expected values in this file were produced by running
/// `tools/reference/verify_geometry.mjs` on this machine (31/31 passing).
/// They are computed numbers, not estimates.
///
/// NOT YET EXECUTED: this test target has never been compiled or run — there is
/// no Swift toolchain on the development machine. Run it on macOS with
/// `swift test` from CoachMeCore/ before trusting it.
final class GeometryTests: XCTestCase {

    private let tol = 1e-9

    // MARK: - Known geometry

    func testElbowInteriorAnglePerpendicular() throws {
        let angle = try XCTUnwrap(AngleMath.interiorAngleDegrees(
            vertex: Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 0, 0)))
        XCTAssertEqual(angle, 90, accuracy: tol)
    }

    func testElbowInteriorAngleExtendedIs180() throws {
        let angle = try XCTUnwrap(AngleMath.interiorAngleDegrees(
            vertex: Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(0, -1, 0)))
        XCTAssertEqual(angle, 180, accuracy: tol)
    }

    func testElbowInteriorAngleFoldedIsZero() throws {
        let angle = try XCTUnwrap(AngleMath.interiorAngleDegrees(
            vertex: Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(0, 2, 0)))
        XCTAssertEqual(angle, 0, accuracy: tol)
    }

    func testFlexionIsComplementOfInterior() {
        XCTAssertEqual(AngleMath.flexionDegrees(fromInteriorAngle: 150), 30, accuracy: tol)
        XCTAssertEqual(AngleMath.flexionDegrees(fromInteriorAngle: 180), 0, accuracy: tol)
    }

    func testAnglesStayWithinDeclaredRange() throws {
        // Range for every interior/unsigned angle metric is 0...180.
        for definition in MetricCatalog.all where definition.unit == "°" && !definition.requiresAddressReference {
            XCTAssertEqual(definition.range.lowerBound, 0)
            XCTAssertEqual(definition.range.upperBound, 180)
        }
        for definition in MetricCatalog.all where definition.requiresAddressReference {
            XCTAssertEqual(definition.range.lowerBound, -180)
            XCTAssertEqual(definition.range.upperBound, 180)
        }
    }

    // MARK: - Degenerate and invalid input must not produce a number

    func testCoincidentPointsReturnNil() {
        XCTAssertNil(AngleMath.interiorAngleDegrees(
            vertex: Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 0)))
        XCTAssertNil(AngleMath.unsignedAngleDegrees(Vector3.zero, Vector3(1, 0, 0)))
    }

    func testVectorParallelToAxisCarriesNoRotation() {
        XCTAssertNil(AngleMath.signedRotationDegrees(
            from: Vector3(1, 0, 0), to: Vector3(0, 1, 0), about: Vector3(0, 1, 0)))
    }

    // MARK: - Signed rotation

    func testSignedRotationMatchesAppliedRotation() throws {
        let axis = Vector3(0, 1, 0)
        let reference = Vector3(1, 0, 0)
        let rotated = Self.rotate(reference, about: axis, degrees: 45)
        let measured = try XCTUnwrap(AngleMath.signedRotationDegrees(from: reference, to: rotated, about: axis))
        XCTAssertEqual(measured, 45, accuracy: tol)

        let back = Self.rotate(reference, about: axis, degrees: -60)
        let measuredBack = try XCTUnwrap(AngleMath.signedRotationDegrees(from: reference, to: back, about: axis))
        XCTAssertEqual(measuredBack, -60, accuracy: tol)
    }

    /// A shoulder line that tilts but does not turn must read 0°, not a rotation.
    /// This is the guard against reporting on-screen tilt as axial rotation.
    func testPureTiltIsNotReportedAsRotation() throws {
        let axis = Vector3(0, 1, 0)
        let reference = Vector3(1, 0, 0)
        let tilted = try XCTUnwrap(Vector3(1, 0.6, 0).normalized())
        let measured = try XCTUnwrap(AngleMath.signedRotationDegrees(from: reference, to: tilted, about: axis))
        XCTAssertEqual(measured, 0, accuracy: tol)
    }

    // MARK: - Rigid-transform invariance (spec §12.1)

    func testInteriorAngleInvariantUnderTranslationAndRotation() throws {
        let shoulder = Vector3(0.1, 0.4, -0.2)
        let elbow = Vector3(0.15, 0.1, -0.1)
        let wrist = Vector3(0.4, -0.1, 0.05)

        let base = try XCTUnwrap(AngleMath.interiorAngleDegrees(vertex: elbow, shoulder, wrist))
        // Value computed by tools/reference/verify_geometry.mjs.
        XCTAssertEqual(base, 140.625924, accuracy: 1e-6)

        let t = Vector3(3.7, -1.2, 0.9)
        let translated = try XCTUnwrap(AngleMath.interiorAngleDegrees(
            vertex: elbow + t, shoulder + t, wrist + t))
        XCTAssertEqual(translated, base, accuracy: tol)

        let rotated = try XCTUnwrap(AngleMath.interiorAngleDegrees(
            vertex: Self.rigid(elbow), Self.rigid(shoulder), Self.rigid(wrist)))
        XCTAssertEqual(rotated, base, accuracy: tol)
    }

    func testSignedRotationInvariantWhenWholeBodyRotates() throws {
        let axis = Vector3(0, 1, 0)
        let reference = Vector3(1, 0, 0)
        let current = Self.rotate(reference, about: axis, degrees: 45)

        let before = try XCTUnwrap(AngleMath.signedRotationDegrees(from: reference, to: current, about: axis))
        let after = try XCTUnwrap(AngleMath.signedRotationDegrees(
            from: Self.rigid(reference), to: Self.rigid(current), about: Self.rigid(axis)))
        XCTAssertEqual(after, before, accuracy: tol)
        XCTAssertEqual(after, 45, accuracy: tol)
    }

    // MARK: - Torso frame

    func testTorsoFrameIsOrthonormal() throws {
        let frame = try XCTUnwrap(Self.sampleTorsoFrame())
        XCTAssertEqual(frame.up.length, 1, accuracy: 1e-12)
        XCTAssertEqual(frame.lateral.length, 1, accuracy: 1e-12)
        XCTAssertEqual(frame.forward.length, 1, accuracy: 1e-12)
        XCTAssertEqual(frame.lateral.dot(frame.up), 0, accuracy: 1e-12)
        XCTAssertEqual(frame.forward.dot(frame.up), 0, accuracy: 1e-12)
        XCTAssertEqual(frame.forward.dot(frame.lateral), 0, accuracy: 1e-12)
        XCTAssertEqual(frame.torsoLength, 0.55, accuracy: 1e-12)
    }

    /// Body-referenced wrist position must ignore the subject walking or the
    /// camera moving, and must change when the arm actually moves.
    func testBodyReferencedWristIgnoresWholeBodyMotion() throws {
        let frame = try XCTUnwrap(Self.sampleTorsoFrame())
        let wrist = Vector3(0.35, 0.15, 0.1)
        let local = try XCTUnwrap(frame.localise(wrist))
        // Values computed by tools/reference/verify_geometry.mjs.
        XCTAssertEqual(local.x, 0.636364, accuracy: 1e-6)
        XCTAssertEqual(local.y, -0.181818, accuracy: 1e-6)
        XCTAssertEqual(local.z, 0.272727, accuracy: 1e-6)

        let t = Vector3(3.7, -1.2, 0.9)
        let moved = try XCTUnwrap(TorsoFrame.make(
            leftHip: Self.leftHip + t, rightHip: Self.rightHip + t,
            leftShoulder: Self.leftShoulder + t, rightShoulder: Self.rightShoulder + t))
        let localAfter = try XCTUnwrap(moved.localise(wrist + t))
        XCTAssertEqual(localAfter.x, local.x, accuracy: tol)
        XCTAssertEqual(localAfter.y, local.y, accuracy: tol)
        XCTAssertEqual(localAfter.z, local.z, accuracy: tol)

        let rotatedFrame = try XCTUnwrap(TorsoFrame.make(
            leftHip: Self.rigid(Self.leftHip), rightHip: Self.rigid(Self.rightHip),
            leftShoulder: Self.rigid(Self.leftShoulder), rightShoulder: Self.rigid(Self.rightShoulder)))
        let localRotated = try XCTUnwrap(rotatedFrame.localise(Self.rigid(wrist)))
        XCTAssertEqual(localRotated.z, local.z, accuracy: tol)

        // Arm genuinely raised: the up-component must change.
        let raised = try XCTUnwrap(frame.localise(Vector3(0.35, 0.35, 0.1)))
        XCTAssertGreaterThan(abs(raised.z - local.z), 0.05)
    }

    // MARK: - Handedness mapping (spec §12.1)

    func testHandednessMapsToLeadAndTrailArm() {
        XCTAssertEqual(Handedness.rightHanded.leadSide, .left)
        XCTAssertEqual(Handedness.rightHanded.trailSide, .right)
        XCTAssertEqual(Handedness.leftHanded.leadSide, .right)
        XCTAssertEqual(Handedness.leftHanded.trailSide, .left)
        XCTAssertEqual(Handedness.rightHanded.side(for: .lead), .left)
        XCTAssertEqual(Handedness.leftHanded.side(for: .trail), .left)
    }

    func testPoseJointIndicesMatchModelOrder() {
        XCTAssertEqual(PoseJoint.nose.rawValue, 0)
        XCTAssertEqual(PoseJoint.leftShoulder.rawValue, 11)
        XCTAssertEqual(PoseJoint.rightShoulder.rawValue, 12)
        XCTAssertEqual(PoseJoint.leftWrist.rawValue, 15)
        XCTAssertEqual(PoseJoint.leftHip.rawValue, 23)
        XCTAssertEqual(PoseJoint.rightFootIndex.rawValue, 32)
        XCTAssertEqual(PoseJoint.allCases.count, 33)
    }

    // MARK: - Fixtures

    static let leftHip = Vector3(-0.15, 0, 0)
    static let rightHip = Vector3(0.15, 0, 0)
    static let leftShoulder = Vector3(-0.2, 0.55, 0.02)
    static let rightShoulder = Vector3(0.2, 0.55, -0.02)

    static func sampleTorsoFrame() -> TorsoFrame? {
        TorsoFrame.make(leftHip: leftHip, rightHip: rightHip,
                        leftShoulder: leftShoulder, rightShoulder: rightShoulder)
    }

    /// Rodrigues rotation, matching the reference implementation.
    static func rotate(_ v: Vector3, about axisRaw: Vector3, degrees: Double) -> Vector3 {
        guard let k = axisRaw.normalized() else { return v }
        let t = AngleMath.radians(degrees: degrees)
        return v * cos(t) + k.cross(v) * sin(t) + k * (k.dot(v) * (1 - cos(t)))
    }

    /// The same arbitrary rigid rotation used in the reference harness.
    static func rigid(_ v: Vector3) -> Vector3 {
        rotate(rotate(v, about: Vector3(1, 0, 0), degrees: 37), about: Vector3(0, 0, 1), degrees: -22)
    }
}

extension GeometryTests {

    /// Regression: real footage produced a 346.4° separation during the
    /// follow-through, when the hip line crossed ±180 and the shoulder line had
    /// not yet. The true value there was -13.6°.
    func testSeparationWrapsAcrossTheSignFlip() {
        XCTAssertEqual(AngleMath.wrappedDifferenceDegrees(167.5, -178.8), -13.7, accuracy: 0.05)
        XCTAssertEqual(AngleMath.wrappedDifferenceDegrees(-178.8, 167.5), 13.7, accuracy: 0.05)
    }

    func testWrappedDifferenceIsPlainSubtractionAwayFromTheSeam() {
        XCTAssertEqual(AngleMath.wrappedDifferenceDegrees(-48.7, -40.1), -8.6, accuracy: 0.001)
        XCTAssertEqual(AngleMath.wrappedDifferenceDegrees(55.9, 38.4), 17.5, accuracy: 0.001)
        XCTAssertEqual(AngleMath.wrappedDifferenceDegrees(0, 0), 0, accuracy: 0.001)
    }

    func testWrappedDifferenceAlwaysLandsInRange() {
        for a in stride(from: -180.0, through: 180.0, by: 7.5) {
            for b in stride(from: -180.0, through: 180.0, by: 7.5) {
                let d = AngleMath.wrappedDifferenceDegrees(a, b)
                XCTAssertTrue((-180.0...180.0).contains(d), "\(a) - \(b) = \(d) 超出范围")
            }
        }
    }
}
