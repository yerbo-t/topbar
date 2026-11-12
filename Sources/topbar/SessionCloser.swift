import Foundation
import TopbarCore

/// Закрытие сессии крестом на острове. Сессию во вкладке Ghostty или Terminal: процесс Claude получает сигнал, как при закрытии
/// окна терминала, и, когда он завершится, закрывается сама вкладка — с одной оболочкой терминал закрывает её без вопроса
/// (Terminal иначе спросил бы, прерывать ли процессы). Остальные сессии этим не трогаются: их только убирает с острова хаб.
@MainActor
enum SessionCloser {
    /// Сколько ждать, пока Claude завершится, прежде чем закрывать вкладку: 10 проверок по 0,2 с.
    private static let exitChecks = 10

    static func close(_ session: Session) {
        guard let tty = session.tty, let bundleId = SessionJumper.hostBundleId(of: session),
              TerminalScripting.canClose(bundleId),
              session.pid > 0, ProcessProbe.isAlive(pid: session.pid, startedAt: session.processStartedAt),
              // tty переиспользуются: закрываем, только если процесс сессии и сейчас сидит в этой вкладке.
              ProcessProbe.ttyName(of: session.pid) == tty else { return }
        kill(session.pid, SIGHUP)
        closeTab(bundleId: bundleId, tty: tty, pid: session.pid, startedAt: session.processStartedAt, check: 0)
    }

    private static func closeTab(bundleId: String, tty: String, pid: Int32, startedAt: Double?, check: Int) {
        if check < exitChecks, ProcessProbe.isAlive(pid: pid, startedAt: startedAt) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                closeTab(bundleId: bundleId, tty: tty, pid: pid, startedAt: startedAt, check: check + 1)
            }
            return
        }
        TerminalScripting.close(bundleId: bundleId, tty: tty)
    }
}
