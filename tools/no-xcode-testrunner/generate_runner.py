"""Emits main.swift: one `run(...)` call per `func test...` found in the suite."""
import re, sys, pathlib

d = pathlib.Path(sys.argv[1])
entries = []
for f in sorted(d.glob("*Tests.swift")):
    src = f.read_text()
    m = re.search(r"class\s+(\w+)\s*:\s*XCTestCase", src)
    if not m:
        continue
    cls = m.group(1)
    for t in re.finditer(r"func\s+(test\w*)\s*\(\s*\)\s*(throws\s*)?\{", src):
        entries.append((cls, t.group(1), bool(t.group(2))))

body = "\n".join(
    '    run("%s.%s") { let obj = %s(); obj.setUp(); %s; obj.tearDown() }'
    % (cls, fn, cls, ("try obj.%s()" % fn) if throws else ("obj.%s()" % fn))
    for cls, fn, throws in entries
)

(d / "main.swift").write_text('''import Foundation
import XCTest

var total = 0, failed = 0
func run(_ name: String, _ body: () throws -> Void) {
    total += 1
    Recorder.failures.removeAll()
    do { try body() } catch {
        if !(error is TestFailure) { Recorder.record("threw \\(error)", #filePath, #line) }
    }
    if Recorder.failures.isEmpty {
        print("PASS  \\(name)")
    } else {
        failed += 1
        print("FAIL  \\(name)")
        for f in Recorder.failures { print("        \\(f)") }
    }
}

''' + body + '''

print("")
print("\\(total - failed) passed, \\(failed) failed  (of \\(total) tests)")
exit(failed == 0 ? 0 : 1)
''')
print("generated runner for %d tests" % len(entries))
