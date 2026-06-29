// Unit tests for the build-log classifier (TKT-074): the pure line->kind rule
// the menu bar's log window uses for color coding, and the incremental cache that
// keeps a SwiftUI re-render from reclassifying the whole buffer.
//
// These live in the shared package so they are testable from RemoteDeployTests,
// which cannot link the menu bar target (mirrors BuildStateReconciler).
import RemoteDeployShared
import XCTest

final class BuildLogClassifierTests: XCTestCase {

    // MARK: - BuildLogLineKind.classify

    func test_classify_errorLine_isError() {
        XCTAssertEqual(BuildLogLineKind.classify("foo.swift:12: error: bad"), .error)
    }

    func test_classify_fatalLine_isError() {
        XCTAssertEqual(BuildLogLineKind.classify("fatal error: file not found"), .error)
    }

    func test_classify_warningLine_isWarning() {
        XCTAssertEqual(BuildLogLineKind.classify("foo.swift:3: warning: unused"), .warning)
    }

    func test_classify_buildSucceeded_isSuccess() {
        XCTAssertEqual(BuildLogLineKind.classify("** BUILD SUCCEEDED **"), .success)
    }

    func test_classify_normalLine_isNormal() {
        XCTAssertEqual(BuildLogLineKind.classify("Compiling Foo.swift"), .normal)
    }

    func test_classify_isCaseInsensitive() {
        XCTAssertEqual(BuildLogLineKind.classify("ERROR: boom"), .error)
        XCTAssertEqual(BuildLogLineKind.classify("Build Succeeded"), .success)
    }

    func test_classify_errorWinsOverWarning() {
        // Error is checked first, so a line mentioning both is an error.
        XCTAssertEqual(BuildLogLineKind.classify("error: also has warning: text"), .error)
    }

    func test_classify_emptyLine_isNormal() {
        XCTAssertEqual(BuildLogLineKind.classify(""), .normal)
    }

    // MARK: - BuildLogClassifierCache

    /// Convenience: the kinds the cache produced, for terse assertions.
    private func kinds(_ entries: [BuildLogClassifierCache.Entry]) -> [BuildLogLineKind] {
        entries.map(\.kind)
    }

    func test_cache_empty_returnsEmpty() {
        let cache = BuildLogClassifierCache()
        XCTAssertTrue(cache.classify([]).isEmpty)
    }

    func test_cache_firstFill_classifiesEverything() {
        let cache = BuildLogClassifierCache()
        let entries = cache.classify(["compile", "error: x", "warning: y"])
        XCTAssertEqual(entries.map(\.text), ["compile", "error: x", "warning: y"])
        XCTAssertEqual(kinds(entries), [.normal, .error, .warning])
    }

    func test_cache_unchangedInput_returnsSameResult() {
        let cache = BuildLogClassifierCache()
        let lines = ["a", "error: b"]
        let first = cache.classify(lines)
        let second = cache.classify(lines)
        XCTAssertEqual(first, second)
        XCTAssertEqual(kinds(second), [.normal, .error])
    }

    func test_cache_appendOnlyGrowth_classifiesNewTail() {
        let cache = BuildLogClassifierCache()
        _ = cache.classify(["compile", "still compiling"])
        let grown = cache.classify(["compile", "still compiling", "error: boom", "** BUILD SUCCEEDED **"])
        XCTAssertEqual(grown.map(\.text), ["compile", "still compiling", "error: boom", "** BUILD SUCCEEDED **"])
        XCTAssertEqual(kinds(grown), [.normal, .normal, .error, .success])
    }

    func test_cache_resetToEmpty_thenRefill() {
        let cache = BuildLogClassifierCache()
        _ = cache.classify(["error: old build"])
        _ = cache.classify([])
        let refilled = cache.classify(["warning: new build"])
        XCTAssertEqual(refilled.map(\.text), ["warning: new build"])
        XCTAssertEqual(kinds(refilled), [.warning])
    }

    func test_cache_shrink_reclassifiesFromScratch() {
        let cache = BuildLogClassifierCache()
        _ = cache.classify(["a", "b", "error: c"])
        let shrunk = cache.classify(["warning: d"])
        XCTAssertEqual(shrunk.map(\.text), ["warning: d"])
        XCTAssertEqual(kinds(shrunk), [.warning])
    }

    func test_cache_growthWithChangedBoundary_reclassifiesCorrectly() {
        // A new build can replace the buffer with MORE lines than before. The
        // previously-last line no longer sits at its old index, so the cache must
        // fall back to a full reclassify rather than splicing a stale prefix.
        let cache = BuildLogClassifierCache()
        _ = cache.classify(["old line 1", "old line 2"])
        let replaced = cache.classify(["new: a", "error: b", "warning: c"])
        XCTAssertEqual(replaced.map(\.text), ["new: a", "error: b", "warning: c"])
        XCTAssertEqual(kinds(replaced), [.normal, .error, .warning])
    }
}
