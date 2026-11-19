import XCTest
@testable import ProxyBrowser

final class RouteSelectionTests: XCTestCase {
    func testMigratesConflictingLegacyRegionWithoutChangingNode() {
        let selection = RouteSelection(names: ["🇸🇬 Singapore丨TEST-A", "🇺🇸 United States丨TEST-A"],
                                       savedNode: "🇸🇬 Singapore丨TEST-A", legacyCountry: "US")
        XCTAssertEqual(selection.selected?.name, "🇸🇬 Singapore丨TEST-A")
        XCTAssertEqual(selection.filter, "SG")
        XCTAssertEqual(selection.available.count, 1)
    }

    func testChangingRegionCannotKeepAnIncompatibleNode() {
        var selection = RouteSelection(names: ["🇸🇬 Singapore丨TEST-A", "US-TEST-A", "US-TEST-B", "备用"],
                                       savedNode: "🇸🇬 Singapore丨TEST-A", savedFilter: "SG")
        selection.setFilter("US")
        XCTAssertNil(selection.selected)
        XCTAssertEqual(selection.available.map(\.name), ["US-TEST-A", "US-TEST-B"])
        selection.select("🇸🇬 Singapore丨TEST-A")
        XCTAssertNil(selection.selected)
        selection.select("US-TEST-B")
        selection.setFilter("SG")
        XCTAssertEqual(selection.selected?.name, "🇸🇬 Singapore丨TEST-A")
        selection.setFilter("US")
        XCTAssertEqual(selection.selected?.name, "US-TEST-B")
    }

    func testAmbiguousLabelsRemainInAllRegionsAndLegacyAutoStaysAuto() {
        let selection = RouteSelection(names: ["🇸🇬 Singapore", "🇺🇸 美国入口 → 新加坡", "备用"],
                                       savedNode: "🇸🇬 Singapore", legacyCountry: "")
        XCTAssertEqual(selection.filter, "")
        XCTAssertEqual(selection.regions, ["SG"])
        XCTAssertEqual(selection.available.count, 3)
        XCTAssertNil(NodeRegions.infer("🇺🇸 美国入口 → 新加坡"))
        XCTAssertEqual(NodeRegions.infer("🇭🇰 中国香港特别行政区"), "HK")
        XCTAssertEqual(NodeRegions.infer("Great Britain | 01"), "GB")
    }
}
