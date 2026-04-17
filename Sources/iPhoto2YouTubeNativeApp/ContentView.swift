import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showExitConfirmation = false
    @State private var selectedScreen: AppScreen

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _selectedScreen = State(initialValue: viewModel.currentScreen)
    }

    var body: some View {
        NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Connection") {
                        VStack(alignment: .leading, spacing: 10) {
                            labeledValue("Workspace", viewModel.environment.workspaceRoot)
                            labeledValue("CLI", viewModel.environment.cliRelativePath)
                            labeledValue("Support Dir", viewModel.environment.supportDirectory)
                            Button("Refresh Auth Status") {
                                Task { await viewModel.refreshAuthStatus() }
                            }
                            .disabled(viewModel.isRunning)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Authenticated Channel") {
                        VStack(alignment: .leading, spacing: 10) {
                            labeledValue("Status", viewModel.authStatus.status)
                            labeledValue("Channel", viewModel.authStatus.channelTitle)
                            labeledValue("Handle", viewModel.authStatus.channelHandle)
                            labeledValue("Channel ID", viewModel.authStatus.channelID)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("YouTube Data API") {
                        youtubeQuotaStatusView
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Shared Metadata") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("These values act as templates. Use \"Apply Shared Values to Empty Fields\" to copy them only into blank video fields.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Apply Shared Values to Empty Fields") {
                                viewModel.applyCommonMetadataToEmptyFields()
                            }
                            .disabled(viewModel.isRunning || viewModel.drafts.isEmpty)

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Required Fields")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.red)
                                historyBackedSingleValueField(
                                    "Location",
                                    text: $viewModel.commonMetadata.place,
                                    options: viewModel.historicalOptions.places,
                                    onSelect: viewModel.selectCommonPlace
                                )
                                historyBackedSingleValueField(
                                    "Event",
                                    text: $viewModel.commonMetadata.eventName,
                                    options: viewModel.historicalOptions.eventNames,
                                    onSelect: viewModel.selectCommonEventName
                                )
                                historyBackedSingleValueField(
                                    "Playlist",
                                    text: $viewModel.commonMetadata.playlistsText,
                                    options: viewModel.historicalOptions.playlists,
                                    onSelect: viewModel.selectCommonPlaylist
                                )
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.red.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.red.opacity(0.7), lineWidth: 2)
                            )

                            participantSelectionField
                            historyBackedSingleValueField(
                                "Camera",
                                text: $viewModel.commonMetadata.cameraModel,
                                options: viewModel.historicalOptions.cameraModels,
                                onSelect: viewModel.selectCommonCameraModel
                            )
                            sidebarTextField("Library Name", text: $viewModel.commonMetadata.libraryName)
                            sidebarTextField("Timezone", text: $viewModel.commonMetadata.timezone)
                            sidebarTextField("OffsetTimeOriginal", text: $viewModel.commonMetadata.offsetTimeOriginal)
                            sidebarPicker("Video Visibility", selection: $viewModel.commonMetadata.privacyStatus)
                            sidebarPicker("Playlist Visibility", selection: $viewModel.commonMetadata.playlistPrivacyStatus)
                            sidebarTextField("Notes", text: $viewModel.commonMetadata.note, axis: .vertical, lineLimit: 3...6)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 290, ideal: 340)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    Picker("Screen", selection: $selectedScreen) {
                        ForEach(AppScreen.allCases) { screen in
                            Text(screen.rawValue).tag(screen)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedScreen) {
                        guard viewModel.currentScreen != selectedScreen else { return }
                        DispatchQueue.main.async {
                            viewModel.currentScreen = selectedScreen
                        }
                    }

                    if selectedScreen == .uploader {
                        uploadedVideoList
                        videoList
                        actionBar
                        if !viewModel.lastError.isEmpty {
                            Text(viewModel.lastError)
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                        if !viewModel.verificationReports.isEmpty {
                            verificationSection
                        }
                        logSection
                    } else if selectedScreen == .photos {
                        photoLibraryScreen
                    } else if selectedScreen == .historyCalendar {
                        historyCalendarScreen
                    } else {
                        uploadHistoryScreen
                    }
                }
                .padding(20)
            }
        }
        .task {
            await viewModel.autoRefreshAuthStatusIfNeeded()
        }
        .alert(
            "You Still Have Pending Drafts",
            isPresented: $showExitConfirmation,
            actions: {
                Button("Cancel", role: .cancel) {}
                Button("Quit", role: .destructive) {
                    confirmAppTermination()
                }
            },
            message: {
                Text("Some videos are still queued for upload. Do you want to quit anyway?")
            }
        )
        .alert(item: $viewModel.pendingHistoryDeletionMode) { _ in
            Alert(
                title: Text("Delete History?"),
                message: Text(historyDeletionConfirmationMessage),
                primaryButton: .destructive(Text("Delete")) {
                    Task { await viewModel.deleteSelectedHistoryEntriesConfirmed() }
                },
                secondaryButton: .cancel {
                    viewModel.cancelPendingHistoryDeletion()
                }
            )
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("iPhoto2YouTube")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                Text("Select local videos and use the existing Python CLI to upload them in batches.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add Videos") {
                viewModel.chooseVideos()
            }
            .disabled(viewModel.isRunning)
            Button("Clear All") {
                viewModel.clearDrafts()
            }
            .disabled(viewModel.isRunning || viewModel.drafts.isEmpty)
            Button("Quit") {
                requestAppTermination()
            }
        }
    }

    private func requestAppTermination() {
        if viewModel.drafts.isEmpty {
            confirmAppTermination()
            return
        }
        showExitConfirmation = true
    }

    private func confirmAppTermination() {
        NSApplication.shared.terminate(nil)
    }

    private var participantSelectionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Participants")
                .font(.caption)
                .foregroundStyle(.secondary)

            BufferedTextField(
                "Participants (manual entry allowed)",
                text: $viewModel.commonMetadata.participantsText
            )

            Menu("Add or Remove from History") {
                if viewModel.historicalOptions.participantNames.isEmpty {
                    Text("No history")
                } else {
                    ForEach(viewModel.historicalOptions.participantNames, id: \.self) { name in
                        Button {
                            viewModel.toggleCommonParticipant(name)
                        } label: {
                            let selected = viewModel.participantSelection.contains(name)
                            Label(name, systemImage: selected ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }

            HStack {
                BufferedTextField("Add new participant", text: $viewModel.newParticipantName)
                Button("Add") {
                    viewModel.addNewParticipantToCommonMetadata()
                }
                .disabled(viewModel.newParticipantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !viewModel.participantSelection.isEmpty {
                Text("Selected: \(viewModel.participantSelection.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var videoList: some View {
        GroupBox("Upload Queue (\(viewModel.drafts.count))") {
            if viewModel.drafts.isEmpty {
                ContentUnavailableView(
                    "No Videos",
                    systemImage: "film",
                    description: Text("Use \"Add Videos\" to choose .mov or .mp4 files.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                VStack(spacing: 12) {
                    ForEach(viewModel.drafts) { draft in
                        DraftRow(draft: draft) {
                            viewModel.removeDraft(id: draft.id)
                        }
                    }
                }
            }
        }
    }

    private var uploadedVideoList: some View {
        GroupBox("Uploaded Videos (\(viewModel.uploadedVideos.count))") {
            if viewModel.uploadedVideos.isEmpty {
                ContentUnavailableView(
                    "No Uploaded Videos",
                    systemImage: "checkmark.circle",
                    description: Text("Completed uploads will appear here.")
                )
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.uploadedVideos) { record in
                        UploadedVideoRow(record: record)
                    }
                }
            }
        }
    }

    private var photoLibraryScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Photo Library Videos")
                    .font(.headline)
                Spacer()
                Text("Access: \(viewModel.photoLibraryAuthorizationStatus.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                DatePicker(
                    "Capture Date",
                    selection: $viewModel.selectedPhotoLibraryDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.compact)
                Button("Load") {
                    Task { await viewModel.loadPhotoLibraryVideos() }
                }
                .disabled(viewModel.isPhotoLibraryBusy)
                Button("Grant Access") {
                    Task { await viewModel.requestPhotoLibraryAuthorization() }
                }
                .disabled(viewModel.isPhotoLibraryBusy)
                Spacer()
            }
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 180), spacing: 12),
                    GridItem(.flexible(minimum: 180), spacing: 12),
                ],
                alignment: .leading,
                spacing: 12
            ) {
                Button("Select All") {
                    viewModel.requestPhotoLibraryAutoWorkflow()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    viewModel.isPhotoLibraryBusy ||
                    viewModel.isPhotoLibraryAutoRunning ||
                    viewModel.photoLibraryVideos.isEmpty
                )
                .alert(item: $viewModel.photoLibraryAutoConfirmation) { confirmation in
                    Alert(
                        title: Text(confirmation.title),
                        message: Text(confirmation.message),
                        primaryButton: .default(Text("Run")) {
                            viewModel.photoLibraryAutoConfirmation = nil
                            Task { await viewModel.runPhotoLibraryAutoWorkflow() }
                        },
                        secondaryButton: .cancel {
                            viewModel.photoLibraryAutoConfirmation = nil
                        }
                    )
                }

                Button("Upload Vlog") {
                    viewModel.applyVlogPhotoLibraryPreset()
                }
                .disabled(
                    viewModel.isPhotoLibraryBusy ||
                    viewModel.isPhotoLibraryAutoRunning ||
                    viewModel.photoLibraryVideos.isEmpty
                )

                Button("Upload Insta360") {
                    viewModel.applyPhotoLibraryPreset(
                        fileNamePrefix: "VID_",
                        cameraModel: "Insta360",
                        playlistName: "Insta360"
                    )
                }
                .disabled(
                    viewModel.isPhotoLibraryBusy ||
                    viewModel.isPhotoLibraryAutoRunning ||
                    viewModel.photoLibraryVideos.isEmpty
                )

                Button("Check Insta360") {
                    viewModel.selectPhotoLibraryVideos(fileNamePrefix: "VID_", label: "Insta360")
                }
                .disabled(
                    viewModel.isPhotoLibraryBusy ||
                    viewModel.isPhotoLibraryAutoRunning ||
                    viewModel.photoLibraryVideos.isEmpty
                )

                Button("Upload HoverX1") {
                    viewModel.applyPhotoLibraryPreset(
                        fileNamePrefix: "HOVER_",
                        cameraModel: "HoverX1",
                        playlistName: "HoverX1"
                    )
                }
                .disabled(
                    viewModel.isPhotoLibraryBusy ||
                    viewModel.isPhotoLibraryAutoRunning ||
                    viewModel.photoLibraryVideos.isEmpty
                )

                Button("Check HoverX1") {
                    viewModel.selectPhotoLibraryVideos(fileNamePrefix: "HOVER_", label: "HoverX1")
                }
                .disabled(
                    viewModel.isPhotoLibraryBusy ||
                    viewModel.isPhotoLibraryAutoRunning ||
                    viewModel.photoLibraryVideos.isEmpty
                )

                Button("ALL") {
                    viewModel.applyAllPhotoLibraryPresets()
                }
                .disabled(
                    viewModel.isPhotoLibraryBusy ||
                    viewModel.isPhotoLibraryAutoRunning ||
                    viewModel.photoLibraryVideos.isEmpty
                )

                Button("Delete Selected Videos from iPhoto") {
                    Task { await viewModel.deleteSelectedPhotoLibraryVideos() }
                }
                .disabled(
                    viewModel.isPhotoLibraryBusy ||
                    viewModel.isPhotoLibraryAutoRunning ||
                    viewModel.selectedPhotoLibraryVideoIDs.isEmpty
                )

                Button("Add Selected Videos to Upload Queue") {
                    viewModel.addSelectedPhotoLibraryVideosToDrafts()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    viewModel.isPhotoLibraryBusy ||
                    viewModel.isPhotoLibraryAutoRunning ||
                    viewModel.selectedPhotoLibraryVideoIDs.isEmpty
                )
            }
            if !viewModel.lastError.isEmpty {
                Text(viewModel.lastError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            GroupBox("Videos Captured on the Selected Date") {
                if viewModel.photoLibraryVideos.isEmpty {
                    ContentUnavailableView(
                        "No Videos",
                        systemImage: "photo.on.rectangle",
                        description: Text("Choose a date and click \"Load\" to show videos from the photo library.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    VStack(spacing: 10) {
                        ForEach(viewModel.photoLibraryVideos) { item in
                            PhotoLibraryVideoRow(
                                item: item,
                                isSelected: viewModel.selectedPhotoLibraryVideoIDs.contains(item.id),
                                isRunning: viewModel.isPhotoLibraryBusy,
                                onToggleSelection: { viewModel.togglePhotoLibraryVideoSelection(item.id) }
                            )
                        }
                    }
                }
            }
            logSection
        }
    }

    private var uploadHistoryScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(isHistorySearchActive
                     ? "Search Results"
                     : "Latest \(viewModel.historyDisplayLimit) History Entries")
                    .font(.headline)
                Spacer()
                Button("Delete History") {
                    viewModel.requestDeleteSelectedHistoryEntries(mode: .localOnly)
                }
                .disabled(viewModel.isRunning || viewModel.selectedHistoryVideoIDs.isEmpty)
                Button("Delete from YouTube + History") {
                    viewModel.requestDeleteSelectedHistoryEntries(mode: .remoteAndLocal)
                }
                .disabled(viewModel.isRunning || viewModel.selectedHistoryVideoIDs.isEmpty)
                Button("Refresh") {
                    Task { await viewModel.refreshUploadHistory() }
                }
                .disabled(viewModel.isRunning)
            }
            HStack {
                TextField("Search by filename, title, playlist, and more", text: $viewModel.historySearchQuery)
                    .textFieldStyle(.roundedBorder)
                Toggle("Capture Date", isOn: $viewModel.historyCaptureDateFilterEnabled)
                    .toggleStyle(.checkbox)
                    .onChange(of: viewModel.historyCaptureDateFilterEnabled) {
                        Task { await viewModel.applyHistorySearch() }
                    }
                DatePicker(
                    "",
                    selection: $viewModel.historyCaptureDateFilterDate,
                    displayedComponents: [.date]
                )
                .labelsHidden()
                .disabled(!viewModel.historyCaptureDateFilterEnabled)
                .onChange(of: viewModel.historyCaptureDateFilterDate) {
                    guard viewModel.historyCaptureDateFilterEnabled else { return }
                    Task { await viewModel.applyHistorySearch() }
                }
                Button("Search") {
                    Task { await viewModel.applyHistorySearch() }
                }
                .disabled(viewModel.isRunning)
                Button("Clear") {
                    viewModel.clearHistoryFilters()
                    Task { await viewModel.applyHistorySearch() }
                }
                .disabled(viewModel.isRunning || !isHistorySearchActive)
            }
            if !viewModel.lastError.isEmpty {
                Text(viewModel.lastError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            GroupBox("Previously Uploaded Videos") {
                if viewModel.uploadHistoryEntries.isEmpty {
                    ContentUnavailableView(
                        "No History",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("The latest 10 history entries are shown here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    VStack(spacing: 10) {
                        ForEach(viewModel.uploadHistoryEntries) { entry in
                            UploadHistoryRow(
                                entry: entry,
                                isSelected: viewModel.selectedHistoryVideoIDs.contains(entry.youtubeVideoID),
                                isRunning: viewModel.isRunning,
                                onToggleSelection: { viewModel.toggleHistorySelection(entry.youtubeVideoID) }
                            )
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Show 10 More") {
                            Task { await viewModel.loadMoreUploadHistory() }
                        }
                        .disabled(viewModel.uploadHistoryEntries.isEmpty)
                    }
                    .padding(.top, 8)
                }
            }
            GroupBox("Videos Deleted from iPhoto") {
                HStack {
                    Text("Category")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Category", selection: $viewModel.deletionHistoryCategoryFilter) {
                        ForEach(PhotoDeletionHistoryCategoryFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: viewModel.deletionHistoryCategoryFilter) {
                        Task { await viewModel.applyDeletionHistoryFilter() }
                    }
                    Spacer()
                    Text("Latest \(viewModel.deletionHistoryDisplayLimit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if viewModel.photoDeletionHistoryEntries.isEmpty {
                    ContentUnavailableView(
                        "No Deletion History",
                        systemImage: "trash",
                        description: Text("Deletion history for videos removed from iPhoto appears here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    VStack(spacing: 10) {
                        ForEach(viewModel.photoDeletionHistoryEntries) { entry in
                            PhotoDeletionHistoryRow(entry: entry)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Show 10 More") {
                            Task { await viewModel.loadMorePhotoDeletionHistory() }
                        }
                        .disabled(viewModel.photoDeletionHistoryEntries.isEmpty)
                    }
                    .padding(.top, 8)
                }
            }
            logSection
        }
    }

    private var isHistorySearchActive: Bool {
        !viewModel.historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.historyCaptureDateFilterEnabled
    }

    private var historyCalendarScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("History Calendar")
                    .font(.headline)
                Spacer()
                Button("Rebuild") {
                    Task { await viewModel.rebuildHistoryCalendarData() }
                }
                .disabled(viewModel.isRunning)
                Button("Refresh") {
                    Task { await viewModel.refreshHistoryCalendarData() }
                }
                .disabled(viewModel.isRunning)
            }

            GroupBox("Overall Totals") {
                VStack(alignment: .leading, spacing: 8) {
                    uploadCountLine("Uploads (All)", counts: viewModel.historyCalendarSnapshot.totalUploadCounts)
                    deletionCountLine("Deletions (All)", counts: viewModel.historyCalendarSnapshot.totalDeletionCounts)
                }
            }

            GroupBox("Monthly Calendar") {
                VStack(spacing: 10) {
                    HStack {
                        Button("Previous") {
                            viewModel.moveHistoryCalendarMonth(by: -1)
                        }
                        Text(viewModel.historyCalendarMonthTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                        Button("Next") {
                            viewModel.moveHistoryCalendarMonth(by: 1)
                        }
                    }

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(minimum: 20), spacing: 6), count: 7),
                        spacing: 6
                    ) {
                        ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { weekday in
                            Text(weekday)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(viewModel.historyCalendarDayItems) { item in
                            Button {
                                viewModel.selectHistoryCalendarDate(item.date)
                            } label: {
                                VStack(spacing: 4) {
                                    Text(item.dayNumberText)
                                        .font(.caption)
                                        .foregroundStyle(item.isInDisplayedMonth ? .primary : .secondary)
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(item.hasUploadMark ? Color.blue : Color.clear)
                                            .frame(width: 6, height: 6)
                                        Circle()
                                            .fill(item.hasDeletionMark ? Color.red : Color.clear)
                                            .frame(width: 6, height: 6)
                                    }
                                    .frame(height: 8)
                                    Text(item.isInDisplayedMonth ? item.memoText : "")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, minHeight: 10)
                                }
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(item.isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            GroupBox("Totals for \(viewModel.selectedCalendarDateLabel)") {
                VStack(alignment: .leading, spacing: 8) {
                    uploadCountLine("Uploads (Day)", counts: viewModel.selectedDateUploadCounts)
                    deletionCountLine("Deletions (Day)", counts: viewModel.selectedDateDeletionCounts)
                    Divider()
                    Text("Memo (up to 10 full-width characters)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HistoryCalendarMemoInlineEditor(
                        text: viewModel.selectedDateMemoText,
                        isRunning: viewModel.isRunning,
                        onSave: { viewModel.setSelectedDateMemo($0) }
                    )
                    .id(viewModel.selectedCalendarDateLabel)
                    Text("Manual Adjustments")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    uploadAdjustmentEditor
                    deletionAdjustmentEditor
                }
            }

            HStack(spacing: 10) {
                Button(viewModel.isManualUploadMarkEnabledForSelectedDate ? "Remove Upload Day Mark" : "Mark as Upload Day") {
                    viewModel.toggleManualUploadMarkForSelectedDate()
                }

                Button(viewModel.isManualDeletionMarkEnabledForSelectedDate ? "Remove Deletion Day Mark" : "Mark as Deletion Day") {
                    viewModel.toggleManualDeletionMarkForSelectedDate()
                }
            }

            if !viewModel.lastError.isEmpty {
                Text(viewModel.lastError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            logSection
        }
    }

    private func uploadCountLine(_ title: String, counts: UploadCategoryCounts) -> some View {
        Text("\(title): Vlog \(counts.vlog) / Insta360 \(counts.insta360) / HoverX1 \(counts.hoverX1) / Other \(counts.other) / Total \(counts.total)")
            .font(.subheadline)
    }

    private func deletionCountLine(_ title: String, counts: DeletionCategoryCounts) -> some View {
        Text("\(title): Insta360 \(counts.insta360) / HoverX1 \(counts.hoverX1) / Other \(counts.other) / Total \(counts.total)")
            .font(.subheadline)
    }

    private var uploadAdjustmentEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper(value: uploadCountBinding("vlog"), in: 0...9_999) {
                Text("Uploads Vlog: \(viewModel.selectedDateUploadCounts.vlog)")
            }
            Stepper(value: uploadCountBinding("insta360"), in: 0...9_999) {
                Text("Uploads Insta360: \(viewModel.selectedDateUploadCounts.insta360)")
            }
            Stepper(value: uploadCountBinding("hoverX1"), in: 0...9_999) {
                Text("Uploads HoverX1: \(viewModel.selectedDateUploadCounts.hoverX1)")
            }
            Stepper(value: uploadCountBinding("other"), in: 0...9_999) {
                Text("Uploads Other: \(viewModel.selectedDateUploadCounts.other)")
            }
        }
    }

    private var deletionAdjustmentEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper(value: deletionCountBinding("insta360"), in: 0...9_999) {
                Text("Deleted Videos Insta360: \(viewModel.selectedDateDeletionCounts.insta360)")
            }
            Stepper(value: deletionCountBinding("hoverX1"), in: 0...9_999) {
                Text("Deleted Videos HoverX1: \(viewModel.selectedDateDeletionCounts.hoverX1)")
            }
            Stepper(value: deletionCountBinding("other"), in: 0...9_999) {
                Text("Deleted Videos Other: \(viewModel.selectedDateDeletionCounts.other)")
            }
        }
    }

    private func uploadCountBinding(_ category: String) -> Binding<Int> {
        Binding(
            get: {
                switch category {
                case "vlog":
                    return viewModel.selectedDateUploadCounts.vlog
                case "insta360":
                    return viewModel.selectedDateUploadCounts.insta360
                case "hoverX1":
                    return viewModel.selectedDateUploadCounts.hoverX1
                default:
                    return viewModel.selectedDateUploadCounts.other
                }
            },
            set: { newValue in
                viewModel.setSelectedDateUploadCount(newValue, category: category)
            }
        )
    }

    private func deletionCountBinding(_ category: String) -> Binding<Int> {
        Binding(
            get: {
                switch category {
                case "insta360":
                    return viewModel.selectedDateDeletionCounts.insta360
                case "hoverX1":
                    return viewModel.selectedDateDeletionCounts.hoverX1
                default:
                    return viewModel.selectedDateDeletionCounts.other
                }
            },
            set: { newValue in
                viewModel.setSelectedDateDeletionCount(newValue, category: category)
            }
        )
    }

    private var actionBar: some View {
        HStack {
            Button("Dry Run") {
                Task { await viewModel.runBatchUpload(dryRun: true) }
            }
            .disabled(viewModel.isRunning || viewModel.drafts.isEmpty)

            Button("Upload") {
                viewModel.requestUploadConfirmation()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isRunning || viewModel.drafts.isEmpty)
            .alert(item: $viewModel.uploadConfirmation) { confirmation in
                Alert(
                    title: Text(confirmation.title),
                    message: Text(confirmation.message),
                    primaryButton: .default(Text("Upload")) {
                        viewModel.uploadConfirmation = nil
                        Task { await viewModel.runBatchUpload(dryRun: false) }
                    },
                    secondaryButton: .cancel {
                        viewModel.uploadConfirmation = nil
                    }
                )
            }

            if viewModel.isRunning {
                ProgressView()
            }
            Spacer()
        }
    }

    private var historyDeletionConfirmationMessage: String {
        let count = viewModel.selectedHistoryVideoIDs.count
        switch viewModel.pendingHistoryDeletionMode {
        case .localOnly:
            return "Delete the selected \(count) item(s) from local history only. Videos on YouTube will be kept."
        case .remoteAndLocal:
            return "Delete the selected \(count) item(s) from both YouTube and local history."
        case nil:
            return ""
        }
    }

    private var logSection: some View {
        GroupBox("Activity Log") {
            TextEditor(text: $viewModel.logOutput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
        }
    }

    private var verificationSection: some View {
        GroupBox("Upload Verification") {
            VerificationReportList(
                reports: viewModel.verificationReports,
                isRunning: viewModel.isRunning,
                onResolve: { videoID in
                    Task { await viewModel.syncVerificationReport(for: videoID) }
                }
            )
        }
    }

    private var youtubeQuotaStatusView: some View {
        let quota = viewModel.authStatus.youtubeAPIQuota
        let accentColor: Color = {
            switch quota.accentColorName {
            case "red":
                return .red
            case "orange":
                return .orange
            default:
                return .blue
            }
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Queries per Day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(quota.percentText)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(accentColor)
                }
                Spacer()
                Text(quota.summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(quota.used), total: Double(max(quota.limit, 1)))
                .tint(accentColor)

            HStack {
                labeledMetric("Used", quota.used.formatted())
                Spacer()
                labeledMetric("Limit", quota.limit.formatted())
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                labeledMetric("Remaining", quota.remaining.formatted())
                Spacer()
                Text(
                    quota.windowEndText.isEmpty
                    ? "Resets \(quota.date.isEmpty ? "Today" : quota.date)"
                    : "Resets \(quota.windowEndText)"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)

            if let topOperation = quota.topOperations.first {
                Text("Primary driver: \(topOperation.operation) (\(topOperation.used))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .textSelection(.enabled)
        }
    }

    private func labeledMetric(_ label: String, _ value: String) -> some View {
        Text("\(label) \(value)")
    }

    private func sidebarTextField(
        _ label: String,
        text: Binding<String>,
        axis: Axis = .horizontal,
        lineLimit: ClosedRange<Int>? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            BufferedTextField(label, text: text, axis: axis, lineLimit: lineLimit)
        }
    }

    private func sidebarPicker(_ label: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(label, selection: selection) {
                Text("private").tag("private")
                Text("unlisted").tag("unlisted")
                Text("public").tag("public")
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func historyBackedSingleValueField(
        _ label: String,
        text: Binding<String>,
        options: [String],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                BufferedTextField(label, text: text)
                Menu("History") {
                    if options.isEmpty {
                        Text("No history")
                    } else {
                        ForEach(options, id: \.self) { option in
                            Button(option) {
                                onSelect(option)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct BufferedTextField: View {
    let title: String
    @Binding var text: String
    let axis: Axis
    let lineLimit: ClosedRange<Int>?

    init(
        _ title: String,
        text: Binding<String>,
        axis: Axis = .horizontal,
        lineLimit: ClosedRange<Int>? = nil
    ) {
        self.title = title
        self._text = text
        self.axis = axis
        self.lineLimit = lineLimit
    }

    var body: some View {
        AppKitBufferedTextField(
            title: title,
            text: $text,
            allowsMultiline: axis == .vertical || (lineLimit?.upperBound ?? 1) > 1
        )
    }
}

private struct AppKitBufferedTextField: NSViewRepresentable {
    enum CommitMode {
        case immediate
        case deferred
    }

    let title: String
    @Binding var text: String
    let allowsMultiline: Bool
    let commitMode: CommitMode

    init(
        title: String,
        text: Binding<String>,
        allowsMultiline: Bool,
        commitMode: CommitMode = .deferred
    ) {
        self.title = title
        self._text = text
        self.allowsMultiline = allowsMultiline
        self.commitMode = commitMode
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, commitMode: commitMode)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = DebugTextField(string: text)
        textField.placeholderString = title
        textField.isBezeled = true
        textField.isBordered = true
        textField.bezelStyle = .roundedBezel
        textField.focusRingType = .default
        textField.isEditable = true
        textField.isSelectable = true
        textField.isEnabled = true
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.commitFromAction(_:))
        context.coordinator.textField = textField
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.placeholderString = title
        context.coordinator.text = $text
        context.coordinator.allowsMultiline = allowsMultiline
        context.coordinator.commitMode = commitMode
        if !context.coordinator.isEditing, nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        weak var textField: NSTextField?
        var isEditing = false
        var allowsMultiline = false
        var commitMode: CommitMode

        init(text: Binding<String>, commitMode: CommitMode) {
            self.text = text
            self.commitMode = commitMode
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            isEditing = true
        }

        func controlTextDidChange(_ obj: Notification) {
            if commitMode == .immediate {
                commit()
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isEditing = false
            commit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if allowsMultiline {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    control.window?.makeFirstResponder(nil)
                }
                commit()
                return true
            }
            return false
        }

        @objc
        func commitFromAction(_ sender: Any?) {
            commit()
        }

        private func commit() {
            guard let textField else { return }
            let currentValue = textField.stringValue
            guard text.wrappedValue != currentValue else { return }
            switch commitMode {
            case .immediate:
                text.wrappedValue = currentValue
            case .deferred:
                DispatchQueue.main.async { [text] in
                    if text.wrappedValue != currentValue {
                        text.wrappedValue = currentValue
                    }
                }
            }
        }
    }
}

private final class DebugTextField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        window?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        return super.becomeFirstResponder()
    }
}

private struct HistoryCalendarMemoInlineEditor: View {
    let text: String
    let isRunning: Bool
    let onSave: (String) -> Void

    @State private var draftText: String

    init(
        text: String,
        isRunning: Bool,
        onSave: @escaping (String) -> Void
    ) {
        self.text = text
        self.isRunning = isRunning
        self.onSave = onSave
        _draftText = State(initialValue: HistoryCalendarDateSupport.sanitizedMemoText(text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AppKitBufferedTextField(
                    title: "Up to 10 characters",
                    text: Binding(
                        get: { draftText },
                        set: { draftText = HistoryCalendarDateSupport.sanitizedMemoText($0) }
                    ),
                    allowsMultiline: false,
                    commitMode: .immediate
                )
                Button("Save") {
                    save()
                }
                .disabled(isRunning)
            }
            Text("\(draftText.count)/10")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: text) {
            let sanitized = HistoryCalendarDateSupport.sanitizedMemoText(text)
            if draftText != sanitized {
                draftText = sanitized
            }
        }
    }

    private func save() {
        onSave(HistoryCalendarDateSupport.sanitizedMemoText(draftText))
    }
}

private struct VerificationReportList: View {
    let reports: [UploadVerificationReport]
    let isRunning: Bool
    let onResolve: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(reports.enumerated()), id: \.element.id) { index, report in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(report.title.isEmpty ? report.youtubeVideoID : report.title)
                            .font(.headline)
                        Spacer()
                        Text(report.mismatchCount == 0 ? "match" : "mismatch \(report.mismatchCount)")
                            .foregroundStyle(report.mismatchCount == 0 ? .green : .orange)
                    }
                    Text("Video ID: \(report.youtubeVideoID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Channel: \(report.channelTitle) / Privacy: \(report.privacyStatus) / Processing: \(report.processingStatus)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !report.playlistTitles.isEmpty {
                        Text("Playlists: \(report.playlistTitles.joined(separator: ", "))")
                            .font(.caption)
                    }
                    if report.mismatchCount > 0 {
                        Button("Resolve Mismatch") {
                            onResolve(report.youtubeVideoID)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunning)
                    }
                    if !report.comparisons.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(report.comparisons.enumerated()), id: \.element.id) { _, comparison in
                                VerificationComparisonRow(comparison: comparison)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                if index < reports.count - 1 {
                    Divider()
                }
            }
        }
    }

}

private struct UploadedVideoRow: View {
    let record: UploadedVideoRecord
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                detailLine("Title", record.title)
                detailLine("Video ID", record.youtubeVideoID)
                if !record.youtubeVideoURL.isEmpty {
                    detailLine("URL", record.youtubeVideoURL)
                }
                detailLine("Status", record.status)
                if !record.reason.isEmpty {
                    detailLine("Reason", record.reason)
                }
                detailLine("Captured At", DateFormatter.batchManifestFormatter.string(from: record.metadata.captureDate))
                detailLine("Location", record.metadata.place)
                detailLine("Event", record.metadata.eventName)
                detailLine("Content", record.metadata.content)
                detailLine("Participants", record.metadata.participantsText)
                detailLine("Camera", record.metadata.cameraModel)
                detailLine("Playlist", record.metadata.playlistsText)
                detailLine("Notes", record.metadata.note)
                if let report = record.verificationReport {
                    Divider()
                    Text(report.mismatchCount == 0 ? "Verification: match" : "Verification: mismatch \(report.mismatchCount)")
                        .font(.caption)
                        .foregroundStyle(report.mismatchCount == 0 ? .green : .orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            HStack {
                Text(record.fileName)
                    .font(.subheadline)
                Spacer()
                if let report = record.verificationReport {
                    Text(report.mismatchCount == 0 ? "match" : "mismatch \(report.mismatchCount)")
                        .font(.caption)
                        .foregroundStyle(report.mismatchCount == 0 ? .green : .orange)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct UploadHistoryRow: View {
    let entry: UploadHistoryEntry
    let isSelected: Bool
    let isRunning: Bool
    let onToggleSelection: () -> Void
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                detailLine("Title", entry.title)
                detailLine("Capture Date", entry.captureDateDisplayText)
                detailLine("Video ID", entry.youtubeVideoID)
                detailLine("URL", entry.youtubeVideoURL)
                detailLine("Uploaded At", entry.uploadedAt)
                detailLine("Status", entry.uploadStatus)
                detailLine("Location", entry.place)
                detailLine("Event", entry.eventName)
                detailLine("Content", entry.content)
                detailLine("Participants", entry.participantsText)
                detailLine("Camera", entry.cameraModel)
                detailLine("Playlist", entry.playlistsText)
                detailLine("File Path", entry.videoPath)
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Button(action: onToggleSelection) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                }
                .buttonStyle(.plain)
                .disabled(isRunning || entry.youtubeVideoID.isEmpty)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.fileName)
                        .font(.subheadline)
                    if !entry.captureDateDisplayText.isEmpty {
                        Text("Capture Date: \(entry.captureDateDisplayText)")
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    Text(summaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if !entry.captureDateDisplayText.isEmpty {
                        Text(entry.captureDateDisplayText)
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    Text(entry.uploadedAt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var summaryLine: String {
        let playlist = entry.playlistsText.isEmpty ? "No playlist" : entry.playlistsText
        let title = entry.title.isEmpty ? "Untitled" : entry.title
        return "\(playlist) / \(title)"
    }
}

private struct PhotoDeletionHistoryRow: View {
    let entry: PhotoDeletionHistoryEntry
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                detailLine("Capture Date", entry.captureDateDisplayText)
                detailLine("Deleted At", entry.deletedAtDisplayText)
                detailLine("Category", entry.category)
                detailLine("File Path", entry.filePath)
            }
            .padding(.top, 6)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.fileName)
                        .font(.subheadline)
                    Text("Capture Date: \(entry.captureDateDisplayText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(entry.category)
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(entry.deletedAtDisplayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct PhotoLibraryVideoRow: View {
    let item: PhotoLibraryVideoItem
    let isSelected: Bool
    let isRunning: Bool
    let onToggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleSelection) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
            thumbnailView
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .font(.subheadline)
                Text("Duration: \(item.durationText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(DateFormatter.batchManifestFormatter.string(from: item.captureDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.filePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let data = item.thumbnailPNGData,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.15))
                .frame(width: 120, height: 68)
                .overlay {
                    Image(systemName: "video")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

private struct VerificationComparisonRow: View {
    let comparison: UploadVerificationComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(comparison.field + ": " + comparison.status)
                .font(.caption2)
                .foregroundColor(comparison.status == "match" ? .secondary : .orange)
            if comparison.isMismatch {
                Text("Expected: \(comparison.local.isEmpty ? "-" : comparison.local)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Actual: \(comparison.remote.isEmpty ? "-" : comparison.remote)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let tagDifference = comparison.tagDifference {
                    if !tagDifference.missing.isEmpty {
                        Text("Missing: \(tagDifference.missing.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if !tagDifference.extra.isEmpty {
                        Text("Extra: \(tagDifference.extra.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

private struct DraftRow: View {
    @ObservedObject var draft: VideoDraft
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(URL(fileURLWithPath: draft.filePath).lastPathComponent)
                        .font(.headline)
                    Text(draft.filePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Remove", role: .destructive, action: onRemove)
            }

            HStack {
                DatePicker(
                    "Capture Time",
                    selection: Binding(
                        get: { draft.captureDate },
                        set: { draft.captureDate = $0 }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                TextField(
                    "Content",
                    text: Binding(get: { draft.content }, set: { draft.content = $0 })
                )
                .textFieldStyle(.roundedBorder)
            }

            HStack {
                TextField("Location", text: Binding(get: { draft.place }, set: { draft.place = $0 }))
                    .textFieldStyle(.roundedBorder)
                TextField("Event", text: Binding(get: { draft.eventName }, set: { draft.eventName = $0 }))
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                TextField("Participants", text: Binding(get: { draft.participantsText }, set: { draft.participantsText = $0 }))
                    .textFieldStyle(.roundedBorder)
                TextField("Camera", text: Binding(get: { draft.cameraModel }, set: { draft.cameraModel = $0 }))
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                TextField("Playlist", text: Binding(get: { draft.playlistsText }, set: { draft.playlistsText = $0 }))
                    .textFieldStyle(.roundedBorder)
                TextField("Notes", text: Binding(get: { draft.note }, set: { draft.note = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
