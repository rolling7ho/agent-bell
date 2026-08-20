extension SessionSummary {
    /// Dashboard rows carry the state in a separate pill, so the headline holds
    /// only the task title, or the source app when details stay hidden.
    public func dashboardHeadline(includesPrivateDetails: Bool) -> String {
        guard includesPrivateDetails || isTest else { return appDisplayName }
        return TurnringSafeText.redacted(displayTitle ?? "Untitled task")
    }

    /// Row metadata shown under the preview: the source app when it is not
    /// already the headline, and the run duration once a run has stopped.
    public func dashboardMetadata(includesPrivateDetails: Bool) -> [String] {
        var components: [String] = []
        if includesPrivateDetails || isTest {
            components.append(appDisplayName)
        }
        if state == .finished || state == .failed,
           let formattedElapsedDuration
        {
            components.append(formattedElapsedDuration)
        }
        return components
    }
}
