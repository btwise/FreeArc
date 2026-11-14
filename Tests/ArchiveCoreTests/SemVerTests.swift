import XCTest
@testable import ArchiveCore

/// 语义化版本解析与比较（更新检查的比较基础）。
final class SemVerTests: XCTestCase {
    func testParseBasic() {
        XCTAssertEqual(SemVer.parse("1.2.0"), [1, 2, 0])
        XCTAssertEqual(SemVer.parse("v1.2.0"), [1, 2, 0])
        XCTAssertEqual(SemVer.parse("V10.20.30"), [10, 20, 30])
        XCTAssertEqual(SemVer.parse("1.2"), [1, 2, 0])
        XCTAssertEqual(SemVer.parse("2"), [2, 0, 0])
    }

    func testParseSuffixes() {
        // 预发布与构建元数据后缀在比较语义下忽略
        XCTAssertEqual(SemVer.parse("1.2.0-beta.1"), [1, 2, 0])
        XCTAssertEqual(SemVer.parse("1.2.0+build42"), [1, 2, 0])
        XCTAssertEqual(SemVer.parse("  v1.2.3  "), [1, 2, 3])
    }

    func testParseInvalid() {
        XCTAssertNil(SemVer.parse(""))
        XCTAssertNil(SemVer.parse("abc"))
        XCTAssertNil(SemVer.parse("1.x.0"))
        XCTAssertNil(SemVer.parse("1.2.3.4.5"))
        // 注："1.2.-3" 里的 -3 会被当作预发布后缀剥离（得 1.2.0），属设计内行为
    }

    func testCompare() {
        XCTAssertEqual(SemVer.compare("1.2.0", to: "1.2.0"), .orderedSame)
        XCTAssertEqual(SemVer.compare("1.2.1", to: "1.2.0"), .orderedDescending)
        XCTAssertEqual(SemVer.compare("1.2.0", to: "1.2.1"), .orderedAscending)
        XCTAssertEqual(SemVer.compare("2.0.0", to: "1.99.99"), .orderedDescending)
        XCTAssertEqual(SemVer.compare("v1.3.0", to: "1.2.9"), .orderedDescending)
        // 预发布后缀不影响主版本比较（1.2.0-beta 与 1.2.0 同级）
        XCTAssertEqual(SemVer.compare("1.2.0-beta", to: "1.2.0"), .orderedSame)
        // 任一侧无法解析 → 视为相等（不弹假更新）
        XCTAssertEqual(SemVer.compare("abc", to: "1.2.0"), .orderedSame)
    }

    func testNormalized() {
        XCTAssertEqual(SemVer.normalized("v1.2"), "1.2.0")
        XCTAssertEqual(SemVer.normalized("1.2.3"), "1.2.3")
        XCTAssertEqual(SemVer.normalized("not-a-version"), "not-a-version")
    }
}
