import XCTest
@testable import JDLV
import JDLVCore

// R4 Phase 1 凭据卫生门禁（任务 02 §4.6.4）：
//  - 默认值：口令为空、remoteHost 为空（不预置内网地址）；
//  - 落盘视图 storageWithoutSecrets 剔除口令键（JSON 编码后同样不含）；
//  - 欢迎文案不再引导用户去读口令文件（字面量运行时拼装，保持全仓扫描干净）；
//  - 诊断导出文本（SettingsStore 注入假口令后）不包含口令值与口令键名。
final class SecretHygieneTests: XCTestCase {

    private func freshDefaults(_ tag: String) -> UserDefaults {
        let name = "test_secrethygiene_\(tag)"
        UserDefaults().removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }

    func testDefaultSettingsHaveNoSecretsAndNoIntranetHost() {
        let s = AppSettings()
        XCTAssertEqual(s.remotePass, "", "remotePass 默认必须为空")
        XCTAssertEqual(s.localPass, "", "localPass 默认必须为空")
        XCTAssertEqual(s.remoteHost, "", "remoteHost 默认必须为空（不预置内网地址）")
    }

    func testStorageWithoutSecretsDropsSecretKeys() throws {
        let storage = AppSettings().storageWithoutSecrets
        for k in AppSettings.secretStorageKeys {
            XCTAssertFalse(storage.keys.contains(k), "落盘视图不得包含口令键 \(k)")
        }
        let data = try XCTUnwrap(AppSettings.encodeStorageJSON(storage))
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("remote_pass"), "JSON 不得出现口令键 remote_pass")
        XCTAssertFalse(json.contains("local_pass"), "JSON 不得出现口令键 local_pass")
        XCTAssertFalse(json.contains("lock_secret"), "JSON 不得出现口令键 lock_secret")
    }

    func testWelcomeHintDoesNotPointAtCredentialFiles() {
        let banned = "mysql" + ".txt"
        XCTAssertFalse(SearchCopy.welcomeHint.contains(banned),
                       "欢迎文案不得再引导用户使用口令文件")
        XCTAssertTrue(SearchCopy.welcomeHint.contains("钥匙串"),
                      "欢迎文案应指向本机钥匙串保存")
    }

    @MainActor
    func testDiagnosticsExportExcludesInjectedSecrets() async throws {
        let store = SettingsStore(defaults: freshDefaults("diag"))
        // 假口令运行时拼装（源码不出现可扫描的口令字面量形态）
        let fakeRemote = "FR" + String(repeating: "x", count: 10) + "!"
        let fakeLocal = "FL" + String(repeating: "y", count: 10) + "!"
        store.edit {
            $0.remotePass = fakeRemote
            $0.localPass = fakeLocal
            $0.remoteHost = "10.0.0.9"
        }
        // edit 走防抖链（1.3s 落盘窗口），等它应用后再导出
        try await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertEqual(store.settings.remotePass, fakeRemote, "前置：假口令已注入 store")

        let lines = SettingsDiagnostics.diagnosticLines(
            s: store.settings,
            metaLines: ["JDLV iOS 诊断日志", "生成时间: \(Date())"])
        let text = lines.joined(separator: "\n")
        XCTAssertFalse(text.contains(fakeRemote), "诊断文本不得包含远程口令值")
        XCTAssertFalse(text.contains(fakeLocal), "诊断文本不得包含本地口令值")
        XCTAssertFalse(text.contains("remote_pass"), "诊断文本不得出现口令键名")
        XCTAssertFalse(text.contains("local_pass"), "诊断文本不得出现口令键名")
        XCTAssertFalse(text.contains("lock_secret"), "诊断文本不得出现口令键名")
    }
}
