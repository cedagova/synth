import Foundation

/// The one on-disk container that holds everything Synth owns.
///
/// Layout (AD3 — one Application Support container):
///
/// ```text
/// <Application Support>/Synth/
///   library.sqlite   metadata database (pieces, sounds, presets, catalog state)
///   pieces/          imported MusicXML, kept verbatim
///   sounds/          synth patch and instrument-variant documents
///   assets/          downloaded instrument sample assets
/// ```
///
/// The database holds metadata; bulk content lives beside it as files so it
/// stays inspectable, backs up well, and can be written atomically.
public struct AppContainer: Sendable, Equatable {
    /// Folder name inside Application Support.
    public static let directoryName = "Synth"

    /// Database file name inside the container.
    public static let databaseFileName = "library.sqlite"

    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// Metadata database for pieces, sounds, presets, and catalog state.
    public var databaseURL: URL { rootURL.appending(path: Self.databaseFileName) }

    /// Imported MusicXML, stored verbatim (one file per piece).
    public var piecesURL: URL { rootURL.appending(path: "pieces") }

    /// Sound documents: synth patches and instrument variants.
    public var soundsURL: URL { rootURL.appending(path: "sounds") }

    /// Downloaded instrument sample assets.
    public var assetsURL: URL { rootURL.appending(path: "assets") }

    /// Every directory `prepare()` guarantees, in creation order.
    public var managedDirectoryURLs: [URL] { [rootURL, piecesURL, soundsURL, assetsURL] }

    /// The container Synth uses by default: `<Application Support>/Synth`.
    ///
    /// Under the App Sandbox this resolves inside the app's own container, so
    /// the library is private to Synth.
    public static func `default`(fileManager: FileManager = .default) throws -> AppContainer {
        let base: URL
        do {
            base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        } catch {
            throw StoreError.applicationSupportUnavailable(
                reason: (error as NSError).localizedDescription
            )
        }
        return AppContainer(rootURL: base.appending(path: Self.directoryName))
    }

    /// Creates every managed directory that does not exist yet.
    ///
    /// Idempotent: an existing, well-formed container is accepted untouched.
    /// If creation fails part way through, every directory this call created is
    /// removed again, so a failed launch never leaves a half-built container
    /// behind. Directories that already existed are never removed.
    public func prepare(fileManager: FileManager = .default) throws {
        var createdByThisCall: [URL] = []

        do {
            for directory in managedDirectoryURLs {
                let path = directory.path(percentEncoded: false)
                var isDirectory: ObjCBool = false

                if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
                    guard isDirectory.boolValue else {
                        throw StoreError.containerPathIsNotADirectory(path: path)
                    }
                    continue
                }

                do {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    throw StoreError.containerCreationFailed(
                        path: path,
                        reason: (error as NSError).localizedDescription
                    )
                }
                createdByThisCall.append(directory)
            }
        } catch {
            removeBestEffort(createdByThisCall.reversed(), fileManager: fileManager)
            throw error
        }
    }

    /// Best-effort rollback of directories this process created. Failures here
    /// cannot be surfaced usefully — the caller is already throwing the real
    /// error — but they are never silent in a state query, only in cleanup.
    private func removeBestEffort(_ urls: [URL], fileManager: FileManager) {
        for url in urls {
            guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                NSLog("Synth: could not roll back partially created container at %@: %@",
                      url.path(percentEncoded: false),
                      (error as NSError).localizedDescription)
            }
        }
    }
}
