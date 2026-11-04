import Foundation
import TopbarCore

// Мост хука: Claude Code запускает его на каждое событие. Любая неудача — тихий выход с кодом 0.
let input = FileHandle.standardInput.readDataToEndOfFile()
if let output = BridgeRunner.run(
    stdin: input,
    environment: ProcessInfo.processInfo.environment,
    parentPid: getppid(),
    socketPath: Paths.socketPath
) {
    FileHandle.standardOutput.write(output)
}
exit(0)
