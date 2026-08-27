import Foundation

/// Renders a container path the owner can actually find in Finder.
///
/// Inside the App Sandbox, `NSHomeDirectory()` is the app's container, so
/// Foundation's `abbreviatingWithTildeInPath` would turn
/// `~/Library/Containers/com.cedagova.synth/Data/Library/Application Support/Synth`
/// into `~/Library/Application Support/Synth` — a path that does not exist for
/// the owner. Abbreviating against the *real* home keeps the displayed path
/// truthful while still hiding the account name.
public enum HomeRelativePath {
    /// The real home directory, which the sandbox does not rewrite.
    public static var realHomeDirectory: String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return String(cString: directory)
        }
        return NSHomeDirectory()
    }

    /// `~/Library/…` for a path inside `home`, otherwise the path unchanged.
    public static func display(_ url: URL, relativeTo home: String = HomeRelativePath.realHomeDirectory) -> String {
        display(url.path(percentEncoded: false), relativeTo: home)
    }

    /// String form, exposed for testing with an injected home directory.
    public static func display(_ path: String, relativeTo home: String) -> String {
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !trimmedHome.isEmpty else { return path }

        if path == trimmedHome { return "~" }
        guard path.hasPrefix(trimmedHome + "/") else { return path }
        return "~" + path.dropFirst(trimmedHome.count)
    }
}
