import Foundation

enum KeepAwakeDuration: Int, CaseIterable, Identifiable {
    case halfHour = 30, hour = 60, twoHours = 120, indefinitely = 0
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .halfHour: return "30 минут"
        case .hour: return "1 час"
        case .twoHours: return "2 часа"
        case .indefinitely: return "До выключения"
        }
    }
}

struct KeepAwakePower: Equatable {
    var external: Bool?
    var batteryPercent: Int?
}

enum KeepAwakePolicy {
    static let lowBatteryPercent = 15
    static let maximumLidSeconds = 8 * 60 * 60

    static func deadline(duration: KeepAwakeDuration, closedLid: Bool, now: Date) -> Date? {
        if duration == .indefinitely {
            return closedLid ? now.addingTimeInterval(TimeInterval(maximumLidSeconds)) : nil
        }
        return now.addingTimeInterval(TimeInterval(duration.rawValue * 60))
    }

    static func stopReason(deadline: Date?, now: Date, power: KeepAwakePower,
                           powerOnly: Bool) -> String? {
        if let deadline, now >= deadline { return "Время истекло — режим остановлен." }
        if powerOnly && power.external != true { return "Питание отключено — режим остановлен." }
        if power.external == false, let percent = power.batteryPercent,
           percent <= lowBatteryPercent {
            return "Заряд не выше 15% — режим остановлен."
        }
        return nil
    }
}

/// Only internally obtained process identities can become part of the privileged
/// command. No paths, filenames, preferences or user-supplied shell are accepted.
struct KeepAwakeWatchdog {
    let appPID: Int32
    let leasePID: Int32
    let appStarted: String
    let leaseStarted: String
    let deadline: Int
    let powerOnly: Bool

    func script(now: Int) throws -> String {
        guard appPID > 1, leasePID > 1, appPID != leasePID,
              !appStarted.isEmpty, !leaseStarted.isEmpty,
              appStarted.count < 80, leaseStarted.count < 80,
              appStarted.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " " || $0 == ":") }),
              leaseStarted.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " " || $0 == ":") }),
              deadline > now, deadline - now <= KeepAwakePolicy.maximumLidSeconds else {
            throw KeepAwakeFailure("Не удалось проверить сеанс режима закрытой крышки.")
        }
        return """
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        LC_ALL=C
        export LC_ALL
        app=\(appPID)
        lease=\(leasePID)
        app_started='\(appStarted)'
        lease_started='\(leaseStarted)'
        deadline=\(deadline)
        power_only=\(powerOnly ? 1 : 0)
        owned=0
        birth() { /bin/ps -p "$1" -o lstart= | /usr/bin/sed 's/^ *//;s/ *$//'; }
        live() {
            state=$(/bin/ps -p "$1" -o stat=) || return 1
            case "$state" in ''|*Z*) return 1 ;; esac
        }
        lease_valid() {
            live "$app" && live "$lease" || return 1
            [ "$(birth "$app")" = "$app_started" ] || return 1
            [ "$(birth "$lease")" = "$lease_started" ] || return 1
            parent=$(/bin/ps -p "$lease" -o ppid= | /usr/bin/tr -d ' ')
            [ "$parent" = "$app" ] || return 1
            [ "$(/bin/date +%s)" -lt "$deadline" ]
        }
        sleep_disabled() {
            /usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" { print $2; exit }'
        }
        power_safe() {
            battery=$(/usr/bin/pmset -g batt) || return 1
            case "$battery" in
                *"'AC Power'"*) return 0 ;;
                *"'Battery Power'"*)
                    [ "$power_only" -eq 0 ] || return 1
                    percent=$(printf '%s\\n' "$battery" | /usr/bin/sed -n 's/.*[[:space:]]\\([0-9][0-9]*\\)%;.*/\\1/p' | /usr/bin/head -n 1)
                    case "$percent" in ''|*[!0-9]*) return 1 ;; esac
                    [ "$percent" -gt 15 ] ;;
                *) return 1 ;;
            esac
        }
        sleep_if_lid_requires_it() {
            # Ending disablesleep alone may not synthesize a new lid event.
            # Only request sleep when macOS says this closed lid should sleep;
            # normal external-display clamshell operation must remain intact.
            /bin/sleep 2
            domain=$(/usr/sbin/ioreg -r -n IOPMrootDomain -d 1) || return 0
            closed=$(printf '%s\\n' "$domain" | /usr/bin/awk '/"AppleClamshellState" = / { print $NF; exit }')
            causes_sleep=$(printf '%s\\n' "$domain" | /usr/bin/awk '/"AppleClamshellCausesSleep" = / { print $NF; exit }')
            [ "$closed" = Yes ] && [ "$causes_sleep" = Yes ] || return 0
            assertions=$(/usr/bin/pmset -g assertions) || return 0
            system=$(printf '%s\\n' "$assertions" | /usr/bin/awk '$1 == "PreventSystemSleep" { print $2; exit }')
            idle=$(printf '%s\\n' "$assertions" | /usr/bin/awk '$1 == "PreventUserIdleSystemSleep" { print $2; exit }')
            [ "$system" = 0 ] && [ "$idle" = 0 ] || return 0
            [ "$(sleep_disabled)" = 0 ] || return 0
            /usr/bin/pmset sleepnow || return 0
        }
        restore() {
            status=$?
            trap - EXIT HUP INT TERM
            if [ "$owned" -eq 1 ]; then
                attempt=0
                while [ "$attempt" -lt 5 ]; do
                    if /usr/bin/pmset disablesleep 0 && [ "$(sleep_disabled)" = 0 ]; then
                        sleep_if_lid_requires_it
                        exit "$status"
                    fi
                    attempt=$((attempt + 1))
                    /bin/sleep 1
                done
                printf '%s\\n' 'NOTCHHUB_RESTORE_FAILED' >&2
                exit 73
            fi
        }
        trap restore EXIT
        trap 'exit 0' HUP INT TERM
        lease_valid && power_safe || { printf '%s\\n' 'NOTCHHUB_LEASE_ENDED' >&2; exit 70; }
        # Never claim or restore a setting that was already enabled externally.
        [ "$(sleep_disabled)" = 0 ] || { printf '%s\\n' 'NOTCHHUB_PREEXISTING_SLEEP_OVERRIDE' >&2; exit 71; }
        lease_valid || { printf '%s\\n' 'NOTCHHUB_LEASE_ENDED' >&2; exit 70; }
        # Mark ownership before the mutation so interruption invokes restoration.
        owned=1
        /usr/bin/pmset disablesleep 1 || exit 72
        [ "$(sleep_disabled)" = 1 ] || exit 72
        tick=0
        while lease_valid; do
            if [ "$tick" -eq 0 ]; then power_safe || break; fi
            tick=$(((tick + 1) % 15))
            /bin/sleep 1
        done
        """
    }

    static func appleScript(for shell: String) -> String {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "with timeout of \(KeepAwakePolicy.maximumLidSeconds + 600) seconds\n"
            + "do shell script \"\(escaped)\" with administrator privileges\nend timeout"
    }
}

struct KeepAwakeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
