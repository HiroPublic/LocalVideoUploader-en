import XCTest
@testable import iPhoto2YouTubeNativeApp
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class BatchUploadManifestBuilderTests: XCTestCase {
    @MainActor
    func testEncodedManifestContainsDefaultsAndVideos() throws {
        let draft = VideoDraft(
            filePath: "/tmp/movie.mov",
            captureDate: Date(timeIntervalSince1970: 0),
            content: "花見",
            customTitle: "手動タイトル",
            customDescription: "手動説明"
        )
        var common = CommonMetadata()
        common.place = "砧公園"
        common.eventName = "花見"
        common.participantsText = "Alice, Bob"
        common.playlistsText = "[散歩] 自宅_花見"

        let data = try BatchUploadManifestBuilder.encodedManifestData(drafts: [draft], common: common)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let defaults = json?["defaults"] as? [String: Any]
        let videos = json?["videos"] as? [[String: Any]]

        XCTAssertEqual(defaults?["place"] as? String, "砧公園")
        XCTAssertEqual(defaults?["event_name"] as? String, "花見")
        XCTAssertEqual((defaults?["participants"] as? [String]) ?? [], ["Alice", "Bob"])
        XCTAssertEqual(videos?.count, 1)
        XCTAssertEqual(videos?.first?["content"] as? String, "花見")
        XCTAssertEqual(videos?.first?["title"] as? String, "手動タイトル")
        XCTAssertEqual(videos?.first?["description"] as? String, "手動説明")
    }

    func testBatchUploadResponseParsing() {
        let json: [String: Any] = [
            "message": "batch_completed",
            "payload": [
                "summary": [
                    "total": 1,
                    "uploaded_count": 1,
                    "skipped_count": 0,
                    "failed_count": 0,
                ],
                "results": [
                    [
                        "video_path": "/tmp/movie.mov",
                        "status": "uploaded",
                        "title": "2026-04-07-JST_砧公園_花見_01",
                        "youtube_video_id": "abc123",
                        "youtube_video_url": "https://youtu.be/abc123",
                        "reason": "",
                    ]
                ],
                "csv_path": ".iphoto2youtube/ledger.csv",
            ],
        ]

        let response = BatchUploadResponse.from(jsonObject: json)

        XCTAssertEqual(response.summary.total, 1)
        XCTAssertEqual(response.summary.uploadedCount, 1)
        XCTAssertEqual(response.results.first?.youtubeVideoID, "abc123")
        XCTAssertEqual(response.csvPath, ".iphoto2youtube/ledger.csv")
    }

    func testUploadVerificationReportParsing() {
        let json: [String: Any] = [
            "message": "verify_upload",
            "payload": [
                "remote": [
                    "youtube_video_id": "abc123",
                    "title": "2026-04-07-JST_砧公園_花見_01",
                    "channel_title": "Sample Channel",
                    "privacy_status": "private",
                    "processing_status": "succeeded",
                    "playlists": [
                        ["title": "[散歩] 自宅_花見"]
                    ],
                ],
                "comparisons": [
                    [
                        "field": "title",
                        "status": "match",
                        "local": "A",
                        "remote": "A",
                    ],
                    [
                        "field": "tags",
                        "status": "mismatch",
                        "local": "x",
                        "remote": "y",
                    ],
                ],
            ],
        ]

        let report = UploadVerificationReport.from(jsonObject: json)

        XCTAssertEqual(report.youtubeVideoID, "abc123")
        XCTAssertEqual(report.playlistTitles, ["[散歩] 自宅_花見"])
        XCTAssertEqual(report.mismatchCount, 1)
    }

    func testLedgerSuggestionLoaderParsesUniqueValues() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let support = root.appendingPathComponent(".iphoto2youtube", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let csv = """
        video_url,youtube_video_id,title,effective_capture_date,effective_timezone,offset_time_original,file_size_bytes,duration_seconds,width,height,place,content,event_name,participants,camera_model,playlists,original_filename
        https://x,1,a,2026-04-08,JST,+09:00,1,1,1,1,砧公園,c,花見,"Alice, Bob",iPhone,[散歩] 自宅_花見,a.mov
        https://y,2,b,2026-04-08,JST,+09:00,1,1,1,1,代々木公園,c,散歩,"光弘　紀子",iPhone,[散歩] 自宅_花見,b.mov
        """
        try csv.write(to: support.appendingPathComponent("ledger.csv"), atomically: true, encoding: .utf8)

        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let options = LedgerSuggestionLoader.loadOptions(from: environment)

        XCTAssertEqual(options.places, ["代々木公園", "砧公園"])
        XCTAssertEqual(options.eventNames, ["散歩", "花見"])
        XCTAssertEqual(options.playlists, ["[散歩] 自宅_花見"])
        XCTAssertFalse(options.participantNames.contains("Alice"))
        XCTAssertFalse(options.participantNames.contains("Bob"))
        XCTAssertTrue(options.participantNames.contains("りえ"))
        XCTAssertTrue(options.participantNames.contains("まき"))
        XCTAssertTrue(options.participantNames.contains("幸司"))
        XCTAssertTrue(options.participantNames.contains("Indy"))
        XCTAssertTrue(options.participantNames.contains("大地"))
        XCTAssertTrue(options.participantNames.contains("伊吹"))
        XCTAssertTrue(options.participantNames.contains("光弘"))
        XCTAssertTrue(options.participantNames.contains("紀子"))
        XCTAssertEqual(options.cameraModels, ["EOS", "HoverX1", "Insta360", "iPhone"])
    }

    func testTitlePreviewBuilderIncludesEventName() {
        let title = TitlePreviewBuilder.buildTitle(
            captureDate: Date(timeIntervalSince1970: 0),
            timezone: "JST",
            place: "砧公園",
            eventName: "春の会",
            content: "花見"
        )

        XCTAssertEqual(title, "1970-01-01-JST_砧公園_春の会_花見")
    }

    func testTitlePreviewBuilderOmitsDuplicateContent() {
        let title = TitlePreviewBuilder.buildTitle(
            captureDate: Date(timeIntervalSince1970: 0),
            timezone: "JST",
            place: "砧公園",
            eventName: "花見",
            content: "花見"
        )

        XCTAssertEqual(title, "1970-01-01-JST_砧公園_花見")
    }

    func testUploadVerificationComparisonBuildsTagDifference() {
        let comparison = UploadVerificationComparison(
            field: "tags",
            status: "mismatch",
            local: "#砧公園, #花見, #光弘",
            remote: "#砧公園, #花見, #紀子"
        )

        XCTAssertEqual(comparison.tagDifference?.missing, ["#光弘"])
        XCTAssertEqual(comparison.tagDifference?.extra, ["#紀子"])
    }

    @MainActor
    func testRequestUploadConfirmationCreatesDialogState() {
        let viewModel = AppViewModel()
        viewModel.authStatus = ChannelStatus(
            status: "authenticated",
            channelID: "channel123",
            channelTitle: "Sample Channel",
            channelHandle: "@example_channel",
            tokenFile: "",
            credentialsFile: "",
            youtubeAPIQuota: .unknown
        )
        viewModel.commonMetadata.place = "鎌倉"
        viewModel.commonMetadata.eventName = "誕生日"
        viewModel.commonMetadata.playlistsText = "Insta360"
        viewModel.drafts = [
            VideoDraft(
                filePath: "/tmp/VID_0001.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                content: "海辺"
            ),
            VideoDraft(
                filePath: "/tmp/VID_0002.mp4",
                captureDate: Date(timeIntervalSince1970: 60),
                content: "夕方"
            ),
        ]

        viewModel.requestUploadConfirmation()

        XCTAssertEqual(viewModel.uploadConfirmation?.title, "Confirm Upload")
        XCTAssertTrue(viewModel.uploadConfirmation?.message.contains("Do you want to upload these videos?") == true)
        XCTAssertTrue(viewModel.uploadConfirmation?.message.contains("Channel: Sample Channel (@example_channel)") == true)
        XCTAssertTrue(viewModel.uploadConfirmation?.message.contains("Videos: 2") == true)
        XCTAssertTrue(viewModel.lastError.isEmpty)
    }

    @MainActor
    func testRequestUploadConfirmationRequiresDrafts() {
        let viewModel = AppViewModel()

        viewModel.requestUploadConfirmation()

        XCTAssertNil(viewModel.uploadConfirmation)
        XCTAssertEqual(viewModel.lastError, "No videos selected.")
    }

    @MainActor
    func testApplyVlogPhotoLibraryPresetUsesHistoryDropdownPlaylist() {
        let viewModel = AppViewModel()
        viewModel.historicalOptions.playlists = ["HoverX1", "Insta360", "[散歩] 自宅_花見"]
        viewModel.photoLibraryVideos = [
            PhotoLibraryVideoItem(
                id: "vlog",
                filePath: "/tmp/12345.mp4",
                fileName: "12345.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 61,
                durationText: "01:01",
                thumbnailPNGData: nil
            ),
            PhotoLibraryVideoItem(
                id: "short",
                filePath: "/tmp/short.mp4",
                fileName: "short.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 59,
                durationText: "00:59",
                thumbnailPNGData: nil
            ),
        ]

        viewModel.applyVlogPhotoLibraryPreset()

        XCTAssertEqual(viewModel.commonMetadata.cameraModel, "Vlog")
        XCTAssertEqual(viewModel.commonMetadata.playlistsText, "[散歩] 自宅_花見")
        XCTAssertEqual(viewModel.drafts.count, 1)
        XCTAssertEqual(viewModel.drafts.first?.cameraModel, "Vlog")
        XCTAssertEqual(viewModel.drafts.first?.playlistsText, "[散歩] 自宅_花見")
        XCTAssertEqual(URL(fileURLWithPath: viewModel.drafts.first?.filePath ?? "").lastPathComponent, "12345.mp4")
    }

    @MainActor
    func testApplyVlogPhotoLibraryPresetTreatsShortNumericMp4AsVlog() {
        let viewModel = AppViewModel()
        viewModel.historicalOptions.playlists = ["HoverX1", "Insta360", "[散歩] 自宅_花見"]
        viewModel.photoLibraryVideos = [
            PhotoLibraryVideoItem(
                id: "short-vlog",
                filePath: "/tmp/67890.mp4",
                fileName: "67890.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 12,
                durationText: "00:12",
                thumbnailPNGData: nil
            )
        ]

        viewModel.applyVlogPhotoLibraryPreset()

        XCTAssertEqual(viewModel.drafts.count, 1)
        XCTAssertEqual(viewModel.drafts.first?.cameraModel, "Vlog")
        XCTAssertEqual(viewModel.drafts.first?.playlistsText, "[散歩] 自宅_花見")
        XCTAssertEqual(URL(fileURLWithPath: viewModel.drafts.first?.filePath ?? "").lastPathComponent, "67890.mp4")
        XCTAssertTrue(viewModel.lastError.isEmpty)
    }

    @MainActor
    func testApplyVlogPhotoLibraryPresetRejectsNonNumericMp4() {
        let viewModel = AppViewModel()
        viewModel.historicalOptions.playlists = ["HoverX1", "Insta360", "[散歩] 自宅_花見"]
        viewModel.photoLibraryVideos = [
            PhotoLibraryVideoItem(
                id: "named-mp4",
                filePath: "/tmp/trip.mp4",
                fileName: "trip.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 120,
                durationText: "02:00",
                thumbnailPNGData: nil
            )
        ]

        viewModel.applyVlogPhotoLibraryPreset()

        XCTAssertTrue(viewModel.drafts.isEmpty)
        XCTAssertEqual(viewModel.lastError, "No .mp4 videos with numeric-only file names were found.")
    }

    @MainActor
    func testApplyAllPhotoLibraryPresetsAddsEachPresetInOrder() {
        let viewModel = AppViewModel()
        viewModel.historicalOptions.playlists = ["HoverX1", "Insta360", "[散歩] 自宅_花見"]
        viewModel.commonMetadata.playlistsText = "[散歩] 自宅_花見"
        viewModel.photoLibraryVideos = [
            PhotoLibraryVideoItem(
                id: "vlog",
                filePath: "/tmp/12345.mp4",
                fileName: "12345.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 61,
                durationText: "01:01",
                thumbnailPNGData: nil
            ),
            PhotoLibraryVideoItem(
                id: "hover",
                filePath: "/tmp/HOVER_0001.mp4",
                fileName: "HOVER_0001.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 30,
                durationText: "00:30",
                thumbnailPNGData: nil
            ),
            PhotoLibraryVideoItem(
                id: "insta",
                filePath: "/tmp/VID_0001.mp4",
                fileName: "VID_0001.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 30,
                durationText: "00:30",
                thumbnailPNGData: nil
            ),
        ]

        viewModel.applyAllPhotoLibraryPresets()

        XCTAssertEqual(viewModel.drafts.count, 3)
        XCTAssertEqual(
            viewModel.drafts.map(\.cameraModel),
            ["Vlog", "HoverX1", "Insta360"]
        )
        XCTAssertEqual(
            viewModel.drafts.map(\.playlistsText),
            ["[散歩] 自宅_花見", "HoverX1", "Insta360"]
        )
        XCTAssertEqual(viewModel.commonMetadata.cameraModel, "Vlog")
        XCTAssertEqual(viewModel.commonMetadata.playlistsText, "[散歩] 自宅_花見")
    }

    @MainActor
    func testApplyAllPhotoLibraryPresetsKeepsSharedPlaylistWhenOnlyInsta360Matches() {
        let viewModel = AppViewModel()
        viewModel.commonMetadata.playlistsText = "[散歩] 自宅_花見"
        viewModel.photoLibraryVideos = [
            PhotoLibraryVideoItem(
                id: "insta",
                filePath: "/tmp/VID_0001.mp4",
                fileName: "VID_0001.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 30,
                durationText: "00:30",
                thumbnailPNGData: nil
            )
        ]

        viewModel.applyAllPhotoLibraryPresets()

        XCTAssertEqual(viewModel.drafts.map(\.playlistsText), ["Insta360"])
        XCTAssertEqual(viewModel.commonMetadata.playlistsText, "[散歩] 自宅_花見")
    }

    @MainActor
    func testDeleteSelectedPhotoLibraryVideosRemovesItemsAndClearsSelection() async {
        let service = MockPhotoLibraryService()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(environment: environment, photoLibraryService: service)
        viewModel.photoLibraryVideos = [
            PhotoLibraryVideoItem(
                id: "delete-me",
                filePath: "/tmp/delete-me.mp4",
                fileName: "delete-me.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 10,
                durationText: "00:10",
                thumbnailPNGData: nil
            ),
            PhotoLibraryVideoItem(
                id: "keep-me",
                filePath: "/tmp/keep-me.mp4",
                fileName: "keep-me.mp4",
                captureDate: Date(timeIntervalSince1970: 1),
                durationSeconds: 20,
                durationText: "00:20",
                thumbnailPNGData: nil
            ),
        ]
        viewModel.selectedPhotoLibraryVideoIDs = ["delete-me"]
        service.fetchedVideos = [
            PhotoLibraryVideoItem(
                id: "keep-me",
                filePath: "/tmp/keep-me.mp4",
                fileName: "keep-me.mp4",
                captureDate: Date(timeIntervalSince1970: 1),
                durationSeconds: 20,
                durationText: "00:20",
                thumbnailPNGData: nil
            )
        ]

        await viewModel.deleteSelectedPhotoLibraryVideos()

        XCTAssertEqual(service.deletedIDs, [["delete-me"]])
        XCTAssertEqual(viewModel.photoLibraryVideos.map(\.id), ["keep-me"])
        XCTAssertTrue(viewModel.selectedPhotoLibraryVideoIDs.isEmpty)
        XCTAssertTrue(viewModel.logOutput.contains("Deleted videos from iPhoto: delete-me.mp4"))
        XCTAssertEqual(viewModel.historyCalendarSnapshot.totalDeletionCounts.total, 1)
        XCTAssertEqual(viewModel.photoDeletionHistoryEntries.count, 1)
        XCTAssertEqual(viewModel.photoDeletionHistoryEntries.first?.fileName, "delete-me.mp4")
        XCTAssertEqual(viewModel.photoDeletionHistoryEntries.first?.category, "Other")
        viewModel.selectHistoryCalendarDate(Date(timeIntervalSince1970: 0))
        XCTAssertEqual(viewModel.selectedDateDeletionCounts.other, 1)
    }

    @MainActor
    func testPhotoDeletionHistoryCanFilterByCategoryAndLoadMore() async {
        let service = MockPhotoLibraryService()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(environment: environment, photoLibraryService: service)

        viewModel.photoLibraryVideos = [
            PhotoLibraryVideoItem(
                id: "insta",
                filePath: "/tmp/VID_0001.mp4",
                fileName: "VID_0001.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 10,
                durationText: "00:10",
                thumbnailPNGData: nil
            ),
            PhotoLibraryVideoItem(
                id: "hover",
                filePath: "/tmp/HOVER_0001.mp4",
                fileName: "HOVER_0001.mp4",
                captureDate: Date(timeIntervalSince1970: 1),
                durationSeconds: 10,
                durationText: "00:10",
                thumbnailPNGData: nil
            ),
        ]
        viewModel.selectedPhotoLibraryVideoIDs = ["insta", "hover"]
        service.fetchedVideos = []

        await viewModel.deleteSelectedPhotoLibraryVideos()

        XCTAssertEqual(viewModel.photoDeletionHistoryEntries.count, 2)
        XCTAssertEqual(viewModel.photoDeletionHistoryEntries.map(\.category).sorted(), ["HoverX1", "Insta360"])

        viewModel.deletionHistoryCategoryFilter = .insta360
        await viewModel.applyDeletionHistoryFilter()
        XCTAssertEqual(viewModel.photoDeletionHistoryEntries.count, 1)
        XCTAssertEqual(viewModel.photoDeletionHistoryEntries.first?.category, "Insta360")

        viewModel.deletionHistoryCategoryFilter = .all
        await viewModel.applyDeletionHistoryFilter()
        XCTAssertEqual(viewModel.deletionHistoryDisplayLimit, 10)
        XCTAssertEqual(viewModel.photoDeletionHistoryEntries.count, 2)

        await viewModel.loadMorePhotoDeletionHistory()
        XCTAssertEqual(viewModel.deletionHistoryDisplayLimit, 20)
        XCTAssertEqual(viewModel.photoDeletionHistoryEntries.count, 2)
    }

    @MainActor
    func testPhotoLibraryAutoWorkflowRunsStepsInOrder() async {
        let service = MockPhotoLibraryService()
        let cliService = MockCLIService()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(environment: environment, cliService: cliService, photoLibraryService: service)
        viewModel.commonMetadata.place = "砧公園"
        viewModel.commonMetadata.eventName = "花見"
        viewModel.commonMetadata.playlistsText = "[散歩] 自宅_花見"

        let vlog = PhotoLibraryVideoItem(
            id: "vlog",
            filePath: "/tmp/12345.mp4",
            fileName: "12345.mp4",
            captureDate: Date(timeIntervalSince1970: 0),
            durationSeconds: 61,
            durationText: "01:01",
            thumbnailPNGData: nil
        )
        let insta = PhotoLibraryVideoItem(
            id: "insta",
            filePath: "/tmp/VID_0001.mp4",
            fileName: "VID_0001.mp4",
            captureDate: Date(timeIntervalSince1970: 1),
            durationSeconds: 30,
            durationText: "00:30",
            thumbnailPNGData: nil
        )
        let hover = PhotoLibraryVideoItem(
            id: "hover",
            filePath: "/tmp/HOVER_0001.mp4",
            fileName: "HOVER_0001.mp4",
            captureDate: Date(timeIntervalSince1970: 2),
            durationSeconds: 30,
            durationText: "00:30",
            thumbnailPNGData: nil
        )
        viewModel.photoLibraryVideos = [vlog, insta, hover]
        service.fetchedVideosResponses = [
            [vlog, hover],
            [vlog],
        ]
        cliService.batchUploadResults = [
            makeBatchUploadResponse(path: vlog.filePath, title: "vlog"),
            makeBatchUploadResponse(path: insta.filePath, title: "insta"),
            makeBatchUploadResponse(path: hover.filePath, title: "hover"),
        ]

        await viewModel.runPhotoLibraryAutoWorkflow()

        XCTAssertEqual(cliService.batchUploadCallCount, 3)
        XCTAssertTrue(viewModel.drafts.isEmpty)
        XCTAssertEqual(service.deletedIDs, [["insta"], ["hover"]])
        XCTAssertEqual(viewModel.photoLibraryVideos.map(\.id), ["vlog"])
        XCTAssertTrue(viewModel.lastError.isEmpty)
        XCTAssertFalse(viewModel.isPhotoLibraryAutoRunning)
        XCTAssertEqual(viewModel.uploadedVideos.map(\.filePath), [hover.filePath, insta.filePath, vlog.filePath])
        XCTAssertEqual(cliService.verifyUploadCallCount, 0)
        XCTAssertTrue(viewModel.logOutput.contains("Started Photo Auto."))
        XCTAssertTrue(viewModel.logOutput.contains("Completed Photo Auto."))
    }

    @MainActor
    func testRunBatchUploadDoesNotAutoVerifyUploadedVideos() async {
        let cliService = MockCLIService()
        cliService.refreshAuthStatusResult = ChannelStatus(
            status: "authenticated",
            channelID: "channel123",
            channelTitle: "Sample Channel",
            channelHandle: "@example_channel",
            tokenFile: "/tmp/token.json",
            credentialsFile: "/tmp/client_secret.json",
            youtubeAPIQuota: YouTubeAPIQuotaStatus(
                date: "2026-05-13",
                used: 100,
                limit: 50_000,
                remaining: 49_900,
                usageRatio: 0.002,
                isEstimated: true,
                windowStartText: "",
                windowEndText: "",
                windowLabel: "",
                topOperations: []
            )
        )
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(
            environment: environment,
            cliService: cliService,
            photoLibraryService: MockPhotoLibraryService()
        )
        viewModel.commonMetadata.place = "砧公園"
        viewModel.commonMetadata.eventName = "花見"
        viewModel.commonMetadata.playlistsText = "[散歩] 自宅_花見"
        viewModel.drafts = [
            VideoDraft(
                filePath: "/tmp/movie.mov",
                captureDate: Date(timeIntervalSince1970: 0),
                content: "花見"
            )
        ]
        cliService.batchUploadResults = [
            makeBatchUploadResponse(path: "/tmp/movie.mov", title: "uploaded")
        ]

        await viewModel.runBatchUpload(dryRun: false)

        XCTAssertEqual(cliService.verifyUploadCallCount, 0)
        XCTAssertEqual(cliService.refreshAuthStatusCallCount, 1)
        XCTAssertTrue(viewModel.verificationReports.isEmpty)
        XCTAssertEqual(viewModel.uploadedVideos.map(\.filePath), ["/tmp/movie.mov"])
        XCTAssertEqual(viewModel.authStatus.youtubeAPIQuota.used, 100)
    }

    @MainActor
    func testRunBatchUploadDryRunDoesNotRefreshAuthStatus() async {
        let cliService = MockCLIService()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(
            environment: environment,
            cliService: cliService,
            photoLibraryService: MockPhotoLibraryService()
        )
        viewModel.commonMetadata.place = "砧公園"
        viewModel.commonMetadata.eventName = "花見"
        viewModel.commonMetadata.playlistsText = "[散歩] 自宅_花見"
        viewModel.drafts = [
            VideoDraft(
                filePath: "/tmp/movie.mov",
                captureDate: Date(timeIntervalSince1970: 0),
                content: "花見"
            )
        ]
        cliService.batchUploadResults = [
            makeBatchUploadResponse(path: "/tmp/movie.mov", title: "uploaded")
        ]

        await viewModel.runBatchUpload(dryRun: true)

        XCTAssertEqual(cliService.refreshAuthStatusCallCount, 0)
    }

    @MainActor
    func testRequestPhotoLibraryAutoWorkflowShowsConfirmation() {
        let viewModel = AppViewModel(cliService: MockCLIService(), photoLibraryService: MockPhotoLibraryService())
        viewModel.commonMetadata.place = "砧公園"
        viewModel.commonMetadata.eventName = "花見"
        viewModel.commonMetadata.playlistsText = "[散歩] 自宅_花見"
        viewModel.selectedPhotoLibraryDate = makeDate(year: 2026, month: 4, day: 7)
        viewModel.photoLibraryVideos = [
            PhotoLibraryVideoItem(
                id: "vlog",
                filePath: "/tmp/12345.mp4",
                fileName: "12345.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 15,
                durationText: "00:15",
                thumbnailPNGData: nil
            )
        ]

        viewModel.requestPhotoLibraryAutoWorkflow()

        XCTAssertEqual(viewModel.photoLibraryAutoConfirmation?.title, "Run Photo Auto?")
        XCTAssertTrue(viewModel.photoLibraryAutoConfirmation?.message.contains("Capture date: 2026-04-07") == true)
        XCTAssertTrue(viewModel.photoLibraryAutoConfirmation?.message.contains("Upload Vlog (.mp4)") == true)
        XCTAssertTrue(viewModel.photoLibraryAutoConfirmation?.message.contains("If an error occurs, the workflow stops at that point.") == true)
    }

    @MainActor
    func testRequestPhotoLibraryAutoWorkflowWithoutRequiredMetadataDoesNotShowConfirmation() {
        let viewModel = AppViewModel(cliService: MockCLIService(), photoLibraryService: MockPhotoLibraryService())
        viewModel.photoLibraryVideos = [
            PhotoLibraryVideoItem(
                id: "vlog",
                filePath: "/tmp/12345.mp4",
                fileName: "12345.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 61,
                durationText: "01:01",
                thumbnailPNGData: nil
            )
        ]

        viewModel.requestPhotoLibraryAutoWorkflow()

        XCTAssertNil(viewModel.photoLibraryAutoConfirmation)
        XCTAssertEqual(viewModel.lastError, "Enter the required field \"Location\" on the left before running Photo Auto.")
    }

    @MainActor
    func testPhotoLibraryAutoWorkflowTreatsNumericMp4AsVlogCandidate() async {
        let service = MockPhotoLibraryService()
        let cliService = MockCLIService()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(environment: environment, cliService: cliService, photoLibraryService: service)
        viewModel.commonMetadata.place = "砧公園"
        viewModel.commonMetadata.eventName = "花見"
        viewModel.commonMetadata.playlistsText = "[散歩] 自宅_花見"
        viewModel.photoLibraryVideos = [
            PhotoLibraryVideoItem(
                id: "vlog",
                filePath: "/tmp/12345.mp4",
                fileName: "12345.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 61,
                durationText: "01:01",
                thumbnailPNGData: nil
            )
        ]
        cliService.batchUploadResults = [
            makeBatchUploadResponse(path: "/tmp/12345.mp4", title: "vlog")
        ]

        await viewModel.runPhotoLibraryAutoWorkflow()

        XCTAssertEqual(cliService.batchUploadCallCount, 1)
        XCTAssertTrue(viewModel.drafts.isEmpty)
        XCTAssertTrue(viewModel.lastError.isEmpty)
        XCTAssertTrue(viewModel.logOutput.contains("Photo Auto: detected Vlog targets."))
    }

    @MainActor
    func testPhotoLibraryAutoWorkflowDoesNotTreatNumericMovAsVlogCandidate() async {
        let service = MockPhotoLibraryService()
        let cliService = MockCLIService()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(environment: environment, cliService: cliService, photoLibraryService: service)
        viewModel.commonMetadata.place = "砧公園"
        viewModel.commonMetadata.eventName = "花見"
        viewModel.commonMetadata.playlistsText = "[散歩] 自宅_花見"
        viewModel.photoLibraryVideos = [
            PhotoLibraryVideoItem(
                id: "movie",
                filePath: "/tmp/12345.mov",
                fileName: "12345.mov",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 61,
                durationText: "01:01",
                thumbnailPNGData: nil
            )
        ]

        viewModel.requestPhotoLibraryAutoWorkflow()
        await viewModel.runPhotoLibraryAutoWorkflow()

        XCTAssertFalse(viewModel.photoLibraryAutoConfirmation?.message.contains("Upload Vlog (.mp4)") ?? false)
        XCTAssertEqual(cliService.batchUploadCallCount, 0)
        XCTAssertTrue(viewModel.drafts.isEmpty)
        XCTAssertTrue(viewModel.lastError.isEmpty)
        XCTAssertFalse(viewModel.logOutput.contains("Photo Auto: detected Vlog targets."))
    }

    @MainActor
    func testPhotoLibraryAutoWorkflowStopsAtFirstError() async {
        let service = MockPhotoLibraryService()
        let cliService = MockCLIService()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(environment: environment, cliService: cliService, photoLibraryService: service)
        viewModel.commonMetadata.place = "砧公園"
        viewModel.commonMetadata.eventName = "花見"
        viewModel.commonMetadata.playlistsText = "[散歩] 自宅_花見"

        viewModel.photoLibraryVideos = [
            PhotoLibraryVideoItem(
                id: "vlog",
                filePath: "/tmp/12345.mp4",
                fileName: "12345.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 61,
                durationText: "01:01",
                thumbnailPNGData: nil
            ),
            PhotoLibraryVideoItem(
                id: "insta",
                filePath: "/tmp/VID_0001.mp4",
                fileName: "VID_0001.mp4",
                captureDate: Date(timeIntervalSince1970: 2),
                durationSeconds: 30,
                durationText: "00:30",
                thumbnailPNGData: nil
            ),
        ]
        cliService.batchUploadResults = [
            makeFailedBatchUploadResponse(path: "/tmp/12345.mp4", title: "vlog"),
        ]

        await viewModel.runPhotoLibraryAutoWorkflow()

        XCTAssertEqual(viewModel.drafts.map(\.filePath), ["/tmp/12345.mp4"])
        XCTAssertEqual(cliService.batchUploadCallCount, 1)
        XCTAssertEqual(service.deletedIDs, [])
        XCTAssertEqual(viewModel.lastError, "upload failed")
        XCTAssertTrue(viewModel.logOutput.contains("Photo Auto aborted: Upload Vlog"))
        XCTAssertFalse(viewModel.isPhotoLibraryAutoRunning)
    }

    @MainActor
    func testPhotoLibraryAutoWorkflowKeepsSharedPlaylistWhenInsta360Runs() async {
        let service = MockPhotoLibraryService()
        let cliService = MockCLIService()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(environment: environment, cliService: cliService, photoLibraryService: service)
        viewModel.commonMetadata.place = "太田"
        viewModel.commonMetadata.eventName = "滞在"
        viewModel.commonMetadata.playlistsText = "[散歩] 自宅_花見"
        viewModel.photoLibraryVideos = [
            PhotoLibraryVideoItem(
                id: "insta",
                filePath: "/tmp/VID_0001.mp4",
                fileName: "VID_0001.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 30,
                durationText: "00:30",
                thumbnailPNGData: nil
            )
        ]
        cliService.batchUploadResults = [
            makeBatchUploadResponse(path: "/tmp/VID_0001.mp4", title: "insta360")
        ]
        service.fetchedVideos = []

        await viewModel.runPhotoLibraryAutoWorkflow()

        XCTAssertEqual(viewModel.commonMetadata.playlistsText, "[散歩] 自宅_花見")
        XCTAssertEqual(cliService.batchUploadCallCount, 1)
        XCTAssertEqual(service.deletedIDs, [["insta"]])
        XCTAssertTrue(viewModel.drafts.isEmpty)
        XCTAssertTrue(viewModel.lastError.isEmpty)
    }

    @MainActor
    func testHistoryCalendarRebuildUsesCaptureDateFromUploadHistory() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let support = root.appendingPathComponent(".iphoto2youtube", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try createUploadHistoryDB(
            at: support.appendingPathComponent("upload_history.db"),
            rows: [
                (
                    effectiveCaptureDate: "2026-04-07T14:32:10",
                    captureDate: "2026-04-07T14:32:10",
                    uploadedAt: "2026-04-08T11:12:43",
                    cameraModel: "Vlog",
                    uploadStatus: "success"
                )
            ]
        )

        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(environment: environment, photoLibraryService: MockPhotoLibraryService())

        await viewModel.refreshHistoryCalendarData()

        viewModel.selectHistoryCalendarDate(makeDate(year: 2026, month: 4, day: 7))
        XCTAssertEqual(viewModel.selectedDateUploadCounts.vlog, 1)
        viewModel.selectHistoryCalendarDate(makeDate(year: 2026, month: 4, day: 8))
        XCTAssertEqual(viewModel.selectedDateUploadCounts.total, 0)
    }

    @MainActor
    func testRequestPhotoLibraryAuthorizationDoesNotAutoLoadVideos() async {
        let service = MockPhotoLibraryService()
        service.authorizationStatusValue = .unknown
        service.requestAuthorizationResult = .granted
        service.fetchedVideos = [
            PhotoLibraryVideoItem(
                id: "video-1",
                filePath: "/tmp/video-1.mp4",
                fileName: "video-1.mp4",
                captureDate: Date(timeIntervalSince1970: 0),
                durationSeconds: 10,
                durationText: "00:10",
                thumbnailPNGData: nil
            )
        ]
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(environment: environment, photoLibraryService: service)

        await viewModel.requestPhotoLibraryAuthorization()

        XCTAssertEqual(viewModel.photoLibraryAuthorizationStatus, .granted)
        XCTAssertFalse(viewModel.isPhotoLibraryBusy)
        XCTAssertTrue(viewModel.photoLibraryVideos.isEmpty)
        XCTAssertEqual(service.fetchVideosCallCount, 0)
        XCTAssertTrue(viewModel.logOutput.contains("Photo library access granted. Select a date and click Load."))
    }

    @MainActor
    func testHistoryCalendarMemoPersistsAndIsLimitedToTenCharacters() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(environment: environment, photoLibraryService: MockPhotoLibraryService())

        let targetDate = makeDate(year: 2026, month: 4, day: 9)
        viewModel.selectHistoryCalendarDate(targetDate)
        viewModel.setSelectedDateMemo("あいうえおかきくけこさ")
        await viewModel.refreshHistoryCalendarData()

        XCTAssertEqual(viewModel.selectedDateMemoText, "あいうえおかきくけこ")
        let item = viewModel.historyCalendarDayItems.first { $0.dateKey == "2026-04-09" && $0.isInDisplayedMonth }
        XCTAssertEqual(item?.memoText, "あいうえおかきくけこ")
    }

    @MainActor
    func testHistoryCalendarMemoRemainsAfterSwitchingDates() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(environment: environment, photoLibraryService: MockPhotoLibraryService())

        let firstDate = makeDate(year: 2026, month: 4, day: 7)
        let secondDate = makeDate(year: 2026, month: 4, day: 8)

        viewModel.selectHistoryCalendarDate(firstDate)
        viewModel.setSelectedDateMemo("花見")

        viewModel.selectHistoryCalendarDate(secondDate)
        XCTAssertEqual(viewModel.selectedDateMemoText, "")

        viewModel.selectHistoryCalendarDate(firstDate)
        XCTAssertEqual(viewModel.selectedDateMemoText, "花見")

        await viewModel.refreshHistoryCalendarData()
        viewModel.selectHistoryCalendarDate(firstDate)
        XCTAssertEqual(viewModel.selectedDateMemoText, "花見")
    }

    @MainActor
    func testCommonMetadataValuesRemainAfterScreenSwitchAndRefresh() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(environment: environment, photoLibraryService: MockPhotoLibraryService())

        viewModel.commonMetadata.place = "太田"
        viewModel.commonMetadata.eventName = "花見"
        viewModel.commonMetadata.playlistsText = "[散歩] 自宅_花見"

        viewModel.currentScreen = .historyCalendar
        await viewModel.refreshHistoryCalendarData()
        viewModel.currentScreen = .uploader
        await viewModel.refreshUploadHistory(resetLimit: true)

        XCTAssertEqual(viewModel.commonMetadata.place, "太田")
        XCTAssertEqual(viewModel.commonMetadata.eventName, "花見")
        XCTAssertEqual(viewModel.commonMetadata.playlistsText, "[散歩] 自宅_花見")
    }

    @MainActor
    func testAutoRefreshStartsGoogleLoginWhenUnauthenticated() async throws {
        let cliService = MockCLIService()
        cliService.refreshAuthStatusResult = .unknown
        cliService.loginResult = ChannelStatus(
            status: "authenticated",
            channelID: "channel123",
            channelTitle: "Sample Channel",
            channelHandle: "@example_channel",
            tokenFile: "/tmp/token.json",
            credentialsFile: "/tmp/client_secret.json",
            youtubeAPIQuota: .unknown
        )

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let support = root.appendingPathComponent(".iphoto2youtube", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try "{}".write(to: support.appendingPathComponent("client_secret.json"), atomically: true, encoding: .utf8)

        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(
            environment: environment,
            cliService: cliService,
            photoLibraryService: MockPhotoLibraryService()
        )

        await viewModel.autoRefreshAuthStatusIfNeeded()

        XCTAssertEqual(cliService.refreshAuthStatusCallCount, 1)
        XCTAssertEqual(cliService.loginCallCount, 1)
        XCTAssertEqual(viewModel.authStatus.status, "authenticated")
        XCTAssertTrue(viewModel.logOutput.contains("Not authenticated. Starting Google sign-in. Complete the flow in your browser."))
        XCTAssertTrue(viewModel.logOutput.contains("Google sign-in completed: Sample Channel @example_channel"))
    }

    @MainActor
    func testAutoRefreshSkipsGoogleLoginWhenAlreadyAuthenticated() async throws {
        let cliService = MockCLIService()
        cliService.refreshAuthStatusResult = ChannelStatus(
            status: "authenticated",
            channelID: "channel123",
            channelTitle: "Sample Channel",
            channelHandle: "@example_channel",
            tokenFile: "/tmp/token.json",
            credentialsFile: "/tmp/client_secret.json",
            youtubeAPIQuota: .unknown
        )

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let support = root.appendingPathComponent(".iphoto2youtube", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try "{}".write(to: support.appendingPathComponent("client_secret.json"), atomically: true, encoding: .utf8)

        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(
            environment: environment,
            cliService: cliService,
            photoLibraryService: MockPhotoLibraryService()
        )

        await viewModel.autoRefreshAuthStatusIfNeeded()

        XCTAssertEqual(cliService.refreshAuthStatusCallCount, 1)
        XCTAssertEqual(cliService.loginCallCount, 0)
        XCTAssertFalse(viewModel.logOutput.contains("Not authenticated. Starting Google sign-in. Complete the flow in your browser."))
    }

    @MainActor
    func testLoadPhotoLibraryVideosLogsLimitedAccessHintWhenNoVideosFound() async {
        let service = MockPhotoLibraryService()
        service.authorizationStatusValue = .limited
        service.fetchedVideos = []

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = NativeAppEnvironment(
            workspaceRoot: root.path,
            cliRelativePath: ".venv/bin/iphoto2youtube",
            supportDirectory: ".iphoto2youtube"
        )
        let viewModel = AppViewModel(environment: environment, photoLibraryService: service)
        viewModel.photoLibraryAuthorizationStatus = .limited
        viewModel.selectedPhotoLibraryDate = makeDate(year: 2026, month: 4, day: 14)

        await viewModel.loadPhotoLibraryVideos()

        XCTAssertTrue(viewModel.logOutput.contains("Photo library load result: 2026-04-14 / 0 item(s)"))
        XCTAssertTrue(viewModel.logOutput.contains("Access is limited. The target videos may not be included in the allowed set."))
    }
}

private func createUploadHistoryDB(
    at url: URL,
    rows: [(effectiveCaptureDate: String, captureDate: String, uploadedAt: String, cameraModel: String, uploadStatus: String)]
) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
        let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite open failed"
        if let db { sqlite3_close(db) }
        XCTFail(message)
        return
    }
    defer { sqlite3_close(db) }

    let createSQL = """
    CREATE TABLE upload_history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      effective_capture_date TEXT,
      capture_date TEXT,
      uploaded_at TEXT NOT NULL,
      camera_model TEXT,
      upload_status TEXT NOT NULL
    );
    """
    XCTAssertEqual(sqlite3_exec(db, createSQL, nil, nil, nil), SQLITE_OK)

    var statement: OpaquePointer?
    XCTAssertEqual(
        sqlite3_prepare_v2(
            db,
            "INSERT INTO upload_history (effective_capture_date, capture_date, uploaded_at, camera_model, upload_status) VALUES (?, ?, ?, ?, ?)",
            -1,
            &statement,
            nil
        ),
        SQLITE_OK
    )
    defer { sqlite3_finalize(statement) }

    for row in rows {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, row.effectiveCaptureDate, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, row.captureDate, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, row.uploadedAt, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, row.cameraModel, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, row.uploadStatus, -1, sqliteTransient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }
}

private func makeDate(year: Int, month: Int, day: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.timeZone = TimeZone(identifier: "Asia/Tokyo")
    return Calendar(identifier: .gregorian).date(from: components) ?? Date()
}

private func makeBatchUploadResponse(path: String, title: String) -> BatchUploadResponse {
    BatchUploadResponse(
        summary: BatchUploadSummary(total: 1, uploadedCount: 1, skippedCount: 0, failedCount: 0),
        results: [
            BatchUploadItemResult(
                videoPath: path,
                status: "uploaded",
                title: title,
                youtubeVideoID: UUID().uuidString,
                youtubeVideoURL: "https://youtu.be/\(UUID().uuidString.prefix(8))",
                reason: ""
            )
        ],
        csvPath: ".iphoto2youtube/ledger.csv"
    )
}

private func makeFailedBatchUploadResponse(path: String, title: String) -> BatchUploadResponse {
    BatchUploadResponse(
        summary: BatchUploadSummary(total: 1, uploadedCount: 0, skippedCount: 0, failedCount: 1),
        results: [
            BatchUploadItemResult(
                videoPath: path,
                status: "failed",
                title: title,
                youtubeVideoID: "",
                youtubeVideoURL: "",
                reason: "upload failed"
            )
        ],
        csvPath: ".iphoto2youtube/ledger.csv"
    )
}

private final class MockPhotoLibraryService: PhotoLibraryServicing, @unchecked Sendable {
    var authorizationStatusValue: PhotoLibraryAuthorizationStatus = .granted
    var requestAuthorizationResult: PhotoLibraryAuthorizationStatus = .granted
    var deletedIDs: [[String]] = []
    var fetchedVideos: [PhotoLibraryVideoItem] = []
    var fetchedVideosResponses: [[PhotoLibraryVideoItem]] = []
    var fetchVideosCallCount = 0

    func authorizationStatus() -> PhotoLibraryAuthorizationStatus {
        authorizationStatusValue
    }

    func requestAuthorization() async -> PhotoLibraryAuthorizationStatus {
        requestAuthorizationResult
    }

    func fetchVideos(on targetDate: Date) async throws -> [PhotoLibraryVideoItem] {
        fetchVideosCallCount += 1
        if !fetchedVideosResponses.isEmpty {
            return fetchedVideosResponses.removeFirst()
        }
        return fetchedVideos
    }

    func deleteVideos(withIDs ids: [String]) async throws {
        deletedIDs.append(ids.sorted())
    }
}

private final class MockCLIService: CLIServicing, @unchecked Sendable {
    var batchUploadResults: [BatchUploadResponse] = []
    var batchUploadCallCount = 0
    var verifyUploadCallCount = 0
    var refreshAuthStatusCallCount = 0
    var fetchCurrentChannelCallCount = 0
    var loginCallCount = 0
    var refreshAuthStatusResult: ChannelStatus = .unknown
    var fetchCurrentChannelResult: ChannelStatus = .unknown
    var loginResult: ChannelStatus = .unknown

    func refreshAuthStatus(environment: NativeAppEnvironment) async throws -> ChannelStatus {
        refreshAuthStatusCallCount += 1
        return refreshAuthStatusResult
    }

    func fetchCurrentChannel(environment: NativeAppEnvironment) async throws -> ChannelStatus {
        fetchCurrentChannelCallCount += 1
        return fetchCurrentChannelResult
    }

    func login(environment: NativeAppEnvironment) async throws -> ChannelStatus {
        loginCallCount += 1
        return loginResult
    }

    func runBatchUpload(
        manifestURL: URL,
        dryRun: Bool,
        environment: NativeAppEnvironment
    ) async throws -> BatchUploadResponse {
        batchUploadCallCount += 1
        if !batchUploadResults.isEmpty {
            return batchUploadResults.removeFirst()
        }
        return BatchUploadResponse(
            summary: BatchUploadSummary(total: 0, uploadedCount: 0, skippedCount: 0, failedCount: 0),
            results: [],
            csvPath: ""
        )
    }

    func verifyUpload(
        youtubeVideoID: String,
        environment: NativeAppEnvironment
    ) async throws -> UploadVerificationReport {
        verifyUploadCallCount += 1
        return UploadVerificationReport(
            youtubeVideoID: youtubeVideoID,
            title: "",
            channelTitle: "",
            privacyStatus: "",
            processingStatus: "",
            playlistTitles: [],
            comparisons: []
        )
    }

    func syncUploadMetadata(
        youtubeVideoID: String,
        environment: NativeAppEnvironment
    ) async throws -> UploadVerificationReport {
        try await verifyUpload(youtubeVideoID: youtubeVideoID, environment: environment)
    }

    func fetchUploadHistory(
        limit: Int,
        query: String,
        captureDate: String,
        environment: NativeAppEnvironment
    ) async throws -> [UploadHistoryEntry] {
        []
    }

    func deleteLocalHistory(
        youtubeVideoID: String,
        environment: NativeAppEnvironment
    ) async throws {}

    func deleteUploadedVideo(
        youtubeVideoID: String,
        environment: NativeAppEnvironment
    ) async throws {}
}
