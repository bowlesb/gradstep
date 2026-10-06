import CSQLite
import CryptoKit
import Foundation

/// Confined to an EncryptedStore call. It neither commits transactions nor
/// retains plaintext cache bodies between calls. Main metadata owns its roots.
struct OfflineCacheStorage {
    let database: SQLiteConnection
    let key: SymmetricKey
    let scope: LibraryCommandScope

    static let createTables = """
        CREATE TABLE local_library_cache_checkpoint(id INTEGER PRIMARY KEY CHECK(id=1), sealed BLOB NOT NULL);
        CREATE TABLE local_library_cache_entries(id TEXT PRIMARY KEY NOT NULL, sealed BLOB NOT NULL);
        CREATE TABLE local_reader_bundle_index(id INTEGER PRIMARY KEY CHECK(id=1), sealed BLOB NOT NULL);
        CREATE TABLE local_reader_bundle_headers(id TEXT PRIMARY KEY NOT NULL, sealed BLOB NOT NULL);
        CREATE TABLE local_reader_bundle_members(bundle_id TEXT NOT NULL REFERENCES local_reader_bundle_headers(id) ON DELETE CASCADE,
          ordinal INTEGER NOT NULL CHECK(ordinal>=0 AND ordinal<512), sealed BLOB NOT NULL, PRIMARY KEY(bundle_id,ordinal));
        """

    func apply(_ mutation: OfflineCacheMutation) throws {
        for write in mutation.writes {
            switch write {
            case .checkpoint(let data):
                try database.update("INSERT INTO local_library_cache_checkpoint(id,sealed) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET sealed=excluded.sealed", values: [.blob(data)])
            case .presentationRow(let id, let data):
                try database.update("INSERT INTO local_library_cache_entries(id,sealed) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET sealed=excluded.sealed", values: [.text(id.wire), .blob(data)])
            case .deletePresentationRow(let id):
                try database.update("DELETE FROM local_library_cache_entries WHERE id=?", values: [.text(id.wire)])
            case .bundleIndex(let data):
                try database.update("INSERT INTO local_reader_bundle_index(id,sealed) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET sealed=excluded.sealed", values: [.blob(data)])
            case .header(let id, let data):
                try database.update("INSERT INTO local_reader_bundle_headers(id,sealed) VALUES(?,?)", values: [.text(id.wire), .blob(data)])
            case .member(let id, let ordinal, let data):
                try database.update("INSERT INTO local_reader_bundle_members(bundle_id,ordinal,sealed) VALUES(?,?,?)", values: [.text(id.wire), .integer(Int64(ordinal)), .blob(data)])
            case .deleteBundle(let id):
                try database.update("DELETE FROM local_reader_bundle_members WHERE bundle_id=?", values: [.text(id.wire)])
                try database.update("DELETE FROM local_reader_bundle_headers WHERE id=?", values: [.text(id.wire)])
            }
        }
    }

    private func blob(_ sql: String, values: [SQLValue] = [], maximum: Int) throws -> Data {
        // length(BLOB) and typeof do not materialize the payload. Keep the
        // full Column operation behind this CASE before sqlite3_step, not only
        // before Foundation's subsequent Data allocation.
        let bounded = sql.replacingOccurrences(of: "SELECT sealed FROM ", with:
            "SELECT CASE WHEN typeof(sealed)='blob' AND length(sealed) BETWEEN 28 AND \(maximum) THEN sealed END FROM ")
        return try database.statement(bounded, values: values) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw OfflineCacheError.corruptCache }
            do { return try SQLiteConnection.blob(statement, 0, maximumBytes: maximum) }
            catch ReaderError.corruptData { throw OfflineCacheError.corruptCache }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, sealed: Data, digest: Data, domain: String,
                                      identity: [String] = [], maximum: Int) throws -> T {
        let plain = try OfflineCacheCodec.open(sealed, digest: digest, domain: domain, scope: scope,
                                               identity: identity, key: key, maximum: maximum)
        do { return try OfflineCacheCodec.decode(type, from: plain) }
        catch { throw OfflineCacheError.corruptCache }
    }

    private func seal<T: Encodable>(_ value: T, domain: String, identity: [String] = [], maximum: Int) throws -> Data {
        try OfflineCacheCodec.seal(OfflineCacheCodec.encode(value), domain: domain, scope: scope,
                                  identity: identity, key: key, maximum: maximum)
    }

    func checkpoint(_ roots: OfflineCacheRoots) throws -> CachePresentationCheckpoint? {
        guard let digest = roots.presentation else { return nil }
        let sealed = try blob("SELECT sealed FROM local_library_cache_checkpoint WHERE id=1", maximum: OfflineCacheLimits.presentationCheckpointBytes)
        let value = try decode(CachePresentationCheckpoint.self, sealed: sealed, digest: digest,
                               domain: "presentation", maximum: OfflineCacheLimits.presentationCheckpointBytes)
        guard [1, CachePresentationCheckpoint.currentFormat].contains(value.format), value.scope == scope, value.cursor >= 0,
              value.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              value.rows.count <= LibraryWire.maximumRetainedEntries else { throw OfflineCacheError.corruptCache }
        var ids = Set<UUID>(), total = sealed.count
        for (name, ref) in value.rows {
            let id = try OfflineCacheCodec.entryID(name)
            guard ids.insert(ref.rowID).inserted, ref.digest.count == 32,
                  (28...OfflineCacheLimits.presentationRowBytes).contains(ref.bytes),
                  id.kind == .item || ref.documentID == nil else { throw OfflineCacheError.corruptCache }
            total += ref.bytes
        }
        guard total <= OfflineCacheLimits.presentationBytes else { throw OfflineCacheError.corruptCache }
        return value
    }

    private func storedRow(_ ref: CacheEntryReference, entryID: LibraryEntryID, cursor: Int64) throws -> CacheLibraryRow {
        let sealed = try blob("SELECT sealed FROM local_library_cache_entries WHERE id=?", values: [.text(ref.rowID.wire)], maximum: OfflineCacheLimits.presentationRowBytes)
        guard sealed.count == ref.bytes else { throw OfflineCacheError.corruptCache }
        let value = try decode(CacheLibraryRow.self, sealed: sealed, digest: ref.digest,
                               domain: "presentation-row", identity: [ref.rowID.wire], maximum: OfflineCacheLimits.presentationRowBytes)
        guard value.format == 1, value.rowID == ref.rowID, value.entry.id == entryID,
              value.entry.stateSequence <= cursor,
              OfflineCacheCodec.documentID(value.entry) == ref.documentID else { throw OfflineCacheError.corruptCache }
        if let policy = value.readerPolicy {
            guard case .item(let item) = value.entry, policy.eligibility.hasObservation,
                  policy.eligibility.itemState == item.stateSequence,
                  policy.eligibility.cursor <= cursor,
                  item.artifactID == nil || item.artifactID == policy.artifactID else { throw OfflineCacheError.corruptCache }
            try policy.eligibility.validate(documentID: item.documentID, artifactID: policy.artifactID)
        }
        return value
    }

    private func row(_ ref: CacheEntryReference, entryID: LibraryEntryID, cursor: Int64) throws -> LibraryEntry {
        try storedRow(ref, entryID: entryID, cursor: cursor).entry
    }

    func presentation(_ roots: OfflineCacheRoots) throws -> CachedLibraryPresentation? {
        // This path also prepares accepted cache mutations. Preserve its
        // existing drain semantics even when its caller has been cancelled.
        guard let projected = try projectPresentation(roots, cancellation: .acceptedWork, project: { $0 }) else { return nil }
        return .init(scope: projected.scope, committedCursor: projected.committedCursor,
                     capturedAt: projected.capturedAt,
                     entries: Dictionary(uniqueKeysWithValues: projected.rows.map { ($0.id, $0) }))
    }

    func projectPresentation<Row: Sendable>(_ roots: OfflineCacheRoots,
        project: @Sendable (LibraryEntry) throws -> Row?) throws -> CachedLibraryProjection<Row>? {
        try projectPresentation(roots, cancellation: .cooperativeRead, project: project)
    }

    private enum PresentationCancellation {
        case acceptedWork, cooperativeRead
        func check() throws {
            if self == .cooperativeRead { try Task.checkCancellation() }
        }
    }

    private func projectPresentation<Row: Sendable>(_ roots: OfflineCacheRoots,
        cancellation: PresentationCancellation,
        project: @Sendable (LibraryEntry) throws -> Row?) throws -> CachedLibraryProjection<Row>? {
        try cancellation.check()
        let checkpoint = try checkpoint(roots)
        let expected = Set(checkpoint?.rows.values.map(\.rowID.wire) ?? [])
        var actual = Set<String>()
        try database.statement("SELECT id FROM local_library_cache_entries LIMIT 4001") { statement in
            while true {
                try cancellation.check()
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw DatabaseFailure(code: result) }
                guard actual.count < LibraryWire.maximumRetainedEntries else { throw OfflineCacheError.corruptCache }
                let id = try SQLiteConnection.text(statement, 0, maximumBytes: 36)
                guard actual.insert(id).inserted else { throw OfflineCacheError.corruptCache }
            }
        }
        guard actual == expected else { throw OfflineCacheError.corruptCache }
        try cancellation.check()
        guard let checkpoint else { return nil }
        var validation = PresentationValidation(cursor: checkpoint.cursor)
        var rows: [(key: LibraryOrderingKey, value: Row)] = []
        rows.reserveCapacity(checkpoint.rows.count)
        // An explicit local order makes projection/corruption schedules stable;
        // global display/search sorting remains the caller's responsibility.
        for name in checkpoint.rows.keys.sorted() {
            try cancellation.check()
            let ref = checkpoint.rows[name]!
            let id = try OfflineCacheCodec.entryID(name)
            // This scope owns at most one complete decoded entry. A native
            // metadata projector does not accumulate the original item DTOs.
            let entry = try row(ref, entryID: id, cursor: checkpoint.cursor)
            try validation.append(entry, id: id)
            if let value = try project(entry) { rows.append((LibraryOrderingKey(entry), value)) }
        }
        try validation.finish()
        try rows.sort { left, right in
            try cancellation.check()
            return left.key < right.key
        }
        let projected = rows.map(\.value)
        try cancellation.check()
        return .init(scope: scope, committedCursor: checkpoint.cursor, capturedAt: checkpoint.capturedAt,
                     validatedEntryCount: checkpoint.rows.count, rows: projected)
    }

    private func validateEntries(_ entries: [LibraryEntryID: LibraryEntry], cursor: Int64) throws {
        var validation = PresentationValidation(cursor: cursor)
        for (id, entry) in entries { try validation.append(entry, id: id) }
        try validation.finish()
    }

    /// Cross-row validation retains identities/links only, never metadata. The
    /// write admission and both read APIs share these exact entry/link rules.
    private struct PresentationValidation {
        let cursor: Int64
        var ids = Set<LibraryEntryID>()
        var documents = Set<UUID>()
        var items: [UUID: UUID] = [:]
        var imports: [(itemID: UUID, documentID: UUID?)] = []

        mutating func append(_ entry: LibraryEntry, id: LibraryEntryID) throws {
            guard cursor >= 0, ids.count < LibraryWire.maximumRetainedEntries,
                  ids.insert(id).inserted else { throw OfflineCacheError.invalidObservation }
            try entry.validate()
            guard id == entry.id, entry.stateSequence <= cursor else { throw OfflineCacheError.invalidObservation }
            switch entry {
            case .item(let item):
                guard documents.insert(item.documentID).inserted else { throw OfflineCacheError.invalidObservation }
                items[item.id] = item.documentID
            case .import(let value):
                if let target = value.libraryItemID {
                    imports.append((target, value.documentID))
                }
            }
        }

        func finish() throws {
            guard cursor >= 0 else { throw OfflineCacheError.invalidObservation }
            for link in imports {
                guard let document = items[link.itemID], document == link.documentID
                else { throw OfflineCacheError.invalidObservation }
            }
        }
    }

    func index(_ roots: OfflineCacheRoots) throws -> (value: CacheBundleIndex, sealedBytes: Int) {
        guard let digest = roots.bundles else { return (.init(format: 1, scope: scope, installations: []), 0) }
        let sealed = try blob("SELECT sealed FROM local_reader_bundle_index WHERE id=1", maximum: OfflineCacheLimits.bundleIndexBytes)
        let value = try decode(CacheBundleIndex.self, sealed: sealed, digest: digest, domain: "bundle-index", maximum: OfflineCacheLimits.bundleIndexBytes)
        guard value.format == 1, value.scope == scope, value.installations.count <= OfflineCacheLimits.installedBundles else { throw OfflineCacheError.corruptCache }
        var ids = Set<UUID>(), artifacts = Set<UUID>(), total = sealed.count
        for item in value.installations {
            _ = try item.binding(scope: scope)
            guard ids.insert(item.id).inserted, artifacts.insert(item.artifactID).inserted,
                  item.headerDigest.count == 32, (28...OfflineCacheLimits.bundleHeaderBytes).contains(item.headerBytes),
                  (1...512).contains(item.memberCount), item.revision > 0,
                  item.ciphertextBytes >= item.headerBytes + item.memberCount * 28,
                  item.ciphertextBytes <= 33_554_432 + 512 * 28 + OfflineCacheLimits.bundleHeaderBytes,
                  item.eligibility.cursor >= 0, item.eligibility.itemState >= 0,
                  item.eligibility.itemState <= item.eligibility.cursor,
                  item.eligibility.availabilityRevision.map({ $0 >= 0 }) ?? true
            else { throw OfflineCacheError.corruptCache }
            try item.eligibility.validate(documentID: item.documentID, artifactID: item.artifactID)
            total += item.ciphertextBytes
        }
        guard total <= OfflineCacheLimits.bundleBytes else { throw OfflineCacheError.corruptCache }
        return (value, sealed.count)
    }

    func list(_ roots: OfflineCacheRoots, generation: Int64) throws -> InstalledReaderBundleList {
        let value = try index(roots)
        return .init(scope: scope, generation: generation, installations: try value.value.installations.map { try $0.summary(scope: scope) },
                     ciphertextBytes: value.sealedBytes + value.value.installations.reduce(0) { $0 + $1.ciphertextBytes })
    }

    private func item(documentID: UUID, checkpoint: CachePresentationCheckpoint) throws -> LibraryItemRecord? {
        let refs = checkpoint.rows.filter { $0.value.documentID == documentID }
        guard refs.count <= 1 else { throw OfflineCacheError.corruptCache }
        guard let ref = refs.first else { return nil }
        guard case .item(let item) = try row(ref.value, entryID: OfflineCacheCodec.entryID(ref.key), cursor: checkpoint.cursor)
        else { throw OfflineCacheError.corruptCache }
        return item
    }

    func eligibility(binding: ReaderArtifactBinding, roots: OfflineCacheRoots, existing: ReaderBundleEligibility = .init()) throws -> ReaderBundleEligibility {
        guard let checkpoint = try checkpoint(roots) else { return existing }
        let refs = checkpoint.rows.filter { $0.value.documentID == binding.documentID }
        guard refs.count <= 1 else { throw OfflineCacheError.corruptCache }
        var base = existing
        var item: LibraryItemRecord?
        if let ref = refs.first {
            let saved = try storedRow(ref.value, entryID: OfflineCacheCodec.entryID(ref.key), cursor: checkpoint.cursor)
            guard case .item(let value) = saved.entry else { throw OfflineCacheError.corruptCache }
            item = value
            if let policy = saved.readerPolicy, policy.artifactID == binding.artifactID,
               !base.hasObservation || policy.eligibility.cursor >= base.cursor { base = policy.eligibility }
        }
        return try base.applying(cursor: checkpoint.cursor, item: item, documentID: binding.documentID, artifactID: binding.artifactID)
    }

    private func indexWrite(_ index: CacheBundleIndex, roots: inout OfflineCacheRoots, writes: inout [CacheWrite]) throws {
        let sealed = try seal(index, domain: "bundle-index", maximum: OfflineCacheLimits.bundleIndexBytes)
        guard index.installations.count <= OfflineCacheLimits.installedBundles,
              index.installations.reduce(sealed.count, { $0 + $1.ciphertextBytes }) <= OfflineCacheLimits.bundleBytes
        else { throw OfflineCacheError.capacityExceeded }
        roots.scope = scope; roots.bundles = OfflineCacheCodec.digest(sealed); writes.append(.bundleIndex(sealed))
    }

    func preparePresentation(_ observation: LibraryCompleteObservation, roots: OfflineCacheRoots, capturedAt: Date,
                             format: Int = CachePresentationCheckpoint.currentFormat) throws -> (OfflineCacheMutation?, CachedLibraryPresentation) {
        guard observation.accountID == scope.accountID, capturedAt.timeIntervalSinceReferenceDate.isFinite else { throw OfflineCacheError.invalidObservation }
        try validateEntries(observation.entries, cursor: observation.committedCursor)
        let old = try presentation(roots), previous = try checkpoint(roots)
        if let old {
            guard observation.committedCursor >= old.committedCursor else { throw OfflineCacheError.staleObservation }
        }
        // A v2-era snapshot may lack web papers at the same cursor: replace it, don't compare.
        if let old, previous?.format == CachePresentationCheckpoint.currentFormat {
            if observation.committedCursor == old.committedCursor {
                guard observation.entries == old.entries else { throw OfflineCacheError.conflictingObservation }
                return (nil, old)
            }
            guard Set(old.entries.keys).isSubset(of: Set(observation.entries.keys)) else { throw OfflineCacheError.invalidObservation }
            for (id, entry) in observation.entries {
                if let prior = old.entries[id] {
                    try validateLibraryIdentity(prior, entry)
                    guard entry.stateSequence >= prior.stateSequence else { throw OfflineCacheError.staleObservation }
                    guard entry.stateSequence != prior.stateSequence || entry == prior else { throw OfflineCacheError.conflictingObservation }
                }
            }
        }
        var writes: [CacheWrite] = [], next = roots, refs: [String: CacheEntryReference] = [:]
        for (id, entry) in observation.entries {
            let name = OfflineCacheCodec.entryKey(id)
            if old?.entries[id] == entry, let existing = previous?.rows[name] { refs[name] = existing; continue }
            let rowID = previous?.rows[name]?.rowID ?? UUID()
            var prior: CacheItemPolicy?
            if let previous, let ref = previous.rows[name] { prior = try storedRow(ref, entryID: id, cursor: previous.cursor).readerPolicy }
            var policy: CacheItemPolicy?
            if case .item(let item) = entry, let artifact = item.artifactID ?? prior?.artifactID {
                let base = prior?.artifactID == artifact ? prior?.eligibility ?? .init() : .init()
                policy = .init(artifactID: artifact, eligibility: try base.applying(cursor: observation.committedCursor,
                    item: item, documentID: item.documentID, artifactID: artifact))
            }
            let row = CacheLibraryRow(format: 1, rowID: rowID, entry: entry, readerPolicy: policy)
            let sealed = try seal(row, domain: "presentation-row", identity: [rowID.wire], maximum: OfflineCacheLimits.presentationRowBytes)
            refs[name] = .init(rowID: rowID, digest: OfflineCacheCodec.digest(sealed), bytes: sealed.count,
                               documentID: OfflineCacheCodec.documentID(entry))
            writes.append(.presentationRow(rowID, sealed))
        }
        for (id, value) in previous?.rows ?? [:] where refs[id] == nil { writes.append(.deletePresentationRow(value.rowID)) }
        let checkpoint = CachePresentationCheckpoint(format: format, scope: scope, cursor: observation.committedCursor, capturedAt: capturedAt, rows: refs)
        let sealed = try seal(checkpoint, domain: "presentation", maximum: OfflineCacheLimits.presentationCheckpointBytes)
        guard refs.values.reduce(sealed.count, { $0 + $1.bytes }) <= OfflineCacheLimits.presentationBytes else { throw OfflineCacheError.capacityExceeded }
        writes.append(.checkpoint(sealed)); next.scope = scope; next.presentation = OfflineCacheCodec.digest(sealed)
        var index = try index(roots).value, changed = false
        let items = Dictionary(uniqueKeysWithValues: observation.entries.values.compactMap { entry -> (UUID, LibraryItemRecord)? in
            if case .item(let item) = entry { return (item.documentID, item) }; return nil
        })
        for position in index.installations.indices {
            var value = index.installations[position]
            let guardValue = try value.eligibility.applying(cursor: observation.committedCursor,
                item: items[value.documentID], documentID: value.documentID, artifactID: value.artifactID)
            if guardValue != value.eligibility {
                if guardValue.membershipVisible != value.eligibility.membershipVisible || guardValue.block != value.eligibility.block {
                    guard value.revision < Int64.max else { throw OfflineCacheError.capacityExceeded }
                    value.revision += 1
                }
                value.eligibility = guardValue; index.installations[position] = value; changed = true
            }
        }
        if changed { try indexWrite(index, roots: &next, writes: &writes) }
        return (.init(roots: next, writes: writes), .init(scope: scope, committedCursor: observation.committedCursor, capturedAt: capturedAt, entries: observation.entries))
    }

    private func bindingAAD(_ binding: ReaderArtifactBinding, id: UUID, ordinal: Int? = nil) -> [String] {
        [id.wire, binding.documentID.wire, binding.artifactID.wire, binding.manifestSHA256] + (ordinal.map { [String($0)] } ?? [])
    }

    func prepareInstall(_ binding: ReaderArtifactBinding, id: UUID, bundle: VerifiedReaderBundle, roots: OfflineCacheRoots) throws -> (OfflineCacheMutation?, InstalledReaderBundle) {
        guard bundle.manifestSHA256 == binding.manifestSHA256 else { throw OfflineCacheError.invalidBinding }
        var index = try index(roots).value
        if let existing = index.installations.first(where: { $0.artifactID == binding.artifactID }) {
            guard try existing.binding(scope: scope) == binding else { throw OfflineCacheError.invalidBinding }
            let summary = try existing.summary(scope: scope)
            guard summary.canOpen else { throw OfflineCacheError.blocked }
            return (nil, summary)
        }
        guard index.installations.count < OfflineCacheLimits.installedBundles else { throw OfflineCacheError.capacityExceeded }
        let guardValue = try eligibility(binding: binding, roots: roots)
        guard guardValue.block == nil, guardValue.membershipVisible != false else { throw OfflineCacheError.blocked }
        let placeholder = Data(repeating: 0, count: 32)
        let anticipatedMembers = bundle.manifest.members.enumerated().map {
            CacheMemberReference(ordinal: $0.offset, digest: placeholder, bytes: $0.element.bytes + 28)
        }
        let anticipatedHeader = CacheBundleHeader(format: 1, installationID: id, binding: binding,
            manifestData: bundle.manifestData, members: anticipatedMembers)
        let headerBytes = try OfflineCacheCodec.encode(anticipatedHeader).count + 28
        let memberBytes = anticipatedMembers.reduce(0) { $0 + $1.bytes }
        let anticipated = CacheInstallation(id: id, documentID: binding.documentID, artifactID: binding.artifactID,
            manifestSHA256: binding.manifestSHA256, headerDigest: placeholder, headerBytes: headerBytes,
            memberCount: anticipatedMembers.count, ciphertextBytes: memberBytes + headerBytes, revision: 1, eligibility: guardValue)
        var anticipatedIndex = index; anticipatedIndex.installations.append(anticipated)
        let indexBytes = try OfflineCacheCodec.encode(anticipatedIndex).count + 28
        guard headerBytes <= OfflineCacheLimits.bundleHeaderBytes, indexBytes <= OfflineCacheLimits.bundleIndexBytes,
              anticipatedIndex.installations.reduce(OfflineCacheLimits.bundleIndexBytes, { $0 + $1.ciphertextBytes }) <= OfflineCacheLimits.bundleBytes
        else { throw OfflineCacheError.capacityExceeded }
        // Header/member charge is exact before encrypting any member. Reserve
        // the directory ceiling so later cursor/block updates still fit at
        // full capacity; the public list reports actual committed bytes.
        var refs: [CacheMemberReference] = [], members: [CacheWrite] = [], bytes = 0
        for (ordinal, member) in bundle.manifest.members.enumerated() {
            guard let plain = bundle.data(for: member.path) else { throw OfflineCacheError.corruptCache }
            let sealed = try OfflineCacheCodec.seal(plain, domain: "bundle-member", scope: scope,
                identity: bindingAAD(binding, id: id, ordinal: ordinal), key: key, maximum: OfflineCacheLimits.memberBytes)
            refs.append(.init(ordinal: ordinal, digest: OfflineCacheCodec.digest(sealed), bytes: sealed.count))
            members.append(.member(id, ordinal, sealed)); bytes += sealed.count
        }
        let header = CacheBundleHeader(format: 1, installationID: id, binding: binding, manifestData: bundle.manifestData, members: refs)
        let sealed = try seal(header, domain: "bundle-header", identity: bindingAAD(binding, id: id), maximum: OfflineCacheLimits.bundleHeaderBytes)
        guard sealed.count == headerBytes, bytes == memberBytes else { throw OfflineCacheError.corruptCache }
        let value = CacheInstallation(id: id, documentID: binding.documentID, artifactID: binding.artifactID,
            manifestSHA256: binding.manifestSHA256, headerDigest: OfflineCacheCodec.digest(sealed), headerBytes: sealed.count,
            memberCount: refs.count, ciphertextBytes: bytes + sealed.count, revision: 1, eligibility: guardValue)
        index.installations.append(value)
        var next = roots, writes: [CacheWrite] = [.header(id, sealed)] + members
        try indexWrite(index, roots: &next, writes: &writes)
        return (.init(roots: next, writes: writes), try value.summary(scope: scope))
    }

    func installed(_ id: UUID, roots: OfflineCacheRoots) throws -> CacheInstallation {
        guard let value = try index(roots).value.installations.first(where: { $0.id == id }) else { throw OfflineCacheError.notInstalled }
        return value
    }

    func read(_ id: UUID, roots: OfflineCacheRoots, writerID: UUID) throws -> StoredReaderBundlePayload {
        let value = try installed(id, roots: roots), binding = try value.binding(scope: scope)
        guard try value.summary(scope: scope).canOpen else { throw OfflineCacheError.blocked }
        let sealed = try blob("SELECT sealed FROM local_reader_bundle_headers WHERE id=?", values: [.text(id.wire)], maximum: OfflineCacheLimits.bundleHeaderBytes)
        guard sealed.count == value.headerBytes else { throw OfflineCacheError.corruptCache }
        let header = try decode(CacheBundleHeader.self, sealed: sealed, digest: value.headerDigest, domain: "bundle-header",
                                identity: bindingAAD(binding, id: id), maximum: OfflineCacheLimits.bundleHeaderBytes)
        guard header.format == 1, header.installationID == id, header.binding == binding,
              header.manifestData.count <= 262_144, header.members.count == value.memberCount,
              VerifiedReaderBundle.digest(header.manifestData) == binding.manifestSHA256 else { throw OfflineCacheError.corruptCache }
        let manifest: ReaderBundleManifest
        do { manifest = try JSONDecoder().decode(ReaderBundleManifest.self, from: header.manifestData) }
        catch { throw OfflineCacheError.corruptCache }
        guard manifest.members.count == header.members.count else { throw OfflineCacheError.corruptCache }
        var expectedTotal = value.headerBytes
        for (ordinal, ref) in header.members.enumerated() {
            guard ref.ordinal == ordinal, ref.digest.count == 32,
                  (28...OfflineCacheLimits.memberBytes).contains(ref.bytes), manifest.members[ordinal].bytes == ref.bytes - 28
            else { throw OfflineCacheError.corruptCache }
            expectedTotal += ref.bytes
        }
        guard expectedTotal == value.ciphertextBytes else { throw OfflineCacheError.corruptCache }
        var members: [String: Data] = [:], seen = 0
        try database.statement("SELECT ordinal FROM local_reader_bundle_members WHERE bundle_id=? ORDER BY ordinal LIMIT 513", values: [.text(id.wire)]) { statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw DatabaseFailure(code: result) }
                guard seen < header.members.count, sqlite3_column_int64(statement, 0) == seen else { throw OfflineCacheError.corruptCache }
                let ref = header.members[seen]
                let data = try blob("SELECT sealed FROM local_reader_bundle_members WHERE bundle_id=? AND ordinal=?",
                    values: [.text(id.wire), .integer(Int64(seen))], maximum: ref.bytes)
                guard data.count == ref.bytes else { throw OfflineCacheError.corruptCache }
                members[manifest.members[seen].path] = try OfflineCacheCodec.open(data, digest: ref.digest, domain: "bundle-member", scope: scope,
                    identity: bindingAAD(binding, id: id, ordinal: seen), key: key, maximum: OfflineCacheLimits.memberBytes)
                seen += 1
            }
        }
        guard seen == header.members.count else { throw OfflineCacheError.corruptCache }
        do { _ = try VerifiedReaderBundle.verify(manifest: header.manifestData, expectedSHA256: binding.manifestSHA256, members: members) }
        catch { throw OfflineCacheError.corruptCache }
        return .init(manifestData: header.manifestData, members: members,
                     openToken: .init(installationID: id, binding: binding, revision: value.revision, writerID: writerID))
    }

    func prepareRemoval(_ id: UUID, revision: Int64, roots: OfflineCacheRoots) throws -> (OfflineCacheMutation, ReaderArtifactBinding) {
        var index = try index(roots).value
        guard let position = index.installations.firstIndex(where: { $0.id == id }) else { throw OfflineCacheError.notInstalled }
        let old = index.installations[position]
        guard revision == old.revision else { throw OfflineCacheError.revisionConflict }
        index.installations.remove(at: position)
        var next = roots, writes: [CacheWrite] = [.deleteBundle(id)]
        try indexWrite(index, roots: &next, writes: &writes)
        return (.init(roots: next, writes: writes), try old.binding(scope: scope))
    }
}
