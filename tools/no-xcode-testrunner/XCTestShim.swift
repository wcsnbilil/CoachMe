@_exported import Foundation

public struct TestFailure: Error, CustomStringConvertible {
    public let message: String
    public let file: String
    public let line: UInt
    public var description: String { "\(message)  (\((file as NSString).lastPathComponent):\(line))" }
}

public final class Recorder {
    public static var failures: [TestFailure] = []
    public static func record(_ m: String, _ f: StaticString, _ l: UInt) {
        failures.append(TestFailure(message: m, file: "\(f)", line: l))
    }
}

open class XCTestCase {
    public init() {}
    open func setUp() {}
    open func tearDown() {}
}

public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    Recorder.record("XCTFail: \(message)", file, line)
}

public func XCTAssertTrue(_ e: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) rethrows {
    if try !e() { Recorder.record("XCTAssertTrue failed. \(message())", file, line) }
}

public func XCTAssertFalse(_ e: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) rethrows {
    if try e() { Recorder.record("XCTAssertFalse failed. \(message())", file, line) }
}

public func XCTAssertNil(_ e: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) rethrows {
    if let v = try e() { Recorder.record("XCTAssertNil failed: got \(v). \(message())", file, line) }
}

public func XCTAssertNotNil(_ e: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) rethrows {
    if try e() == nil { Recorder.record("XCTAssertNotNil failed. \(message())", file, line) }
}

public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) rethrows {
    let (x, y) = (try a(), try b())
    if x != y { Recorder.record("XCTAssertEqual failed: \(x) != \(y). \(message())", file, line) }
}

public func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, accuracy: T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) rethrows {
    let (x, y) = (try a(), try b())
    if !(abs(x - y) <= accuracy) { Recorder.record("XCTAssertEqual failed: \(x) != \(y) (accuracy \(accuracy)). \(message())", file, line) }
}

public func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) rethrows {
    let (x, y) = (try a(), try b())
    if !(x > y) { Recorder.record("XCTAssertGreaterThan failed: \(x) <= \(y). \(message())", file, line) }
}

public func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) rethrows {
    let (x, y) = (try a(), try b())
    if !(x < y) { Recorder.record("XCTAssertLessThan failed: \(x) >= \(y). \(message())", file, line) }
}

public func XCTUnwrap<T>(_ e: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let v = try e() else {
        let f = TestFailure(message: "XCTUnwrap failed: value was nil. \(message())", file: "\(file)", line: line)
        Recorder.failures.append(f)
        throw f
    }
    return v
}
