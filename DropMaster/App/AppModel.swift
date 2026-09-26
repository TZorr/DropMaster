//
//  AppModel.swift
//  DropMaster
//
//  The whole app state: a target, five reference slots, one result, one
//  player.
//
//  Of the five references one is active, and the match, the Reference row
//  and the Reference preview all mean that one. Choosing another slot
//  matches again against it - half a second, not a decode: every slot
//  keeps its decoded audio, about 110 MB for a five-minute song, so all
//  five full is roughly half a gigabyte. That is the price of switching
//  between references as fast as between Original and Matched. Nothing is
//  remembered across launches, as with the target.
//
//  A preset stands in for a reference: when one is loaded, the tone comes
//  from its saved curve and its slot shows the preset instead. Dropping a
//  reference into that slot throws the preset away - two sources for the
//  same curve would be one too many. The preset's limiter settings are
//  applied when it is opened, not every time its slot is chosen: a slot
//  button that silently rewrote the limiter panel would be a trap.
//
//  There is no "Match" button. The moment the target and the active slot
//  hold decoded audio the match starts, and dropping a new file into
//  either starts it again. A reference decoding in another slot does not.
//  Matching takes seconds, not minutes, and a button would only add a step
//  between dropping a file and hearing what it does - the one thing the app
//  is for.
//
//  Every background job carries a generation number - one per slot for
//  decoding (the target and each reference slot), one for matching. A file dropped while the previous one is
//  still decoding, or while a match is running, bumps them; results that
//  come back with an older number are thrown away rather than overwriting
//  newer ones. Per slot, not one for everything: dropping the reference
//  while the target is still decoding must not throw the target away. The
//  running task is cancelled too, but cancellation is only checked between
//  stages, so the generation is what actually guarantees the order.
//
//  The limiter panel re-runs only the last stage (Matcher.finish) on the
//  prepared match it keeps. A slider drag changes the settings many times a
//  second, so the run waits 150 ms for the drag to settle, and each new
//  change cancels the one before. The result replaces the matched audio in
//  the player without stopping it: the listener hears the new limiter at
//  the same place in the song.
//

import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

enum SlotRole: String, CaseIterable, Identifiable {
    case target, reference
    var id: String { rawValue }
    var title: String {
        switch self {
        case .target: "Target"
        case .reference: "Reference"
        }
    }
    var subtitle: String {
        switch self {
        case .target: "The track to master"
        case .reference: "How it should sound"
        }
    }
}

/// Which slot a decode, its generation and its loudness figures belong
/// to.
enum SlotKey: Hashable {
    case target
    case reference(Int)
}

/// One drop zone's content.
struct Slot {
    enum State {
        case empty
        case decoding
        case ready(StereoAudio, SourceInfo)
        case failed(String)
    }
    var url: URL?
    var state: State = .empty

    var audio: StereoAudio? {
        if case .ready(let audio, _) = state { return audio }
        return nil
    }
}

enum MatchState {
    case idle
    case running(MatchStage)
    case done(MatchReport)
    case failed(String)
}

@Observable
final class AppModel {
    static let referenceSlotCount = 5

    private(set) var target = Slot()
    /// The reference slots; `activeReference` is the one matched against.
    private(set) var references = Array(repeating: Slot(), count: AppModel.referenceSlotCount)
    /// Saved matches standing in for a slot's reference, per slot.
    private(set) var presets: [MatchPreset?] = Array(repeating: nil, count: AppModel.referenceSlotCount)
    private(set) var activeReference = 0
    private(set) var match: MatchState = .idle
    private(set) var result: StereoAudio?
    /// The last export's outcome, shown beside the export buttons.
    private(set) var exportMessage: String?
    private(set) var exporting = false
    /// Loudness figures per slot, and of the result; nil while measuring.
    private var slotStats: [SlotKey: LoudnessStats] = [:]
    private(set) var matchedStats: LoudnessStats?
    /// True while the limiter stage is running again for new settings.
    private(set) var refining = false

    /// The active slot's reference file, and the preset standing in for
    /// it, or nil.
    var reference: Slot { references[activeReference] }
    var preset: MatchPreset? { presets[activeReference] }

    var limiter: LimiterSettings = AppModel.storedLimiter() {
        didSet {
            guard limiter != oldValue else { return }
            if let data = try? JSONEncoder().encode(limiter) {
                UserDefaults.standard.set(data, forKey: Self.limiterKey)
            }
            refine()
        }
    }

    let player = ABPlayer()

    @ObservationIgnored private var decodeGeneration: [SlotKey: Int] = [:]
    @ObservationIgnored private var matchGeneration = 0
    @ObservationIgnored private var decodeTasks: [SlotKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var matchTask: Task<Void, Never>?
    @ObservationIgnored private var preparation: MatchPreparation?
    @ObservationIgnored private var refineTask: Task<Void, Never>?
    /// The settings the running match was started with: if the panel
    /// changed meanwhile, the limiter stage runs again when it arrives.
    @ObservationIgnored private var matchSettings = LimiterSettings()

    private static let limiterKey = "limiterSettings"

    /// JSON as Data: a String written by another tool would read as nothing.
    private static func storedLimiter() -> LimiterSettings {
        guard let data = UserDefaults.standard.data(forKey: limiterKey),
              let settings = try? JSONDecoder().decode(LimiterSettings.self, from: data) else { return LimiterSettings() }
        return settings
    }

    func slot(_ role: SlotRole) -> Slot {
        role == .target ? target : reference
    }

    /// The key a role means now: the reference is the active slot.
    private func key(_ role: SlotRole) -> SlotKey {
        role == .target ? .target : .reference(activeReference)
    }

    /// The target's figures, or the active reference file's.
    func stats(_ role: SlotRole) -> LoudnessStats? { slotStats[key(role)] }

    // MARK: - Loading

    /// What the loudness table's Reference row shows: the loaded
    /// reference, or the figures the preset carries.
    var referenceStats: LoudnessStats? { preset?.reference ?? stats(.reference) }

    /// Matching needs a target plus either a reference or a preset.
    var canMatch: Bool { target.audio != nil && (preset != nil || reference.audio != nil) }

    func load(_ url: URL, into role: SlotRole) {
        load(url, key: key(role))
    }

    /// A file dropped on a slot button: it goes into that slot, which
    /// becomes the active one.
    func loadReference(_ url: URL, slot index: Int) {
        selectReference(index)
        load(url, key: .reference(index))
    }

    private func load(_ url: URL, key: SlotKey) {
        let mine = (decodeGeneration[key] ?? 0) + 1
        decodeGeneration[key] = mine
        decodeTasks[key]?.cancel()
        set(key, Slot(url: url, state: .decoding))
        slotStats[key] = nil
        switch key {
        case .target:
            cancelMatch()
            player.setOriginal(nil)
            exportMessage = nil
        case .reference(let index):
            // A dropped reference replaces the slot's preset: it is the
            // fresher answer to the same question.
            presets[index] = nil
            if index == activeReference {
                cancelMatch()
                player.setReference(nil)
            }
        }
        let role = key == .target ? SlotRole.target : .reference
        decodeTasks[key] = Task.detached(priority: .userInitiated) { [weak self] in
            let state: Slot.State
            do {
                let (audio, info) = try Decoder.decode(url)
                try Matcher.validate(audio, role: role.rawValue)
                state = .ready(audio, info)
            } catch is CancellationError {
                return
            } catch {
                state = .failed(error.localizedDescription)
            }
            await self?.decoded(key, generation: mine, slot: Slot(url: url, state: state))
            if case .ready(let audio, _) = state {
                let measured = LoudnessStats.measure(audio)
                await self?.measured(key, generation: mine, stats: measured)
            }
        }
    }

    private func measured(_ key: SlotKey, generation: Int, stats: LoudnessStats) {
        guard decodeGeneration[key] == generation else { return }
        slotStats[key] = stats
    }

    private func decoded(_ key: SlotKey, generation: Int, slot: Slot) {
        guard decodeGeneration[key] == generation else { return }
        set(key, slot)
        switch key {
        case .target:
            player.setOriginal(target.audio)
        case .reference(let index):
            // A slot in the background only fills; it is matched against
            // when it is chosen.
            guard index == activeReference else { return }
            player.setReference(reference.audio)
        }
        startMatchIfReady()
    }

    /// Makes another slot the active reference and matches against it. An
    /// empty slot leaves the match idle.
    func selectReference(_ index: Int) {
        guard references.indices.contains(index), index != activeReference else { return }
        activeReference = index
        player.setReference(reference.audio)
        cancelMatch()
        startMatchIfReady()
    }

    /// Empties a slot: its file, its preset and its figures.
    func clearReference(_ index: Int) {
        guard references.indices.contains(index) else { return }
        let key = SlotKey.reference(index)
        decodeTasks[key]?.cancel()
        decodeGeneration[key] = (decodeGeneration[key] ?? 0) + 1
        references[index] = Slot()
        presets[index] = nil
        slotStats[key] = nil
        if index == activeReference {
            player.setReference(nil)
            cancelMatch()
        }
    }

    func chooseReference(slot index: Int) {
        guard let url = openAudioPanel(title: "Choose reference \(index + 1)") else { return }
        loadReference(url, slot: index)
    }

    func choose(_ role: SlotRole) {
        if let url = openAudioPanel(title: "Choose the \(role.title.lowercased())") {
            load(url, into: role)
        }
    }

    private func openAudioPanel(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func set(_ key: SlotKey, _ slot: Slot) {
        switch key {
        case .target: target = slot
        case .reference(let index): references[index] = slot
        }
    }

    // MARK: - Matching

    private func cancelMatch() {
        matchGeneration += 1
        matchTask?.cancel()
        matchTask = nil
        refineTask?.cancel()
        refineTask = nil
        refining = false
        preparation = nil
        matchedStats = nil
        result = nil
        player.setMatched(nil)
        match = .idle
    }

    private func startMatchIfReady() {
        guard let targetAudio = target.audio, preset != nil || reference.audio != nil else { return }
        let referenceAudio = reference.audio
        let usedPreset = preset
        matchGeneration += 1
        let mine = matchGeneration
        match = .running(.analysing)
        let settings = limiter
        matchSettings = settings
        matchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<(MatchPreparation, StereoAudio, MatchReport), Error>
            do {
                let progress: (MatchStage) -> Void = { [weak self] stage in
                    Task { await self?.progressed(stage, generation: mine) }
                }
                let preparation: MatchPreparation
                if let usedPreset {
                    preparation = try Matcher.prepare(target: targetAudio, preset: usedPreset, progress: progress)
                } else {
                    preparation = try Matcher.prepare(target: targetAudio, reference: referenceAudio!, progress: progress)
                }
                progress(.limiting)
                let (audio, report) = try Matcher.finish(preparation, settings: settings)
                outcome = .success((preparation, audio, report))
            } catch is CancellationError {
                return
            } catch {
                outcome = .failure(error)
            }
            await self?.matched(outcome, generation: mine)
            if case .success(let (_, audio, _)) = outcome {
                let measured = LoudnessStats.measure(audio)
                await self?.measuredResult(measured, generation: mine)
            }
        }
    }

    /// Runs the limiter stage again for the current settings, after the
    /// settings have been still for 150 ms.
    private func refine() {
        guard let preparation else { return }
        refineTask?.cancel()
        matchGeneration += 1
        let mine = matchGeneration
        let settings = limiter
        refining = true
        refineTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                let (audio, report) = try Matcher.finish(preparation, settings: settings)
                try Task.checkCancellation()
                await self?.refined(audio, report, generation: mine)
                let measured = LoudnessStats.measure(audio)
                await self?.measuredResult(measured, generation: mine)
            } catch {
                // Cancelled by a newer change, which will finish instead.
            }
        }
    }

    private func refined(_ audio: StereoAudio, _ report: MatchReport, generation: Int) {
        guard matchGeneration == generation else { return }
        result = audio
        player.setMatched(audio)
        match = .done(report)
        refining = false
    }

    private func measuredResult(_ stats: LoudnessStats, generation: Int) {
        guard matchGeneration == generation else { return }
        matchedStats = stats
    }

    private func progressed(_ stage: MatchStage, generation: Int) {
        guard matchGeneration == generation, case .running = match else { return }
        match = .running(stage)
    }

    private func matched(_ outcome: Result<(MatchPreparation, StereoAudio, MatchReport), Error>, generation: Int) {
        guard matchGeneration == generation else { return }
        switch outcome {
        case .success(let (preparation, audio, report)):
            self.preparation = preparation
            result = audio
            player.setMatched(audio)
            match = .done(report)
            if limiter != matchSettings { refine() }
        case .failure(let error):
            match = .failed(error.localizedDescription)
        }
    }

    // MARK: - Presets

    /// A preset read from a file, into the active slot.
    func apply(_ loaded: MatchPreset) {
        let index = activeReference, key = SlotKey.reference(activeReference)
        presets[index] = loaded
        limiter = loaded.limiter
        // The preset answers for the slot's reference; the slot shows it.
        decodeTasks[key]?.cancel()
        decodeGeneration[key] = (decodeGeneration[key] ?? 0) + 1
        references[index] = Slot()
        slotStats[key] = nil
        player.setReference(nil)
        cancelMatch()
        startMatchIfReady()
    }

    func openPreset() {
        let panel = NSOpenPanel()
        panel.title = "Open a preset"
        panel.allowedContentTypes = [UTType(filenameExtension: MatchPreset.fileExtension) ?? .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            apply(try MatchPreset.read(from: url))
        } catch {
            match = .failed(error.localizedDescription)
        }
    }

    /// The current match, saved: its curve, the reference's loudness and
    /// the limiter settings (see MatchPreset).
    func savePreset() {
        guard case .done(let report) = match, let preparation else { return }
        let panel = NSSavePanel()
        panel.title = "Save preset"
        panel.allowedContentTypes = [UTType(filenameExtension: MatchPreset.fileExtension) ?? .json]
        let base = preset?.name ?? reference.url?.deletingPathExtension().lastPathComponent ?? "Preset"
        panel.nameFieldStringValue = "\(base).\(MatchPreset.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let saved = MatchPreset(name: url.deletingPathExtension().lastPathComponent,
                                referenceName: reference.url?.lastPathComponent ?? preset?.referenceName ?? "",
                                report: report, reference: referenceStats, limiter: limiter,
                                autoCeilingDB: preparation.autoCeilingDB)
        do {
            try saved.write(to: url)
            exportMessage = "Saved \(url.lastPathComponent)"
            if preset != nil { presets[activeReference] = saved }
        } catch {
            exportMessage = error.localizedDescription
        }
    }

    func closePreset() {
        guard preset != nil else { return }
        presets[activeReference] = nil
        cancelMatch()
        startMatchIfReady()
    }

    // MARK: - Export

    /// Export format and quality, remembered on this Mac. A new format
    /// starts at its own default quality: a "256 kbps" carried over to
    /// FLAC would mean nothing.
    var exportFormat: OutputFormat = AppModel.storedFormat() {
        didSet {
            guard exportFormat != oldValue else { return }
            UserDefaults.standard.set(exportFormat.rawValue, forKey: Self.formatKey)
            exportQuality = exportFormat.defaultQuality
        }
    }

    var exportQuality: QualityOption = AppModel.storedQuality(for: AppModel.storedFormat()) {
        didSet { UserDefaults.standard.set(exportQuality.label, forKey: Self.qualityKey) }
    }

    private static let formatKey = "exportFormat"
    private static let qualityKey = "exportQuality"

    /// WAV / 24-bit until something else is chosen: what a master is
    /// usually delivered as.
    private static func storedFormat() -> OutputFormat {
        UserDefaults.standard.string(forKey: formatKey).flatMap(OutputFormat.init(rawValue:)) ?? .wav
    }

    private static func storedQuality(for format: OutputFormat) -> QualityOption {
        let label = UserDefaults.standard.string(forKey: qualityKey)
        return format.qualityOptions.first { $0.label == label } ?? format.defaultQuality
    }

    var canExport: Bool { result != nil && !exporting && !refining }

    var defaultExportName: String {
        let base = target.url?.deletingPathExtension().lastPathComponent ?? "Matched"
        return "\(base) (matched).\(exportFormat.fileExtension)"
    }

    func export() {
        guard let result, canExport else { return }
        let format = exportFormat, quality = exportQuality
        let panel = NSSavePanel()
        panel.title = "Export \(format.menuTitle) · \(quality.label)"
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = defaultExportName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        exportMessage = "Exporting…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let message: String
            do {
                try Exporter.export(result, format: format, quality: quality, to: url)
                message = "Saved \(url.lastPathComponent) · \(format.menuTitle) \(quality.label)"
            } catch {
                message = error.localizedDescription
            }
            await self?.exported(message)
        }
    }

    private func exported(_ message: String) {
        exporting = false
        exportMessage = message
    }
}
