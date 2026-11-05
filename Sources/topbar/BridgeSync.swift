import Foundation
import TopbarCore

/// Мост хука лежит по стабильному пути, на который ссылаются хуки. При обновлении приложения копия там устаревает:
/// при запуске сверяем её с мостом из приложения и заменяем (атомарно; уже запущенные хуки доработают со старой копией).
enum BridgeSync {
    static func syncIfNeeded() {
        let fm = FileManager.default
        let target = Paths.bridgeInstallPath
        guard let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("topbar-hook"),
              fm.fileExists(atPath: target), fm.fileExists(atPath: bundled.path),
              !fm.contentsEqual(atPath: bundled.path, andPath: target) else { return }
        let staging = target + ".new"
        do {
            try? fm.removeItem(atPath: staging)
            try fm.copyItem(atPath: bundled.path, toPath: staging)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging)
            _ = try fm.replaceItemAt(URL(fileURLWithPath: target), withItemAt: URL(fileURLWithPath: staging))
        } catch {
            try? fm.removeItem(atPath: staging)
        }
    }
}
