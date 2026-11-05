// Инструменты выпуска topbar: подпись обновлений ключом EdDSA (Ed25519) и сборка ленты обновлений (appcast) для Sparkle.
// Собственный код вместо готовых утилит Sparkle: формат простой (подпись Ed25519 над байтами файла, ключ — 32 байта в base64).
//
//   release-tool keygen <файл-ключа>                     создать ключ (права 0600) и напечатать открытую часть
//   release-tool public <файл-ключа>                     напечатать открытую часть
//   release-tool sign <файл-ключа> <файл>                напечатать sparkle:edSignature и length
//   release-tool verify <открытый-ключ> <файл> <подпись> код 0, если подпись верна
//   release-tool appcast <файл-ключа> <архив> <url-архива> <версия> <сборка> <файл-описания|-> [мин. macOS]
import CryptoKit
import Foundation

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
}

func loadKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { fail("Не удалось прочитать ключ \(path)") }
    return key
}

func signature(of file: String, key: Curve25519.Signing.PrivateKey) -> (String, Int) {
    guard let data = FileManager.default.contents(atPath: file) else { fail("Нет файла \(file)") }
    guard let sig = try? key.signature(for: data) else { fail("Не удалось подписать") }
    return (sig.base64EncodedString(), data.count)
}

func xml(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("Использование: release-tool keygen|public|sign|verify|appcast …") }

switch args[1] {
case "keygen":
    let path = args[2]
    if FileManager.default.fileExists(atPath: path) { fail("Ключ уже есть: \(path) (не перезаписываю)") }
    let key = Curve25519.Signing.PrivateKey()
    let ok = FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                            attributes: [.posixPermissions: 0o600])
    guard ok else { fail("Не удалось записать \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey(args[2]).publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count >= 4 else { fail("sign <файл-ключа> <файл>") }
    let (sig, length) = signature(of: args[3], key: loadKey(args[2]))
    print("sparkle:edSignature=\"\(sig)\" length=\"\(length)\"")
case "verify":
    guard args.count >= 5, let pub = Data(base64Encoded: args[2]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub),
          let sig = Data(base64Encoded: args[4]), let data = FileManager.default.contents(atPath: args[3]) else { fail("verify <открытый-ключ> <файл> <подпись>") }
    exit(key.isValidSignature(sig, for: data) ? 0 : 1)
case "appcast":
    guard args.count >= 8 else { fail("appcast <ключ> <архив> <url> <версия> <сборка> <описание|-> [мин. macOS]") }
    let (sig, length) = signature(of: args[3], key: loadKey(args[2]))
    let url = args[4], version = args[5], build = args[6]
    let notes = args[7] == "-" ? "" : ((try? String(contentsOfFile: args[7], encoding: .utf8)) ?? "")
    let minOS = args.count >= 9 ? args[8] : "14.0"
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    let date = formatter.string(from: Date())
    print("""
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
      <channel>
        <title>topbar</title>
        <item>
          <title>Версия \(xml(version))</title>
          <pubDate>\(date)</pubDate>
          <sparkle:version>\(xml(build))</sparkle:version>
          <sparkle:shortVersionString>\(xml(version))</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>\(xml(minOS))</sparkle:minimumSystemVersion>
          <description><![CDATA[\(notes)]]></description>
          <enclosure url="\(xml(url))" sparkle:edSignature="\(sig)" length="\(length)" type="application/octet-stream" />
        </item>
      </channel>
    </rss>
    """)
default:
    fail("Неизвестная команда \(args[1])")
}
