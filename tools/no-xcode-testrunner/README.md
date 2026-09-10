# 无 Xcode 测试运行器

`swift test` 需要 XCTest，而 XCTest 只随完整 Xcode 分发，Command Line Tools 里没有。
在只装了 CLT 的机器上会直接报：

```
warning: could not determine XCTest paths: ...
error: XCTest not available
```

这个目录提供一个绕开办法：把 `CoachMeCore/Tests/` 里**原封不动**的测试文件，
连同一个最小 XCTest 垫片（`XCTestShim.swift`）和自动生成的 runner 一起编译成可执行文件。
断言逻辑是真跑的，跑的也是真实的 `CoachMeCore`。

```bash
tools/no-xcode-testrunner/run.sh
```

## 局限

- 只覆盖 `CoachMeCore` 的测试。`CoachMeTests/ChatFrameworkTests.swift` 用了
  `@testable import CoachMe`，依赖 App 目标，这里跑不了。
- 垫片只实现了本仓库用到的断言：`XCTAssertEqual`（含 `accuracy:`）、`XCTAssertTrue`/
  `XCTAssertFalse`、`XCTAssertNil`/`XCTAssertNotNil`、`XCTAssertGreaterThan`/
  `XCTAssertLessThan`、`XCTUnwrap`、`XCTFail`。新测试用到别的断言需要自行补。
- 没有 `measure`、异步期望、参数化等 XCTest 特性。
- **装了 Xcode 之后就别用这个了**，直接 `swift test`。
