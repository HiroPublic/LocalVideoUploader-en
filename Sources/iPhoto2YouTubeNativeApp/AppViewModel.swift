import AppKit
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var environment: NativeAppEnvironment
    @Published var currentScreen: AppScreen
    @Published var commonMetadata: CommonMetadata
    @Published var drafts: [VideoDraft]
    @Published var authStatus: ChannelStatus
    @Published var logOutput: String
    @Published var isRunning: Bool
    @Published var lastError: String
    @Published var uploadConfirmation: UploadConfirmationState?
    @Published var photoLibraryAutoConfirmation: PhotoLibraryAutoConfirmationState?
    @Published var verificationReports: [UploadVerificationReport]
    @Published var uploadedVideos: [UploadedVideoRecord]
    @Published var uploadHistoryEntries: [UploadHistoryEntry]
    @Published var photoDeletionHistoryEntries: [PhotoDeletionHistoryEntry]
    @Published var photoLibraryAuthorizationStatus: PhotoLibraryAuthorizationStatus
    @Published var isPhotoLibraryBusy: Bool
    @Published var isPhotoLibraryAutoRunning: Bool
    @Published var selectedPhotoLibraryDate: Date
    @Published var photoLibraryVideos: [PhotoLibraryVideoItem]
    @Published var selectedPhotoLibraryVideoIDs: Set<String>
    @Published var selectedHistoryVideoIDs: Set<String>
    @Published var pendingHistoryDeletionMode: HistoryDeletionMode?
    @Published var historyDisplayLimit: Int
    @Published var deletionHistoryDisplayLimit: Int
    @Published var historySearchQuery: String
    @Published var historyCaptureDateFilterEnabled: Bool
    @Published var historyCaptureDateFilterDate: Date
    @Published var deletionHistoryCategoryFilter: PhotoDeletionHistoryCategoryFilter
    @Published var historyCalendarMonth: Date
    @Published var historyCalendarSelectedDate: Date
    @Published var historyCalendarSnapshot: HistoryCalendarSnapshot
    @Published var historicalOptions: HistoricalMetadataOptions
    @Published var newParticipantName: String

    private var hasAttemptedInitialAuthRefresh: Bool
    private var hasAttemptedInitialLoginFlow: Bool
    private var manualUploadMarkedDates: Set<String>
    private var manualDeletionMarkedDates: Set<String>
    private var baseUploadCountsByDate: [String: UploadCategoryCounts]
    private var baseDeletionCountsByDate: [String: DeletionCategoryCounts]

    private let cliService: any CLIServicing
    private let photoLibraryService: any PhotoLibraryServicing
    private let historyCalendarRepository: HistoryCalendarRepository
    private let calendar: Calendar

    init(
        environment: NativeAppEnvironment = .default(),
        commonMetadata: CommonMetadata = CommonMetadata(),
        drafts: [VideoDraft] = [],
        authStatus: ChannelStatus = .unknown,
        cliService: any CLIServicing = CLIService(),
        photoLibraryService: any PhotoLibraryServicing = PhotoLibraryService()
    ) {
        self.environment = environment
        self.currentScreen = .uploader
        self.commonMetadata = commonMetadata
        self.drafts = drafts
        self.authStatus = authStatus
        self.cliService = cliService
        self.photoLibraryService = photoLibraryService
        self.logOutput = ""
        self.isRunning = false
        self.lastError = ""
        self.uploadConfirmation = nil
        self.photoLibraryAutoConfirmation = nil
        self.verificationReports = []
        self.uploadedVideos = []
        self.uploadHistoryEntries = []
        self.photoDeletionHistoryEntries = []
        self.photoLibraryAuthorizationStatus = .unknown
        self.isPhotoLibraryBusy = false
        self.isPhotoLibraryAutoRunning = false
        self.selectedPhotoLibraryDate = Date()
        self.photoLibraryVideos = []
        self.selectedPhotoLibraryVideoIDs = []
        self.selectedHistoryVideoIDs = []
        self.pendingHistoryDeletionMode = nil
        self.historyDisplayLimit = 10
        self.deletionHistoryDisplayLimit = 10
        self.historySearchQuery = ""
        self.historyCaptureDateFilterEnabled = false
        self.historyCaptureDateFilterDate = Date()
        self.deletionHistoryCategoryFilter = .all
        let today = Date()
        self.historyCalendarMonth = Self.startOfMonth(for: today)
        self.historyCalendarSelectedDate = today
        self.historyCalendarSnapshot = .empty
        self.historicalOptions = LedgerSuggestionLoader.loadOptions(from: environment)
        self.newParticipantName = ""
        self.hasAttemptedInitialAuthRefresh = false
        self.hasAttemptedInitialLoginFlow = false
        self.manualUploadMarkedDates = []
        self.manualDeletionMarkedDates = []
        self.baseUploadCountsByDate = [:]
        self.baseDeletionCountsByDate = [:]
        self.historyCalendarRepository = HistoryCalendarRepository(environment: environment)
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        self.calendar = calendar
    }

    func chooseVideos() {
        let panel = NSOpenPanel()
        panel.title = "Select Videos to Upload"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard !drafts.contains(where: { $0.filePath == url.path }) else { continue }
            drafts.append(
                VideoDraft(
                    filePath: url.path,
                    captureDate: Self.defaultCaptureDate(for: url),
                    place: commonMetadata.place,
                    eventName: commonMetadata.eventName,
                    participantsText: commonMetadata.participantsText,
                    cameraModel: commonMetadata.cameraModel,
                    playlistsText: commonMetadata.playlistsText,
                    note: commonMetadata.note
                )
            )
        }
    }

    func removeDraft(id: UUID) {
        drafts.removeAll { $0.id == id }
    }

    func clearDrafts() {
        drafts.removeAll()
    }

    func applyCommonMetadataToEmptyFields() {
        for draft in drafts {
            if draft.place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.place = commonMetadata.place
            }
            if draft.eventName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.eventName = commonMetadata.eventName
            }
            if draft.participantsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.participantsText = commonMetadata.participantsText
            }
            if draft.cameraModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.cameraModel = commonMetadata.cameraModel
            }
            if draft.playlistsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.playlistsText = commonMetadata.playlistsText
            }
            if draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.note = commonMetadata.note
            }
        }
        appendLog("Applied shared metadata to empty video fields.")
    }

    func refreshHistoricalOptions() {
        historicalOptions = LedgerSuggestionLoader.loadOptions(from: environment)
    }

    func selectCommonPlace(_ value: String) {
        commonMetadata.place = value
    }

    func selectCommonEventName(_ value: String) {
        commonMetadata.eventName = value
    }

    func selectCommonPlaylist(_ value: String) {
        commonMetadata.playlistsText = value
    }

    func selectCommonCameraModel(_ value: String) {
        commonMetadata.cameraModel = value
    }

    func toggleCommonParticipant(_ value: String) {
        var names = participantSelection
        if names.contains(value) {
            names.removeAll { $0 == value }
        } else {
            names.append(value)
        }
        commonMetadata.participantsText = names.joined(separator: ", ")
    }

    func addNewParticipantToCommonMetadata() {
        let value = newParticipantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var names = participantSelection
        if !names.contains(value) {
            names.append(value)
        }
        commonMetadata.participantsText = names.joined(separator: ", ")
        if !historicalOptions.participantNames.contains(value) {
            historicalOptions.participantNames.append(value)
            historicalOptions.participantNames.sort()
        }
        newParticipantName = ""
    }

    var participantSelection: [String] {
        commonMetadata.participantsText
            .replacingOccurrences(of: "\u{3000}", with: ",")
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var historyCalendarMonthTitle: String {
        Self.monthTitleFormatter.string(from: historyCalendarMonth)
    }

    var historyCalendarDayItems: [HistoryCalendarDayItem] {
        let monthStart = Self.startOfMonth(for: historyCalendarMonth)
        let monthInterval = calendar.dateInterval(of: .month, for: monthStart)
        let monthEnd = monthInterval?.end ?? monthStart
        let daysInMonth = calendar.dateComponents([.day], from: monthStart, to: monthEnd).day ?? 0
        let weekdayOfFirst = calendar.component(.weekday, from: monthStart)
        let leading = (weekdayOfFirst - calendar.firstWeekday + 7) % 7

        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: monthStart) else {
            return []
        }

        let selectedKey = Self.dateKey(for: historyCalendarSelectedDate)
        var items: [HistoryCalendarDayItem] = []
        for offset in 0..<42 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else { continue }
            let key = Self.dateKey(for: date)
            let isInMonth = calendar.isDate(date, equalTo: monthStart, toGranularity: .month)
            let day = String(calendar.component(.day, from: date))
            items.append(
                HistoryCalendarDayItem(
                    date: date,
                    dateKey: key,
                    dayNumberText: day,
                    isInDisplayedMonth: isInMonth,
                    isSelected: key == selectedKey,
                    hasUploadMark: historyCalendarSnapshot.uploadMarkedDates.contains(key),
                    hasDeletionMark: historyCalendarSnapshot.deletionMarkedDates.contains(key),
                    memoText: historyCalendarSnapshot.memoByDate[key] ?? ""
                )
            )
        }
        if daysInMonth == 0 {
            return []
        }
        return items
    }

    var selectedCalendarDateLabel: String {
        Self.selectedDateFormatter.string(from: historyCalendarSelectedDate)
    }

    var selectedDateUploadCounts: UploadCategoryCounts {
        historyCalendarSnapshot.uploadCountsByDate[Self.dateKey(for: historyCalendarSelectedDate)] ?? .zero
    }

    var selectedDateDeletionCounts: DeletionCategoryCounts {
        historyCalendarSnapshot.deletionCountsByDate[Self.dateKey(for: historyCalendarSelectedDate)] ?? .zero
    }

    var selectedDateUploadCountsBase: UploadCategoryCounts {
        baseUploadCountsByDate[Self.dateKey(for: historyCalendarSelectedDate)] ?? .zero
    }

    var selectedDateDeletionCountsBase: DeletionCategoryCounts {
        baseDeletionCountsByDate[Self.dateKey(for: historyCalendarSelectedDate)] ?? .zero
    }

    var isManualUploadMarkEnabledForSelectedDate: Bool {
        manualUploadMarkedDates.contains(Self.dateKey(for: historyCalendarSelectedDate))
    }

    var isManualDeletionMarkEnabledForSelectedDate: Bool {
        manualDeletionMarkedDates.contains(Self.dateKey(for: historyCalendarSelectedDate))
    }

    var selectedDateMemoText: String {
        historyCalendarSnapshot.memoByDate[Self.dateKey(for: historyCalendarSelectedDate)] ?? ""
    }

    func selectHistoryCalendarDate(_ date: Date) {
        historyCalendarSelectedDate = date
        if !calendar.isDate(date, equalTo: historyCalendarMonth, toGranularity: .month) {
            historyCalendarMonth = Self.startOfMonth(for: date)
        }
    }

    func moveHistoryCalendarMonth(by offset: Int) {
        guard let moved = calendar.date(byAdding: .month, value: offset, to: historyCalendarMonth) else { return }
        historyCalendarMonth = Self.startOfMonth(for: moved)
    }

    func toggleManualUploadMarkForSelectedDate() {
        let key = Self.dateKey(for: historyCalendarSelectedDate)
        let enabled = !manualUploadMarkedDates.contains(key)
        do {
            try historyCalendarRepository.setManualUploadMark(dateKey: key, enabled: enabled)
            try loadHistoryCalendarSnapshotFromDatabase()
        } catch {
            lastError = error.localizedDescription
            appendLog("Failed to update the history calendar: \(error.localizedDescription)")
        }
    }

    func toggleManualDeletionMarkForSelectedDate() {
        let key = Self.dateKey(for: historyCalendarSelectedDate)
        let enabled = !manualDeletionMarkedDates.contains(key)
        do {
            try historyCalendarRepository.setManualDeletionMark(dateKey: key, enabled: enabled)
            try loadHistoryCalendarSnapshotFromDatabase()
        } catch {
            lastError = error.localizedDescription
            appendLog("Failed to update the history calendar: \(error.localizedDescription)")
        }
    }

    func setSelectedDateUploadCount(_ value: Int, category: String) {
        let key = Self.dateKey(for: historyCalendarSelectedDate)
        let base = selectedDateUploadCountsBase
        var adjustment = UploadCategoryCounts(
            vlog: selectedDateUploadCounts.vlog - base.vlog,
            insta360: selectedDateUploadCounts.insta360 - base.insta360,
            hoverX1: selectedDateUploadCounts.hoverX1 - base.hoverX1,
            other: selectedDateUploadCounts.other - base.other
        )
        switch category {
        case "vlog":
            adjustment.vlog = value - base.vlog
        case "insta360":
            adjustment.insta360 = value - base.insta360
        case "hoverX1":
            adjustment.hoverX1 = value - base.hoverX1
        default:
            adjustment.other = value - base.other
        }
        do {
            try historyCalendarRepository.setManualUploadAdjustment(dateKey: key, adjustment: adjustment)
            try loadHistoryCalendarSnapshotFromDatabase()
        } catch {
            lastError = error.localizedDescription
            appendLog("Failed to update the history calendar: \(error.localizedDescription)")
        }
    }

    func setSelectedDateDeletionCount(_ value: Int, category: String) {
        let key = Self.dateKey(for: historyCalendarSelectedDate)
        let base = selectedDateDeletionCountsBase
        var adjustment = DeletionCategoryCounts(
            insta360: selectedDateDeletionCounts.insta360 - base.insta360,
            hoverX1: selectedDateDeletionCounts.hoverX1 - base.hoverX1,
            other: selectedDateDeletionCounts.other - base.other
        )
        switch category {
        case "insta360":
            adjustment.insta360 = value - base.insta360
        case "hoverX1":
            adjustment.hoverX1 = value - base.hoverX1
        default:
            adjustment.other = value - base.other
        }
        do {
            try historyCalendarRepository.setManualDeletionAdjustment(dateKey: key, adjustment: adjustment)
            try loadHistoryCalendarSnapshotFromDatabase()
        } catch {
            lastError = error.localizedDescription
            appendLog("Failed to update the history calendar: \(error.localizedDescription)")
        }
    }

    func setSelectedDateMemo(_ value: String) {
        let key = Self.dateKey(for: historyCalendarSelectedDate)
        let sanitized = HistoryCalendarDateSupport.sanitizedMemoText(value)
        do {
            try historyCalendarRepository.setMemoText(dateKey: key, memoText: sanitized)
            try loadHistoryCalendarSnapshotFromDatabase()
        } catch {
            lastError = error.localizedDescription
            appendLog("Failed to update the history calendar: \(error.localizedDescription)")
        }
    }

    func refreshAuthStatus() async {
        await runTask(label: "auth-status") {
            let status = try await cliService.refreshAuthStatus(environment: environment)
            authStatus = status
            if status.channelTitle.isEmpty {
                appendLog("Refreshed auth status: \(status.status)")
            } else {
                appendLog("Refreshed auth status: \(status.channelTitle) \(status.channelHandle)")
            }
            guard status.status == "authenticated" else { return }
            Task {
                await refreshCurrentChannelDetails()
            }
        }
    }

    func loginIfNeededOnLaunch() async {
        guard !hasAttemptedInitialLoginFlow else { return }
        hasAttemptedInitialLoginFlow = true
        guard authStatus.status != "authenticated" else { return }

        let credentialsPath = URL(fileURLWithPath: environment.workspaceRoot, isDirectory: true)
            .appendingPathComponent(environment.supportDirectory, isDirectory: true)
            .appendingPathComponent("client_secret.json")
        guard FileManager.default.fileExists(atPath: credentialsPath.path) else {
            appendLog("Could not start Google sign-in automatically: OAuth client settings were not found.")
            return
        }

        await runTask(label: "auth-login") {
            appendLog("Not authenticated. Starting Google sign-in. Complete the flow in your browser.")
            let status = try await cliService.login(environment: environment)
            authStatus = status
            appendLog("Google sign-in completed: \(status.channelTitle) \(status.channelHandle)")
        }
    }

    private func refreshCurrentChannelDetails() async {
        do {
            let channel = try await cliService.fetchCurrentChannel(environment: environment)
            guard authStatus.status == "authenticated" else { return }
            authStatus.channelID = channel.channelID
            authStatus.channelTitle = channel.channelTitle
            authStatus.channelHandle = channel.channelHandle
            appendLog("Fetched authenticated channel: \(channel.channelTitle) \(channel.channelHandle)")
        } catch {
            appendLog("Failed to fetch the authenticated channel: \(error.localizedDescription)")
        }
    }

    func autoRefreshAuthStatusIfNeeded() async {
        guard !hasAttemptedInitialAuthRefresh else { return }
        hasAttemptedInitialAuthRefresh = true
        // Defer initial publishes until after the first render pass.
        // Publishing during the initial view update can destabilize text-field focus on macOS.
        await Task.yield()
        await refreshUploadHistory(resetLimit: true)
        await refreshHistoryCalendarData()
        let authorizationStatus = photoLibraryService.authorizationStatus()
        if photoLibraryAuthorizationStatus != authorizationStatus {
            photoLibraryAuthorizationStatus = authorizationStatus
        }
        await refreshAuthStatus()
        await loginIfNeededOnLaunch()
    }

    func refreshPhotoLibraryAuthorizationStatus() {
        photoLibraryAuthorizationStatus = photoLibraryService.authorizationStatus()
    }

    func requestPhotoLibraryAuthorization() async {
        guard !isPhotoLibraryBusy else { return }
        isPhotoLibraryBusy = true
        defer { isPhotoLibraryBusy = false }
        photoLibraryAuthorizationStatus = await photoLibraryService.requestAuthorization()
        if photoLibraryAuthorizationStatus == .granted || photoLibraryAuthorizationStatus == .limited {
            lastError = ""
            appendLog("Photo library access granted. Select a date and click Load.")
        }
    }

    func loadPhotoLibraryVideos() async {
        guard !isPhotoLibraryBusy else { return }
        isPhotoLibraryBusy = true
        defer { isPhotoLibraryBusy = false }
        await runTask(label: "photo-library") {
            photoLibraryVideos = try await photoLibraryService.fetchVideos(on: selectedPhotoLibraryDate)
            let validIDs = Set(photoLibraryVideos.map(\.id))
            selectedPhotoLibraryVideoIDs = selectedPhotoLibraryVideoIDs.intersection(validIDs)
            let dateText = Self.selectedDateFormatter.string(from: selectedPhotoLibraryDate)
            appendLog("Photo library load result: \(dateText) / \(photoLibraryVideos.count) item(s)")
            if photoLibraryVideos.isEmpty {
                if photoLibraryAuthorizationStatus == .limited {
                    appendLog("Access is limited. The target videos may not be included in the allowed set.")
                } else {
                    appendLog("No videos were found for the selected date. Check whether the capture date may fall on a different day.")
                }
            }
        }
    }

    func togglePhotoLibraryVideoSelection(_ id: String) {
        if selectedPhotoLibraryVideoIDs.contains(id) {
            selectedPhotoLibraryVideoIDs.remove(id)
        } else {
            selectedPhotoLibraryVideoIDs.insert(id)
        }
    }

    func deleteSelectedPhotoLibraryVideos() async {
        let targetIDs = Array(selectedPhotoLibraryVideoIDs)
        guard !targetIDs.isEmpty else { return }
        guard !isPhotoLibraryBusy else { return }
        isPhotoLibraryBusy = true
        defer { isPhotoLibraryBusy = false }

        let targets = photoLibraryVideos.filter { selectedPhotoLibraryVideoIDs.contains($0.id) }

        await runTask(label: "delete-photo-library-videos") {
            try await photoLibraryService.deleteVideos(withIDs: targetIDs)
            photoLibraryVideos = try await photoLibraryService.fetchVideos(on: selectedPhotoLibraryDate)
            let validIDs = Set(photoLibraryVideos.map(\.id))
            selectedPhotoLibraryVideoIDs = selectedPhotoLibraryVideoIDs.intersection(validIDs)

            let removedNames = targets.map(\.fileName).sorted()
            let summary = removedNames.isEmpty ? "\(targetIDs.count) item(s)" : removedNames.joined(separator: ", ")
            appendLog("Deleted videos from iPhoto: \(summary)")
            try recordPhotoLibraryDeletionEvent(for: targets)
        }
    }

    func requestPhotoLibraryAutoWorkflow() {
        guard validatePhotoLibraryAutoWorkflowPreconditions() else { return }

        photoLibraryAutoConfirmation = PhotoLibraryAutoConfirmationState(
            title: "Run Photo Auto?",
            message: buildPhotoLibraryAutoConfirmationMessage()
        )
    }

    func runPhotoLibraryAutoWorkflow() async {
        guard !isPhotoLibraryBusy, !isPhotoLibraryAutoRunning else { return }

        let originalScreen = currentScreen
        isPhotoLibraryAutoRunning = true
        defer {
            isPhotoLibraryAutoRunning = false
            currentScreen = .photos
            if originalScreen != .photos && uploadConfirmation == nil {
                currentScreen = .photos
            }
        }

        lastError = ""

        guard validatePhotoLibraryAutoWorkflowPreconditions() else { return }

        appendLog("Started Photo Auto.")

        if containsPhotoLibraryVideos(matching: Self.isNumericMP4FileName(_:)) {
            appendLog("Photo Auto: detected Vlog targets.")
            applyPhotoLibraryPreset(
                matching: { item in Self.isNumericMP4FileName(item.fileName) },
                cameraModel: "Vlog",
                playlistName: commonMetadata.playlistsText,
                presetName: "Vlog",
                notFoundMessage: "No Vlog videos were found for Auto."
            )
            guard handlePhotoLibraryAutoStepResult(stepName: "Upload Vlog") else { return }
            await runBatchUpload(dryRun: false)
            guard handlePhotoLibraryAutoUploadResult(stepName: "Upload Vlog") else { return }
            currentScreen = .photos
        }

        if containsPhotoLibraryVideos(matching: { $0.uppercased().hasPrefix("VID_") }) {
            appendLog("Photo Auto: detected Insta360 targets.")
            applyPhotoLibraryPreset(
                fileNamePrefix: "VID_",
                cameraModel: "Insta360",
                playlistName: "Insta360"
            )
            guard handlePhotoLibraryAutoStepResult(stepName: "Upload Insta360") else { return }
            await runBatchUpload(dryRun: false)
            guard handlePhotoLibraryAutoUploadResult(stepName: "Upload Insta360") else { return }
            currentScreen = .photos

            selectedPhotoLibraryVideoIDs.removeAll()
            selectPhotoLibraryVideos(fileNamePrefix: "VID_", label: "Insta360")
            guard handlePhotoLibraryAutoStepResult(stepName: "Check Insta360") else { return }
            await deleteSelectedPhotoLibraryVideos()
            guard handlePhotoLibraryAutoStepResult(stepName: "Delete selected Insta360 videos from iPhoto") else { return }
        }

        if containsPhotoLibraryVideos(matching: { $0.uppercased().hasPrefix("HOVER_") }) {
            appendLog("Photo Auto: detected HoverX1 targets.")
            applyPhotoLibraryPreset(
                fileNamePrefix: "HOVER_",
                cameraModel: "HoverX1",
                playlistName: "HoverX1"
            )
            guard handlePhotoLibraryAutoStepResult(stepName: "Upload HoverX1") else { return }
            await runBatchUpload(dryRun: false)
            guard handlePhotoLibraryAutoUploadResult(stepName: "Upload HoverX1") else { return }
            currentScreen = .photos

            selectedPhotoLibraryVideoIDs.removeAll()
            selectPhotoLibraryVideos(fileNamePrefix: "HOVER_", label: "HoverX1")
            guard handlePhotoLibraryAutoStepResult(stepName: "Check HoverX1") else { return }
            await deleteSelectedPhotoLibraryVideos()
            guard handlePhotoLibraryAutoStepResult(stepName: "Delete selected HoverX1 videos from iPhoto") else { return }
        }

        appendLog("Completed Photo Auto.")
    }

    func addSelectedPhotoLibraryVideosToDrafts() {
        let chosen = photoLibraryVideos.filter { selectedPhotoLibraryVideoIDs.contains($0.id) }
        addPhotoLibraryVideosToDrafts(chosen)
    }

    func selectPhotoLibraryVideos(fileNamePrefix: String, label: String) {
        let matchedIDs = photoLibraryVideos
            .filter { $0.fileName.uppercased().hasPrefix(fileNamePrefix.uppercased()) }
            .map(\.id)

        guard !matchedIDs.isEmpty else {
            lastError = "No videos starting with \(fileNamePrefix) were found."
            return
        }

        lastError = ""
        selectedPhotoLibraryVideoIDs.formUnion(matchedIDs)
        appendLog("Checked videos matching \(label): \(matchedIDs.count) item(s)")
    }

    private func validatePhotoLibraryAutoWorkflowPreconditions() -> Bool {
        guard !photoLibraryVideos.isEmpty else {
            lastError = "Photo library videos have not been loaded. Select a date and click Load."
            appendLog("Photo Auto aborted: \(lastError)")
            return false
        }

        let importantFields: [(String, String)] = [
            ("Location", commonMetadata.place),
            ("Event", commonMetadata.eventName),
            ("Playlist", commonMetadata.playlistsText),
        ]
        if let missing = importantFields.first(where: { $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            lastError = "Enter the required field \"\(missing.0)\" on the left before running Photo Auto."
            appendLog("Photo Auto aborted: \(lastError)")
            return false
        }

        guard drafts.isEmpty else {
            lastError = "Clear any pending videos from the Upload screen before running Photo Auto."
            appendLog("Photo Auto aborted: \(lastError)")
            return false
        }

        return true
    }

    private func handlePhotoLibraryAutoStepResult(stepName: String) -> Bool {
        guard lastError.isEmpty else {
            appendLog("Photo Auto aborted: \(stepName) / \(lastError)")
            return false
        }
        return true
    }

    private func handlePhotoLibraryAutoUploadResult(stepName: String) -> Bool {
        guard handlePhotoLibraryAutoStepResult(stepName: stepName) else { return false }
        if !drafts.isEmpty {
            lastError = "Pending videos remain after \(stepName)."
            appendLog("Photo Auto aborted: \(stepName) / \(lastError)")
            return false
        }
        return true
    }

    private func containsPhotoLibraryVideos(matching matcher: (String) -> Bool) -> Bool {
        photoLibraryVideos.contains { matcher($0.fileName) }
    }

    private func buildPhotoLibraryAutoConfirmationMessage() -> String {
        let dateText = Self.selectedDateFormatter.string(from: selectedPhotoLibraryDate)
        let videoCount = photoLibraryVideos.count
        let detectedSteps = [
            containsPhotoLibraryVideos(matching: Self.isNumericMP4FileName(_:)) ? "1. Upload Vlog (.mp4)" : nil,
            containsPhotoLibraryVideos(matching: { $0.uppercased().hasPrefix("VID_") }) ? "2. Upload Insta360, then delete from iPhoto" : nil,
            containsPhotoLibraryVideos(matching: { $0.uppercased().hasPrefix("HOVER_") }) ? "3. Upload HoverX1, then delete from iPhoto" : nil,
        ].compactMap { $0 }

        return [
            "Capture date: \(dateText)",
            "Loaded videos: \(videoCount)",
            "Location: \(commonMetadata.place)",
            "Event: \(commonMetadata.eventName)",
            "Playlist: \(commonMetadata.playlistsText)",
            "",
            "The following targets will run in order.",
            detectedSteps.isEmpty ? "No matching target videos were found." : detectedSteps.joined(separator: "\n"),
            "",
            "If an error occurs, the workflow stops immediately."
        ].joined(separator: "\n")
    }

    func applyPhotoLibraryPreset(
        fileNamePrefix: String,
        cameraModel: String,
        playlistName: String
    ) {
        applyPhotoLibraryPreset(
            matching: { $0.fileName.uppercased().hasPrefix(fileNamePrefix.uppercased()) },
            cameraModel: cameraModel,
            playlistName: playlistName,
            presetName: cameraModel,
            notFoundMessage: "No videos starting with \(fileNamePrefix) were found."
        )
    }

    func applyVlogPhotoLibraryPreset() {
        guard let playlistName = latestVlogPlaylistName() else {
            lastError = "No playlist was found for Vlog. A playlist history entry other than HoverX1 or Insta360 is required."
            return
        }

        applyPhotoLibraryPreset(
            matching: { item in Self.isNumericMP4FileName(item.fileName) },
            cameraModel: "Vlog",
            playlistName: playlistName,
            presetName: "Vlog",
            notFoundMessage: "No .mp4 videos with numeric-only filenames were found."
        )
    }

    func applyAllPhotoLibraryPresets() {
        let presets: [() -> Void] = [
            { self.applyVlogPhotoLibraryPreset() },
            {
                self.applyPhotoLibraryPreset(
                    fileNamePrefix: "HOVER_",
                    cameraModel: "HoverX1",
                    playlistName: "HoverX1"
                )
            },
            {
                self.applyPhotoLibraryPreset(
                    fileNamePrefix: "VID_",
                    cameraModel: "Insta360",
                    playlistName: "Insta360"
                )
            },
        ]

        let existingDraftCount = drafts.count
        lastError = ""
        for applyPreset in presets {
            applyPreset()
        }
        if drafts.count == existingDraftCount && lastError.isEmpty {
            lastError = "No videos were available to add."
        } else if drafts.count > existingDraftCount {
            appendLog("Applied ALL preset: added \(drafts.count - existingDraftCount) item(s) to the upload queue.")
        }
    }

    private func addPhotoLibraryVideosToDrafts(_ chosen: [PhotoLibraryVideoItem]) {
        guard !chosen.isEmpty else { return }
        var addedCount = 0
        for item in chosen {
            guard !drafts.contains(where: { $0.filePath == item.filePath }) else { continue }
            drafts.append(
                VideoDraft(
                    filePath: item.filePath,
                    captureDate: item.captureDate,
                    place: commonMetadata.place,
                    eventName: commonMetadata.eventName,
                    participantsText: commonMetadata.participantsText,
                    cameraModel: commonMetadata.cameraModel,
                    playlistsText: commonMetadata.playlistsText,
                    note: commonMetadata.note
                )
            )
            addedCount += 1
        }
        selectedPhotoLibraryVideoIDs.removeAll()
        currentScreen = .uploader
        appendLog("Added \(addedCount) item(s) from the photo library to the upload queue.")
    }

    private func applyPhotoLibraryPreset(
        matching matcher: (PhotoLibraryVideoItem) -> Bool,
        cameraModel: String,
        playlistName: String,
        presetName: String,
        notFoundMessage: String
    ) {
        let matched = photoLibraryVideos.filter { matcher($0) }
        guard !matched.isEmpty else {
            lastError = notFoundMessage
            return
        }
        let newItems = matched.filter { item in
            !drafts.contains(where: { $0.filePath == item.filePath })
        }
        guard !newItems.isEmpty else {
            lastError = ""
            appendLog("Videos matching the \(presetName) preset have already been added.")
            return
        }

        lastError = ""
        commonMetadata.cameraModel = cameraModel
        commonMetadata.playlistsText = playlistName
        selectedPhotoLibraryVideoIDs = Set(newItems.map(\.id))
        addPhotoLibraryVideosToDrafts(newItems)
        appendLog("Applied \(presetName) preset: selected \(newItems.count) item(s) and updated shared metadata.")
    }

    private func latestVlogPlaylistName() -> String? {
        for playlist in historicalOptions.playlists {
            if playlist != "HoverX1" && playlist != "Insta360" {
                return playlist
            }
        }
        return nil
    }

    private static func isNumericMP4FileName(_ fileName: String) -> Bool {
        let pattern = #"^\d+\.mp4$"#
        return fileName.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }


    func refreshUploadHistory(resetLimit: Bool = false) async {
        if resetLimit, historyDisplayLimit != 10 {
            historyDisplayLimit = 10
        }
        await runTask(label: "history list") {
            uploadHistoryEntries = try await cliService.fetchUploadHistory(
                limit: historyDisplayLimit,
                query: historySearchQuery,
                captureDate: historyCaptureDateFilterQuery,
                environment: environment
            )
            let validIDs = Set(uploadHistoryEntries.map(\.youtubeVideoID))
            selectedHistoryVideoIDs = selectedHistoryVideoIDs.intersection(validIDs)
        }
        refreshPhotoDeletionHistory()
    }

    func refreshHistoryCalendarData() async {
        await runTask(label: "history calendar") {
            try loadHistoryCalendarSnapshotFromDatabase()
        }
    }

    func rebuildHistoryCalendarData() async {
        await runTask(label: "history calendar rebuild") {
            try historyCalendarRepository.rebuildFromUploadHistory()
            try loadHistoryCalendarSnapshotFromDatabase()
        }
    }

    func loadMoreUploadHistory() async {
        historyDisplayLimit += 10
        await refreshUploadHistory()
    }

    func loadMorePhotoDeletionHistory() async {
        deletionHistoryDisplayLimit += 10
        refreshPhotoDeletionHistory()
    }

    func applyHistorySearch() async {
        await refreshUploadHistory(resetLimit: true)
    }

    func applyDeletionHistoryFilter() async {
        deletionHistoryDisplayLimit = 10
        refreshPhotoDeletionHistory()
    }

    func clearHistoryFilters() {
        historySearchQuery = ""
        historyCaptureDateFilterEnabled = false
        historyCaptureDateFilterDate = Date()
    }

    func toggleHistorySelection(_ youtubeVideoID: String) {
        if selectedHistoryVideoIDs.contains(youtubeVideoID) {
            selectedHistoryVideoIDs.remove(youtubeVideoID)
        } else {
            selectedHistoryVideoIDs.insert(youtubeVideoID)
        }
    }

    func requestDeleteSelectedHistoryEntries(mode: HistoryDeletionMode) {
        guard !selectedHistoryVideoIDs.isEmpty else { return }
        pendingHistoryDeletionMode = mode
    }

    func cancelPendingHistoryDeletion() {
        pendingHistoryDeletionMode = nil
    }

    func deleteSelectedHistoryEntriesConfirmed() async {
        let targets = uploadHistoryEntries.filter { selectedHistoryVideoIDs.contains($0.youtubeVideoID) }
        guard !targets.isEmpty else {
            pendingHistoryDeletionMode = nil
            return
        }
        let mode = pendingHistoryDeletionMode ?? .localOnly
        pendingHistoryDeletionMode = nil
        await runTask(label: mode == .localOnly ? "delete-local-history" : "delete-uploaded-video") {
            for target in targets {
                if mode == .localOnly {
                    try await cliService.deleteLocalHistory(
                        youtubeVideoID: target.youtubeVideoID,
                        environment: environment
                    )
                    appendLog("Deleted history entry: \(target.youtubeVideoID) / \(target.title)")
                } else {
                    try await cliService.deleteUploadedVideo(
                        youtubeVideoID: target.youtubeVideoID,
                        environment: environment
                    )
                    appendLog("Deleted from YouTube and history: \(target.youtubeVideoID) / \(target.title)")
                }
                uploadHistoryEntries.removeAll { $0.youtubeVideoID == target.youtubeVideoID }
                uploadedVideos.removeAll { $0.youtubeVideoID == target.youtubeVideoID }
                verificationReports.removeAll { $0.youtubeVideoID == target.youtubeVideoID }
            }
            selectedHistoryVideoIDs.removeAll()
        }
        await refreshUploadHistory()
    }

    func requestUploadConfirmation() {
        guard !drafts.isEmpty else {
            lastError = "No videos selected."
            return
        }
        lastError = ""
        uploadConfirmation = UploadConfirmationState(
            title: "Confirm Upload",
            message: buildUploadConfirmationMessage()
        )
    }

    func runBatchUpload(dryRun: Bool) async {
        guard !drafts.isEmpty else {
            lastError = "No videos selected."
            return
        }
        verificationReports = []
        let draftSnapshots = Dictionary(
            uniqueKeysWithValues: drafts.map { ($0.filePath, UploadedVideoMetadataSnapshot(draft: $0)) }
        )
        await runTask(label: dryRun ? "batch-upload --dry-run" : "batch-upload") {
            let data = try BatchUploadManifestBuilder.encodedManifestData(drafts: drafts, common: commonMetadata)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("iphoto2youtube-native-\(UUID().uuidString).json")
            try data.write(to: tempURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let result = try await cliService.runBatchUpload(
                manifestURL: tempURL,
                dryRun: dryRun,
                environment: environment
            )
            appendLog(renderBatchUploadLog(result: result, dryRun: dryRun))
            if result.summary.failedCount > 0,
               let firstFailure = result.results.first(where: { $0.status == "failed" && !$0.reason.isEmpty }) {
                lastError = firstFailure.reason
            } else {
                lastError = ""
            }

            if !dryRun {
                moveUploadedVideos(from: result, snapshots: draftSnapshots)
                try updateHistoryCalendarAfterUpload(result: result, snapshots: draftSnapshots)
                verificationReports = []
            }
            refreshHistoricalOptions()
        }
    }

    func syncVerificationReport(for videoID: String) async {
        await runTask(label: "sync-upload-metadata") {
            let updated = try await cliService.syncUploadMetadata(
                youtubeVideoID: videoID,
                environment: environment
            )
            if let index = verificationReports.firstIndex(where: { $0.youtubeVideoID == videoID }) {
                verificationReports[index] = updated
            } else {
                verificationReports.append(updated)
            }
            updateUploadedVideoReports(with: [updated])
            appendLog(renderVerificationSyncLog(report: updated))
        }
    }

    private func refreshAuthStatusAfterUpload() async {
        do {
            authStatus = try await cliService.refreshAuthStatus(environment: environment)
        } catch {
            appendLog("Failed to refresh auth status after upload: \(error.localizedDescription)")
        }
    }

    private func verifyUploadedVideos(videoIDs: [String]) async -> [UploadVerificationReport] {
        var reports: [UploadVerificationReport] = []
        for videoID in videoIDs {
            do {
                let report = try await cliService.verifyUpload(
                    youtubeVideoID: videoID,
                    environment: environment
                )
                reports.append(report)
            } catch {
                appendLog("Skipped verify-upload: \(videoID) / \(error.localizedDescription)")
                if shouldStopVerification(after: error) {
                    appendLog("Stopped verify-upload: quota or rate limit detected. Please retry the remaining verifications later.")
                    break
                }
            }
        }
        return reports
    }

    private func shouldStopVerification(after error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("クォータ不足")
            || message.contains("quota")
            || message.contains("レート制限")
            || message.contains("rate limit")
            || message.contains("ratelimit")
            || message.contains("userratelimitexceeded")
    }

    private func moveUploadedVideos(
        from response: BatchUploadResponse,
        snapshots: [String: UploadedVideoMetadataSnapshot]
    ) {
        let migrated = response.results.compactMap { item -> UploadedVideoRecord? in
            guard item.status != "failed", let snapshot = snapshots[item.videoPath] else { return nil }
            return UploadedVideoRecord(
                filePath: item.videoPath,
                title: item.title,
                youtubeVideoID: item.youtubeVideoID,
                youtubeVideoURL: item.youtubeVideoURL,
                status: item.status,
                reason: item.reason,
                metadata: snapshot,
                verificationReport: nil
            )
        }
        let movedPaths = Set(migrated.map(\.filePath))
        if !movedPaths.isEmpty {
            drafts.removeAll { movedPaths.contains($0.filePath) }
        }
        if !migrated.isEmpty {
            uploadedVideos = migrated + uploadedVideos
        }
    }

    private func updateUploadedVideoReports(with reports: [UploadVerificationReport]) {
        let reportByID = Dictionary(uniqueKeysWithValues: reports.map { ($0.youtubeVideoID, $0) })
        for index in uploadedVideos.indices {
            let videoID = uploadedVideos[index].youtubeVideoID
            if let report = reportByID[videoID] {
                uploadedVideos[index].verificationReport = report
            }
        }
    }

    private func loadHistoryCalendarSnapshotFromDatabase() throws {
        let loaded = try historyCalendarRepository.load()
        historyCalendarSnapshot = loaded.snapshot
        baseUploadCountsByDate = loaded.baseUploadCountsByDate
        baseDeletionCountsByDate = loaded.baseDeletionCountsByDate
        manualUploadMarkedDates = loaded.manualUploadMarkedDates
        manualDeletionMarkedDates = loaded.manualDeletionMarkedDates
    }

    private func updateHistoryCalendarAfterUpload(
        result: BatchUploadResponse,
        snapshots: [String: UploadedVideoMetadataSnapshot]
    ) throws {
        var countsByDate: [String: UploadCategoryCounts] = [:]
        for item in result.results where item.status == "uploaded" {
            guard let snapshot = snapshots[item.videoPath] else { continue }
            let dateKey = HistoryCalendarDateSupport.dateKey(for: snapshot.captureDate)
            var counts = countsByDate[dateKey] ?? .zero
            switch HistoryCalendarDateSupport.uploadCategory(forCameraModel: snapshot.cameraModel) {
            case .vlog:
                counts.vlog += 1
            case .insta360:
                counts.insta360 += 1
            case .hoverX1:
                counts.hoverX1 += 1
            case .other:
                counts.other += 1
            }
            countsByDate[dateKey] = counts
        }
        guard !countsByDate.isEmpty else { return }
        for (dateKey, counts) in countsByDate where counts.total > 0 {
            try historyCalendarRepository.incrementUploadCounts(on: dateKey, counts: counts)
        }
        try loadHistoryCalendarSnapshotFromDatabase()
    }

    private func recordPhotoLibraryDeletionEvent(for targets: [PhotoLibraryVideoItem]) throws {
        var countsByDate: [String: DeletionCategoryCounts] = [:]
        let deletedAt = Self.storageDateFormatter.string(from: Date())
        var deletionEntries: [PhotoDeletionHistoryEntry] = []
        for item in targets {
            let dateKey = HistoryCalendarDateSupport.dateKey(for: item.captureDate)
            var counts = countsByDate[dateKey] ?? .zero
            let category: String
            switch HistoryCalendarDateSupport.deletionCategory(forFileName: item.fileName) {
            case .insta360:
                counts.insta360 += 1
                category = "Insta360"
            case .hoverX1:
                counts.hoverX1 += 1
                category = "HoverX1"
            case .other:
                counts.other += 1
                category = "Other"
            }
            countsByDate[dateKey] = counts
            deletionEntries.append(
                PhotoDeletionHistoryEntry(
                    id: 0,
                    assetIdentifier: item.id,
                    filePath: item.filePath,
                    fileName: item.fileName,
                    captureDate: Self.storageDateFormatter.string(from: item.captureDate),
                    deletedAt: deletedAt,
                    category: category
                )
            )
        }
        guard !countsByDate.isEmpty else { return }
        for (dateKey, counts) in countsByDate where counts.total > 0 {
            try historyCalendarRepository.incrementDeletionCounts(on: dateKey, counts: counts)
        }
        try historyCalendarRepository.appendDeletionHistoryEntries(deletionEntries)
        refreshPhotoDeletionHistory()
        try loadHistoryCalendarSnapshotFromDatabase()
    }

    private func refreshPhotoDeletionHistory() {
        do {
            photoDeletionHistoryEntries = try historyCalendarRepository.loadDeletionHistory(
                limit: deletionHistoryDisplayLimit,
                category: deletionHistoryCategoryFilter.storedCategoryValue
            )
        } catch {
            lastError = error.localizedDescription
            appendLog("Failed to load deletion history: \(error.localizedDescription)")
        }
    }

    private static func dateKey(for date: Date) -> String {
        HistoryCalendarDateSupport.dateKey(for: date)
    }

    private static func startOfMonth(for date: Date) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    private static let monthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    private static let selectedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var historyCaptureDateFilterQuery: String {
        guard historyCaptureDateFilterEnabled else { return "" }
        return Self.historyFilterDateFormatter.string(from: historyCaptureDateFilterDate)
    }

    private static let historyFilterDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let storageDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private func runTask(label: String, operation: () async throws -> Void) async {
        isRunning = true
        lastError = ""
        appendLog("Started: \(label)")
        do {
            try await operation()
            appendLog("Completed: \(label)")
        } catch {
            lastError = error.localizedDescription
            appendLog("Error: \(error.localizedDescription)")
        }
        isRunning = false
    }

    private func appendLog(_ message: String) {
        if !logOutput.isEmpty {
            logOutput += "\n\n"
        }
        logOutput += message
    }

    private func buildUploadConfirmationMessage() -> String {
        let channelLine: String
        if authStatus.status == "authenticated" {
            if authStatus.channelTitle.isEmpty {
                channelLine = "Channel: Authenticated"
            } else {
                let handle = authStatus.channelHandle.isEmpty ? "" : " (\(authStatus.channelHandle))"
                channelLine = "Channel: \(authStatus.channelTitle)\(handle)"
            }
        } else {
            channelLine = "Channel: Unknown"
        }

        let previewItems = drafts.prefix(3).map { draft in
            let title: String
            if draft.customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let place = draft.place.isEmpty ? commonMetadata.place : draft.place
                let eventName = draft.eventName.isEmpty ? commonMetadata.eventName : draft.eventName
                title = TitlePreviewBuilder.buildTitle(
                    captureDate: draft.captureDate,
                    timezone: commonMetadata.timezone,
                    place: place,
                    eventName: eventName,
                    content: draft.content
                )
            } else {
                title = draft.customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "- \(title)"
        }
        let remaining = max(drafts.count - previewItems.count, 0)
        let remainingLine = remaining > 0 ? "\nAnd \(remaining) more" : ""

        return [
            "Do you want to upload these videos?",
            "",
            channelLine,
            "Videos: \(drafts.count)",
            "Video Visibility: \(commonMetadata.privacyStatus)",
            "Playlist Visibility: \(commonMetadata.playlistPrivacyStatus)",
            "",
            previewItems.joined(separator: "\n") + remainingLine,
        ].joined(separator: "\n")
    }

    private func renderBatchUploadLog(result: BatchUploadResponse, dryRun: Bool) -> String {
        let header = "$ \(dryRun ? "batch-upload --dry-run" : "batch-upload")"
        let summary = "Summary: total=\(result.summary.total) uploaded=\(result.summary.uploadedCount) skipped=\(result.summary.skippedCount) failed=\(result.summary.failedCount)"
        let rows = result.results.map { item in
            var line = "- \(item.status): \(item.videoPath)"
            if !item.youtubeVideoID.isEmpty {
                line += " -> \(item.youtubeVideoID)"
            }
            if !item.reason.isEmpty {
                line += " (\(item.reason))"
            }
            return line
        }
        let csvLine = result.csvPath.isEmpty ? nil : "CSV: \(result.csvPath)"
        return ([header, summary] + rows + [csvLine].compactMap { $0 }).joined(separator: "\n")
    }

    private func renderVerificationLog(reports: [UploadVerificationReport]) -> String {
        guard !reports.isEmpty else { return "verify-upload: No videos were available for verification." }
        let lines = reports.map { report in
            let mismatch = report.mismatchCount
            let playlists = report.playlistTitles.isEmpty ? "none" : report.playlistTitles.joined(separator: ", ")
            return "verify-upload: \(report.youtubeVideoID) / \(report.title) / privacy=\(report.privacyStatus) / processing=\(report.processingStatus) / playlists=\(playlists) / mismatches=\(mismatch)"
        }
        return lines.joined(separator: "\n")
    }

    private func renderVerificationSyncLog(report: UploadVerificationReport) -> String {
        let playlists = report.playlistTitles.isEmpty ? "none" : report.playlistTitles.joined(separator: ", ")
        return "sync-upload-metadata: \(report.youtubeVideoID) / \(report.title) / privacy=\(report.privacyStatus) / processing=\(report.processingStatus) / playlists=\(playlists) / mismatches=\(report.mismatchCount)"
    }

    private static func defaultCaptureDate(for url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }
}
