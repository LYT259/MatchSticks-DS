import Foundation

// MARK: - OpenStep 文本 .strings 解析（纯 Swift，三平台同一实现）
//
// `en.lproj/Localizable.strings` 是 OpenStep 老式 plist 文本（"key" = "value";，支持 /* */ 与 // 注释、
// \" \\ \n \r \t 与 \uXXXX 转义）。Apple 平台的 Bundle.localizedString 能读它，但 corelibs Foundation
// 在 Linux/Windows 上对该格式的支持不可依赖，故统一自己解析。
// 容错：坏条目（缺等号/无值/未闭合引号）跳过不入表，不影响其余条目；重复键取后者。

public enum OpenStepStringsTable {
    public static func parse(_ text: String) -> [String: String] {
        var parser = Parser(text)
        return parser.parseEntries()
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ text: String) {
            scalars = Array(text.unicodeScalars)
        }

        var end: Int { scalars.count }

        mutating func parseEntries() -> [String: String] {
            var result: [String: String] = [:]
            while true {
                skipTrivia()
                guard index < end else { break }
                if scalars[index] == ";" { index += 1; continue }
                guard let key = readToken() else { break }
                skipTrivia()
                guard index < end, scalars[index] == "=" else {
                    skipToSemicolon()
                    continue
                }
                index += 1
                skipTrivia()
                guard let value = readToken() else {
                    skipToSemicolon()
                    continue
                }
                skipTrivia()
                if index < end, scalars[index] == ";" { index += 1 }
                result[key] = value
            }
            return result
        }

        mutating func skipTrivia() {
            while index < end {
                let c = scalars[index]
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    index += 1
                } else if c == "/", index + 1 < end, scalars[index + 1] == "*" {
                    index += 2
                    while index + 1 < end, !(scalars[index] == "*" && scalars[index + 1] == "/") { index += 1 }
                    index = min(end, index + 2)
                } else if c == "/", index + 1 < end, scalars[index + 1] == "/" {
                    while index < end, scalars[index] != "\n" { index += 1 }
                } else {
                    return
                }
            }
        }

        mutating func skipToSemicolon() {
            while index < end, scalars[index] != ";" { index += 1 }
            if index < end { index += 1 }
        }

        /// 引号串（含转义）或裸 token；到结尾/无内容返回 nil
        mutating func readToken() -> String? {
            guard index < end else { return nil }
            if scalars[index] == "\"" { return readQuoted() }
            var out = String.UnicodeScalarView()
            while index < end {
                let c = scalars[index]
                if c == "=" || c == ";" || c == " " || c == "\t" || c == "\n" || c == "\r" { break }
                out.append(c)
                index += 1
            }
            return out.isEmpty ? nil : String(out)
        }

        mutating func readQuoted() -> String? {
            index += 1
            var out = String.UnicodeScalarView()
            while index < end {
                let c = scalars[index]
                if c == "\"" {
                    index += 1
                    return String(out)
                }
                if c == "\\" {
                    index += 1
                    guard index < end else { return nil }
                    let escape = scalars[index]
                    switch escape {
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "u", "U":
                        var hex = ""
                        var digits = 0
                        while index + 1 < end, digits < 4, scalars[index + 1].properties.isASCIIHexDigit {
                            index += 1
                            hex.unicodeScalars.append(scalars[index])
                            digits += 1
                        }
                        if digits == 4, let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                            out.append(scalar)
                        }
                    default:
                        out.append(escape)
                    }
                    index += 1
                    continue
                }
                out.append(c)
                index += 1
            }
            return nil
        }
    }
}
