import XCTest
import JDLVCore
@testable import JDLV

// R4 P9 门禁（任务 06 §17.5.6/§17.7.3）：注入失败 store —— FavsVM.reload 显式 error
// （与空收藏区分，绝不静默显示为空）；remove 失败同样置位 error。
final class FavsVMTests: XCTestCase {

    /// 恒失败的 FavsStore（模拟 SQLite 打不开/磁盘错误）
    private struct FailingFavsStore: FavsStore {
        func favList(kind: String) async throws -> [Row] { throw StoreUnavailable() }
        func favRemove(kind: String, id: String, title: String) async throws {
            throw StoreUnavailable()
        }
    }

    @MainActor
    func testReloadErrorSurfacesNotSilentEmpty() async {
        let vm = FavsVM(store: FailingFavsStore())
        await vm.reload()
        XCTAssertNotNil(vm.error, "读取失败必须显式 error（V42：不能显示为空收藏）")
        XCTAssertFalse(vm.error?.isEmpty ?? true, "error 必须有可读文案")
    }

    @MainActor
    func testRemoveFailureSurfacesError() async {
        let vm = FavsVM(store: FailingFavsStore())
        let row = Row(["kind": .string("movie"), "id": .string("m1"), "title": .string("T")])
        await vm.remove(row)
        XCTAssertNotNil(vm.error, "删除失败必须显式 error")
    }

    @MainActor
    func testDemoStoreReloadNoError() async {
        // demo store 不抛错 → reload 后 error == nil（正常路径回归保护）
        let vm = FavsVM(store: DemoFavsStore())
        await vm.reload()
        XCTAssertNil(vm.error)
    }
}
