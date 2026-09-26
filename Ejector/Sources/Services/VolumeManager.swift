import Foundation

struct VolumeEjectResult {
    let successful: [Volume]
    let blocking: [Volume: [ProcessInfo]]
    let failedWithoutProcesses: [Volume]

    var isSuccess: Bool {
        return blocking.isEmpty && failedWithoutProcesses.isEmpty
    }
}

final class VolumeManager {
    private let fileManager: FileManager

    private enum EjectAttemptOutcome {
        case success
        case blocked([ProcessInfo])
        case failed
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func enumerateExternalVolumes() -> [Volume] {
        var result: [Volume] = []
        let keys: Set<URLResourceKey> = [
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeURLForRemountingKey,
            .volumeNameKey,
            .volumeLocalizedNameKey,
            .volumeIsInternalKey,
            .volumeIsRootFileSystemKey,
        ]

        guard
            let mountedVolumeURLs = fileManager.mountedVolumeURLs(
                includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes])
        else {
            return result
        }

        for url in mountedVolumeURLs {
            do {
                let resourceValues = try url.resourceValues(forKeys: keys)
                let isRemovable = resourceValues.volumeIsRemovable ?? false
                let isEjectable = resourceValues.volumeIsEjectable ?? false
                let isInternal = resourceValues.volumeIsInternal ?? true
                let isRoot = resourceValues.volumeIsRootFileSystem ?? false
                let volumeName = resourceValues.volumeLocalizedName ?? url.lastPathComponent

                if isRoot || url.path == "/" {
                    continue
                }

                let systemPaths = [
                    "/System", "/private", "/home", "/net", "/Network", "/dev", "/Volumes/Recovery",
                ]
                if systemPaths.contains(where: { url.path.hasPrefix($0) }) {
                    continue
                }

                if !isInternal || isRemovable || isEjectable {
                    if url.path.hasPrefix("/Volumes/") && isUSBConnectedVolume(at: url) {
                        let volume = Volume(name: volumeName, path: url.path)
                        result.append(volume)
                    }
                }
            } catch {
                continue
            }
        }

        return result
    }

    func findProcessesUsingVolume(_ volume: Volume) -> [ProcessInfo] {
        var result: [ProcessInfo] = []
        var seenPIDs: Set<Int> = []
        let task = Process()
        task.launchPath = "/usr/sbin/lsof"
        task.arguments = ["+f", "--", volume.path]
        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: "\n")
                for index in 1..<lines.count {
                    let line = lines[index]
                    let components = line.components(separatedBy: " ").filter { !$0.isEmpty }
                    if components.count >= 2 {
                        let processName = components[0]
                        if let pid = Int(components[1]), seenPIDs.insert(pid).inserted {
                            let process = ProcessInfo(
                                name: processName,
                                pid: pid,
                                startedAt: processStartTime(for: pid)
                            )
                            result.append(process)
                        }
                    }
                }
            }
        } catch {
            // Ignore errors from lsof failures
        }

        return result
    }

    func attemptEject(volumes: [Volume]) -> VolumeEjectResult {
        var successful: [Volume] = []
        var blocking: [Volume: [ProcessInfo]] = [:]
        var failedWithoutProcesses: [Volume] = []

        for volume in volumes {
            let processes = findProcessesUsingVolume(volume)
            if !processes.isEmpty {
                blocking[volume] = processes
                continue
            }

            switch ejectVolumeWithRetry(volume) {
            case .success:
                successful.append(volume)
            case .blocked(let processes):
                if !processes.isEmpty {
                    blocking[volume] = processes
                } else {
                    failedWithoutProcesses.append(volume)
                }
            case .failed:
                failedWithoutProcesses.append(volume)
            }
        }

        return VolumeEjectResult(
            successful: successful,
            blocking: blocking,
            failedWithoutProcesses: failedWithoutProcesses
        )
    }

    func eject(_ volume: Volume) -> Bool {
        let task = Process()
        task.launchPath = "/usr/sbin/diskutil"
        task.arguments = ["eject", volume.path]

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    func terminate(
        processes: [ProcessInfo],
        gracefulTimeout: TimeInterval = 2.0,
        forcedTimeout: TimeInterval = 1.0
    ) {
        var processesByPID: [Int: ProcessInfo] = [:]
        for process in processes where processesByPID[process.pid] == nil && isCurrent(process) {
            processesByPID[process.pid] = process
        }

        var remaining = processesByPID.values.filter { sendSignal("-TERM", to: $0) }
        remaining = waitForExit(of: remaining, timeout: gracefulTimeout)

        // A process may ignore TERM. Revalidate its identity before forcefully ending it
        // so a recycled PID can never receive KILL.
        remaining = remaining.filter { isCurrent($0) && sendSignal("-KILL", to: $0) }
        _ = waitForExit(of: remaining, timeout: forcedTimeout)
    }

    private func sendSignal(_ signal: String, to process: ProcessInfo) -> Bool {
        let task = Process()
        task.launchPath = "/bin/kill"
        task.arguments = [signal, String(process.pid)]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func waitForExit(
        of processes: [ProcessInfo],
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1
    ) -> [ProcessInfo] {
        var remaining = processes.filter(isCurrent)
        let deadline = Date().addingTimeInterval(max(0, timeout))

        while !remaining.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: min(pollInterval, max(0, deadline.timeIntervalSinceNow)))
            remaining = remaining.filter(isCurrent)
        }

        return remaining
    }

    func isCurrent(_ process: ProcessInfo) -> Bool {
        guard let startedAt = process.startedAt else { return false }
        return processStartTime(for: process.pid) == startedAt
    }

    func processStartTime(for pid: Int) -> String? {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", String(pid), "-o", "lstart="]
        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard task.terminationStatus == 0,
                  let value = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else {
                return nil
            }
            return value
        } catch {
            return nil
        }
    }

    private func isUSBConnectedVolume(at url: URL) -> Bool {
        let task = Process()
        task.launchPath = "/usr/sbin/diskutil"
        task.arguments = ["info", "-plist", url.path]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }

        guard task.terminationStatus == 0 else {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any],
            let busProtocol = plist["BusProtocol"] as? String
        else {
            return false
        }

        return busProtocol.range(of: "USB", options: .caseInsensitive) != nil
    }

    private func ejectVolumeWithRetry(
        _ volume: Volume,
        maxAttempts: Int = 4,
        initialDelay: TimeInterval = 0.4,
        delayMultiplier: Double = 1.5,
        maxDelay: TimeInterval = 2.0
    ) -> EjectAttemptOutcome {
        var attempt = 0
        var delay = initialDelay

        while attempt < maxAttempts {
            if eject(volume) {
                return .success
            }

            let processes = findProcessesUsingVolume(volume)
            if !processes.isEmpty {
                return .blocked(processes)
            }

            attempt += 1
            guard attempt < maxAttempts else {
                break
            }

            Thread.sleep(forTimeInterval: delay)
            delay = min(delay * delayMultiplier, maxDelay)
        }

        return .failed
    }
}
