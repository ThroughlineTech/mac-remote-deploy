// Tests for ProjectSetupValidators extracted from ProjectSetupStep. TKT-014.
@testable import RemoteDeploy
import XCTest

final class ProjectSetupValidatorsTests: XCTestCase {

    // MARK: - validateBundleID

    func test_validateBundleID_emptyReturnsNil() {
        XCTAssertNil(ProjectSetupValidators.validateBundleID(""))
    }

    func test_validateBundleID_acceptsValidReverseDNS() {
        XCTAssertNil(ProjectSetupValidators.validateBundleID("com.example.app"))
        XCTAssertNil(ProjectSetupValidators.validateBundleID("com.example.sub-app"))
        XCTAssertNil(ProjectSetupValidators.validateBundleID("io.a.b.c"))
    }

    func test_validateBundleID_rejectsSingleSegment() {
        XCTAssertNotNil(ProjectSetupValidators.validateBundleID("com"))
    }

    func test_validateBundleID_rejectsTrailingDot() {
        XCTAssertNotNil(ProjectSetupValidators.validateBundleID("com.example."))
    }

    func test_validateBundleID_rejectsDigitFirstSegment() {
        XCTAssertNotNil(ProjectSetupValidators.validateBundleID("1com.example.app"))
    }

    // MARK: - validateTeamID

    func test_validateTeamID_emptyReturnsNil() {
        XCTAssertNil(ProjectSetupValidators.validateTeamID(""))
    }

    func test_validateTeamID_acceptsTenUppercaseAlnum() {
        XCTAssertNil(ProjectSetupValidators.validateTeamID("ABCD123456"))
    }

    func test_validateTeamID_rejectsWrongLength() {
        XCTAssertNotNil(ProjectSetupValidators.validateTeamID("ABCD12345")) // 9
        XCTAssertNotNil(ProjectSetupValidators.validateTeamID("ABCD1234567")) // 11
    }

    func test_validateTeamID_rejectsLowercase() {
        XCTAssertNotNil(ProjectSetupValidators.validateTeamID("abcd123456"))
    }

    // MARK: - validatePath

    func test_validatePath_emptyReturnsNil() {
        XCTAssertNil(ProjectSetupValidators.validatePath(""))
    }

    func test_validatePath_rejectsNonexistentPath() {
        XCTAssertNotNil(ProjectSetupValidators.validatePath("/absolutely/does/not/exist/\(UUID().uuidString)"))
    }

    func test_validatePath_acceptsExistingPath() {
        // /tmp exists on every macOS system
        XCTAssertNil(ProjectSetupValidators.validatePath("/tmp"))
    }

    // MARK: - validateScheme (TKT-014 — empty is an ERROR here)

    func test_validateScheme_emptyReturnsError() {
        XCTAssertNotNil(
            ProjectSetupValidators.validateScheme(""),
            "TKT-014: empty scheme must be rejected — scheme is required to build"
        )
    }

    func test_validateScheme_nonEmptyReturnsNil() {
        XCTAssertNil(ProjectSetupValidators.validateScheme("MyApp"))
    }
}
