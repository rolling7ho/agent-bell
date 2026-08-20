import TurnringCore
import Foundation

private func enclosingAppBundleURL() -> URL? {
    var url = URL(fileURLWithPath: CommandLine.arguments[0])
        .standardizedFileURL
        .resolvingSymlinksInPath()
    for _ in 0..<3 {
        url.deleteLastPathComponent()
    }
    return url.pathExtension.lowercased() == "app" ? url : nil
}

private func providerFromArguments() -> AgentProvider? {
    guard let index = CommandLine.arguments.firstIndex(of: "--provider"),
          CommandLine.arguments.indices.contains(index + 1)
    else {
        return nil
    }
    return AgentProvider(rawValue: CommandLine.arguments[index + 1])
}

private func readLimitedInput() -> Data? {
    do {
        var data = Data()
        while data.count <= EventNormalizer.maximumPayloadBytes {
            let remaining = EventNormalizer.maximumPayloadBytes + 1 - data.count
            guard remaining > 0 else { return nil }
            guard let chunk = try FileHandle.standardInput.read(
                upToCount: min(64 * 1_024, remaining)
            ),
                !chunk.isEmpty
            else {
                break
            }
            data.append(chunk)
        }
        return data.isEmpty || data.count > EventNormalizer.maximumPayloadBytes
            ? nil
            : data
    } catch {
        return nil
    }
}

private func wakeTurnring(appBundleURL: URL) throws {
    DistributedNotificationCenter.default().post(
        name: TurnringPaths.eventNotificationName,
        object: nil,
        userInfo: nil
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-gj", appBundleURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw QueueStoreError.writeFailed
    }
}

guard let appBundleURL = enclosingAppBundleURL(),
      BundleIntegrityVerifier.isValidAppBundle(at: appBundleURL)
else {
    exit(EXIT_FAILURE)
}

guard let provider = providerFromArguments(),
      let data = readLimitedInput()
else {
    FileHandle.standardError.write(
        Data("Turnring hook rejected invalid input.\n".utf8)
    )
    exit(EXIT_FAILURE)
}

do {
    let origin = ProcessInspector.captureOrigin(provider: provider)
    let codexApprovalReviewer = provider == .codex
        ? CodexApprovalContextResolver.reviewer(fromHookPayload: data)
        : nil
    let event = try EventNormalizer.normalize(
        data: data,
        provider: provider,
        origin: origin,
        codexApprovalReviewer: codexApprovalReviewer
    )
    try EventQueue.append(event)
    try wakeTurnring(appBundleURL: appBundleURL)
} catch {
    FileHandle.standardError.write(
        Data("Turnring could not safely queue this agent event.\n".utf8)
    )
    exit(EXIT_FAILURE)
}

exit(EXIT_SUCCESS)
