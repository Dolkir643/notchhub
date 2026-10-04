import Foundation

enum KeepAwakeLidPhase: Equatable {
    case idle, authorizing, active, restoring, failed
}

@MainActor protocol KeepAwakeLidControlling: AnyObject {
    var phase: KeepAwakeLidPhase { get }
    var message: String? { get }
    var pendingRestoration: Bool { get }
    func begin(deadline: Date, powerOnly: Bool) throws
    func stop()
    func refresh() async
}

/// A privileged watchdog exists only for the current session. It receives no
/// writable paths and installs neither a helper nor a sudoers exception.
@MainActor final class KeepAwakeLidController: KeepAwakeLidControlling {
    private(set) var phase: KeepAwakeLidPhase = .idle
    private(set) var message: String?
    private var lease: Process?
    private var authorization: Process?
    private var commandFinished = false
    private var stoppedAt: Date?
    private var restoreStartedAt: Date?
    private var needsVerification = false
    private var reading = false

    var pendingRestoration: Bool { needsVerification && phase == .restoring }

    func begin(deadline: Date, powerOnly: Bool) throws {
        guard authorization == nil, !needsVerification else {
            throw KeepAwakeFailure("Предыдущий сеанс ещё завершает работу.")
        }
        let baseline = try Self.readSleepDisabled()
        guard baseline == false else {
            throw KeepAwakeFailure("Системный сон уже отключён другой программой. Её настройка сохранена; завершите тот режим перед запуском этого.")
        }
        let seconds = min(KeepAwakePolicy.maximumLidSeconds,
                          max(1, Int(deadline.timeIntervalSinceNow.rounded(.up))))
        let lease = Process()
        lease.executableURL = URL(fileURLWithPath: "/bin/sleep")
        lease.arguments = [String(seconds)]
        lease.standardInput = FileHandle.nullDevice
        lease.standardOutput = FileHandle.nullDevice
        lease.standardError = FileHandle.nullDevice
        try lease.run()
        self.lease = lease
        do {
            let appPID = ProcessInfo.processInfo.processIdentifier
            let spec = KeepAwakeWatchdog(appPID: appPID, leasePID: lease.processIdentifier,
                appStarted: try Self.birth(appPID), leaseStarted: try Self.birth(lease.processIdentifier),
                deadline: Int(deadline.timeIntervalSince1970), powerOnly: powerOnly)
            let shell = try spec.script(now: Int(Date().timeIntervalSince1970))
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", KeepAwakeWatchdog.appleScript(for: shell)]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            process.terminationHandler = { [weak self] process in
                let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                Task { @MainActor in self?.finished(status: process.terminationStatus, error: error) }
            }
            authorization = process
            commandFinished = false
            stoppedAt = nil
            restoreStartedAt = nil
            message = nil
            needsVerification = true
            phase = .authorizing
            try process.run()
        } catch {
            if lease.isRunning { lease.terminate() }
            self.lease = nil
            authorization = nil
            needsVerification = false
            phase = .failed
            throw error
        }
    }

    func stop() {
        guard needsVerification else { return }
        if stoppedAt == nil { stoppedAt = Date() }
        if restoreStartedAt == nil { restoreStartedAt = Date() }
        if let lease, lease.isRunning { lease.terminate() }
        lease = nil
        // Only cancel an unanswered/ongoing authorization, never kill the root
        // watchdog: its EXIT trap and lease monitor own restoration.
        if phase == .authorizing, let authorization, authorization.isRunning {
            authorization.terminate()
        }
        phase = .restoring
    }

    func refresh() async {
        guard needsVerification, !reading else { return }
        reading = true
        let result = await Task.detached(priority: .utility) {
            Result { try Self.readSleepDisabled() }
        }.value
        reading = false
        guard needsVerification else { return }
        switch result {
        case .success(let disabled):
            if disabled, phase == .authorizing { phase = .active }
            if phase == .restoring {
                // Allow a command already in pmset during cancellation to return
                // and run its trap before declaring restoration complete.
                let settled = Date().timeIntervalSince(restoreStartedAt ?? Date()) >= 3
                if !disabled, settled, commandFinished {
                    needsVerification = false
                    phase = message == nil ? .idle : .failed
                } else if Date().timeIntervalSince(restoreStartedAt ?? Date()) > 10 {
                    message = "Сон пока не восстановлен. Не закрывайте приложение. Если режим остался включён, выполните в Терминале: sudo pmset disablesleep 0"
                }
            } else if !disabled, phase == .active {
                stop()
                message = "Системный режим завершился."
            }
        case .failure:
            if phase == .restoring {
                message = "Не удалось проверить восстановление сна. Команда восстановления: sudo pmset disablesleep 0"
            }
        }
    }

    private func finished(status: Int32, error: String) {
        commandFinished = true
        authorization = nil
        if let lease, lease.isRunning { lease.terminate() }
        lease = nil
        if error.contains("NOTCHHUB_PREEXISTING_SLEEP_OVERRIDE") {
            needsVerification = false
            phase = .failed
            message = "Другая программа изменила системный сон во время подтверждения. Её настройка сохранена."
            return
        }
        if error.contains("NOTCHHUB_LEASE_ENDED") || (error.contains("-128") && stoppedAt == nil) {
            needsVerification = false
            phase = .failed
            message = "Включение отменено; системный сон не изменён."
            return
        }
        if status != 0 && stoppedAt == nil {
            if error.contains("-128") {
                message = "Включение отменено в системном окне."
            } else if error.contains("NOTCHHUB_RESTORE_FAILED") {
                message = "Не удалось восстановить системный сон: sudo pmset disablesleep 0"
            } else {
                message = "macOS не включила режим закрытой крышки. Проверьте разрешение администратора и питание."
            }
        }
        if restoreStartedAt == nil { restoreStartedAt = Date() }
        phase = .restoring
    }

    private nonisolated static func birth(_ pid: Int32) throws -> String {
        try output("/bin/ps", ["-p", String(pid), "-o", "lstart="])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func readSleepDisabled() throws -> Bool {
        let text = try output("/usr/bin/pmset", ["-g"])
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[0] == "SleepDisabled" {
                if fields[1] == "0" { return false }
                if fields[1] == "1" { return true }
            }
        }
        // Missing/unknown state is not evidence that we can safely overwrite it.
        throw KeepAwakeFailure("macOS не сообщает текущее состояние системного сна.")
    }

    private nonisolated static func output(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"], uniquingKeysWith: { _, new in new })
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let result = String(data: data, encoding: .utf8) else {
            throw KeepAwakeFailure("Не удалось прочитать состояние питания macOS.")
        }
        return result
    }
}
