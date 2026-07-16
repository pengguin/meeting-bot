import AppKit
import Combine
import Darwin
import Foundation

struct MeetingRecord: Identifiable, Equatable {
    let id: String
    let sessionID: String
    let sessionURL: URL
    let title: String
    let meetingType: String
    let version: String
    let takeaway: String
    let summary: String
    let topics: [String]
    let transcript: String
    let detectedSpeakers: [String]
    let createdAt: Date?
    let latestPDFURL: URL?
    let latestDOCXURL: URL?
    let latestHTMLURL: URL?
    let latestMDURL: URL?
    let transcriptURL: URL?
    let transcriptSegmentsURL: URL?
    let audioURL: URL?
    let isTemporary: Bool
    let processingStage: String
    let processingMessage: String
    let processingErrorDetail: String
    let canRetryReport: Bool
    let canReprocessFromAudio: Bool
    let requestedTemplateID: String?

    var createdAtDisplay: String {
        guard let createdAt else {
            return sessionID
        }

        return DateDisplay.displayFormatter.string(from: createdAt)
    }

    var searchableText: String {
        [
            title,
            meetingType,
            takeaway,
            summary,
            topics.joined(separator: " "),
            transcript,
        ]
        .joined(separator: "\n")
        .lowercased()
    }

    var versionDisplayName: String {
        if isTemporary {
            if processingStage == "paused" {
                return "已暂停"
            }
            return canRetryReport ? "待生成纪要" : "处理中"
        }
        return version == "named" ? "实名版" : "匿名版"
    }

    var titleDisplayName: String {
        title.isEmpty ? sessionID : title
    }
}

struct TranscriptSegment: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var speaker: String
    var text: String

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case speaker
        case text
    }
}

struct LocalMeetingCreationRequest {
    let title: String
    let audioURL: URL?
    let transcriptURL: URL?
    let templateID: String
    let exportFormats: Set<String>
}

struct LocalMeetingCreationResult: Decodable {
    let sessionID: String
    let sessionDirectory: String
    let docxPath: String
    let htmlPath: String
    let mdPath: String
    let pdfPath: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sessionDirectory = "session_dir"
        case docxPath = "docx"
        case htmlPath = "html"
        case mdPath = "md"
        case pdfPath = "pdf"
    }

    func fileURL(for target: MeetingOpenAfterCreation) -> URL? {
        let rawPath: String
        switch target {
        case .none:
            return nil
        case .html:
            rawPath = htmlPath
        case .docx:
            rawPath = docxPath
        case .md:
            rawPath = mdPath
        case .pdf:
            rawPath = pdfPath
        }

        guard !rawPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: rawPath)
    }
}

struct LibraryMetadataDocument: Codable {
    var sessions: [String: SessionUserMetadata] = [:]
    var folders: [LibraryFolder] = [LibraryFolder.trash]
    var globalLabels: [String] = []

    enum CodingKeys: String, CodingKey {
        case sessions
        case folders
        case globalLabels
    }

    init(
        sessions: [String: SessionUserMetadata] = [:],
        folders: [LibraryFolder] = [LibraryFolder.trash],
        globalLabels: [String] = []
    ) {
        self.sessions = sessions
        self.folders = folders
        self.globalLabels = globalLabels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent([String: SessionUserMetadata].self, forKey: .sessions) ?? [:]
        folders = try container.decodeIfPresent([LibraryFolder].self, forKey: .folders) ?? [LibraryFolder.trash]
        globalLabels = try container.decodeIfPresent([String].self, forKey: .globalLabels) ?? []
        if !folders.contains(where: \.isTrash) {
            folders.append(.trash)
        }
    }
}

struct SessionUserMetadata: Codable, Equatable {
    var labels: [String] = []
    var speakerLabels: [String: String] = [:]
    var note: String = ""
    var actualMeetingAt: String = ""
    var folderID: String = ""

    enum CodingKeys: String, CodingKey {
        case labels
        case speakerLabels
        case note
        case actualMeetingAt
        case folderID
    }

    init(
        labels: [String] = [],
        speakerLabels: [String: String] = [:],
        note: String = "",
        actualMeetingAt: String = "",
        folderID: String = ""
    ) {
        self.labels = labels
        self.speakerLabels = speakerLabels
        self.note = note
        self.actualMeetingAt = actualMeetingAt
        self.folderID = folderID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        speakerLabels = try container.decodeIfPresent([String: String].self, forKey: .speakerLabels) ?? [:]
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        actualMeetingAt = try container.decodeIfPresent(String.self, forKey: .actualMeetingAt) ?? ""
        folderID = try container.decodeIfPresent(String.self, forKey: .folderID) ?? ""
    }
}

struct MeetingDetailDraft: Equatable {
    var labelsText = ""
    var note = ""
    var actualMeetingDate: Date?
    var speakerLabels: [String: String] = [:]
}

struct LibraryFolder: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var sortOrder: Int
    var isTrash: Bool

    static let trash = LibraryFolder(id: "trash", name: "回收站", sortOrder: Int.max, isTrash: true)
    static let uncategorized = LibraryFolder(
        id: "uncategorized",
        name: "未分类",
        sortOrder: Int.max - 1,
        isTrash: false
    )
}

enum LibraryDateFilterMode: String, CaseIterable, Identifiable {
    case all
    case single
    case range

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:
            return "全部"
        case .single:
            return "单日"
        case .range:
            return "时间段"
        }
    }
}

private struct MeetingReportSnapshot: Decodable {
    let reportTitle: String?
    let meetingType: String?
    let version: String?
    let oneSentenceTakeaway: String?
    let executiveSummary: String?
    let discussionTopics: [DiscussionTopicSnapshot]?

    enum CodingKeys: String, CodingKey {
        case reportTitle = "report_title"
        case meetingType = "meeting_type"
        case version
        case oneSentenceTakeaway = "one_sentence_takeaway"
        case executiveSummary = "executive_summary"
        case discussionTopics = "discussion_topics"
    }
}

private struct DiscussionTopicSnapshot: Decodable {
    let title: String?
}

private struct LocalMeetingStateSnapshot: Decodable {
    let taskStatus: String?
    let stage: String?
    let message: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case taskStatus = "task_status"
        case stage
        case message
        case updatedAt = "updated_at"
    }
}

private struct LocalMeetingRequestSnapshot: Decodable {
    let title: String?
    let template: String?
    let formats: [String]?
}

final class MeetingLibraryStore: ObservableObject {
    @Published private(set) var meetings: [MeetingRecord] = []
    @Published private(set) var metadata = LibraryMetadataDocument()
    @Published var searchText = ""
    @Published var selectedLabels: Set<String> = []
    @Published var selectedFolderID: String?
    @Published var selectedFolderIDs: Set<String> = []
    @Published var dateFilterMode: LibraryDateFilterMode = .all
    @Published var dateFilterStart = Date()
    @Published var dateFilterEnd = Date()
    @Published var selectedMeetingID: String? {
        didSet { refreshHighlightedFolder() }
    }
    @Published var selectedMeetingIDs: Set<String> = []
    @Published private(set) var highlightedFolderID: String?
    @Published var lastErrorMessage: String?
    @Published private(set) var localMeetingCreationError: String?
    @Published private(set) var reportRegenerationErrors: [String: String] = [:]
    @Published private(set) var regeneratingSessionIDs: Set<String> = []
    @Published private(set) var generatingExportKeys: Set<String> = []
    @Published private(set) var isCreatingLocalMeeting = false
    @Published private(set) var isCancellingLocalMeeting = false
    @Published private(set) var localMeetingCreationMessage = ""

    private let fileManager = FileManager.default
    private var lastSessionsDirectoryModificationDate: Date?
    private var localMeetingProcess: Process?
    private var pendingProgressReload: DispatchWorkItem?

    init() {
        reload()
    }

    var availableLabels: [String] {
        let labels = metadata.sessions.values
            .flatMap(\.labels)
            .filter { !$0.isEmpty }
        return Array(Set(labels + metadata.globalLabels)).sorted()
    }

    var globalLabels: [String] {
        metadata.globalLabels.sorted()
    }

    var folders: [LibraryFolder] {
        metadata.folders
            .sorted {
                if $0.isTrash != $1.isTrash {
                    return !$0.isTrash
                }
                if $0.sortOrder == $1.sortOrder {
                    return $0.name < $1.name
                }
                return $0.sortOrder < $1.sortOrder
            }
    }

    var visibleFolders: [LibraryFolder] {
        folders.filter { !$0.isTrash }
    }

    var trashFolder: LibraryFolder {
        folders.first(where: \.isTrash) ?? .trash
    }

    var uncategorizedFolder: LibraryFolder {
        .uncategorized
    }

    var filteredMeetings: [MeetingRecord] {
        meetings.filter { meeting in
            let userMetadata = metadata.sessions[meeting.sessionID] ?? SessionUserMetadata()
            let matchesLabel = selectedLabels.isEmpty || !selectedLabels.isDisjoint(with: userMetadata.labels)
            let matchesFolder = matchesFolderFilter(userMetadata)
            let matchesDate = matchesDateFilter(meeting)

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !query.isEmpty else {
                return matchesLabel && matchesFolder && matchesDate
            }

            let speakerText = userMetadata.speakerLabels.values.joined(separator: " ").lowercased()
            let labelText = userMetadata.labels.joined(separator: " ").lowercased()
            let noteText = userMetadata.note.lowercased()
            return matchesLabel
                && matchesFolder
                && matchesDate
                && (
                    meeting.searchableText.contains(query)
                        || speakerText.contains(query)
                        || labelText.contains(query)
                        || noteText.contains(query)
                )
        }
    }

    var selectedMeeting: MeetingRecord? {
        if let selectedMeetingID,
           let selected = filteredMeetings.first(where: { $0.id == selectedMeetingID }) {
            return selected
        }

        return filteredMeetings.first
    }

    func reload(forceScan: Bool = false) {
        loadMetadata()
        if forceScan || shouldRescanMeetings() {
            meetings = scanMeetings()
            lastSessionsDirectoryModificationDate = sessionsDirectoryModificationDate()
        }

        if let selectedMeetingID,
           meetings.contains(where: { $0.id == selectedMeetingID }) {
            return
        }

        selectedMeetingID = meetings.first?.id
        selectedMeetingIDs = selectedMeetingID.map { [$0] } ?? []
    }

    func reloadMetadata() {
        loadMetadata()
    }

    func labels(for meeting: MeetingRecord) -> [String] {
        metadata.sessions[meeting.sessionID]?.labels ?? []
    }

    func speakerLabel(for meeting: MeetingRecord, speakerID: String) -> String {
        if let stored = metadata.sessions[meeting.sessionID]?.speakerLabels[speakerID] {
            return stored
        }

        let mapped = loadSpeakerMap(for: meeting)[speakerID] ?? ""
        return Self.isAnonymousSpeakerName(mapped, for: speakerID) ? "" : mapped
    }

    func anonymousSpeakerLabel(for speakerID: String) -> String {
        Self.anonymousSpeakerLabel(for: speakerID)
    }

    func displaySpeakerLabel(for meeting: MeetingRecord, speakerID: String) -> String {
        let override = speakerLabel(for: meeting, speakerID: speakerID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            return override
        }

        return Self.anonymousSpeakerLabel(for: speakerID)
    }

    func note(for meeting: MeetingRecord) -> String {
        metadata.sessions[meeting.sessionID]?.note ?? ""
    }

    func actualMeetingDate(for meeting: MeetingRecord) -> Date? {
        guard let rawValue = metadata.sessions[meeting.sessionID]?.actualMeetingAt,
              !rawValue.isEmpty else {
            return nil
        }

        return DateDisplay.date(fromISO8601: rawValue)
    }

    func effectiveMeetingDate(for meeting: MeetingRecord) -> Date? {
        actualMeetingDate(for: meeting) ?? meeting.createdAt
    }

    func displayMeetingDate(for meeting: MeetingRecord) -> String {
        guard let date = effectiveMeetingDate(for: meeting) else {
            return "未知"
        }

        return DateDisplay.displayFormatter.string(from: date)
    }

    func detailDraft(for meeting: MeetingRecord) -> MeetingDetailDraft {
        let speakerLabels = meeting.detectedSpeakers.reduce(into: [String: String]()) { result, speakerID in
            let label = speakerLabel(for: meeting, speakerID: speakerID)
            if !label.isEmpty {
                result[speakerID] = label
            }
        }
        return MeetingDetailDraft(
            labelsText: labels(for: meeting).joined(separator: ", "),
            note: note(for: meeting),
            actualMeetingDate: actualMeetingDate(for: meeting),
            speakerLabels: speakerLabels
        )
    }

    func saveDetailDraft(_ draft: MeetingDetailDraft, for meeting: MeetingRecord) {
        let previousMetadata = metadata.sessions[meeting.sessionID] ?? SessionUserMetadata()
        var sessionMetadata = previousMetadata
        sessionMetadata.labels = Self.parseLabels(draft.labelsText)
        sessionMetadata.note = draft.note
        sessionMetadata.actualMeetingAt = draft.actualMeetingDate.map(DateDisplay.storageString) ?? ""
        sessionMetadata.speakerLabels = draft.speakerLabels.reduce(into: [:]) { result, entry in
            let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result[entry.key] = trimmed
            }
        }
        metadata.sessions[meeting.sessionID] = sessionMetadata
        saveMetadata()

        guard previousMetadata.speakerLabels != sessionMetadata.speakerLabels else {
            return
        }

        do {
            try writeSessionSpeakerMap(
                for: meeting,
                speakerOverrides: sessionMetadata.speakerLabels
            )
            let version = sessionMetadata.speakerLabels.isEmpty ? "anonymous" : "named"
            regenerateReport(
                for: meeting,
                templateID: meeting.meetingType,
                version: version
            )
        } catch {
            lastErrorMessage = "说话人标注保存失败：\(error.localizedDescription)"
        }
    }

    func updateLabels(for meeting: MeetingRecord, rawValue: String) {
        let labels = Self.parseLabels(rawValue)

        var sessionMetadata = metadata.sessions[meeting.sessionID] ?? SessionUserMetadata()
        sessionMetadata.labels = labels
        metadata.sessions[meeting.sessionID] = sessionMetadata
        saveMetadata()
    }

    func toggleLabel(_ label: String, for meeting: MeetingRecord) {
        guard !label.isEmpty else {
            return
        }

        var labels = Set(self.labels(for: meeting))
        if labels.contains(label) {
            labels.remove(label)
        } else {
            labels.insert(label)
        }
        updateLabels(for: meeting, rawValue: labels.sorted().joined(separator: ","))
    }

    @discardableResult
    func addGlobalLabels(_ rawValue: String) -> [String] {
        let labels = Self.parseLabels(rawValue)
        guard !labels.isEmpty else {
            return []
        }

        metadata.globalLabels = Array(Set(metadata.globalLabels + labels)).sorted()
        saveMetadata()
        return labels
    }

    func addGlobalLabels(_ rawValue: String, applyingTo meeting: MeetingRecord) {
        let labels = addGlobalLabels(rawValue)
        guard !labels.isEmpty else {
            return
        }

        let merged = Array(Set(self.labels(for: meeting) + labels)).sorted()
        updateLabels(for: meeting, rawValue: merged.joined(separator: ", "))
    }

    func removeGlobalLabel(_ label: String) {
        metadata.globalLabels.removeAll { $0 == label }
        for sessionID in metadata.sessions.keys {
            metadata.sessions[sessionID]?.labels.removeAll { $0 == label }
        }
        selectedLabels.remove(label)
        saveMetadata()
    }

    func renameGlobalLabel(_ oldValue: String, to rawValue: String) {
        let newValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newValue.isEmpty, oldValue != newValue else {
            return
        }

        metadata.globalLabels = metadata.globalLabels.map { $0 == oldValue ? newValue : $0 }
        metadata.globalLabels = Array(Set(metadata.globalLabels)).sorted()
        for sessionID in metadata.sessions.keys {
            guard var sessionMetadata = metadata.sessions[sessionID] else {
                continue
            }
            sessionMetadata.labels = sessionMetadata.labels.map { $0 == oldValue ? newValue : $0 }
            sessionMetadata.labels = Array(Set(sessionMetadata.labels)).sorted()
            metadata.sessions[sessionID] = sessionMetadata
        }
        if selectedLabels.remove(oldValue) != nil {
            selectedLabels.insert(newValue)
        }
        saveMetadata()
    }

    func updateSpeakerLabel(
        for meeting: MeetingRecord,
        speakerID: String,
        value: String
    ) {
        var sessionMetadata = metadata.sessions[meeting.sessionID] ?? SessionUserMetadata()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            sessionMetadata.speakerLabels.removeValue(forKey: speakerID)
        } else {
            sessionMetadata.speakerLabels[speakerID] = trimmed
        }

        metadata.sessions[meeting.sessionID] = sessionMetadata
        saveMetadata()
    }

    func updateNote(for meeting: MeetingRecord, value: String) {
        var sessionMetadata = metadata.sessions[meeting.sessionID] ?? SessionUserMetadata()
        sessionMetadata.note = value
        metadata.sessions[meeting.sessionID] = sessionMetadata
        saveMetadata()
    }

    func updateActualMeetingDate(for meeting: MeetingRecord, date: Date?) {
        var sessionMetadata = metadata.sessions[meeting.sessionID] ?? SessionUserMetadata()
        sessionMetadata.actualMeetingAt = date.map(DateDisplay.storageString) ?? ""
        metadata.sessions[meeting.sessionID] = sessionMetadata
        saveMetadata()
    }

    func selectMeeting(sessionID: String) {
        if meetings.contains(where: { $0.sessionID == sessionID }) {
            selectedMeetingID = sessionID
            selectedMeetingIDs = [sessionID]
        }
    }

    func selectMeeting(_ meeting: MeetingRecord, modifiers: NSEvent.ModifierFlags = []) {
        if modifiers.contains(.shift) {
            selectMeetingRange(to: meeting)
        } else if modifiers.contains(.command) || modifiers.contains(.control) {
            if selectedMeetingIDs.contains(meeting.id) {
                selectedMeetingIDs.remove(meeting.id)
            } else {
                selectedMeetingIDs.insert(meeting.id)
            }
            if selectedMeetingIDs.isEmpty {
                selectedMeetingID = nil
            } else if selectedMeetingID == nil || !selectedMeetingIDs.contains(selectedMeetingID ?? "") {
                selectedMeetingID = meeting.id
            }
        } else {
            selectedMeetingID = meeting.id
            selectedMeetingIDs = [meeting.id]
        }
    }

    private func selectMeetingRange(to meeting: MeetingRecord) {
        let visibleMeetings = filteredMeetings
        guard let targetIndex = visibleMeetings.firstIndex(where: { $0.id == meeting.id }) else {
            selectedMeetingID = meeting.id
            selectedMeetingIDs = [meeting.id]
            return
        }

        let anchorID = selectedMeetingID
            ?? selectedMeetingIDs
                .compactMap { id in visibleMeetings.firstIndex(where: { $0.id == id }) }
                .min()
                .map { visibleMeetings[$0].id }

        guard let anchorID,
              let anchorIndex = visibleMeetings.firstIndex(where: { $0.id == anchorID }) else {
            selectedMeetingID = meeting.id
            selectedMeetingIDs = [meeting.id]
            return
        }

        let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        selectedMeetingIDs = Set(bounds.map { visibleMeetings[$0].id })
        selectedMeetingID = meeting.id
    }

    func ensureSelection(for meeting: MeetingRecord) {
        if !selectedMeetingIDs.contains(meeting.id) {
            selectedMeetingID = meeting.id
            selectedMeetingIDs = [meeting.id]
        }
    }

    func selectAllFilteredMeetings() {
        selectedMeetingIDs = Set(filteredMeetings.map(\.id))
        selectedMeetingID = filteredMeetings.first?.id
    }

    var dateFilterDisplayName: String {
        switch dateFilterMode {
        case .all:
            return "全部"
        case .single:
            return shortDateFormatter.string(from: dateFilterStart)
        case .range:
            let start = shortDateFormatter.string(from: min(dateFilterStart, dateFilterEnd))
            let end = shortDateFormatter.string(from: max(dateFilterStart, dateFilterEnd))
            return "\(start) - \(end)"
        }
    }

    var meetingRecordDays: Set<Date> {
        Set(
            meetings
                .compactMap(effectiveMeetingDate)
                .map { Calendar.current.startOfDay(for: $0) }
        )
    }

    func hasMeeting(on date: Date) -> Bool {
        meetingRecordDays.contains(Calendar.current.startOfDay(for: date))
    }

    func folder(for meeting: MeetingRecord) -> LibraryFolder? {
        let folderID = metadata.sessions[meeting.sessionID]?.folderID ?? ""
        return folders.first(where: { $0.id == folderID })
    }

    private func refreshHighlightedFolder() {
        guard let selectedMeetingID,
              let meeting = meetings.first(where: { $0.id == selectedMeetingID }) else {
            highlightedFolderID = nil
            return
        }

        let folderID = metadata.sessions[meeting.sessionID]?.folderID ?? ""
        highlightedFolderID = folderID.isEmpty ? uncategorizedFolder.id : folderID
    }

    func meetingCount(in folder: LibraryFolder?) -> Int {
        meetings.filter { meeting in
            let metadata = self.metadata.sessions[meeting.sessionID] ?? SessionUserMetadata()
            if let folder {
                if folder.id == LibraryFolder.uncategorized.id {
                    return metadata.folderID.isEmpty
                }
                return metadata.folderID == folder.id
            }
            return metadata.folderID.isEmpty
        }.count
    }

    func selectFolder(_ folder: LibraryFolder?, modifiers: NSEvent.ModifierFlags = []) {
        guard let folder else {
            selectedFolderID = nil
            selectedFolderIDs.removeAll()
            normalizeSelectionForCurrentFilter()
            return
        }

        if folder.id == trashFolder.id || folder.id == uncategorizedFolder.id {
            selectedFolderID = folder.id
            selectedFolderIDs.removeAll()
            normalizeSelectionForCurrentFilter()
            return
        }

        if modifiers.contains(.command) || modifiers.contains(.shift) {
            if selectedFolderIDs.contains(folder.id) {
                selectedFolderIDs.remove(folder.id)
            } else {
                selectedFolderIDs.insert(folder.id)
            }
            selectedFolderID = folder.id
        } else {
            selectedFolderID = folder.id
            selectedFolderIDs = [folder.id]
        }
        normalizeSelectionForCurrentFilter()
    }

    func createFolder(named rawName: String) {
        let name = normalizedFolderName(rawName)
        guard !name.isEmpty else {
            return
        }
        guard !metadata.folders.contains(where: { $0.name == name }) else {
            return
        }

        let nextOrder = (visibleFolders.map(\.sortOrder).max() ?? 0) + 1
        metadata.folders.append(
            LibraryFolder(
                id: UUID().uuidString,
                name: name,
                sortOrder: nextOrder,
                isTrash: false
            )
        )
        saveMetadata()
    }

    @discardableResult
    func createFolderReturningFolder(named rawName: String) -> LibraryFolder? {
        let name = normalizedFolderName(rawName)
        guard !name.isEmpty else {
            return nil
        }
        if let existing = metadata.folders.first(where: { $0.name == name && !$0.isTrash }) {
            return existing
        }

        let nextOrder = (visibleFolders.map(\.sortOrder).max() ?? 0) + 1
        let folder = LibraryFolder(
            id: UUID().uuidString,
            name: name,
            sortOrder: nextOrder,
            isTrash: false
        )
        metadata.folders.append(folder)
        saveMetadata()
        return folder
    }

    func renameFolder(_ folder: LibraryFolder, to rawName: String) {
        guard !folder.isTrash else {
            return
        }
        let name = normalizedFolderName(rawName)
        guard !name.isEmpty,
              let index = metadata.folders.firstIndex(where: { $0.id == folder.id }) else {
            return
        }

        metadata.folders[index].name = name
        saveMetadata()
    }

    func meetings(in folder: LibraryFolder) -> [MeetingRecord] {
        meetings.filter { metadata.sessions[$0.sessionID]?.folderID == folder.id }
    }

    func deleteFolder(_ folder: LibraryFolder, deletingMeetings: Bool = false) {
        guard !folder.isTrash else {
            return
        }
        let contained = meetings(in: folder)
        if deletingMeetings {
            for meeting in contained {
                try? fileManager.removeItem(at: meeting.sessionURL)
                metadata.sessions.removeValue(forKey: meeting.sessionID)
            }
        } else {
            for meeting in contained {
                var sessionMetadata = metadata.sessions[meeting.sessionID] ?? SessionUserMetadata()
                sessionMetadata.folderID = ""
                metadata.sessions[meeting.sessionID] = sessionMetadata
            }
        }
        metadata.folders.removeAll { $0.id == folder.id }
        selectedFolderIDs.remove(folder.id)
        if selectedFolderID == folder.id {
            selectedFolderID = nil
        }
        saveMetadata()
        if deletingMeetings {
            reload(forceScan: true)
        }
    }

    func moveFolder(_ folder: LibraryFolder, offset: Int) {
        guard !folder.isTrash else {
            return
        }
        var normalFolders = visibleFolders
        guard let currentIndex = normalFolders.firstIndex(where: { $0.id == folder.id }) else {
            return
        }
        let targetIndex = currentIndex + offset
        guard normalFolders.indices.contains(targetIndex) else {
            return
        }
        normalFolders.swapAt(currentIndex, targetIndex)
        for (index, updatedFolder) in normalFolders.enumerated() {
            if let metadataIndex = metadata.folders.firstIndex(where: { $0.id == updatedFolder.id }) {
                metadata.folders[metadataIndex].sortOrder = index + 1
            }
        }
        saveMetadata()
    }

    func mergeFolder(_ source: LibraryFolder, into target: LibraryFolder) {
        guard !source.isTrash, source.id != target.id else {
            return
        }
        for meeting in meetings where metadata.sessions[meeting.sessionID]?.folderID == source.id {
            var sessionMetadata = metadata.sessions[meeting.sessionID] ?? SessionUserMetadata()
            sessionMetadata.folderID = target.id
            metadata.sessions[meeting.sessionID] = sessionMetadata
        }
        metadata.folders.removeAll { $0.id == source.id }
        if selectedFolderID == source.id {
            selectedFolderID = target.id
        }
        saveMetadata()
    }

    func mergeFolders(_ sources: [LibraryFolder], into target: LibraryFolder) {
        let validSources = sources.filter { !$0.isTrash && $0.id != target.id }
        guard !target.isTrash, !validSources.isEmpty else {
            return
        }
        let sourceIDs = Set(validSources.map(\.id))
        for meeting in meetings where sourceIDs.contains(metadata.sessions[meeting.sessionID]?.folderID ?? "") {
            var sessionMetadata = metadata.sessions[meeting.sessionID] ?? SessionUserMetadata()
            sessionMetadata.folderID = target.id
            metadata.sessions[meeting.sessionID] = sessionMetadata
        }
        metadata.folders.removeAll { sourceIDs.contains($0.id) }
        selectedFolderIDs.removeAll()
        selectedFolderID = target.id
        saveMetadata()
    }

    func moveMeetings(_ meetings: [MeetingRecord], to folder: LibraryFolder?) {
        for meeting in meetings {
            var sessionMetadata = metadata.sessions[meeting.sessionID] ?? SessionUserMetadata()
            sessionMetadata.folderID = folder?.id ?? ""
            metadata.sessions[meeting.sessionID] = sessionMetadata
        }
        saveMetadata()
        normalizeSelectionForCurrentFilter()
    }

    func moveSelectedMeetings(to folder: LibraryFolder?) {
        let selected = meetings.filter { selectedMeetingIDs.contains($0.id) }
        moveMeetings(selected, to: folder)
    }

    func moveMeetingsToTrash(_ meetings: [MeetingRecord]) {
        moveMeetings(meetings, to: trashFolder)
    }

    func moveSelectedMeetingsToTrash() {
        let selected = meetings.filter { selectedMeetingIDs.contains($0.id) }
        moveMeetingsToTrash(selected)
    }

    func emptyTrash() {
        permanentlyDelete(meetings.filter {
            metadata.sessions[$0.sessionID]?.folderID == trashFolder.id
        })
    }

    func permanentlyDelete(_ meetingsToDelete: [MeetingRecord]) {
        for meeting in meetingsToDelete {
            try? fileManager.removeItem(at: meeting.sessionURL)
            metadata.sessions.removeValue(forKey: meeting.sessionID)
        }
        saveMetadata()
        reload(forceScan: true)
    }

    func transcriptSegments(for meeting: MeetingRecord) -> [TranscriptSegment] {
        guard let transcriptSegmentsURL = meeting.transcriptSegmentsURL,
              let data = try? Data(contentsOf: transcriptSegmentsURL),
              let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: data) else {
            return []
        }
        return segments
    }

    func saveTranscriptSegments(_ segments: [TranscriptSegment], for meeting: MeetingRecord) {
        guard let transcriptSegmentsURL = meeting.transcriptSegmentsURL else {
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(segments)
            try data.write(to: transcriptSegmentsURL, options: .atomic)
            if let transcriptURL = meeting.transcriptURL {
                let markdown = renderTranscriptMarkdown(
                    segments: segments,
                    speakerMap: loadSpeakerMap(for: meeting),
                    named: transcriptURL.lastPathComponent.contains("named")
                )
                try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
            }
            reload(forceScan: true)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "转录稿保存失败：\(error.localizedDescription)"
        }
    }

    func regenerateReport(
        for meeting: MeetingRecord,
        templateID: String,
        version: String = "auto"
    ) {
        guard !regeneratingSessionIDs.contains(meeting.sessionID) else {
            return
        }

        let python = AppPaths.projectRoot.appendingPathComponent(".venv/bin/python")
        let script = AppPaths.projectRoot.appendingPathComponent("scripts/regenerate_session.py")
        guard AppPaths.exists(python), AppPaths.exists(script) else {
            reportRegenerationErrors[meeting.sessionID] = "缺少重生成所需的 Python 环境或脚本"
            return
        }

        regeneratingSessionIDs.insert(meeting.sessionID)
        let speakerMapURL = writeSpeakerOverridesFile(for: meeting)
        var arguments = [
            script.path,
            "--session",
            meeting.sessionURL.path,
            "--template",
            templateID,
            "--version",
            version,
        ]
        if let speakerMapURL {
            arguments.append(contentsOf: ["--speaker-map-file", speakerMapURL.path])
        }
        if let formats = decodeLocalMeetingRequest(in: meeting.sessionURL)?.formats,
           !formats.isEmpty {
            arguments.append(contentsOf: ["--formats", formats.sorted().joined(separator: ",")])
        }
        let process = Process()
        process.executableURL = python
        process.arguments = arguments
        process.currentDirectoryURL = AppPaths.projectRoot
        process.environment = AppPaths.runtimeEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [weak self] process in
            if let speakerMapURL {
                try? FileManager.default.removeItem(at: speakerMapURL)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.regeneratingSessionIDs.remove(meeting.sessionID)
                if process.terminationStatus == 0 {
                    self.reload(forceScan: true)
                    self.selectMeeting(sessionID: meeting.sessionID)
                    self.reportRegenerationErrors.removeValue(forKey: meeting.sessionID)
                } else {
                    self.reportRegenerationErrors[meeting.sessionID] =
                        self.compactProcessError(
                            stdout: "",
                            stderr: output,
                            fallback: "重生成纪要失败"
                        )
                }
            }
        }

        do {
            try process.run()
        } catch {
            regeneratingSessionIDs.remove(meeting.sessionID)
            reportRegenerationErrors[meeting.sessionID] = "无法启动重生成任务：\(error.localizedDescription)"
        }
    }

    func reportRegenerationError(for meeting: MeetingRecord) -> String? {
        reportRegenerationErrors[meeting.sessionID]
    }

    func isGeneratingExport(for meeting: MeetingRecord, format: String) -> Bool {
        generatingExportKeys.contains(exportGenerationKey(meeting: meeting, format: format))
    }

    func generateExport(for meeting: MeetingRecord, format: String) {
        let normalizedFormat = format.lowercased()
        guard ["html", "docx", "md", "pdf"].contains(normalizedFormat) else {
            return
        }

        let key = exportGenerationKey(meeting: meeting, format: normalizedFormat)
        guard !generatingExportKeys.contains(key) else {
            return
        }

        let python = AppPaths.projectRoot.appendingPathComponent(".venv/bin/python")
        let script = AppPaths.projectRoot.appendingPathComponent("scripts/export_session_file.py")
        guard AppPaths.exists(python), AppPaths.exists(script) else {
            reportRegenerationErrors[meeting.sessionID] = "缺少生成导出文件所需的 Python 环境或脚本"
            return
        }

        generatingExportKeys.insert(key)
        reportRegenerationErrors.removeValue(forKey: meeting.sessionID)

        let process = Process()
        process.executableURL = python
        process.arguments = [
            script.path,
            "--session",
            meeting.sessionURL.path,
            "--formats",
            normalizedFormat,
        ]
        process.currentDirectoryURL = AppPaths.projectRoot
        process.environment = AppPaths.runtimeEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [weak self] process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.generatingExportKeys.remove(key)
                if process.terminationStatus == 0 {
                    self.reload(forceScan: true)
                    self.selectMeeting(sessionID: meeting.sessionID)
                    self.reportRegenerationErrors.removeValue(forKey: meeting.sessionID)
                } else {
                    self.reportRegenerationErrors[meeting.sessionID] = self.compactProcessError(
                        stdout: "",
                        stderr: output,
                        fallback: "生成导出文件失败"
                    )
                }
            }
        }

        do {
            try process.run()
        } catch {
            generatingExportKeys.remove(key)
            reportRegenerationErrors[meeting.sessionID] = "无法启动导出任务：\(error.localizedDescription)"
        }
    }

    private func exportGenerationKey(meeting: MeetingRecord, format: String) -> String {
        "\(meeting.sessionID):\(format.lowercased())"
    }

    func hasNamedSpeakers(for meeting: MeetingRecord) -> Bool {
        meeting.detectedSpeakers.contains { speakerID in
            !speakerLabel(for: meeting, speakerID: speakerID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }

    private func writeSpeakerOverridesFile(for meeting: MeetingRecord) -> URL? {
        let overrides = meeting.detectedSpeakers.reduce(into: [String: String]()) { result, speakerID in
            let name = speakerLabel(for: meeting, speakerID: speakerID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                result[speakerID] = name
            }
        }
        guard !overrides.isEmpty else {
            return nil
        }

        let url = fileManager.temporaryDirectory
            .appendingPathComponent("speaker_overrides_\(UUID().uuidString).json")
        do {
            let data = try JSONSerialization.data(withJSONObject: overrides)
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func writeSessionSpeakerMap(
        for meeting: MeetingRecord,
        speakerOverrides: [String: String]
    ) throws {
        let existingMap = loadSpeakerMap(for: meeting)
        let segmentSpeakerIDs = transcriptSegments(for: meeting).map(\.speaker)
        let speakerIDs = Set(existingMap.keys + meeting.detectedSpeakers + segmentSpeakerIDs)

        let updatedMap = speakerIDs.reduce(into: [String: String]()) { result, speakerID in
            let override = speakerOverrides[speakerID]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result[speakerID] = override.isEmpty
                ? Self.anonymousSpeakerLabel(for: speakerID)
                : override
        }

        let data = try JSONSerialization.data(
            withJSONObject: updatedMap,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: meeting.sessionURL.appendingPathComponent("speaker_map.json"),
            options: .atomic
        )
    }

    /// 把"有录音但还没转录稿"的中断/失败草稿，**在原会话目录里原地重跑**整条流水线：
    /// 复用目录中保存的原始录音重新转写、分离、生成纪要。会话目录与 session_id 不变，
    /// 这条草稿直接从"中断"变回"处理中"，不产生第二条草稿、不复制/移动录音，零丢失风险。
    func reprocessLocalMeeting(_ meeting: MeetingRecord) {
        guard !isCreatingLocalMeeting else {
            return
        }
        guard let audioURL = meeting.audioURL, AppPaths.exists(audioURL) else {
            localMeetingCreationError = "草稿缺少可重新处理的录音文件"
            return
        }

        let templateID = meeting.requestedTemplateID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let request = LocalMeetingCreationRequest(
            title: meeting.title,
            audioURL: audioURL,
            transcriptURL: nil,
            templateID: templateID.isEmpty ? "auto" : templateID,
            exportFormats: Set(
                decodeLocalMeetingRequest(in: meeting.sessionURL)?.formats ?? ["html", "docx"]
            )
        )
        createLocalMeeting(request: request, reuseSessionURL: meeting.sessionURL)
    }

    func createLocalMeeting(
        request: LocalMeetingCreationRequest,
        reuseSessionURL: URL? = nil,
        completion: @escaping (LocalMeetingCreationResult?) -> Void = { _ in }
    ) {
        guard !isCreatingLocalMeeting else {
            return
        }

        let python = AppPaths.projectRoot.appendingPathComponent(".venv/bin/python")
        let script = AppPaths.projectRoot.appendingPathComponent("scripts/create_local_meeting.py")
        guard AppPaths.exists(python), AppPaths.exists(script) else {
            localMeetingCreationError = "缺少新增会议所需的 Python 环境或脚本"
            completion(nil)
            return
        }
        guard request.audioURL != nil || request.transcriptURL != nil else {
            localMeetingCreationError = "请至少选择一份录音或转录稿"
            completion(nil)
            return
        }

        var arguments = [
            script.path,
            "--title",
            request.title,
            "--template",
            request.templateID,
            "--formats",
            request.exportFormats.sorted().joined(separator: ","),
        ]
        if let reuseSessionURL {
            arguments.append(contentsOf: ["--session", reuseSessionURL.path])
        }
        if let audioURL = request.audioURL {
            arguments.append(contentsOf: ["--audio", audioURL.path])
        }
        if let transcriptURL = request.transcriptURL {
            arguments.append(contentsOf: ["--transcript", transcriptURL.path])
        }

        isCreatingLocalMeeting = true
        isCancellingLocalMeeting = false
        localMeetingCreationMessage = "正在准备新增会议"
        localMeetingCreationError = nil

        let process = Process()
        process.executableURL = python
        process.arguments = arguments
        process.currentDirectoryURL = AppPaths.projectRoot
        process.environment = AppPaths.runtimeEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdoutText = ""
        var stderrText = ""
        var pendingLine = ""

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else {
                return
            }
            DispatchQueue.main.async {
                stdoutText += chunk
                pendingLine += chunk
                let segments = pendingLine.components(separatedBy: "\n")
                pendingLine = segments.last ?? ""
                for line in segments.dropLast() {
                    self?.handleLocalMeetingProgressLine(line)
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else {
                return
            }
            DispatchQueue.main.async {
                stderrText += chunk
            }
        }

        process.terminationHandler = { [weak self] process in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                if let chunk = String(data: remainingOut, encoding: .utf8) {
                    stdoutText += chunk
                }
                if let chunk = String(data: remainingErr, encoding: .utf8) {
                    stderrText += chunk
                }
                self.isCreatingLocalMeeting = false
                self.localMeetingProcess = nil

                let trimmedStdout = stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedStderr = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                if self.isCancellingLocalMeeting {
                    self.isCancellingLocalMeeting = false
                    self.localMeetingCreationMessage = "处理已暂停，可在会议库中继续"
                    self.localMeetingCreationError = nil
                    self.writeIdleRuntimeStatus()
                    // 暂停保留会话及阶段产物，刷新会议库展示继续入口。
                    self.reload(forceScan: true)
                    completion(nil)
                } else if process.terminationStatus == 0,
                   let result = self.decodeLocalMeetingCreationResult(from: trimmedStdout) {
                    self.localMeetingCreationMessage = "会议已创建"
                    self.reload(forceScan: true)
                    self.selectMeeting(sessionID: result.sessionID)
                    self.localMeetingCreationError = nil
                    completion(result)
                } else {
                    self.localMeetingCreationMessage = ""
                    self.localMeetingCreationError = self.compactProcessError(
                        stdout: trimmedStdout,
                        stderr: trimmedStderr,
                        fallback: "新增会议失败"
                    )
                    // 非中止失败：会话目录作为草稿保留，刷新并选中它以露出「重试生成纪要」。
                    self.reload(forceScan: true)
                    if let sessionID = self.currentRuntimeStatusPayload()?["session_id"] as? String,
                       !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.selectMeeting(sessionID: sessionID)
                    }
                    completion(nil)
                }
            }
        }

        do {
            try process.run()
            localMeetingProcess = process
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            isCreatingLocalMeeting = false
            isCancellingLocalMeeting = false
            localMeetingProcess = nil
            localMeetingCreationMessage = ""
            localMeetingCreationError = "无法启动新增会议任务：\(error.localizedDescription)"
            completion(nil)
        }
    }

    func cancelLocalMeetingCreation() {
        guard isCreatingLocalMeeting,
              let process = localMeetingProcess,
              process.isRunning else {
            return
        }

        isCancellingLocalMeeting = true
        localMeetingCreationMessage = "正在暂停处理"

        // create_local_meeting.py 已通过 setsid 自成进程组；
        // 整组发信号可同时结束 ffmpeg、LLM、LibreOffice 等子进程。
        let pid = process.processIdentifier
        if kill(-pid, SIGTERM) != 0 {
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning {
                _ = kill(-pid, SIGKILL)
                _ = kill(pid, SIGKILL)
            }
        }
    }

    private func handleLocalMeetingProgressLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let progress = object["progress"] as? [String: Any] else {
            return
        }
        if let message = progress["message"] as? String, !message.isEmpty {
            localMeetingCreationMessage = message
        }
        // 后端在会话目录创建后会带上 session_id：刷新库以展示草稿会议，
        // 并在新增过程中跟随选中该草稿，让用户看到实时处理阶段。
        if let sessionID = progress["session_id"] as? String,
           !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleProgressReload(selecting: sessionID)
            if isCreatingLocalMeeting || selectedMeetingID == nil || selectedMeetingID == sessionID {
                selectMeeting(sessionID: sessionID)
            }
        }
    }

    private func scheduleProgressReload(selecting sessionID: String) {
        pendingProgressReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reload(forceScan: true)
            if self.isCreatingLocalMeeting || self.selectedMeetingID == nil || self.selectedMeetingID == sessionID {
                self.selectMeeting(sessionID: sessionID)
            }
        }
        pendingProgressReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func currentRuntimeStatusPayload() -> [String: Any]? {
        let statusURL = AppPaths.projectRoot.appendingPathComponent("runtime/status.json")
        guard let data = try? Data(contentsOf: statusURL),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload
    }

    /// 通过非阻塞抢 `runtime/local_meeting.lock` 判断是否真的有新增会议进程在运行：
    /// 成功抢到说明当前无人持锁（随即释放）；`EWOULDBLOCK` 说明确有进程持锁。
    /// 进程崩溃/被杀时 OS 会自动释放 flock，因此"锁空闲"是判定陈旧 processing 草稿的可靠信号。
    private func isLocalMeetingProcessActive() -> Bool {
        let lockURL = AppPaths.projectRoot.appendingPathComponent("runtime/local_meeting.lock")
        guard AppPaths.exists(lockURL) else {
            return false
        }
        let fd = open(lockURL.path, O_RDONLY)
        guard fd >= 0 else {
            return false
        }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    private func writeIdleRuntimeStatus() {
        if let payload = currentRuntimeStatusPayload(),
           (payload["source"] as? String) == "feishu_bot",
           (payload["task_status"] as? String) == "processing" {
            // 飞书机器人正在处理自己的任务，不要覆盖它的状态。
            return
        }

        let statusURL = AppPaths.projectRoot.appendingPathComponent("runtime/status.json")
        let payload: [String: String] = [
            "service_status": "running",
            "task_status": "idle",
            "stage": "idle",
            "message": "机器人后台服务运行中",
            "session_id": "",
            "session_dir": "",
            "latest_pdf": "",
            "latest_docx": "",
            "latest_html": "",
            "latest_md": "",
            "updated_at": DateDisplay.storageString(from: Date()),
            "source": "menu_bar_app",
        ]

        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: statusURL, options: .atomic)
        } catch {
            lastErrorMessage = "处理已暂停，但状态栏重置失败：\(error.localizedDescription)"
        }
    }

    func relatedMeetingsByTopic(for meeting: MeetingRecord) -> [MeetingRecord] {
        guard !meeting.topics.isEmpty || !labels(for: meeting).isEmpty else {
            return []
        }

        return meetings
            .compactMap { candidate -> (MeetingRecord, Int)? in
                guard candidate.id != meeting.id else {
                    return nil
                }
                guard metadata.sessions[candidate.sessionID]?.folderID != trashFolder.id else {
                    return nil
                }

                let score = topicSimilarityScore(between: meeting, and: candidate)
                return score > 0 ? (candidate, score) : nil
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return (lhs.0.createdAt ?? .distantPast) > (rhs.0.createdAt ?? .distantPast)
                }
                return lhs.1 > rhs.1
            }
            .map(\.0)
    }

    func relatedMeetingsBySpeaker(for meeting: MeetingRecord) -> [MeetingRecord] {
        let currentNames = Set(
            (metadata.sessions[meeting.sessionID]?.speakerLabels.values.map { $0 } ?? [])
                .map(normalizeKey)
                .filter { !$0.isEmpty }
        )
        guard !currentNames.isEmpty else {
            return []
        }

        return meetings.filter { candidate in
            guard candidate.id != meeting.id else {
                return false
            }
            guard metadata.sessions[candidate.sessionID]?.folderID != trashFolder.id else {
                return false
            }

            let names = Set(
                (metadata.sessions[candidate.sessionID]?.speakerLabels.values.map { $0 } ?? [])
                    .map(normalizeKey)
                    .filter { !$0.isEmpty }
            )
            return !currentNames.isDisjoint(with: names)
        }
    }

    private func loadMetadata() {
        guard AppPaths.exists(AppPaths.libraryMetadataFile) else {
            metadata = LibraryMetadataDocument()
            return
        }

        do {
            let data = try Data(contentsOf: AppPaths.libraryMetadataFile)
            metadata = try JSONDecoder().decode(LibraryMetadataDocument.self, from: data)
            lastErrorMessage = nil
        } catch {
            metadata = LibraryMetadataDocument()
            lastErrorMessage = "会议库元数据读取失败：\(error.localizedDescription)"
        }
    }

    private func saveMetadata() {
        do {
            try fileManager.createDirectory(
                at: AppPaths.libraryDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: AppPaths.libraryMetadataFile, options: .atomic)
            lastErrorMessage = nil
            refreshHighlightedFolder()
        } catch {
            lastErrorMessage = "会议库元数据保存失败：\(error.localizedDescription)"
        }
    }

    private func scanMeetings() -> [MeetingRecord] {
        guard AppPaths.exists(AppPaths.sessionsDirectory) else {
            return []
        }

        do {
            let sessionURLs = try fileManager.contentsOfDirectory(
                at: AppPaths.sessionsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }

            // 整次扫描只探测一次锁状态：用于识别陈旧 processing 草稿（进程已退出但状态未落定）。
            let localMeetingProcessActive = isLocalMeetingProcessActive()
            return sessionURLs
                .compactMap { loadMeetingRecord(from: $0, localMeetingProcessActive: localMeetingProcessActive) }
                .sorted { lhs, rhs in
                    let lhsDate = lhs.createdAt ?? .distantPast
                    let rhsDate = rhs.createdAt ?? .distantPast
                    if lhsDate == rhsDate {
                        return lhs.sessionID > rhs.sessionID
                    }
                    return lhsDate > rhsDate
                }
        } catch {
            lastErrorMessage = "会议目录读取失败：\(error.localizedDescription)"
            return []
        }
    }

    private func shouldRescanMeetings() -> Bool {
        guard !meetings.isEmpty else {
            return true
        }

        return sessionsDirectoryModificationDate() != lastSessionsDirectoryModificationDate
    }

    private func sessionsDirectoryModificationDate() -> Date? {
        guard AppPaths.exists(AppPaths.sessionsDirectory) else {
            return nil
        }

        return try? AppPaths.sessionsDirectory
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    private func loadMeetingRecord(from sessionURL: URL, localMeetingProcessActive: Bool) -> MeetingRecord? {
        let sessionID = sessionURL.lastPathComponent
        let sessionFiles = (try? fileManager.contentsOfDirectory(
            at: sessionURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let state = decodeLocalMeetingState(in: sessionURL)
        let request = decodeLocalMeetingRequest(in: sessionURL)
        let isIncompleteLocalMeeting = (state != nil || request != nil)
            && state?.taskStatus != "done"
        let reportURL = preferredFile(
            in: sessionURL,
            matching: ["report_named.json", "report_anon.json"]
        )

        let transcriptURL = preferredFile(
            in: sessionURL,
            matching: ["transcript_named.md", "transcript_anon.md"]
        )
        let transcript = transcriptURL
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let speakerMapURL = sessionURL.appendingPathComponent("speaker_map.json")
        let detectedSpeakers = loadSpeakerIDs(from: speakerMapURL)
        let transcriptSegmentsURL = preferredFile(
            in: sessionURL,
            matching: ["transcript_with_speaker_raw.json"]
        )
        let audioURL = preferredAudioFile(in: sessionFiles)

        if !isIncompleteLocalMeeting,
           let reportURL,
           let report = decodeReport(at: reportURL) {
            return MeetingRecord(
                id: sessionID,
                sessionID: sessionID,
                sessionURL: sessionURL,
                title: report.reportTitle ?? sessionID,
                meetingType: report.meetingType ?? "unknown",
                version: report.version ?? "anonymous",
                takeaway: report.oneSentenceTakeaway ?? "",
                summary: report.executiveSummary ?? "",
                topics: (report.discussionTopics ?? [])
                    .compactMap(\.title)
                    .filter { !$0.isEmpty },
                transcript: transcript,
                detectedSpeakers: detectedSpeakers,
                createdAt: DateDisplay.sessionDate(from: sessionID),
                latestPDFURL: latestFile(in: sessionFiles, pathExtension: "pdf"),
                latestDOCXURL: latestFile(in: sessionFiles, pathExtension: "docx"),
                latestHTMLURL: latestFile(in: sessionFiles, pathExtension: "html"),
                latestMDURL: latestMarkdownSummary(in: sessionFiles),
                transcriptURL: transcriptURL,
                transcriptSegmentsURL: transcriptSegmentsURL,
                audioURL: audioURL,
                isTemporary: false,
                processingStage: "",
                processingMessage: "",
                processingErrorDetail: "",
                canRetryReport: false,
                canReprocessFromAudio: false,
                requestedTemplateID: nil
            )
        }

        // 没有完整 report：尝试作为「草稿会议」识别（处理中或纪要生成失败）。
        guard state != nil || request != nil || transcriptURL != nil else {
            return nil
        }

        let requestedTitle = request?.title?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceName = (try? String(
            contentsOf: sessionURL.appendingPathComponent("source_name.txt"),
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceMetadata = decodeJSONObject(at: sessionURL.appendingPathComponent("source_metadata.json"))
        let metadataSourceName = (sourceMetadata["source_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let classification = decodeJSONObject(at: sessionURL.appendingPathComponent("classification.json"))
        let classifiedTemplate = (classification["template"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawTaskStatus = state?.taskStatus
        // 进程已退出（锁空闲）但状态仍停在 processing → 视为陈旧（崩溃/被杀），可重试/重处理。
        let isStaleProcessing = rawTaskStatus == "processing" && !localMeetingProcessActive
        let isError = rawTaskStatus == "error"
        let isPaused = rawTaskStatus == "paused"
        let isNotRunning = isError || isPaused || rawTaskStatus == nil || isStaleProcessing
        let stage = state?.stage ?? "pending"
        let baseMessage = state?.message
            ?? (transcriptURL == nil ? "正在准备会议材料" : "转录稿已生成，等待生成纪要")
        // 失败时只显示简短摘要，完整报错放进可点开的详情；陈旧中断给中性提示。
        let errorDetail = isError ? baseMessage : ""
        let displayMessage: String
        if isError {
            displayMessage = "新增会议失败"
        } else if isPaused {
            displayMessage = "处理已暂停，可继续执行"
        } else if isStaleProcessing {
            displayMessage = "处理似乎已中断"
        } else {
            displayMessage = baseMessage
        }
        let requestedTemplate = request?.template ?? ""
        let effectiveTemplateID = requestedTemplate == "auto" || requestedTemplate.isEmpty
            ? (classifiedTemplate.isEmpty ? "general_meeting" : classifiedTemplate)
            : requestedTemplate
        // 有转录稿 → 可只重试"生成纪要"；无转录稿但有录音 → 需从头重跑整条流水线。
        let canRetry = transcriptURL != nil && isNotRunning
        let canReprocess = transcriptURL == nil && audioURL != nil && isNotRunning

        return MeetingRecord(
            id: sessionID,
            sessionID: sessionID,
            sessionURL: sessionURL,
            title: requestedTitle.isEmpty
                ? (metadataSourceName.isEmpty ? (sourceName.isEmpty ? sessionID : sourceName) : metadataSourceName)
                : requestedTitle,
            meetingType: requestedTemplate == "auto" && classifiedTemplate.isEmpty ? "unknown" : effectiveTemplateID,
            version: "draft",
            takeaway: "",
            summary: "",
            topics: [],
            transcript: transcript,
            detectedSpeakers: detectedSpeakers,
            createdAt: DateDisplay.sessionDate(from: sessionID),
            latestPDFURL: latestFile(in: sessionFiles, pathExtension: "pdf"),
            latestDOCXURL: latestFile(in: sessionFiles, pathExtension: "docx"),
            latestHTMLURL: latestFile(in: sessionFiles, pathExtension: "html"),
            latestMDURL: latestMarkdownSummary(in: sessionFiles),
            transcriptURL: transcriptURL,
            transcriptSegmentsURL: transcriptSegmentsURL,
            audioURL: audioURL,
            isTemporary: true,
            processingStage: stage,
            processingMessage: displayMessage,
            processingErrorDetail: errorDetail,
            canRetryReport: canRetry,
            canReprocessFromAudio: canReprocess,
            requestedTemplateID: effectiveTemplateID
        )
    }

    private func decodeLocalMeetingState(in sessionURL: URL) -> LocalMeetingStateSnapshot? {
        decodeJSON(LocalMeetingStateSnapshot.self, at: sessionURL.appendingPathComponent("local_meeting_state.json"))
    }

    private func decodeLocalMeetingRequest(in sessionURL: URL) -> LocalMeetingRequestSnapshot? {
        decodeJSON(LocalMeetingRequestSnapshot.self, at: sessionURL.appendingPathComponent("local_meeting_request.json"))
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func decodeJSONObject(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func decodeReport(at url: URL) -> MeetingReportSnapshot? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(MeetingReportSnapshot.self, from: data)
    }

    private func preferredFile(in directory: URL, matching names: [String]) -> URL? {
        for name in names {
            let candidate = directory.appendingPathComponent(name)
            if AppPaths.exists(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func latestFile(in files: [URL], pathExtension: String) -> URL? {
        return files
            .filter { $0.pathExtension.lowercased() == pathExtension }
            .sorted(by: isNewerFile)
            .first
    }

    private func latestMarkdownSummary(in files: [URL]) -> URL? {
        return files
            .filter {
                $0.pathExtension.lowercased() == "md"
                    && isGeneratedSummaryMarkdown($0)
            }
            .sorted(by: isNewerFile)
            .first
    }

    private func isGeneratedSummaryMarkdown(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        return name.contains("匿名版") || name.contains("实名版")
    }

    private func preferredAudioFile(in files: [URL]) -> URL? {
        return files
            .filter {
                ["m4a", "mp3", "wav", "aac", "flac", "ogg", "opus", "mp4", "mov", "webm"]
                    .contains($0.pathExtension.lowercased())
                    && $0.lastPathComponent != "analysis_audio_16k_mono.wav"
            }
            .sorted(by: isNewerFile)
            .first
    }

    private func loadSpeakerIDs(from url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return []
        }

        return raw.keys
            .filter(Self.isDisplayableSpeakerID)
            .sorted()
    }

    private static func isDisplayableSpeakerID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "TEXT" else {
            return false
        }
        let reserved = ["生成时间", "报告版本", "会议类型", "使用说明", "核心判断", "重要性"]
        let normalized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "*- "))
        guard !reserved.contains(normalized) else {
            return false
        }
        return !trimmed.hasPrefix("#")
            && !trimmed.hasPrefix("-")
            && !trimmed.hasPrefix("*")
            && !trimmed.hasPrefix("|")
    }

    private func compactProcessError(
        stdout: String,
        stderr: String,
        fallback: String
    ) -> String {
        let combined = [stderr, stdout]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let lines = combined
            .split(separator: "\n")
            .map(String.init)
            .filter {
                !$0.contains("Class AVFFrameReceiver is implemented in both")
                    && !$0.contains("Class AVFAudioReceiver is implemented in both")
            }
        if lines.contains(where: { $0.contains("No such file or directory: 'ffmpeg'") }) {
            return "新增会议失败：未找到 ffmpeg，请在设置中确认 ffmpeg 路径。"
        }
        return lines.last ?? fallback
    }

    private func isNewerFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap(\.contentModificationDate) ?? .distantPast
        let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap(\.contentModificationDate) ?? .distantPast
        if lhsDate == rhsDate {
            return lhs.lastPathComponent > rhs.lastPathComponent
        }
        return lhsDate > rhsDate
    }

    private func normalizeKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func parseLabels(_ rawValue: String) -> [String] {
        let labels = rawValue
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(labels)).sorted()
    }

    private func matchesDateFilter(_ meeting: MeetingRecord) -> Bool {
        guard dateFilterMode != .all else {
            return true
        }
        guard let meetingDate = effectiveMeetingDate(for: meeting) else {
            return false
        }

        switch dateFilterMode {
        case .all:
            return true
        case .single:
            return Calendar.current.isDate(meetingDate, inSameDayAs: dateFilterStart)
        case .range:
            let start = Calendar.current.startOfDay(for: min(dateFilterStart, dateFilterEnd))
            let end = Calendar.current.date(
                byAdding: .day,
                value: 1,
                to: Calendar.current.startOfDay(for: max(dateFilterStart, dateFilterEnd))
            ) ?? max(dateFilterStart, dateFilterEnd)
            return meetingDate >= start && meetingDate < end
        }
    }

    private func matchesFolderFilter(_ metadata: SessionUserMetadata) -> Bool {
        guard let selectedFolderID else {
            return metadata.folderID != trashFolder.id
        }
        if selectedFolderID == uncategorizedFolder.id {
            return metadata.folderID.isEmpty
        }
        return metadata.folderID == selectedFolderID
    }

    private func normalizeSelectionForCurrentFilter() {
        let visibleIDs = Set(filteredMeetings.map(\.id))
        selectedMeetingIDs = selectedMeetingIDs.intersection(visibleIDs)

        if let selectedMeetingID, visibleIDs.contains(selectedMeetingID) {
            return
        }

        self.selectedMeetingID = filteredMeetings.first?.id
        if let selectedMeetingID {
            selectedMeetingIDs = [selectedMeetingID]
        }
    }

    private func loadSpeakerMap(for meeting: MeetingRecord) -> [String: String] {
        let speakerMapURL = meeting.sessionURL.appendingPathComponent("speaker_map.json")
        guard let data = try? Data(contentsOf: speakerMapURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return raw
    }

    private static func anonymousSpeakerLabel(for speakerID: String) -> String {
        let normalized = speakerID.uppercased()
        if normalized == "UNKNOWN" {
            return "未知说话人"
        }
        if normalized == "TEXT" {
            return "转录文本"
        }

        let pattern = #"^SPEAKER[_\s-]?(\d+)$"#
        if let expression = try? NSRegularExpression(pattern: pattern),
           let match = expression.firstMatch(
               in: speakerID,
               range: NSRange(speakerID.startIndex..., in: speakerID)
           ),
           let numberRange = Range(match.range(at: 1), in: speakerID),
           let number = Int(speakerID[numberRange]) {
            return "说话人\(number + 1)"
        }

        return speakerID
    }

    private static func isAnonymousSpeakerName(_ name: String, for speakerID: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty
            || normalized == speakerID
            || normalized == anonymousSpeakerLabel(for: speakerID)
            || (speakerID.uppercased() == "UNKNOWN" && normalized == "说话人未知")
    }

    private func renderTranscriptMarkdown(
        segments: [TranscriptSegment],
        speakerMap: [String: String],
        named: Bool
    ) -> String {
        let title = named ? "完整转录稿（已标注说话人身份）" : "完整转录稿（匿名说话人版）"
        var lines = ["# \(title)", ""]
        for segment in segments {
            let speaker = speakerMap[segment.speaker] ?? segment.speaker
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }
            lines.append(
                "- [\(timestamp(segment.start)) - \(timestamp(segment.end))] \(speaker)：\(text)"
            )
        }
        return lines.joined(separator: "\n")
    }

    private func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    private func normalizedFolderName(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeLocalMeetingCreationResult(from output: String) -> LocalMeetingCreationResult? {
        guard let line = output
            .split(separator: "\n")
            .last(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") }),
              let data = String(line).data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(LocalMeetingCreationResult.self, from: data)
    }

    private let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func topicSimilarityScore(
        between lhs: MeetingRecord,
        and rhs: MeetingRecord
    ) -> Int {
        let lhsTopics = lhs.topics.map(normalizeTopic)
        let rhsTopics = rhs.topics.map(normalizeTopic)
        var score = 0

        for left in lhsTopics where !left.isEmpty {
            for right in rhsTopics where !right.isEmpty {
                if left == right {
                    score = max(score, 6)
                } else if left.contains(right) || right.contains(left) {
                    score = max(score, 4)
                } else if bigramSimilarity(left, right) >= 0.45 {
                    score = max(score, 2)
                }
            }
        }

        let lhsLabels = Set(labels(for: lhs).map(normalizeKey))
        let rhsLabels = Set(labels(for: rhs).map(normalizeKey))
        if !lhsLabels.isDisjoint(with: rhsLabels) {
            score += 3
        }

        return score
    }

    private func normalizeTopic(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func bigramSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsBigrams = characterBigrams(for: lhs)
        let rhsBigrams = characterBigrams(for: rhs)
        guard !lhsBigrams.isEmpty, !rhsBigrams.isEmpty else {
            return 0
        }

        let union = lhsBigrams.union(rhsBigrams)
        guard !union.isEmpty else {
            return 0
        }

        return Double(lhsBigrams.intersection(rhsBigrams).count) / Double(union.count)
    }

    private func characterBigrams(for value: String) -> Set<String> {
        let characters = Array(value)
        guard characters.count >= 2 else {
            return value.isEmpty ? [] : [value]
        }

        return Set(
            zip(characters, characters.dropFirst())
                .map { String([$0, $1]) }
        )
    }
}
