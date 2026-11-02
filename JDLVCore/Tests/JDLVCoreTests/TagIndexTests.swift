import Foundation
import XCTest
@testable import JDLVCore

/// B13. TagIndexTest —— 标签名↔ID 双向索引与合并（15 用例）。
/// 合并优先级：远程 taxonomy > assets；id→name 优先远程 name，缺失回退 assets；
/// 查不到返回 nil 由 UI 显示 #id。
final class TagIndexTests: XCTestCase {

    /// assets 资产表：{"1"→巨乳, "2"→人妻, "3"→單體作品}
    private func makeAssets() -> TagIndex {
        TagIndex.of([("1", "巨乳"), ("2", "人妻"), ("3", "單體作品")])
    }

    // MARK: - 双向查

    /// nameToId：assets {"1"→巨乳,...} → idOf("巨乳")=="1"
    func testNameToId() {
        XCTAssertEqual(makeAssets().idOf("巨乳"), "1")
    }

    /// idToName：nameOf("2")=="人妻"
    func testIdToName() {
        XCTAssertEqual(makeAssets().nameOf("2"), "人妻")
    }

    /// unknownIdReturnsNull：查不到的 id → nil
    func testUnknownIdReturnsNull() {
        XCTAssertNil(makeAssets().nameOf("999"))
    }

    /// unknownNameReturnsNull：查不到的名字 → nil
    func testUnknownNameReturnsNull() {
        XCTAssertNil(makeAssets().idOf("不存在"))
    }

    /// emptyIndex：EMPTY 索引 isEmpty() 且查询恒 nil
    func testEmptyIndex() {
        XCTAssertTrue(TagIndex.EMPTY.isEmpty())
        XCTAssertNil(TagIndex.EMPTY.idOf("x"))
        XCTAssertNil(TagIndex.EMPTY.nameOf("x"))
    }

    /// blankInputs：空白/nil 输入一律拒绝（trim 后为空即 nil）
    func testBlankInputs() {
        let assets = makeAssets()
        XCTAssertNil(assets.idOf(""))
        XCTAssertNil(assets.idOf("   "))
        XCTAssertNil(assets.nameOf(""))
        XCTAssertNil(assets.nameOf("   "))
        XCTAssertNil(assets.idOf(nil))
        XCTAssertNil(assets.nameOf(nil))
    }

    // MARK: - 合并（远程优先）

    /// remoteOverridesSameNameWithDifferentId：远程同名不同 id 覆盖
    func testRemoteOverridesSameNameWithDifferentId() {
        let merged = TagIndex.merge(makeAssets(), TagIndex.of([("77", "巨乳")]))
        XCTAssertEqual(merged.idOf("巨乳"), "77")
        XCTAssertEqual(merged.nameOf("77"), "巨乳")
    }

    /// remoteNameOverridesIdToName：远程 id→name 覆盖资产名
    func testRemoteNameOverridesIdToName() {
        let merged = TagIndex.merge(makeAssets(), TagIndex.of([("2", "已婚")]))
        XCTAssertEqual(merged.nameOf("2"), "已婚")
        XCTAssertEqual(merged.idOf("已婚"), "2")
    }

    /// idToNameFallsBackToAssets：远程新增不破坏资产映射
    func testIdToNameFallsBackToAssets() {
        let merged = TagIndex.merge(makeAssets(), TagIndex.of([("9", "新标签")]))
        XCTAssertEqual(merged.nameOf("2"), "人妻")
        XCTAssertEqual(merged.nameOf("9"), "新标签")
        XCTAssertEqual(merged.idOf("人妻"), "2")
    }

    /// mergeWithNullKeepsAssets：remote 为 nil → 原样保留资产
    func testMergeWithNullKeepsAssets() {
        let merged = makeAssets().mergeWith(nil)
        XCTAssertEqual(merged.idOf("巨乳"), "1")
        XCTAssertEqual(merged.nameOf("1"), "巨乳")
    }

    /// emptyRemoteKeepsAssets：空远程索引不参与合并
    func testEmptyRemoteKeepsAssets() {
        let merged = TagIndex.merge(makeAssets(), TagIndex.EMPTY)
        XCTAssertEqual(merged.idOf("單體作品"), "3")
        XCTAssertEqual(merged, makeAssets())
    }

    // MARK: - TagIndex.of 归并规则

    /// duplicateIdKeepsFirstName：同 id 取首条真实名
    func testDuplicateIdKeepsFirstName() {
        let idx = TagIndex.of([("5", "甲"), ("5", "乙")])
        XCTAssertEqual(idx.nameOf("5"), "甲")
        XCTAssertEqual(idx.idOf("甲"), "5")
    }

    /// placeholderNameIsReplacedByRealName：占位名 name==id 不锁死 id→name，
    /// 后续真实名可覆盖（assets 存在 id=10/8 的占位名）
    func testPlaceholderNameIsReplacedByRealName() {
        let idx = TagIndex.of([
            ("10", "10"), ("10", "4小时以上作品"),
            ("8", "8"), ("8", "中文字幕"),
        ])
        XCTAssertEqual(idx.nameOf("10"), "4小时以上作品")
        XCTAssertEqual(idx.nameOf("8"), "中文字幕")
        XCTAssertEqual(idx.idOf("4小时以上作品"), "10")
    }

    /// invalidPairsIgnored：空 id / 空名的对全部忽略
    func testInvalidPairsIgnored() {
        let idx = TagIndex.of([("", "空id"), ("6", "")])
        XCTAssertTrue(idx.isEmpty())
        XCTAssertEqual(idx, TagIndex.EMPTY)
        XCTAssertNil(idx.idOf("空id"))
    }

    /// remoteHitDoesNotEraseAssets：远程命中不清空资产映射
    func testRemoteHitDoesNotEraseAssets() {
        let merged = TagIndex.merge(makeAssets(), TagIndex.of([("100", "远程标签")]))
        XCTAssertFalse(merged.isEmpty())
        XCTAssertEqual(merged.idOf("巨乳"), "1")
        XCTAssertEqual(merged.nameOf("100"), "远程标签")
    }
}
