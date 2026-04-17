import AppKit
import AVFoundation
import Foundation
import Photos

protocol PhotoLibraryServicing: Sendable {
    func authorizationStatus() -> PhotoLibraryAuthorizationStatus
    func requestAuthorization() async -> PhotoLibraryAuthorizationStatus
    func fetchVideos(on targetDate: Date) async throws -> [PhotoLibraryVideoItem]
    func deleteVideos(withIDs ids: [String]) async throws
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

    func fetchVideos(on targetDate: Date) async throws -> [PhotoLibraryVideoItem] {
        let status = authorizationStatus()
        guard status == .granted || status == .limited else {
            throw PhotoLibraryServiceError.accessDenied
        }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        let assets = PHAsset.fetchAssets(with: options)
        var items: [PhotoLibraryVideoItem] = []
        for index in 0 ..< assets.count {
            let asset = assets.object(at: index)
            guard let creationDate = asset.creationDate,
                  calendar.isDate(creationDate, inSameDayAs: targetDate) else {
                continue
            }
            if let item = try await buildItem(from: asset) {
                items.append(item)
            }
        }
        return items
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

    private func buildItem(from asset: PHAsset) async throws -> PhotoLibraryVideoItem? {
        let resources = PHAssetResource.assetResources(for: asset)
        let fileName = resources.first?.originalFilename ?? asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        guard let fileURL = try await exportVideoToCache(for: asset, suggestedFileName: fileName) else {
            return nil
        }
        let thumbnailPNGData = await generateThumbnailPNGData(for: fileURL)
        return PhotoLibraryVideoItem(
            id: asset.localIdentifier,
            filePath: fileURL.path,
            fileName: fileName,
            captureDate: asset.creationDate ?? Date(),
            durationSeconds: Int(asset.duration.rounded()),
            durationText: formatDuration(asset.duration),
            thumbnailPNGData: thumbnailPNGData
        )
    }

    private func exportVideoToCache(for asset: PHAsset, suggestedFileName: String) async throws -> URL? {
        let exportURL = try makeCachedVideoURL(assetIdentifier: asset.localIdentifier, suggestedFileName: suggestedFileName)
        if FileManager.default.fileExists(atPath: exportURL.path) {
            return exportURL
        }

        if let directURL = try await requestVideoURL(for: asset),
           FileManager.default.isReadableFile(atPath: directURL.path) {
            do {
                try copyDirectVideoURL(directURL, to: exportURL)
                return exportURL
            } catch {
                // Fall back to PhotoKit-managed export when the direct file URL is not reliably readable.
            }
        }

        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .video || $0.type == .fullSizeVideo }) ??
                PHAssetResource.assetResources(for: asset).first else {
            throw PhotoLibraryServiceError.assetNotFound
        }

        try await writeAssetResource(resource, to: exportURL)
        return exportURL
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
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ??
            fileManager.temporaryDirectory
        let root = cachesDirectory
            .appendingPathComponent("iPhoto2YouTube", isDirectory: true)
            .appendingPathComponent("PhotoLibraryVideos", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let ext = URL(fileURLWithPath: suggestedFileName).pathExtension
        let sanitizedIdentifier = assetIdentifier.replacingOccurrences(of: "/", with: "_")
        let outputName = ext.isEmpty ? sanitizedIdentifier : "\(sanitizedIdentifier).\(ext)"
        return root.appendingPathComponent(outputName, isDirectory: false)
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
