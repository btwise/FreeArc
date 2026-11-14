import Foundation
import Testing
@testable import ArchiveCore

/// 包内编辑能力矩阵：只有 ZIP 家族能安全重写，其余格式必须只读；
/// 加密包与分卷包同样不进编辑态（否则用户改完才在保存时失败）。
struct EditPolicyTests {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    @Test("ZIP 与 JAR 可编辑")
    func zipFamilyIsEditable() {
        #expect(ArchiveEditPolicy.capability(
            url: url("a.zip"), format: .zip, isEncrypted: false
        ) == .editable)
        #expect(ArchiveEditPolicy.capability(
            url: url("app.jar"), format: .zip, isEncrypted: false
        ) == .editable)
        #expect(ArchiveEditPolicy.capability(
            url: url("pkg.apk"), format: .zip, isEncrypted: false
        ) == .editable)
    }

    @Test("非 ZIP 容器为只读")
    func nonZipIsReadOnly() {
        for (name, format) in [("a.7z", ArchiveFormat.sevenZip), ("a.rar", .rar), ("a.tar", .tar), ("a.dmg", .dmg)] {
            guard case .readOnly(let reason) = ArchiveEditPolicy.capability(
                url: url(name), format: format, isEncrypted: false
            ) else {
                Issue.record("\(name) 不应可编辑")
                continue
            }
            #expect(reason.contains(format.rawValue))
        }
    }

    @Test("加密包与分卷包为只读")
    func encryptedAndVolumeAreReadOnly() {
        guard case .readOnly(let encrypted) = ArchiveEditPolicy.capability(
            url: url("secret.zip"), format: .zip, isEncrypted: true
        ) else {
            Issue.record("加密包不应可编辑")
            return
        }
        #expect(encrypted.contains("加密"))

        guard case .readOnly(let volume) = ArchiveEditPolicy.capability(
            url: url("big.zip.001"), format: .zip, isEncrypted: false
        ) else {
            Issue.record("分卷包不应可编辑")
            return
        }
        #expect(volume.contains("分卷"))
    }

    @Test("同时保留的命名规则")
    func keepBothNaming() {
        #expect(ArchiveEntryName.keepBoth("报告.pdf", taken: ["报告.pdf"]) == "报告 2.pdf")
        #expect(ArchiveEntryName.keepBoth("报告.pdf", taken: ["报告.pdf", "报告 2.pdf"]) == "报告 3.pdf")
        #expect(ArchiveEntryName.keepBoth("README", taken: ["README"]) == "README 2")
        #expect(ArchiveEntryName.keepBoth("a.tar.gz", taken: ["a.tar.gz"]) == "a.tar 2.gz")
    }

    @Test("JAR 签名文件识别")
    func packageSignatureDetection() {
        #expect(!ArchiveEditPolicy.containsPackageSignature(paths: [
            "META-INF/MANIFEST.MF", "com/example/Main.class"
        ]))
        #expect(ArchiveEditPolicy.containsPackageSignature(paths: [
            "META-INF/MANIFEST.MF", "META-INF/CERT.SF"
        ]))
        #expect(ArchiveEditPolicy.containsPackageSignature(paths: ["META-INF/CERT.RSA"]))
        #expect(ArchiveEditPolicy.containsPackageSignature(paths: ["META-INF/KEY.DSA"]))
        // 只在 META-INF 根下才算签名；子目录里的同名扩展名不算
        #expect(!ArchiveEditPolicy.containsPackageSignature(paths: ["docs/META-INF/CERT.SF"]))
    }
}
