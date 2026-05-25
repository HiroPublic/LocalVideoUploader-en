import Foundation
import SQLite3

@MainActor
final class VideoDraft: ObservableObject, Identifiable {
    let id: UUID
    @Published var filePath: String
    @Published var captureDate: Date
    @Published var content: String
    @Published var customTitle: String
    @Published var customDescription: String
    @Published var place: String
    @Published var eventName: String
    @Published var participantsText: String
    @Published var cameraModel: String
    @Published var playlistsText: String
    @Published var note: String

    init(
        id: UUID = UUID(),
        filePath: String,
        captureDate: Date,
        content: String = "",
        customTitle: String = "",
        customDescription: String = "",
        place: String = "",
        eventName: String = "",
        participantsText: String = "",
        cameraModel: String = "",
        playlistsText: String = "",
        note: String = ""
    ) {
        self.id = id
        self.filePath = filePath
        self.captureDate = captureDate
        self.content = content
        self.customTitle = customTitle
        self.customDescription = customDescription
        self.place = place
        self.eventName = eventName
        self.participantsText = participantsText
        self.cameraModel = cameraModel
        self.playlistsText = playlistsText
        self.note = note
    }
}

struct ChannelStatus: Equatable {
    var status: String
    var channelID: String
    var channelTitle: String
    var channelHandle: String
    var tokenFile: String
    var credentialsFile: String
    var youtubeAPIQuota: YouTubeAPIQuotaStatus

    static let unknown = ChannelStatus(
        status: "unknown",
        channelID: "",
        channelTitle: "",
        channelHandle: "",
        tokenFile: "",
        credentialsFile: "",
        youtubeAPIQuota: .unknown
    )
}

struct YouTubeAPIQuotaStatus: Equatable {
    var date: String
    var used: Int
    var limit: Int
    var remaining: Int
    var usageRatio: Double
    var isEstimated: Bool
    var windowStartText: String
    var windowEndText: String
    var windowLabel: String
    var topOperations: [YouTubeAPIQuotaOperation]

    var percentText: String {
        guard limit > 0 else { return "-" }
        return String(format: "%.1f%%", usageRatio * 100)
    }

    var usageText: String {
        guard limit > 0 else { return "-" }
        return "\(used) / \(limit)"
    }

    var summaryText: String {
        let prefix = isEstimated ? "Estimated" : "Current"
        return "\(prefix) \(usageText)"
    }

    var accentColorName: String {
        switch usageRatio {
        case 0.9...:
            return "red"
        case 0.75...:
            return "orange"
        default:
            return "blue"
        }
    }

    static let unknown = YouTubeAPIQuotaStatus(
        date: "",
        used: 0,
        limit: 50_000,
        remaining: 50_000,
        usageRatio: 0,
        isEstimated: true,
        windowStartText: "",
        windowEndText: "",
        windowLabel: "",
        topOperations: []
    )
}

struct YouTubeAPIQuotaOperation: Equatable {
    var operation: String
    var used: Int
}

struct UploadConfirmationState: Equatable, Identifiable {
    var id: String { title + "\n" + message }
    var title: String
    var message: String
}

struct PhotoLibraryAutoConfirmationState: Equatable, Identifiable {
    var id: String { title + "\n" + message }
    var title: String
    var message: String
}

struct PhotoLibraryAutoBlockedState: Equatable, Identifiable {
    var id: String { title + "\n" + message }
    var title: String
    var message: String
}

struct PhotoLibraryCacheDeletionConfirmationState: Equatable, Identifiable {
    var id: String { title + "\n" + message }
    var title: String
    var message: String
}

enum PhotoLibraryAlertState: Identifiable, Equatable {
    case autoConfirmation(PhotoLibraryAutoConfirmationState)
    case autoBlocked(PhotoLibraryAutoBlockedState)
    case cacheDeletion(PhotoLibraryCacheDeletionConfirmationState)

    var id: String {
        switch self {
        case .autoConfirmation(let state):
            return "auto-confirmation:\(state.id)"
        case .autoBlocked(let state):
            return "auto-blocked:\(state.id)"
        case .cacheDeletion(let state):
            return "cache-deletion:\(state.id)"
        }
    }
}

struct BatchUploadSummary: Equatable {
    var total: Int
    var uploadedCount: Int
    var skippedCount: Int
    var failedCount: Int
}

struct BatchUploadItemResult: Equatable, Identifiable {
    var id: String { youtubeVideoID.isEmpty ? "\(status)-\(videoPath)" : youtubeVideoID }
    var videoPath: String
    var status: String
    var title: String
    var youtubeVideoID: String
    var youtubeVideoURL: String
    var reason: String
}

struct BatchUploadResponse: Equatable {
    var summary: BatchUploadSummary
    var results: [BatchUploadItemResult]
    var csvPath: String
}

struct TaskProgressState: Equatable {
    var title: String
    var detail: String
    var fractionCompleted: Double?

    var percentText: String {
        guard let fractionCompleted else { return "" }
        return String(format: "%.0f%%", max(0, min(fractionCompleted, 1)) * 100)
    }
}

struct CLIProgressEvent: Equatable {
    var event: String
    var current: Int?
    var total: Int?
    var videoPath: String
    var fileName: String
    var progress: Double?
}

struct PhotoLibraryLoadProgress: Equatable {
    var processedCount: Int
    var totalCount: Int
    var currentFileName: String
}

struct UploadedVideoMetadataSnapshot: Equatable {
    var captureDate: Date
    var content: String
    var customTitle: String
    var customDescription: String
    var place: String
    var eventName: String
    var participantsText: String
    var cameraModel: String
    var playlistsText: String
    var note: String

    @MainActor
    init(draft: VideoDraft) {
        self.captureDate = draft.captureDate
        self.content = draft.content
        self.customTitle = draft.customTitle
        self.customDescription = draft.customDescription
        self.place = draft.place
        self.eventName = draft.eventName
        self.participantsText = draft.participantsText
        self.cameraModel = draft.cameraModel
        self.playlistsText = draft.playlistsText
        self.note = draft.note
    }
}

struct UploadedVideoRecord: Equatable, Identifiable {
    var id: String { youtubeVideoID.isEmpty ? "\(status)-\(filePath)" : youtubeVideoID }
    var filePath: String
    var title: String
    var youtubeVideoID: String
    var youtubeVideoURL: String
    var status: String
    var reason: String
    var metadata: UploadedVideoMetadataSnapshot
    var verificationReport: UploadVerificationReport?

    var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }

    var mismatchCount: Int {
        verificationReport?.mismatchCount ?? 0
    }
}

struct UploadHistoryEntry: Equatable, Identifiable {
    var id: Int
    var youtubeVideoID: String
    var youtubeVideoURL: String
    var title: String
    var videoPath: String
    var captureDate: String
    var uploadedAt: String
    var place: String
    var content: String
    var eventName: String
    var participantsText: String
    var cameraModel: String
    var playlistsText: String
    var uploadStatus: String

    var fileName: String {
        URL(fileURLWithPath: videoPath).lastPathComponent
    }

    var captureDateDisplayText: String {
        HistoryCalendarDateSupport.displayDateTimeText(fromStoredString: captureDate)
    }
}

struct PhotoDeletionHistoryEntry: Equatable, Identifiable {
    var id: Int
    var assetIdentifier: String
    var filePath: String
    var fileName: String
    var captureDate: String
    var deletedAt: String
    var category: String

    var captureDateDisplayText: String {
        HistoryCalendarDateSupport.displayDateTimeText(fromStoredString: captureDate)
    }

    var deletedAtDisplayText: String {
        HistoryCalendarDateSupport.displayDateTimeText(fromStoredString: deletedAt)
    }
}

enum AppScreen: String, CaseIterable, Identifiable {
    case uploader = "Upload"
    case history = "Recent History"
    case historyCalendar = "History Calendar"
    case photos = "Photos"

    var id: String { rawValue }
}

enum PhotoDeletionHistoryCategoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case insta360 = "Insta360"
    case hoverX1 = "HoverX1"
    case other = "Other"

    var id: String { rawValue }

    var storedCategoryValue: String? {
        switch self {
        case .all:
            return nil
        case .insta360:
            return "Insta360"
        case .hoverX1:
            return "HoverX1"
        case .other:
            return "Other"
        }
    }
}

struct UploadCategoryCounts: Codable, Equatable {
    var vlog: Int = 0
    var insta360: Int = 0
    var hoverX1: Int = 0
    var other: Int = 0

    var total: Int {
        vlog + insta360 + hoverX1 + other
    }

    static let zero = UploadCategoryCounts()
}

struct DeletionCategoryCounts: Codable, Equatable {
    var insta360: Int = 0
    var hoverX1: Int = 0
    var other: Int = 0

    var total: Int {
        insta360 + hoverX1 + other
    }

    static let zero = DeletionCategoryCounts()
}

struct HistoryCalendarDayItem: Equatable, Identifiable {
    var id: String { dateKey + (isInDisplayedMonth ? "-in" : "-out") }
    var date: Date
    var dateKey: String
    var dayNumberText: String
    var isInDisplayedMonth: Bool
    var isSelected: Bool
    var hasUploadMark: Bool
    var hasDeletionMark: Bool
    var memoText: String
}

struct HistoryCalendarSnapshot: Equatable {
    var uploadCountsByDate: [String: UploadCategoryCounts]
    var deletionCountsByDate: [String: DeletionCategoryCounts]
    var uploadMarkedDates: Set<String>
    var deletionMarkedDates: Set<String>
    var memoByDate: [String: String]
    var totalUploadCounts: UploadCategoryCounts
    var totalDeletionCounts: DeletionCategoryCounts

    static let empty = HistoryCalendarSnapshot(
        uploadCountsByDate: [:],
        deletionCountsByDate: [:],
        uploadMarkedDates: [],
        deletionMarkedDates: [],
        memoByDate: [:],
        totalUploadCounts: .zero,
        totalDeletionCounts: .zero
    )
}

struct HistoryDeletionEvent: Codable, Equatable {
    var dateKey: String
    var insta360: Int
    var hoverX1: Int
    var other: Int
}

struct HistoryCalendarStorePayload: Codable, Equatable {
    var deletionEvents: [HistoryDeletionEvent]
    var manualUploadMarkedDates: [String]
    var manualDeletionMarkedDates: [String]
    var manualUploadAdjustmentsByDate: [String: UploadCategoryCounts]
    var manualDeletionAdjustmentsByDate: [String: DeletionCategoryCounts]

    static let empty = HistoryCalendarStorePayload(
        deletionEvents: [],
        manualUploadMarkedDates: [],
        manualDeletionMarkedDates: [],
        manualUploadAdjustmentsByDate: [:],
        manualDeletionAdjustmentsByDate: [:]
    )
}

struct HistoryCalendarLoadedState {
    var snapshot: HistoryCalendarSnapshot
    var baseUploadCountsByDate: [String: UploadCategoryCounts]
    var baseDeletionCountsByDate: [String: DeletionCategoryCounts]
    var manualUploadMarkedDates: Set<String>
    var manualDeletionMarkedDates: Set<String>
}

enum HistoryCalendarRepositoryError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case invalidHistoryDB(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message),
             .prepareFailed(let message),
             .stepFailed(let message),
             .invalidHistoryDB(let message):
            return message
        }
    }
}

final class HistoryCalendarRepository {
    private let dbURL: URL
    private let uploadHistoryDBURL: URL
    private let legacyMarksURL: URL

    init(environment: NativeAppEnvironment) {
        let root = URL(fileURLWithPath: environment.workspaceRoot, isDirectory: true)
            .appendingPathComponent(environment.supportDirectory, isDirectory: true)
        self.dbURL = root.appendingPathComponent("history_calendar.db")
        self.uploadHistoryDBURL = root.appendingPathComponent("upload_history.db")
        self.legacyMarksURL = root.appendingPathComponent("history_calendar_marks.json")
    }

    func initialize() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let shouldBootstrap = !fileManager.fileExists(atPath: dbURL.path)

        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try execute(
            sql:
            """
            CREATE TABLE IF NOT EXISTS history_calendar_day (
              date_key TEXT PRIMARY KEY,
              base_upload_vlog INTEGER NOT NULL DEFAULT 0,
              base_upload_insta360 INTEGER NOT NULL DEFAULT 0,
              base_upload_hoverx1 INTEGER NOT NULL DEFAULT 0,
              base_upload_other INTEGER NOT NULL DEFAULT 0,
              base_delete_insta360 INTEGER NOT NULL DEFAULT 0,
              base_delete_hoverx1 INTEGER NOT NULL DEFAULT 0,
              base_delete_other INTEGER NOT NULL DEFAULT 0,
              manual_upload_vlog_adjustment INTEGER NOT NULL DEFAULT 0,
              manual_upload_insta360_adjustment INTEGER NOT NULL DEFAULT 0,
              manual_upload_hoverx1_adjustment INTEGER NOT NULL DEFAULT 0,
              manual_upload_other_adjustment INTEGER NOT NULL DEFAULT 0,
              manual_delete_insta360_adjustment INTEGER NOT NULL DEFAULT 0,
              manual_delete_hoverx1_adjustment INTEGER NOT NULL DEFAULT 0,
              manual_delete_other_adjustment INTEGER NOT NULL DEFAULT 0,
              manual_upload_mark INTEGER NOT NULL DEFAULT 0,
              manual_delete_mark INTEGER NOT NULL DEFAULT 0,
              memo_text TEXT NOT NULL DEFAULT ''
            );
            """,
            db: db
        )
        try execute(
            sql:
            """
            CREATE TABLE IF NOT EXISTS photo_library_deletion_history (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              asset_identifier TEXT NOT NULL,
              file_path TEXT NOT NULL,
              file_name TEXT NOT NULL,
              capture_date TEXT NOT NULL,
              deleted_at TEXT NOT NULL,
              category TEXT NOT NULL
            );
            """,
            db: db
        )
        try ensureColumn(
            named: "memo_text",
            definition: "TEXT NOT NULL DEFAULT ''",
            in: "history_calendar_day",
            db: db
        )

        if shouldBootstrap {
            try migrateLegacyJSONIfNeeded(db: db)
            if fileManager.fileExists(atPath: uploadHistoryDBURL.path) {
                try rebuildUploadBaseCounts(db: db)
            }
        }
    }

    func load() throws -> HistoryCalendarLoadedState {
        try initialize()
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        SELECT
          date_key,
          base_upload_vlog,
          base_upload_insta360,
          base_upload_hoverx1,
          base_upload_other,
          base_delete_insta360,
          base_delete_hoverx1,
          base_delete_other,
          manual_upload_vlog_adjustment,
          manual_upload_insta360_adjustment,
          manual_upload_hoverx1_adjustment,
          manual_upload_other_adjustment,
          manual_delete_insta360_adjustment,
          manual_delete_hoverx1_adjustment,
          manual_delete_other_adjustment,
          manual_upload_mark,
          manual_delete_mark,
          memo_text
        FROM history_calendar_day
        ORDER BY date_key ASC
        """
        let statement = try prepare(sql: sql, db: db)
        defer { sqlite3_finalize(statement) }

        var baseUploadByDate: [String: UploadCategoryCounts] = [:]
        var baseDeletionByDate: [String: DeletionCategoryCounts] = [:]
        var finalUploadByDate: [String: UploadCategoryCounts] = [:]
        var finalDeletionByDate: [String: DeletionCategoryCounts] = [:]
        var uploadMarks: Set<String> = []
        var deletionMarks: Set<String> = []
        var memoByDate: [String: String] = [:]
        var totalUpload = UploadCategoryCounts.zero
        var totalDeletion = DeletionCategoryCounts.zero

        while sqlite3_step(statement) == SQLITE_ROW {
            let dateKey = stringValue(at: 0, statement: statement)
            let baseUpload = UploadCategoryCounts(
                vlog: intValue(at: 1, statement: statement),
                insta360: intValue(at: 2, statement: statement),
                hoverX1: intValue(at: 3, statement: statement),
                other: intValue(at: 4, statement: statement)
            )
            let baseDeletion = DeletionCategoryCounts(
                insta360: intValue(at: 5, statement: statement),
                hoverX1: intValue(at: 6, statement: statement),
                other: intValue(at: 7, statement: statement)
            )
            let uploadAdjustment = UploadCategoryCounts(
                vlog: intValue(at: 8, statement: statement),
                insta360: intValue(at: 9, statement: statement),
                hoverX1: intValue(at: 10, statement: statement),
                other: intValue(at: 11, statement: statement)
            )
            let deletionAdjustment = DeletionCategoryCounts(
                insta360: intValue(at: 12, statement: statement),
                hoverX1: intValue(at: 13, statement: statement),
                other: intValue(at: 14, statement: statement)
            )
            let finalUpload = UploadCategoryCounts(
                vlog: max(0, baseUpload.vlog + uploadAdjustment.vlog),
                insta360: max(0, baseUpload.insta360 + uploadAdjustment.insta360),
                hoverX1: max(0, baseUpload.hoverX1 + uploadAdjustment.hoverX1),
                other: max(0, baseUpload.other + uploadAdjustment.other)
            )
            let finalDeletion = DeletionCategoryCounts(
                insta360: max(0, baseDeletion.insta360 + deletionAdjustment.insta360),
                hoverX1: max(0, baseDeletion.hoverX1 + deletionAdjustment.hoverX1),
                other: max(0, baseDeletion.other + deletionAdjustment.other)
            )

            if baseUpload.total > 0 { baseUploadByDate[dateKey] = baseUpload }
            if baseDeletion.total > 0 { baseDeletionByDate[dateKey] = baseDeletion }
            if finalUpload.total > 0 { finalUploadByDate[dateKey] = finalUpload }
            if finalDeletion.total > 0 { finalDeletionByDate[dateKey] = finalDeletion }
            if intValue(at: 15, statement: statement) != 0 { uploadMarks.insert(dateKey) }
            if intValue(at: 16, statement: statement) != 0 { deletionMarks.insert(dateKey) }
            let memoText = stringValue(at: 17, statement: statement)
            if !memoText.isEmpty { memoByDate[dateKey] = memoText }

            totalUpload.vlog += finalUpload.vlog
            totalUpload.insta360 += finalUpload.insta360
            totalUpload.hoverX1 += finalUpload.hoverX1
            totalUpload.other += finalUpload.other

            totalDeletion.insta360 += finalDeletion.insta360
            totalDeletion.hoverX1 += finalDeletion.hoverX1
            totalDeletion.other += finalDeletion.other
        }

        return HistoryCalendarLoadedState(
            snapshot: HistoryCalendarSnapshot(
                uploadCountsByDate: finalUploadByDate,
                deletionCountsByDate: finalDeletionByDate,
                uploadMarkedDates: Set(finalUploadByDate.keys).union(uploadMarks),
                deletionMarkedDates: Set(finalDeletionByDate.keys).union(deletionMarks),
                memoByDate: memoByDate,
                totalUploadCounts: totalUpload,
                totalDeletionCounts: totalDeletion
            ),
            baseUploadCountsByDate: baseUploadByDate,
            baseDeletionCountsByDate: baseDeletionByDate,
            manualUploadMarkedDates: uploadMarks,
            manualDeletionMarkedDates: deletionMarks
        )
    }

    func incrementUploadCounts(on dateKey: String, counts: UploadCategoryCounts) throws {
        try initialize()
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try upsertDay(dateKey: dateKey, db: db)
        try execute(
            sql:
            """
            UPDATE history_calendar_day
            SET base_upload_vlog = base_upload_vlog + ?,
                base_upload_insta360 = base_upload_insta360 + ?,
                base_upload_hoverx1 = base_upload_hoverx1 + ?,
                base_upload_other = base_upload_other + ?
            WHERE date_key = ?
            """,
            bindings: [
                .int(counts.vlog),
                .int(counts.insta360),
                .int(counts.hoverX1),
                .int(counts.other),
                .text(dateKey),
            ],
            db: db
        )
    }

    func incrementDeletionCounts(on dateKey: String, counts: DeletionCategoryCounts) throws {
        try initialize()
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try upsertDay(dateKey: dateKey, db: db)
        try execute(
            sql:
            """
            UPDATE history_calendar_day
            SET base_delete_insta360 = base_delete_insta360 + ?,
                base_delete_hoverx1 = base_delete_hoverx1 + ?,
                base_delete_other = base_delete_other + ?
            WHERE date_key = ?
            """,
            bindings: [
                .int(counts.insta360),
                .int(counts.hoverX1),
                .int(counts.other),
                .text(dateKey),
            ],
            db: db
        )
    }

    func setManualUploadMark(dateKey: String, enabled: Bool) throws {
        try initialize()
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try upsertDay(dateKey: dateKey, db: db)
        try execute(
            sql:
            "UPDATE history_calendar_day SET manual_upload_mark = ? WHERE date_key = ?",
            bindings: [.int(enabled ? 1 : 0), .text(dateKey)],
            db: db
        )
    }

    func setManualDeletionMark(dateKey: String, enabled: Bool) throws {
        try initialize()
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try upsertDay(dateKey: dateKey, db: db)
        try execute(
            sql:
            "UPDATE history_calendar_day SET manual_delete_mark = ? WHERE date_key = ?",
            bindings: [.int(enabled ? 1 : 0), .text(dateKey)],
            db: db
        )
    }

    func setManualUploadAdjustment(dateKey: String, adjustment: UploadCategoryCounts) throws {
        try initialize()
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try upsertDay(dateKey: dateKey, db: db)
        try execute(
            sql:
            """
            UPDATE history_calendar_day
            SET manual_upload_vlog_adjustment = ?,
                manual_upload_insta360_adjustment = ?,
                manual_upload_hoverx1_adjustment = ?,
                manual_upload_other_adjustment = ?
            WHERE date_key = ?
            """,
            bindings: [
                .int(adjustment.vlog),
                .int(adjustment.insta360),
                .int(adjustment.hoverX1),
                .int(adjustment.other),
                .text(dateKey),
            ],
            db: db
        )
    }

    func setManualDeletionAdjustment(dateKey: String, adjustment: DeletionCategoryCounts) throws {
        try initialize()
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try upsertDay(dateKey: dateKey, db: db)
        try execute(
            sql:
            """
            UPDATE history_calendar_day
            SET manual_delete_insta360_adjustment = ?,
                manual_delete_hoverx1_adjustment = ?,
                manual_delete_other_adjustment = ?
            WHERE date_key = ?
            """,
            bindings: [
                .int(adjustment.insta360),
                .int(adjustment.hoverX1),
                .int(adjustment.other),
                .text(dateKey),
            ],
            db: db
        )
    }

    func setMemoText(dateKey: String, memoText: String) throws {
        try initialize()
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try upsertDay(dateKey: dateKey, db: db)
        try execute(
            sql: "UPDATE history_calendar_day SET memo_text = ? WHERE date_key = ?",
            bindings: [.text(HistoryCalendarDateSupport.sanitizedMemoText(memoText)), .text(dateKey)],
            db: db
        )
    }

    func rebuildFromUploadHistory() throws {
        try initialize()
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try rebuildUploadBaseCounts(db: db)
    }

    func appendDeletionHistoryEntries(_ entries: [PhotoDeletionHistoryEntry]) throws {
        guard !entries.isEmpty else { return }
        try initialize()
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        for entry in entries {
            try execute(
                sql:
                """
                INSERT INTO photo_library_deletion_history (
                  asset_identifier, file_path, file_name, capture_date, deleted_at, category
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(entry.assetIdentifier),
                    .text(entry.filePath),
                    .text(entry.fileName),
                    .text(entry.captureDate),
                    .text(entry.deletedAt),
                    .text(entry.category),
                ],
                db: db
            )
        }
    }

    func loadDeletionHistory(limit: Int, category: String? = nil) throws -> [PhotoDeletionHistoryEntry] {
        try initialize()
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let statement: OpaquePointer?
        if let category, !category.isEmpty {
            statement = try prepare(
                sql:
                """
                SELECT id, asset_identifier, file_path, file_name, capture_date, deleted_at, category
                FROM photo_library_deletion_history
                WHERE category = ?
                ORDER BY id DESC
                LIMIT ?
                """,
                db: db
            )
            sqlite3_bind_text(statement, 1, category, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 2, Int32(limit))
        } else {
            statement = try prepare(
                sql:
                """
                SELECT id, asset_identifier, file_path, file_name, capture_date, deleted_at, category
                FROM photo_library_deletion_history
                ORDER BY id DESC
                LIMIT ?
                """,
                db: db
            )
            sqlite3_bind_int(statement, 1, Int32(limit))
        }
        defer { sqlite3_finalize(statement) }

        var entries: [PhotoDeletionHistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            entries.append(
                PhotoDeletionHistoryEntry(
                    id: intValue(at: 0, statement: statement),
                    assetIdentifier: stringValue(at: 1, statement: statement),
                    filePath: stringValue(at: 2, statement: statement),
                    fileName: stringValue(at: 3, statement: statement),
                    captureDate: stringValue(at: 4, statement: statement),
                    deletedAt: stringValue(at: 5, statement: statement),
                    category: stringValue(at: 6, statement: statement)
                )
            )
        }
        return entries
    }

    private func rebuildUploadBaseCounts(db: OpaquePointer?) throws {
        let aggregated = try aggregateUploadsFromHistoryDB()
        try execute(
            sql:
            """
            UPDATE history_calendar_day
            SET base_upload_vlog = 0,
                base_upload_insta360 = 0,
                base_upload_hoverx1 = 0,
                base_upload_other = 0
            """,
            db: db
        )
        for (dateKey, counts) in aggregated {
            try upsertDay(dateKey: dateKey, db: db)
            try execute(
                sql:
                """
                UPDATE history_calendar_day
                SET base_upload_vlog = ?,
                    base_upload_insta360 = ?,
                    base_upload_hoverx1 = ?,
                    base_upload_other = ?
                WHERE date_key = ?
                """,
                bindings: [
                    .int(counts.vlog),
                    .int(counts.insta360),
                    .int(counts.hoverX1),
                    .int(counts.other),
                    .text(dateKey),
                ],
                db: db
            )
        }
    }

    private func migrateLegacyJSONIfNeeded(db: OpaquePointer?) throws {
        guard FileManager.default.fileExists(atPath: legacyMarksURL.path),
              let data = try? Data(contentsOf: legacyMarksURL),
              let payload = try? JSONDecoder().decode(HistoryCalendarStorePayload.self, from: data) else {
            return
        }

        for dateKey in Set(payload.manualUploadMarkedDates) {
            try upsertDay(dateKey: dateKey, db: db)
            try execute(
                sql:
                "UPDATE history_calendar_day SET manual_upload_mark = 1 WHERE date_key = ?",
                bindings: [.text(dateKey)],
                db: db
            )
        }
        for dateKey in Set(payload.manualDeletionMarkedDates) {
            try upsertDay(dateKey: dateKey, db: db)
            try execute(
                sql:
                "UPDATE history_calendar_day SET manual_delete_mark = 1 WHERE date_key = ?",
                bindings: [.text(dateKey)],
                db: db
            )
        }
        for (dateKey, adjustment) in payload.manualUploadAdjustmentsByDate {
            try upsertDay(dateKey: dateKey, db: db)
            try execute(
                sql:
                """
                UPDATE history_calendar_day
                SET manual_upload_vlog_adjustment = ?,
                    manual_upload_insta360_adjustment = ?,
                    manual_upload_hoverx1_adjustment = ?,
                    manual_upload_other_adjustment = ?
                WHERE date_key = ?
                """,
                bindings: [
                    .int(adjustment.vlog),
                    .int(adjustment.insta360),
                    .int(adjustment.hoverX1),
                    .int(adjustment.other),
                    .text(dateKey),
                ],
                db: db
            )
        }
        for (dateKey, adjustment) in payload.manualDeletionAdjustmentsByDate {
            try upsertDay(dateKey: dateKey, db: db)
            try execute(
                sql:
                """
                UPDATE history_calendar_day
                SET manual_delete_insta360_adjustment = ?,
                    manual_delete_hoverx1_adjustment = ?,
                    manual_delete_other_adjustment = ?
                WHERE date_key = ?
                """,
                bindings: [
                    .int(adjustment.insta360),
                    .int(adjustment.hoverX1),
                    .int(adjustment.other),
                    .text(dateKey),
                ],
                db: db
            )
        }
        let deletionBase = payload.deletionEvents.reduce(into: [String: DeletionCategoryCounts]()) { partial, event in
            var counts = partial[event.dateKey] ?? .zero
            counts.insta360 += event.insta360
            counts.hoverX1 += event.hoverX1
            counts.other += event.other
            partial[event.dateKey] = counts
        }
        for (dateKey, counts) in deletionBase {
            try upsertDay(dateKey: dateKey, db: db)
            try execute(
                sql:
                """
                UPDATE history_calendar_day
                SET base_delete_insta360 = ?,
                    base_delete_hoverx1 = ?,
                    base_delete_other = ?
                WHERE date_key = ?
                """,
                bindings: [.int(counts.insta360), .int(counts.hoverX1), .int(counts.other), .text(dateKey)],
                db: db
            )
        }
    }

    private func aggregateUploadsFromHistoryDB() throws -> [String: UploadCategoryCounts] {
        guard FileManager.default.fileExists(atPath: uploadHistoryDBURL.path) else { return [:] }

        var historyDB: OpaquePointer?
        guard sqlite3_open(uploadHistoryDBURL.path, &historyDB) == SQLITE_OK else {
            let message = historyDB.flatMap { sqliteMessage(db: $0) } ?? "Failed to open upload_history.db."
            if let historyDB { sqlite3_close(historyDB) }
            throw HistoryCalendarRepositoryError.invalidHistoryDB(message)
        }
        defer { sqlite3_close(historyDB) }

        let statement = try prepare(
            sql: """
            SELECT effective_capture_date, capture_date, uploaded_at, camera_model
            FROM upload_history
            WHERE upload_status = 'success'
            """,
            db: historyDB
        )
        defer { sqlite3_finalize(statement) }

        var result: [String: UploadCategoryCounts] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let effectiveCaptureDate = stringValue(at: 0, statement: statement)
            let captureDate = stringValue(at: 1, statement: statement)
            let uploadedAt = stringValue(at: 2, statement: statement)
            let cameraModel = stringValue(at: 3, statement: statement)
            let dateKey = HistoryCalendarDateSupport.dateKey(
                fromPreferredStrings: [effectiveCaptureDate, captureDate, uploadedAt]
            )
            guard !dateKey.isEmpty else { continue }
            var counts = result[dateKey] ?? .zero
            switch HistoryCalendarDateSupport.uploadCategory(forCameraModel: cameraModel) {
            case .vlog:
                counts.vlog += 1
            case .insta360:
                counts.insta360 += 1
            case .hoverX1:
                counts.hoverX1 += 1
            case .other:
                counts.other += 1
            }
            result[dateKey] = counts
        }
        return result
    }

    private func upsertDay(dateKey: String, db: OpaquePointer?) throws {
        try execute(
            sql:
            "INSERT OR IGNORE INTO history_calendar_day (date_key) VALUES (?)",
            bindings: [.text(dateKey)],
            db: db
        )
    }

    private func openDatabase() throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            let message = db.flatMap { sqliteMessage(db: $0) } ?? "Failed to open history_calendar.db."
            if let db { sqlite3_close(db) }
            throw HistoryCalendarRepositoryError.openFailed(message)
        }
        return db
    }

    private func ensureColumn(named columnName: String, definition: String, in tableName: String, db: OpaquePointer?) throws {
        let statement = try prepare(sql: "PRAGMA table_info(\(tableName))", db: db)
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if stringValue(at: 1, statement: statement) == columnName {
                return
            }
        }
        try execute(sql: "ALTER TABLE \(tableName) ADD COLUMN \(columnName) \(definition)", db: db)
    }

    private enum SQLiteBinding {
        case int(Int)
        case text(String)
    }

    private func execute(sql: String, bindings: [SQLiteBinding] = [], db: OpaquePointer?) throws {
        let statement = try prepare(sql: sql, db: db)
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            let parameterIndex = Int32(index + 1)
            switch binding {
            case .int(let value):
                sqlite3_bind_int(statement, parameterIndex, Int32(value))
            case .text(let value):
                sqlite3_bind_text(statement, parameterIndex, value, -1, SQLITE_TRANSIENT)
            }
        }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw HistoryCalendarRepositoryError.stepFailed(sqliteMessage(db: db))
        }
    }

    private func prepare(sql: String, db: OpaquePointer?) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoryCalendarRepositoryError.prepareFailed(sqliteMessage(db: db))
        }
        return statement
    }

    private func intValue(at index: Int32, statement: OpaquePointer?) -> Int {
        Int(sqlite3_column_int(statement, index))
    }

    private func stringValue(at index: Int32, statement: OpaquePointer?) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    private func sqliteMessage(db: OpaquePointer?) -> String {
        guard let db, let message = sqlite3_errmsg(db) else {
            return "A SQLite error occurred."
        }
        return String(cString: message)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum HistoryCalendarUploadCategory {
    case vlog
    case insta360
    case hoverX1
    case other
}

enum HistoryCalendarDeletionCategory {
    case insta360
    case hoverX1
    case other
}

enum HistoryCalendarDateSupport {
    static func sanitizedMemoText(_ value: String) -> String {
        String(value.replacingOccurrences(of: "\n", with: " ").prefix(10))
    }

    static func uploadCategory(forCameraModel cameraModel: String) -> HistoryCalendarUploadCategory {
        let value = cameraModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("vlog") { return .vlog }
        if value.contains("insta360") { return .insta360 }
        if value.contains("hoverx1") || value.contains("hover") { return .hoverX1 }
        return .other
    }

    static func deletionCategory(forFileName fileName: String) -> HistoryCalendarDeletionCategory {
        let upper = fileName.uppercased()
        if upper.hasPrefix("VID_") { return .insta360 }
        if upper.hasPrefix("HOVER_") { return .hoverX1 }
        return .other
    }

    static func dateKey(fromPreferredStrings rawValues: [String]) -> String {
        for raw in rawValues {
            let dateKey = dateKey(fromStoredString: raw)
            if !dateKey.isEmpty {
                return dateKey
            }
        }
        return ""
    }

    static func dateKey(fromStoredString raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 10 {
            let prefix = String(trimmed.prefix(10))
            if dateKeyFormatter.date(from: prefix) != nil { return prefix }
        }
        if let parsed = makeFractionalISODateFormatter().date(from: trimmed)
            ?? makeISODateFormatter().date(from: trimmed)
            ?? plainDateTimeFormatter.date(from: trimmed) {
            return dateKey(for: parsed)
        }
        return ""
    }

    static func dateKey(for date: Date) -> String {
        dateKeyFormatter.string(from: date)
    }

    static func displayDateTimeText(fromStoredString raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let parsed = makeFractionalISODateFormatter().date(from: trimmed)
            ?? makeISODateFormatter().date(from: trimmed)
            ?? plainDateTimeFormatter.date(from: trimmed) {
            return displayDateTimeFormatter.string(from: parsed)
        }
        if trimmed.count >= 10 {
            let prefix = String(trimmed.prefix(10))
            if dateKeyFormatter.date(from: prefix) != nil {
                return prefix
            }
        }
        return trimmed
    }

    private static let dateKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let plainDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static let displayDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static func makeISODateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static func makeFractionalISODateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

enum HistoryDeletionMode: String, Identifiable {
    case localOnly = "History Only"
    case remoteAndLocal = "YouTube + History"

    var id: String { rawValue }
}

struct UploadVerificationComparison: Equatable, Identifiable {
    var id: String { field }
    var field: String
    var status: String
    var local: String
    var remote: String

    var isMismatch: Bool {
        status != "match"
    }

    var tagDifference: TagDifference? {
        guard field == "tags", isMismatch else { return nil }
        let localTags = Set(Self.parseCSV(local))
        let remoteTags = Set(Self.parseCSV(remote))
        return TagDifference(
            missing: localTags.subtracting(remoteTags).sorted(),
            extra: remoteTags.subtracting(localTags).sorted()
        )
    }

    private static func parseCSV(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct TagDifference: Equatable {
    var missing: [String]
    var extra: [String]
}

struct UploadVerificationReport: Equatable, Identifiable {
    var id: String { youtubeVideoID }
    var youtubeVideoID: String
    var title: String
    var channelTitle: String
    var privacyStatus: String
    var processingStatus: String
    var playlistTitles: [String]
    var comparisons: [UploadVerificationComparison]

    var mismatchCount: Int {
        comparisons.filter { $0.status != "match" }.count
    }
}

struct CommonMetadata: Equatable {
    var timezone: String = "JST"
    var offsetTimeOriginal: String = "+09:00"
    var place: String = ""
    var eventName: String = ""
    var participantsText: String = ""
    var cameraModel: String = ""
    var playlistsText: String = ""
    var note: String = ""
    var libraryName: String = "Local Files"
    var captureDateSource: String = "manual_input"
    var privacyStatus: String = "private"
    var playlistPrivacyStatus: String = "private"
}

struct HistoricalMetadataOptions: Equatable {
    var places: [String] = []
    var eventNames: [String] = []
    var participantNames: [String] = []
    var playlists: [String] = []
    var cameraModels: [String] = []
}

struct NativeAppEnvironment: Equatable, Sendable {
    var workspaceRoot: String
    var cliRelativePath: String
    var supportDirectory: String

    var supportDirectoryURL: URL {
        URL(fileURLWithPath: workspaceRoot, isDirectory: true)
            .appendingPathComponent(supportDirectory, isDirectory: true)
    }

    var uploadLimitStateFileURL: URL {
        supportDirectoryURL.appendingPathComponent("upload_limit_state.json", isDirectory: false)
    }

    static func `default`() -> NativeAppEnvironment {
        let packageRoot = resolveWorkspaceRoot()
        return NativeAppEnvironment(
            workspaceRoot: packageRoot.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
    }

    private static func resolveWorkspaceRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["IPHOTO2YOUTUBE_WORKSPACE_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let fileManager = FileManager.default
        var searchRoots = [Bundle.main.bundleURL]
        searchRoots.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))

        for root in searchRoots {
            if let workspaceRoot = findWorkspaceRoot(startingAt: root) {
                return workspaceRoot
            }
        }

        let sourceFile = URL(fileURLWithPath: #filePath)
        return sourceFile
            .deletingLastPathComponent()   // Sources/iPhoto2YouTubeNativeApp
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
    }

    private static func findWorkspaceRoot(startingAt url: URL) -> URL? {
        let fileManager = FileManager.default
        var candidate = url.standardizedFileURL
        let homeDirectory = fileManager.homeDirectoryForCurrentUser.standardizedFileURL

        while true {
            let cliPath = candidate.appendingPathComponent(".venv/bin/iphoto2youtube").path
            let sourcePath = candidate.appendingPathComponent("src/iphoto2youtube_cli").path
            if fileManager.fileExists(atPath: cliPath) && fileManager.fileExists(atPath: sourcePath) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            if parent == candidate || candidate == homeDirectory {
                return nil
            }
            candidate = parent
        }
    }
}

private struct UploadLimitStateRecord: Codable {
    var estimatedResetAt: String
}

struct UploadLimitStateStore {
    let environment: NativeAppEnvironment

    func load(now: Date = Date()) -> Date? {
        let fileURL = environment.uploadLimitStateFileURL
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(UploadLimitStateRecord.self, from: data),
              let estimatedResetAt = Self.makeISO8601Formatter().date(from: record.estimatedResetAt) else {
            return nil
        }
        guard estimatedResetAt > now else {
            clear()
            return nil
        }
        return estimatedResetAt
    }

    func save(_ date: Date) throws {
        let fileManager = FileManager.default
        let directory = environment.supportDirectoryURL
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = UploadLimitStateRecord(estimatedResetAt: Self.makeISO8601Formatter().string(from: date))
        let data = try JSONEncoder().encode(record)
        try data.write(to: environment.uploadLimitStateFileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: environment.uploadLimitStateFileURL)
    }

    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

struct BatchManifest: Encodable {
    var defaults: BatchDefaults
    var videos: [BatchVideoItem]
}

struct BatchDefaults: Encodable, Equatable {
    var timezone: String
    var offsetTimeOriginal: String
    var place: String
    var eventName: String
    var participants: [String]
    var cameraModel: String
    var playlists: [String]
    var note: String
    var libraryName: String
    var captureDateSource: String
    var privacyStatus: String
    var playlistPrivacyStatus: String

    enum CodingKeys: String, CodingKey {
        case timezone
        case offsetTimeOriginal = "offset_time_original"
        case place
        case eventName = "event_name"
        case participants
        case cameraModel = "camera_model"
        case playlists
        case note
        case libraryName = "library_name"
        case captureDateSource = "capture_date_source"
        case privacyStatus = "privacy_status"
        case playlistPrivacyStatus = "playlist_privacy_status"
    }
}

struct BatchVideoItem: Encodable, Equatable {
    var video: String
    var captureDatetime: String
    var content: String
    var title: String?
    var description: String?
    var place: String?
    var eventName: String?
    var participants: [String]?
    var cameraModel: String?
    var playlists: [String]?
    var note: String?

    enum CodingKeys: String, CodingKey {
        case video
        case captureDatetime = "capture_datetime"
        case content
        case title
        case description
        case place
        case eventName = "event_name"
        case participants
        case cameraModel = "camera_model"
        case playlists
        case note
    }
}

@MainActor
struct BatchUploadManifestBuilder {
    static func makeManifest(
        drafts: [VideoDraft],
        common: CommonMetadata,
        dateFormatter: DateFormatter = DateFormatter.batchManifestFormatter
    ) -> BatchManifest {
        let defaults = BatchDefaults(
            timezone: common.timezone,
            offsetTimeOriginal: common.offsetTimeOriginal,
            place: common.place,
            eventName: common.eventName,
            participants: splitCSV(common.participantsText),
            cameraModel: common.cameraModel,
            playlists: splitCSV(common.playlistsText),
            note: common.note,
            libraryName: common.libraryName,
            captureDateSource: common.captureDateSource,
            privacyStatus: common.privacyStatus,
            playlistPrivacyStatus: common.playlistPrivacyStatus
        )

        let videos = drafts.map { draft in
            BatchVideoItem(
                video: draft.filePath,
                captureDatetime: dateFormatter.string(from: draft.captureDate),
                content: draft.content,
                title: draft.customTitle.isEmpty ? nil : draft.customTitle,
                description: draft.customDescription.isEmpty ? nil : draft.customDescription,
                place: draft.place.isEmpty ? nil : draft.place,
                eventName: draft.eventName.isEmpty ? nil : draft.eventName,
                participants: splitCSV(draft.participantsText).isEmpty ? nil : splitCSV(draft.participantsText),
                cameraModel: draft.cameraModel.isEmpty ? nil : draft.cameraModel,
                playlists: splitCSV(draft.playlistsText).isEmpty ? nil : splitCSV(draft.playlistsText),
                note: draft.note.isEmpty ? nil : draft.note
            )
        }
        return BatchManifest(defaults: defaults, videos: videos)
    }

    static func encodedManifestData(drafts: [VideoDraft], common: CommonMetadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(makeManifest(drafts: drafts, common: common))
    }

    static func splitCSV(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum TitlePreviewBuilder {
    static func buildTitle(
        captureDate: Date,
        timezone: String,
        place: String,
        eventName: String,
        content: String
    ) -> String {
        let datePart = DateFormatter.titlePreviewFormatter.string(from: captureDate)
        let timezonePart = sanitizeTitleComponent(timezone.isEmpty ? "JST" : timezone)
        var parts = [
            "\(datePart)-\(timezonePart)",
            sanitizeTitleComponent(place.isEmpty ? "LocationUnset" : place),
        ]

        let eventComponent = eventName.isEmpty ? "" : sanitizeTitleComponent(eventName)
        let contentComponent = content.isEmpty ? "" : sanitizeTitleComponent(content)
        if !eventComponent.isEmpty {
            parts.append(eventComponent)
        }
        if !contentComponent.isEmpty && contentComponent != eventComponent {
            parts.append(contentComponent)
        }
        return parts.joined(separator: "_")
    }

    private static func sanitizeTitleComponent(_ value: String) -> String {
        let compact = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let scalarView = compact.unicodeScalars.map { invalidCharacters.contains($0) ? "-" : Character($0) }
        return String(scalarView).replacingOccurrences(of: " ", with: "")
    }
}

extension DateFormatter {
    static let batchManifestFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static let titlePreviewFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

extension BatchUploadResponse {
    static func from(jsonObject: [String: Any]) -> BatchUploadResponse {
        let payload = jsonObject["payload"] as? [String: Any] ?? [:]
        let summaryPayload = payload["summary"] as? [String: Any] ?? [:]
        let summary = BatchUploadSummary(
            total: summaryPayload["total"] as? Int ?? 0,
            uploadedCount: summaryPayload["uploaded_count"] as? Int ?? 0,
            skippedCount: summaryPayload["skipped_count"] as? Int ?? 0,
            failedCount: summaryPayload["failed_count"] as? Int ?? 0
        )
        let resultsPayload = payload["results"] as? [[String: Any]] ?? []
        let results = resultsPayload.map {
            BatchUploadItemResult(
                videoPath: $0["video_path"] as? String ?? "",
                status: $0["status"] as? String ?? "",
                title: $0["title"] as? String ?? "",
                youtubeVideoID: $0["youtube_video_id"] as? String ?? "",
                youtubeVideoURL: $0["youtube_video_url"] as? String ?? "",
                reason: $0["reason"] as? String ?? ""
            )
        }
        return BatchUploadResponse(
            summary: summary,
            results: results,
            csvPath: payload["csv_path"] as? String ?? ""
        )
    }
}

extension UploadVerificationReport {
    static func from(jsonObject: [String: Any]) -> UploadVerificationReport {
        let payload = jsonObject["payload"] as? [String: Any] ?? [:]
        let remote = payload["remote"] as? [String: Any] ?? [:]
        let playlistTitles = (remote["playlists"] as? [[String: Any]] ?? []).compactMap {
            $0["title"] as? String
        }
        let comparisonsPayload = payload["comparisons"] as? [[String: Any]] ?? []
        let comparisons = comparisonsPayload.map {
            UploadVerificationComparison(
                field: $0["field"] as? String ?? "",
                status: $0["status"] as? String ?? "",
                local: $0["local"] as? String ?? "",
                remote: $0["remote"] as? String ?? ""
            )
        }
        return UploadVerificationReport(
            youtubeVideoID: remote["youtube_video_id"] as? String ?? "",
            title: remote["title"] as? String ?? "",
            channelTitle: remote["channel_title"] as? String ?? "",
            privacyStatus: remote["privacy_status"] as? String ?? "",
            processingStatus: remote["processing_status"] as? String ?? "",
            playlistTitles: playlistTitles,
            comparisons: comparisons
        )
    }
}

enum LedgerSuggestionLoader {
    private static let defaultParticipantNames = ["りえ", "まき", "幸司", "Indy", "大地", "伊吹"]
    private static let excludedParticipantNames = Set(["Alice", "Bob"])

    static func loadOptions(from environment: NativeAppEnvironment) -> HistoricalMetadataOptions {
        let workspaceRoot = URL(fileURLWithPath: environment.workspaceRoot, isDirectory: true)
        let ledgerURL = workspaceRoot
            .appendingPathComponent(environment.supportDirectory, isDirectory: true)
            .appendingPathComponent("ledger.csv")
        guard let content = try? String(contentsOf: ledgerURL, encoding: .utf8) else {
            return HistoricalMetadataOptions()
        }
        let rows = content
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard let headerLine = rows.first else {
            return HistoricalMetadataOptions()
        }
        let headers = parseCSVLine(headerLine)
        let placeIndex = headers.firstIndex(of: "place")
        let eventIndex = headers.firstIndex(of: "event_name")
        let participantIndex = headers.firstIndex(of: "participants")
        let playlistIndex = headers.firstIndex(of: "playlists")
        let cameraModelIndex = headers.firstIndex(of: "camera_model")

        var places = Set<String>()
        var eventNames = Set<String>()
        var participantNames = Set(defaultParticipantNames)
        var playlists = Set<String>()
        var cameraModels = Set(defaultCameraModels)

        for row in rows.dropFirst() {
            let values = parseCSVLine(row)
            if let placeIndex, placeIndex < values.count {
                normalized(values[placeIndex]).forEach { places.insert($0) }
            }
            if let eventIndex, eventIndex < values.count {
                normalized(values[eventIndex]).forEach { eventNames.insert($0) }
            }
            if let participantIndex, participantIndex < values.count {
                splitParticipants(values[participantIndex]).forEach { participantNames.insert($0) }
            }
            if let playlistIndex, playlistIndex < values.count {
                splitCSVValues(values[playlistIndex]).forEach { playlists.insert($0) }
            }
            if let cameraModelIndex, cameraModelIndex < values.count {
                normalized(values[cameraModelIndex]).forEach { cameraModels.insert($0) }
            }
        }

        return HistoricalMetadataOptions(
            places: places.sorted(),
            eventNames: eventNames.sorted(),
            participantNames: participantNames.subtracting(excludedParticipantNames).sorted(),
            playlists: playlists.sorted(),
            cameraModels: cameraModels.sorted()
        )
    }

    private static let defaultCameraModels = ["iPhone", "Insta360", "HoverX1", "EOS"]

    private static func parseCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let char = characters[index]
            switch char {
            case "\"":
                if inQuotes {
                    let nextIndex = index + 1
                    if nextIndex < characters.count, characters[nextIndex] == "\"" {
                        current.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            case ",":
                if inQuotes {
                    current.append(char)
                } else {
                    result.append(current)
                    current = ""
                }
            default:
                current.append(char)
            }
            index += 1
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func normalized(_ raw: String) -> [String] {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? [] : [value]
    }

    private static func splitCSVValues(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func splitParticipants(_ raw: String) -> [String] {
        let normalized = raw.replacingOccurrences(of: "\u{3000}", with: ",")
        return normalized
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
