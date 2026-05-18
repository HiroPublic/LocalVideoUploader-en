import AppKit
import AVFoundation
import Foundation
import Photos

protocol PhotoLibraryServicing: Sendable {
    func authorizationStatus() -> PhotoLibraryAuthorizationStatus
    func requestAuthorization() async -> PhotoLibraryAuthorizationStatus
    func fetchVideos(on targetDate: Date) async throws -> PhotoLibraryFetchResult
    func deleteVideos(withIDs ids: [String]) async throws
    func photoLibraryCacheStatus() throws -> PhotoLibraryCacheStatus
    func clearPhotoLibraryCache() throws
}

struct PhotoLibraryVideoItem: Identifiable, Equatable {
    let id: String
    let filePath: String
    let fileName: String
    let captureDate: Date
    let durationSeconds: Int
    let durationText: String
    let thumbnailPNGData: Data?
}

struct PhotoLibraryFetchFailure: Equatable {
    let assetIdentifier: String
    let fileName: String
    let message: String
}

struct PhotoLibraryFetchResult: Equatable {
    let items: [PhotoLibraryVideoItem]
    let failures: [PhotoLibraryFetchFailure]
}

struct PhotoLibraryCacheStatus: Equatable {
    let fileCount: Int
    let totalBytes: Int64

    var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: totalBytes)
    }

    var summaryText: String {
        "\(fileCount) item(s) / \(sizeText)"
    }

    static let empty = PhotoLibraryCacheStatus(fileCount: 0, totalBytes: 0)
}

enum PhotoLibraryAuthorizationStatus: Equatable {
    case unknown
    case granted
    case denied
    case limited

    var description: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .granted:
            return "Granted"
        case .denied:
            return "Denied"
        case .limited:
            return "Limited"
        }
    }
}

enum PhotoLibraryServiceError: LocalizedError {
    case accessDenied
    case assetNotFound
    case assetExportFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access to the photo library has not been granted."
        case .assetNotFound:
            return "The photo or video to delete could not be found."
        case .assetExportFailed:
            return "Failed to export the video from the photo library."
        }
    }
}

struct PhotoLibraryService {
    func authorizationStatus() -> PhotoLibraryAuthorizationStatus {
        Self.mapAuthorizationStatus(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoLibraryAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return Self.mapAuthorizationStatus(status)
    }

    func fetchVideos(on targetDate: Date) async throws -> PhotoLibraryFetchResult {
        let status = authorizationStatus()
        guard status == .granted || status == .limited else {
            throw PhotoLibraryServiceError.accessDenied
        }

        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        guard let dayInterval = calendar.dateInterval(of: .day, for: targetDate) else {
            return PhotoLibraryFetchResult(items: [], failures: [])
        }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@",
            dayInterval.start as NSDate,
            dayInterval.end as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let assets = PHAsset.fetchAssets(with: options)
        var items: [PhotoLibraryVideoItem] = []
        var failures: [PhotoLibraryFetchFailure] = []
        for index in 0 ..< assets.count {
            let asset = assets.object(at: index)
            let resources = PHAssetResource.assetResources(for: asset)
            guard isVideoLikeAsset(asset, resources: resources) else { continue }

            let captureDate = asset.creationDate ?? asset.modificationDate ?? targetDate
            do {
                if let item = try await buildItem(from: asset, resources: resources, captureDate: captureDate) {
                    items.append(item)
                }
            } catch {
                let fileName = resources.first?.originalFilename ?? asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
                failures.append(
                    PhotoLibraryFetchFailure(
                        assetIdentifier: asset.localIdentifier,
                        fileName: fileName,
                        message: describeFetchError(error)
                    )
                )
            }
        }
        return PhotoLibraryFetchResult(items: items, failures: failures)
    }

    func deleteVideos(withIDs ids: [String]) async throws {
        let status = authorizationStatus()
        guard status == .granted || status == .limited else {
            throw PhotoLibraryServiceError.accessDenied
        }

        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: uniqueIDs, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        guard !assets.isEmpty else {
            throw PhotoLibraryServiceError.assetNotFound
        }
        let assetIdentifiers = assets.map(\.localIdentifier)
        try await performPhotoLibraryDeletion(assetIdentifiers: assetIdentifiers)
    }

    func photoLibraryCacheStatus() throws -> PhotoLibraryCacheStatus {
        let root = photoLibraryCacheDirectory()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else {
            return .empty
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        var fileCount = 0
        var totalBytes: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            fileCount += 1
            totalBytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }

        return PhotoLibraryCacheStatus(fileCount: fileCount, totalBytes: totalBytes)
    }

    func clearPhotoLibraryCache() throws {
        let root = photoLibraryCacheDirectory()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return }
        try fileManager.removeItem(at: root)
    }

    private func buildItem(
        from asset: PHAsset,
        resources: [PHAssetResource],
        captureDate: Date
    ) async throws -> PhotoLibraryVideoItem? {
        let fileName = resources.first?.originalFilename ?? asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        guard let fileURL = try await exportVideoToCache(for: asset, resources: resources, suggestedFileName: fileName) else {
            return nil
        }
        let thumbnailPNGData = await generateThumbnailPNGData(for: fileURL)
        return PhotoLibraryVideoItem(
            id: asset.localIdentifier,
            filePath: fileURL.path,
            fileName: fileName,
            captureDate: captureDate,
            durationSeconds: Int(asset.duration.rounded()),
            durationText: formatDuration(asset.duration),
            thumbnailPNGData: thumbnailPNGData
        )
    }

    private func describeFetchError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "CloudPhotoLibraryErrorDomain" && nsError.code == 1005 {
            return "Download from iCloud Photos was interrupted."
        }
        if nsError.domain == "PHPhotosErrorDomain" {
            return "Photos request failed (\(nsError.code))."
        }
        let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return localized.isEmpty ? "Unknown photo library error." : localized
    }

    private func exportVideoToCache(
        for asset: PHAsset,
        resources: [PHAssetResource],
        suggestedFileName: String
    ) async throws -> URL? {
        let exportURL = try makeCachedVideoURL(assetIdentifier: asset.localIdentifier, suggestedFileName: suggestedFileName)
        if FileManager.default.fileExists(atPath: exportURL.path) {
            return exportURL
        }

        if asset.mediaType == .video,
           let directURL = try await requestVideoURL(for: asset),
           FileManager.default.isReadableFile(atPath: directURL.path) {
            do {
                try copyDirectVideoURL(directURL, to: exportURL)
                return exportURL
            } catch {
                // Fall back to PhotoKit-managed export when the direct file URL is not reliably readable.
            }
        }

        guard let resource = preferredVideoResource(from: resources) ?? resources.first else {
            throw PhotoLibraryServiceError.assetNotFound
        }

        try await writeAssetResource(resource, to: exportURL)
        return exportURL
    }

    private func isVideoLikeAsset(_ asset: PHAsset, resources: [PHAssetResource]) -> Bool {
        if asset.mediaType == .video {
            return true
        }
        return preferredVideoResource(from: resources) != nil
    }

    private func preferredVideoResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo || $0.type == .pairedVideo })
    }

    private func requestVideoURL(for asset: PHAsset) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    continuation.resume(returning: nil)
                    return
                }
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
    }

    private func writeAssetResource(_ resource: PHAssetResource, to url: URL) async throws {
        let fileManager = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
    }

    private func copyDirectVideoURL(_ sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func makeCachedVideoURL(assetIdentifier: String, suggestedFileName: String) throws -> URL {
        let fileManager = FileManager.default
        let root = photoLibraryCacheDirectory()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let ext = URL(fileURLWithPath: suggestedFileName).pathExtension
        let sanitizedIdentifier = assetIdentifier.replacingOccurrences(of: "/", with: "_")
        let outputName = ext.isEmpty ? sanitizedIdentifier : "\(sanitizedIdentifier).\(ext)"
        return root.appendingPathComponent(outputName, isDirectory: false)
    }

    private func photoLibraryCacheDirectory() -> URL {
        let fileManager = FileManager.default
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ??
            fileManager.temporaryDirectory
        return cachesDirectory
            .appendingPathComponent("iPhoto2YouTube", isDirectory: true)
            .appendingPathComponent("PhotoLibraryVideos", isDirectory: true)
    }

    private func performPhotoLibraryChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "PhotoLibraryService",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to update the photo library."]
                    ))
                }
            }
        }
    }

    private func performPhotoLibraryDeletion(assetIdentifiers: [String]) async throws {
        try await Task.detached(priority: .userInitiated) {
            do {
                try PHPhotoLibrary.shared().performChangesAndWait {
                    let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: assetIdentifiers, options: nil)
                    var assets: [PHAsset] = []
                    fetchResult.enumerateObjects { asset, _, _ in
                        assets.append(asset)
                    }
                    PHAssetChangeRequest.deleteAssets(assets as NSArray)
                }
            } catch {
                throw error
            }
        }.value
    }

    private func generateThumbnailPNGData(for fileURL: URL) async -> Data? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 135)

        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            return await MainActor.run {
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                return bitmap.representation(using: .png, properties: [:])
            }
        } catch {
            return nil
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func mapAuthorizationStatus(_ status: PHAuthorizationStatus) -> PhotoLibraryAuthorizationStatus {
        switch status {
        case .authorized:
            return .granted
        case .limited:
            return .limited
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }
}

extension PhotoLibraryService: PhotoLibraryServicing {}
