import Foundation

/// Every reason an import can be refused.
///
/// REQ-004's contract in one type: each case names the file it is about and
/// carries a concrete reason, so a rejection is always actionable and the
/// library is always untouched by the time one of these is thrown.
public enum ImportError: Error, Equatable, Sendable {
    /// The source file could not be read at all.
    case unreadableSource(fileName: String, reason: String)

    /// The file's extension is not one of the accepted MusicXML forms.
    case unsupportedFileType(fileName: String, fileExtension: String)

    /// The source is bigger than this build will read into memory.
    case sourceTooLarge(fileName: String, byteCount: Int, limit: Int)

    /// The source file has no content.
    case emptySource(fileName: String)

    /// The `.mxl` is not a readable ZIP container.
    case compressedContainerUnreadable(fileName: String, reason: String)

    /// The `.mxl` has no `META-INF/container.xml`.
    case containerDescriptorMissing(fileName: String, entryName: String)

    /// The container descriptor does not point at a MusicXML score, or points
    /// at an entry the archive does not contain.
    case containerRootfileUnusable(fileName: String, reason: String)

    /// The XML did not parse.
    case notWellFormedXML(fileName: String, reason: String, line: Int, column: Int)

    /// Well-formed XML, but not a MusicXML score.
    case notAMusicXMLScore(fileName: String, rootElement: String)

    /// The verbatim content could not be written into the container.
    case contentWriteFailed(fileName: String, reason: String)

    /// The library record could not be written. Any content already written
    /// for this import has been removed before this is thrown.
    case catalogWriteFailed(fileName: String, reason: String)
}

extension ImportError: LocalizedError {
    /// The file this error is about, always present.
    public var fileName: String {
        switch self {
        case .unreadableSource(let fileName, _),
             .unsupportedFileType(let fileName, _),
             .sourceTooLarge(let fileName, _, _),
             .emptySource(let fileName),
             .compressedContainerUnreadable(let fileName, _),
             .containerDescriptorMissing(let fileName, _),
             .containerRootfileUnusable(let fileName, _),
             .notWellFormedXML(let fileName, _, _, _),
             .notAMusicXMLScore(let fileName, _),
             .contentWriteFailed(let fileName, _),
             .catalogWriteFailed(let fileName, _):
            return fileName
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unreadableSource(let fileName, let reason):
            return "Synth could not read “\(fileName)”. \(reason)"
        case .unsupportedFileType(let fileName, let fileExtension):
            let described = fileExtension.isEmpty ? "no file extension" : "the extension “.\(fileExtension)”"
            return "Synth cannot import “\(fileName)”: it has \(described), and Synth imports .musicxml, .xml, and .mxl files."
        case .sourceTooLarge(let fileName, let byteCount, let limit):
            return "Synth cannot import “\(fileName)”: it is \(Self.megabytes(byteCount)), over the \(Self.megabytes(limit)) import limit."
        case .emptySource(let fileName):
            return "Synth cannot import “\(fileName)”: the file is empty."
        case .compressedContainerUnreadable(let fileName, let reason):
            return "Synth could not open the compressed MusicXML file “\(fileName)”: \(reason)."
        case .containerDescriptorMissing(let fileName, let entryName):
            return "Synth could not open the compressed MusicXML file “\(fileName)”: it contains no \(entryName), so nothing says which entry is the score."
        case .containerRootfileUnusable(let fileName, let reason):
            return "Synth could not open the compressed MusicXML file “\(fileName)”: \(reason)."
        case .notWellFormedXML(let fileName, let reason, let line, let column):
            return "Synth could not read “\(fileName)”: it is not well-formed XML. \(reason) (line \(line), column \(column))"
        case .notAMusicXMLScore(let fileName, let rootElement):
            return "Synth could not import “\(fileName)”: it is XML, but its top-level element is “\(rootElement)” rather than a MusicXML score."
        case .contentWriteFailed(let fileName, let reason):
            return "Synth could not save “\(fileName)” into your library. \(reason)"
        case .catalogWriteFailed(let fileName, let reason):
            return "Synth could not add “\(fileName)” to your library. \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unreadableSource:
            return "Check that the file still exists and that you can open it, then try again. Your library is unchanged."
        case .unsupportedFileType:
            return "Export the score as MusicXML (.musicxml or .mxl) from your notation app, then import that file."
        case .sourceTooLarge:
            return "This is far larger than any engraved score; check that the file is really MusicXML. Your library is unchanged."
        case .emptySource, .notWellFormedXML, .compressedContainerUnreadable,
             .containerDescriptorMissing, .containerRootfileUnusable:
            return "The file is damaged or incomplete. Re-export or re-download it, then try again. Your library is unchanged."
        case .notAMusicXMLScore:
            return "Pick the MusicXML score itself rather than another XML document. Your library is unchanged."
        case .contentWriteFailed, .catalogWriteFailed:
            return "Check available disk space, then try again. Your library is unchanged."
        }
    }

    private static func megabytes(_ byteCount: Int) -> String {
        let megabytes = Double(byteCount) / (1024 * 1024)
        return String(format: "%.1f MB", megabytes)
    }
}
