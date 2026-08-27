import Foundation

/// A store holding rows that belong to a piece and must not outlive it.
///
/// REQ-003 says removing a piece also removes its presets. Presets themselves
/// arrive in increment 004, so this leaf cannot — and must not — invent their
/// model. What it can do is own the *cascade*: the removal transaction asks
/// every registered dependent store to delete that piece's rows before the
/// piece row itself goes, and the whole thing commits or does not.
///
/// Increment 004's preset store conforms to this and is registered at
/// `LibraryStore.open`. Nothing else about removal changes then, and the
/// ordering guarantee below is already exercised by tests using a stand-in
/// dependent store.
public protocol PieceDependentStore: Sendable {
    /// Named in errors, so a failed cascade says which store refused.
    var dependentDescription: String { get }

    /// Deletes everything this store holds for `pieceID`.
    ///
    /// Called inside the removal transaction on `database`; it must not open a
    /// transaction of its own. Removing a piece that has no rows here is normal
    /// and must succeed.
    func removeDependents(ofPieceID pieceID: String, in database: SQLiteDatabase) throws
}

/// Every way removing a piece can fail.
///
/// Each case names the piece, because the alert the owner sees has to say which
/// removal failed — and each one is thrown only after the transaction rolled
/// back, so the piece really is still there.
public enum PieceRemovalError: Error, Equatable, Sendable {
    /// The piece was already gone when the removal ran — another window, or a
    /// stale list.
    case pieceNotFound(title: String)

    /// A dependent store refused. The piece and every dependent row are intact.
    case dependentRemovalFailed(title: String, dependent: String, reason: String)

    /// The catalog refused to delete the piece row. Nothing was removed.
    case catalogRemovalFailed(title: String, reason: String)
}

extension PieceRemovalError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .pieceNotFound(let title):
            return "“\(title)” is no longer in your library."
        case .dependentRemovalFailed(let title, let dependent, let reason):
            return "Synth could not remove “\(title)”: its \(dependent) could not be deleted. \(reason)"
        case .catalogRemovalFailed(let title, let reason):
            return "Synth could not remove “\(title)” from your library. \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .pieceNotFound:
            return "The library list has been refreshed."
        case .dependentRemovalFailed, .catalogRemovalFailed:
            return "Nothing was removed and the piece is still in your library. Try again; if this keeps happening, the library database may be damaged."
        }
    }
}

/// Removes a piece and everything that belongs to it.
///
/// The order is the whole design:
///
/// 1. inside one transaction, confirm the piece is still there;
/// 2. still inside it, let every dependent store delete its rows;
/// 3. still inside it, delete the piece row — commit or roll back as one; then
/// 4. only once the metadata is committed gone, delete the verbatim content
///    file.
///
/// Step 4 is deliberately outside the transaction and deliberately last. A
/// filesystem delete cannot join a SQL transaction, so one of the two has to be
/// able to fail alone. Losing the file while the record survives would leave a
/// piece that cannot be opened; losing the record while the file survives
/// leaves an unreferenced file the catalog already defines as debris rather
/// than a piece. The harmless failure is the one that is allowed to happen.
public struct PieceRemover: Sendable {
    private let database: SQLiteDatabase
    private let catalog: PieceCatalogDeleting
    private let contentStore: PieceContentStoring
    private let dependentStores: [PieceDependentStore]

    /// A remover writing into an opened library.
    public init(store: LibraryStore) {
        self.init(
            database: store.database,
            catalog: store.pieces,
            contentStore: store.pieceContent,
            dependentStores: store.dependentStores
        )
    }

    /// Seams exist for the failure paths: a catalog that refuses to delete, and
    /// a dependent store that fails the way a damaged preset table would.
    init(
        database: SQLiteDatabase,
        catalog: PieceCatalogDeleting,
        contentStore: PieceContentStoring,
        dependentStores: [PieceDependentStore]
    ) {
        self.database = database
        self.catalog = catalog
        self.contentStore = contentStore
        self.dependentStores = dependentStores
    }

    /// Removes `record` and every dependent row, permanently.
    ///
    /// - Throws: `PieceRemovalError`, always naming the piece. The library is
    ///   unchanged whenever this throws.
    public func remove(_ record: PieceRecord) throws {
        try database.withTransaction { _ in
            guard try existingPiece(record) != nil else {
                throw PieceRemovalError.pieceNotFound(title: record.title)
            }

            for dependent in dependentStores {
                do {
                    try dependent.removeDependents(ofPieceID: record.id, in: database)
                } catch {
                    throw PieceRemovalError.dependentRemovalFailed(
                        title: record.title,
                        dependent: dependent.dependentDescription,
                        reason: Self.describe(error)
                    )
                }
            }

            do {
                try catalog.delete(pieceID: record.id)
            } catch {
                throw PieceRemovalError.catalogRemovalFailed(
                    title: record.title,
                    reason: Self.describe(error)
                )
            }
        }

        contentStore.removeIfPresent(named: record.contentFileName)
    }

    /// A read that fails is not "already removed": that would delete the
    /// content file of a piece whose record is still there.
    private func existingPiece(_ record: PieceRecord) throws -> PieceRecord? {
        do {
            return try catalog.piece(withID: record.id)
        } catch {
            throw PieceRemovalError.catalogRemovalFailed(
                title: record.title,
                reason: Self.describe(error)
            )
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
    }
}
