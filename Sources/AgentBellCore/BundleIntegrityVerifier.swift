import Foundation
import Security

public enum BundleIntegrityVerifier {
    public static func isValidAppBundle(at bundleURL: URL) -> Bool {
        guard bundleURL.isFileURL,
              bundleURL.pathExtension.lowercased() == "app"
        else {
            return false
        }

        let normalizedURL = bundleURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            normalizedURL as CFURL,
            SecCSFlags(rawValue: kSecCSDefaultFlags),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            return false
        }

        let validationFlags = SecCSFlags(
            rawValue:
                kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode
                | kSecCSStrictValidate
                | kSecCSRestrictSymlinks
        )
        return SecStaticCodeCheckValidity(
            staticCode,
            validationFlags,
            nil
        ) == errSecSuccess
    }
}
