import Darwin
import Foundation

enum BoundedProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let outputCollector = ProcessOutputCollector()
        let outputGroup = DispatchGroup()
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { outputGroup.leave() }
            while true {
                let chunk: Data
                do {
                    guard let value = try pipe.fileHandleForReading.read(
                        upToCount: 64 * 1_024
                    ),
                        !value.isEmpty
                    else {
                        return
                    }
                    chunk = value
                } catch {
                    return
                }
                outputCollector.append(chunk)
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            finishReadingOutput(pipe: pipe, group: outputGroup)
            return (-2, "")
        }
        finishReadingOutput(pipe: pipe, group: outputGroup)
        return (
            process.terminationStatus,
            String(decoding: outputCollector.data, as: UTF8.self)
        )
    }

    private static func finishReadingOutput(
        pipe: Pipe,
        group: DispatchGroup
    ) {
        if group.wait(timeout: .now() + 0.5) == .timedOut {
            try? pipe.fileHandleForReading.close()
            _ = group.wait(timeout: .now() + 0.1)
        }
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private static let maximumBytes = 1 * 1_024 * 1_024
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard storage.count < Self.maximumBytes else { return }
        storage.append(
            data.prefix(Self.maximumBytes - storage.count)
        )
    }
}
