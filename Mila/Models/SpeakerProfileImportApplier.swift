import Foundation
import os

private let applierLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                category: "SpeakerProfileImport")

/// What applying a `SpeakerProfileImportPlan` did, and how the recording's
/// labels should be rewritten to agree with it.
struct SpeakerProfileImportResult: Equatable {
    /// Incoming (sender's) name → the name now on the receiver's profile.
    /// Identity for skipped rows. `RecordingShareImporter` maps the shared
    /// recording's `speakerNames` through this before saving it, so a
    /// speaker merged into "Alex" is labelled "Alex" on the transcript and
    /// one kept separate is labelled "Alex (from Daniel)".
    var nameMapping: [String: String] = [:]
    var merged = 0
    var added = 0
    var skipped = 0
}

/// Writes a plan into the receiver's `SpeakerProfileStore`. Synchronous and
/// on the main actor: no Python, no `await`, nothing to race.
///
/// Both actions go through `updateProfile`, which is already the
/// weighted-mean upsert-by-name and carries the consent gate
/// (`isConfigured`) and the dimension / model guards. `mergeProfiles` is the
/// wrong tool here — it merges two profiles that are both already stored.
@MainActor
enum SpeakerProfileImportApplier {

    /// The label rewrite `apply` would produce, computed WITHOUT writing
    /// anything. `RecordingShareImporter` uses it to relabel the recording
    /// and save it first, then calls `apply` only once the library write
    /// succeeded — so a failed import cannot leave the user's voice data
    /// changed. Same rules as `apply`, kept side by side so they can't drift:
    /// a merge maps to the local profile's name (identity if it has gone),
    /// add-as-new maps to the new name, skip and blocked rows map to
    /// themselves.
    static func nameMapping(for plan: SpeakerProfileImportPlan,
                            in store: SpeakerProfileStore) -> [String: String] {
        var mapping: [String: String] = [:]
        for row in plan.rows {
            let incoming = row.incoming.name
            let target: SpeakerProfileImportPlan.Target = row.isBlocked ? .skip : row.target
            switch target {
            case .skip:
                mapping[incoming] = incoming
            case .merge(let id):
                mapping[incoming] = store.profiles.first { $0.id == id }?.name ?? incoming
            case .addAsNew(let rawName):
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                mapping[incoming] = name.isEmpty ? incoming : name
            }
        }
        return mapping
    }

    static func apply(_ plan: SpeakerProfileImportPlan,
                      to store: SpeakerProfileStore) -> SpeakerProfileImportResult {
        var result = SpeakerProfileImportResult()
        for row in plan.rows {
            let incoming = row.incoming
            let token = ImportedShareToken(bundleKey: plan.bundleKey, sharedName: incoming.name)
            // Defensive: a blocked row's target is `.skip` by construction,
            // but the plan is a value the UI edits.
            let target: SpeakerProfileImportPlan.Target = row.isBlocked ? .skip : row.target

            switch target {
            case .skip:
                result.nameMapping[incoming.name] = incoming.name
                result.skipped += 1

            case .merge(let id):
                // The user may have deleted the target while the sheet was
                // open; nothing sensible to fold into, so skip rather than
                // guess.
                guard let local = store.profiles.first(where: { $0.id == id }) else {
                    applierLog.log("merge target vanished; skipping one shared profile")
                    result.nameMapping[incoming.name] = incoming.name
                    result.skipped += 1
                    continue
                }
                let before = local.sampleCount
                store.updateProfile(name: local.name,
                                    embedding: incoming.embedding,
                                    sampleCount: incoming.sampleCount,
                                    embeddingModel: incoming.embeddingModel)
                let after = store.profile(named: local.name)?.sampleCount ?? before
                // The user asserted "this is my Dan", so the transcript says
                // Dan either way; only the COUNT tells us whether the fold
                // was accepted (the store refuses silently on a guard).
                result.nameMapping[incoming.name] = local.name
                if after > before {
                    store.recordImport(token: token, onProfileNamed: local.name)
                    result.merged += 1
                } else {
                    applierLog.log("merge refused by the store; shared profile not folded")
                    result.skipped += 1
                }

            case .addAsNew(let rawName):
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    result.nameMapping[incoming.name] = incoming.name
                    result.skipped += 1
                    continue
                }
                // If the name came into existence while the sheet was open,
                // `updateProfile` folds into it — the same semantics a merge
                // would have had. Count it honestly either way.
                let existedBefore = store.profileExists(name: name)
                let countBefore = store.profiles.count
                let samplesBefore = store.profile(named: name)?.sampleCount ?? 0
                store.updateProfile(name: name,
                                    embedding: incoming.embedding,
                                    sampleCount: incoming.sampleCount,
                                    embeddingModel: incoming.embeddingModel)
                result.nameMapping[incoming.name] = name
                if store.profiles.count > countBefore {
                    store.recordImport(token: token, onProfileNamed: name)
                    result.added += 1
                } else if existedBefore, (store.profile(named: name)?.sampleCount ?? 0) > samplesBefore {
                    store.recordImport(token: token, onProfileNamed: name)
                    result.merged += 1
                } else {
                    applierLog.log("add refused by the store; shared profile not written")
                    result.skipped += 1
                }
            }
        }
        applierLog.log("applied shared voice profiles: merged \(result.merged) added \(result.added) skipped \(result.skipped)")
        return result
    }
}
