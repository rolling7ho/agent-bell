import Foundation

public enum NtfyDeviceSetupLink {
    public static func makeURL(
        serverURL: String,
        topic: String
    ) -> URL? {
        guard NtfyRequestBuilder.isValidTopic(topic),
              var components = URLComponents(string: serverURL),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            return nil
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([basePath, topic].filter { !$0.isEmpty }).joined(separator: "/")
        return components.url
    }
}
