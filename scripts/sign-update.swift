// MARK: Sparkle appcast EdDSA 签名工具（CryptoKit Ed25519；不依赖 Sparkle 二进制工具）
//
// 用法：
//   swift scripts/sign-update.swift genkey <私钥文件路径>
//     生成 Ed25519 密钥对：私钥（base64 种子）写入文件（0600），打印公钥 base64
//     （放入 .app Info.plist 的 SUPublicEDKey；本地打包经 build-app.sh 的 SU_PUBLIC_ED_KEY 环境变量）。
//   swift scripts/sign-update.swift sign <私钥文件路径> <待签名文件>
//     打印 appcast item 属性串：sparkle:edSignature="…" length="…"
//     （Sparkle 2 校验的即 RFC 8032 Ed25519 签名，与官方 sign_update 工具互验）。
//
// 私钥纪律：真发版私钥只留本机（不入库、不进日志）；本地升级链路测试用临时密钥。

import Foundation
import CryptoKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("错误：\(message)\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : ""
let keyPath = args.count > 2 ? args[2] : ""
if mode == "genkey" {
    guard args.count == 3 else { fail("genkey 参数：<私钥文件路径>") }
} else if mode == "sign" {
    guard args.count == 4 else { fail("sign 参数：<私钥文件路径> <待签名文件>") }
} else {
    fail("参数：<genkey|sign> <私钥文件路径> [sign: <待签名文件>]")
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("无法读取私钥文件 \(keyPath)（期望 base64 种子，由 genkey 生成）")
    }
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
        fail("私钥种子格式无效")
    }
    return key
}

switch mode {
case "genkey":
    let key = Curve25519.Signing.PrivateKey()
    let seed = key.rawRepresentation
    FileManager.default.createFile(atPath: keyPath, contents: Data(seed.base64EncodedString().utf8))
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)
    print("公钥（SUPublicEDKey）：\(key.publicKey.rawRepresentation.base64EncodedString())")
    print("私钥已写入：\(keyPath)（0600，勿入库勿外传）")
case "sign":
    let filePath = args[3]
    guard let data = FileManager.default.contents(atPath: filePath) else {
        fail("无法读取待签名文件 \(filePath)")
    }
    let key = loadPrivateKey()
    guard let signature = try? key.signature(for: data) else {
        fail("签名失败")
    }
    // 自验：签名公钥对可还原（防止输出坏签名）
    guard key.publicKey.isValidSignature(signature, for: data) else {
        fail("签名自验失败")
    }
    print("sparkle:edSignature=\"\(signature.base64EncodedString())\" length=\"\(data.count)\"")
default:
    fail("未知模式 \(mode)（期望 genkey 或 sign）")
}
