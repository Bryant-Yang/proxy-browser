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

    func testUnambiguousTextControlsFilteringWhenFlagsDiffer() {
        let american = "\u{1F1FA}\u{1F1F2} 美国 02"
        let taiwanese = "\u{1F1E8}\u{1F1F3} 台湾 TEST"
        let german = "\u{1F1EF}\u{1F1F5} Germany TEST"
        var selection = RouteSelection(names: [american, taiwanese, german], savedNode: american)

        XCTAssertEqual(Set(selection.regions), ["US", "TW", "DE"])
        selection.setFilter("US")
        XCTAssertEqual(selection.available.map(\.name), [american])
        XCTAssertEqual(selection.selected?.name, american)
    }

    func testFlagOnlySuppliesRegionWhenTextHasNoRegion() {
        let japan = "\u{1F1EF}\u{1F1F5}"
        let america = "\u{1F1FA}\u{1F1F8}"
        XCTAssertEqual(NodeRegions.infer(japan + " 01"), "JP")
        XCTAssertNil(NodeRegions.infer(japan + " " + america + " 01"))
        XCTAssertNil(NodeRegions.infer(japan + " 美国入口 → 新加坡"))
        XCTAssertNil(NodeRegions.infer("JP | " + america + " United States 01"))
    }

    func testRegionCodeAfterDecorativeFlagTakesPrecedence() {
        let decoratedTaiwan = "\u{1F1E8}\u{1F1F3} TW-TEST"
        let decoratedAmerica = "\u{1F1FA}\u{1F1F2} | US TEST"
        XCTAssertEqual(NodeRegions.infer(decoratedTaiwan), "TW")
        XCTAssertEqual(NodeRegions.infer(decoratedAmerica), "US")
        XCTAssertNil(NodeRegions.infer(decoratedTaiwan + " United States"))
    }
}
