import AgentBellCore
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

private func wakeAgentBell() {
    DistributedNotificationCenter.default().post(
        name: AgentBellPaths.eventNotificationName,
        object: nil,
        userInfo: nil
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-gj", "-a", "AgentBell"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

guard let appBundleURL = enclosingAppBundleURL(),
      BundleIntegrityVerifier.isValidAppBundle(at: appBundleURL)
else {
    exit(EXIT_FAILURE)
}

if let provider = providerFromArguments(),
   let data = readLimitedInput()
{
    let origin = ProcessInspector.captureOrigin(provider: provider)
    let codexApprovalReviewer = provider == .codex
        ? CodexApprovalContextResolver.reviewer(fromHookPayload: data)
        : nil
    if let event = try? EventNormalizer.normalize(
        data: data,
        provider: provider,
        origin: origin,
        codexApprovalReviewer: codexApprovalReviewer
    ) {
        try? EventQueue.append(event)
        wakeAgentBell()
    }
}

exit(EXIT_SUCCESS)
