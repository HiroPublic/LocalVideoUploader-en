import Foundation

struct CLICommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum CLIServiceError: LocalizedError {
    case executableNotFound(String)
    case commandFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "CLI executable not found: \(path)"
        case .commandFailed(let message):
            return message
        case .invalidResponse(let message):
            return message
        }
    }
}

private struct CLILaunchConfiguration {
    let executableURL: URL
    let argumentsPrefix: [String]
    let environment: [String: String]
}

protocol CLIServicing: Sendable {
    func refreshAuthStatus(environment: NativeAppEnvironment) async throws -> ChannelStatus
    func fetchCurrentChannel(environment: NativeAppEnvironment) async throws -> ChannelStatus
    func login(environment: NativeAppEnvironment) async throws -> ChannelStatus
    func runBatchUpload(
        manifestURL: URL,
        dryRun: Bool,
        environment: NativeAppEnvironment
    ) async throws -> BatchUploadResponse
    func verifyUpload(
        youtubeVideoID: String,
        environment: NativeAppEnvironment
    ) async throws -> UploadVerificationReport
    func syncUploadMetadata(
        youtubeVideoID: String,
        environment: NativeAppEnvironment
    ) async throws -> UploadVerificationReport
    func fetchUploadHistory(
        limit: Int,
        query: String,
        captureDate: String,
        environment: NativeAppEnvironment
    ) async throws -> [UploadHistoryEntry]
    func deleteLocalHistory(
        youtubeVideoID: String,
        environment: NativeAppEnvironment
    ) async throws
    func deleteUploadedVideo(
        youtubeVideoID: String,
        environment: NativeAppEnvironment
    ) async throws
}

struct CLIService: CLIServicing {
    func refreshAuthStatus(environment: NativeAppEnvironment) async throws -> ChannelStatus {
        let decoded = try await runJSON(arguments: ["auth-status"], environment: environment)
        return channelStatus(from: decoded)
    }

    func fetchCurrentChannel(environment: NativeAppEnvironment) async throws -> ChannelStatus {
        let decoded = try await runJSON(arguments: ["current-channel"], environment: environment)
        return channelStatus(from: decoded)
    }

    func login(environment: NativeAppEnvironment) async throws -> ChannelStatus {
        let decoded = try await runJSON(arguments: ["auth-login"], environment: environment)
        return channelStatus(from: decoded)
    }

    private func channelStatus(from decoded: [String: Any]) -> ChannelStatus {
        let payload = decoded["payload"] as? [String: Any]
        let quotaPayload = payload?["youtube_api_quota"] as? [String: Any]
        let breakdown = quotaPayload?["breakdown"] as? [[String: Any]] ?? []
        return ChannelStatus(
            status: (payload?["status"] as? String) ?? (decoded["message"] as? String) ?? "unknown",
            channelID: payload?["channel_id"] as? String ?? "",
            channelTitle: payload?["channel_title"] as? String ?? "",
            channelHandle: payload?["channel_handle"] as? String ?? "",
            tokenFile: payload?["token_file"] as? String ?? "",
            credentialsFile: payload?["credentials_file"] as? String ?? "",
            youtubeAPIQuota: YouTubeAPIQuotaStatus(
                date: quotaPayload?["date"] as? String ?? "",
                used: quotaPayload?["used"] as? Int ?? 0,
                limit: quotaPayload?["limit"] as? Int ?? 10_000,
                remaining: quotaPayload?["remaining"] as? Int ?? 0,
                usageRatio: quotaPayload?["usage_ratio"] as? Double ?? 0,
                isEstimated: quotaPayload?["is_estimated"] as? Bool ?? true,
                windowStartText: quotaPayload?["window_start_text"] as? String ?? "",
                windowEndText: quotaPayload?["window_end_text"] as? String ?? "",
                windowLabel: quotaPayload?["window_label"] as? String ?? "",
                topOperations: breakdown.compactMap { item in
                    guard let operation = item["operation"] as? String else { return nil }
                    return YouTubeAPIQuotaOperation(
                        operation: operation,
                        used: item["used"] as? Int ?? 0
                    )
                }
            )
        )
    }

    func runBatchUpload(
        manifestURL: URL,
        dryRun: Bool,
        environment: NativeAppEnvironment
    ) async throws -> BatchUploadResponse {
        var arguments = [
            "batch-upload",
            "--manifest", manifestURL.path,
            "--yes",
            "--output", "json",
        ]
        if dryRun {
            arguments.append("--dry-run")
        }
        let decoded = try await runJSON(arguments: arguments, environment: environment)
        return BatchUploadResponse.from(jsonObject: decoded)
    }

    func verifyUpload(
        youtubeVideoID: String,
        environment: NativeAppEnvironment
    ) async throws -> UploadVerificationReport {
        let decoded = try await runJSON(
            arguments: ["verify-upload", "--youtube-video-id", youtubeVideoID, "--output", "json"],
            environment: environment
        )
        return UploadVerificationReport.from(jsonObject: decoded)
    }

    func syncUploadMetadata(
        youtubeVideoID: String,
        environment: NativeAppEnvironment
    ) async throws -> UploadVerificationReport {
        let decoded = try await runJSON(
            arguments: ["sync-upload-metadata", "--youtube-video-id", youtubeVideoID, "--output", "json"],
            environment: environment
        )
        return UploadVerificationReport.from(jsonObject: decoded)
    }

    func fetchUploadHistory(
        limit: Int,
        query: String,
        captureDate: String,
        environment: NativeAppEnvironment
    ) async throws -> [UploadHistoryEntry] {
        var arguments = ["history", "list", "--limit", String(limit), "--output", "json"]
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--query", query])
        }
        if !captureDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--capture-date", captureDate])
        }
        let decoded = try await runJSON(arguments: arguments, environment: environment)
        let payload = decoded["payload"] as? [String: Any] ?? [:]
        let results = payload["results"] as? [[String: Any]] ?? []
        return results.compactMap { item in
            guard let id = item["id"] as? Int else { return nil }
            return UploadHistoryEntry(
                id: id,
                youtubeVideoID: item["youtube_video_id"] as? String ?? "",
                youtubeVideoURL: item["youtube_video_url"] as? String ?? "",
                title: item["title"] as? String ?? "",
                videoPath: item["video_path"] as? String ?? "",
                captureDate: item["capture_date"] as? String ?? "",
                uploadedAt: item["uploaded_at"] as? String ?? "",
                place: item["place"] as? String ?? "",
                content: item["content"] as? String ?? "",
                eventName: item["event_name"] as? String ?? "",
                participantsText: item["participants"] as? String ?? "",
                cameraModel: item["camera_model"] as? String ?? "",
                playlistsText: item["playlists"] as? String ?? "",
                uploadStatus: item["upload_status"] as? String ?? ""
            )
        }
    }

    func deleteLocalHistory(
        youtubeVideoID: String,
        environment: NativeAppEnvironment
    ) async throws {
        _ = try await runJSON(
            arguments: ["delete-local-history", "--youtube-video-id", youtubeVideoID, "--output", "json"],
            environment: environment
        )
    }

    func deleteUploadedVideo(
        youtubeVideoID: String,
        environment: NativeAppEnvironment
    ) async throws {
        _ = try await runJSON(
            arguments: ["delete-uploaded-video", "--youtube-video-id", youtubeVideoID, "--output", "json"],
            environment: environment
        )
    }

    private func runBlocking(arguments: [String], environment: NativeAppEnvironment) throws -> CLICommandResult {
        let workspaceRoot = URL(fileURLWithPath: environment.workspaceRoot, isDirectory: true)
        let launchConfig = try resolveLaunchConfiguration(workspaceRoot: workspaceRoot, environment: environment)

        let process = Process()
        process.currentDirectoryURL = workspaceRoot
        process.executableURL = launchConfig.executableURL
        process.arguments = launchConfig.argumentsPrefix + ["--support-dir", environment.supportDirectory] + arguments
        process.environment = launchConfig.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CLICommandResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    private func resolveLaunchConfiguration(
        workspaceRoot: URL,
        environment: NativeAppEnvironment
    ) throws -> CLILaunchConfiguration {
        let fileManager = FileManager.default
        let cliURL = workspaceRoot.appendingPathComponent(environment.cliRelativePath)
        if fileManager.isExecutableFile(atPath: cliURL.path) {
            return CLILaunchConfiguration(
                executableURL: cliURL,
                argumentsPrefix: [],
                environment: ProcessInfo.processInfo.environment
            )
        }

        let sourcePackageURL = workspaceRoot.appendingPathComponent("src/iphoto2youtube_cli", isDirectory: true)
        if fileManager.fileExists(atPath: sourcePackageURL.path) {
            let pythonCandidates = [
                "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
                "/opt/anaconda3/bin/python3",
                "/opt/homebrew/bin/python3",
                "/usr/bin/python3",
            ]
            if let pythonPath = pythonCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
                var launchEnvironment = ProcessInfo.processInfo.environment
                let sourceRoot = workspaceRoot.appendingPathComponent("src", isDirectory: true).path
                let existing = launchEnvironment["PYTHONPATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                launchEnvironment["PYTHONPATH"] = {
                    guard let existing, !existing.isEmpty else { return sourceRoot }
                    return sourceRoot + ":" + existing
                }()
                return CLILaunchConfiguration(
                    executableURL: URL(fileURLWithPath: pythonPath),
                    argumentsPrefix: ["-m", "iphoto2youtube_cli"],
                    environment: launchEnvironment
                )
            }
        }

        throw CLIServiceError.executableNotFound(cliURL.path)
    }

    private func run(arguments: [String], environment: NativeAppEnvironment) async throws -> CLICommandResult {
        try await Task.detached(priority: .userInitiated) {
            try runBlocking(arguments: arguments, environment: environment)
        }.value
    }

    private func runJSON(arguments: [String], environment: NativeAppEnvironment) async throws -> [String: Any] {
        let result = try await run(arguments: arguments, environment: environment)
        guard result.exitCode == 0 else {
            let errorText = result.stderr.isEmpty ? result.stdout : result.stderr
            throw CLIServiceError.commandFailed(parseCommandFailureMessage(errorText))
        }
        let data = Data(result.stdout.utf8)
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIServiceError.invalidResponse("Failed to parse the CLI JSON response.")
        }
        return decoded
    }

    private func parseCommandFailureMessage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let payload = decoded["payload"] as? [String: Any],
           let message = payload["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let lastLine = trimmed.split(separator: "\n").last, !lastLine.isEmpty {
            return String(lastLine)
        }
        return trimmed.isEmpty ? "CLI execution failed." : trimmed
    }
}
