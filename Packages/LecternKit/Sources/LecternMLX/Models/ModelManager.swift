import Foundation
import HuggingFace
import LecternCore

/// Byte-level progress of a model download.
public struct ModelDownloadProgress: Sendable, Hashable {
    public var completedBytes: Int64
    public var totalBytes: Int64

    public init(completedBytes: Int64, totalBytes: Int64) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    /// 0...1.
    public var fractionCompleted: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
    }
}

public enum ModelManagerError: Error, LocalizedError, Sendable, Hashable {
    case invalidModelID(String)
    /// The download finished but required files are missing.
    case incompleteDownload(String)

    public var errorDescription: String? {
        switch self {
        case .invalidModelID(let id): "“\(id)” is not a valid Hugging Face model id."
        case .incompleteDownload(let id): "The download of \(id) is incomplete. Try again."
        }
    }
}

/// Downloads, locates and deletes on-device MLX models.
///
/// Models are stored in the standard Hugging Face hub cache (`~/.cache/huggingface/hub`, or
/// `$HF_HUB_CACHE` / `$HF_HOME/hub`), the same layout Python `huggingface_hub` and `mlx_lm`
/// use, so a model downloaded by either is reused. Downloads resume from partial files.
///
/// A download keeps running when the caller that started it stops waiting (e.g. Settings
/// closes); call ``cancelDownload(_:)`` to stop it. Concurrent `download` calls for the same
/// model share one transfer.
public actor ModelManager {
    public static let shared = ModelManager()

    /// Files needed to run a model with mlx-swift-lm.
    static let downloadPatterns = ["*.safetensors", "*.json", "*.jinja"]

    private let client: HubClient
    private let cache: HubCache
    private var downloads: [String: ActiveDownload] = [:]

    /// Creates a manager over the default hub cache, or over `cacheDirectory` when given.
    public init(cacheDirectory: URL? = nil) {
        let cache = cacheDirectory.map { HubCache(cacheDirectory: $0) } ?? .default
        self.cache = cache
        self.client = HubClient(cache: cache)
    }

    /// Root folder that holds downloaded models.
    public nonisolated var storageDirectory: URL { cache.cacheDirectory }

    /// Models offered in Settings, default first.
    public nonisolated var catalog: [OnDeviceModel] { OnDeviceModel.curated }

    // MARK: - Local state

    /// The local snapshot folder when every required file of `id` is present, else nil.
    public nonisolated func localDirectory(for id: String) -> URL? {
        guard let repo = Repo.ID(rawValue: id),
            let commit = cache.resolveRevision(repo: repo, kind: .model, ref: "main"),
            let snapshot = try? cache.snapshotPath(repo: repo, kind: .model, commitHash: commit)
        else { return nil }
        return Self.isComplete(snapshot) ? snapshot : nil
    }

    /// Whether `id` is fully downloaded.
    public nonisolated func isDownloaded(_ id: String) -> Bool {
        localDirectory(for: id) != nil
    }

    /// Bytes `id` occupies on disk, including partial downloads.
    public nonisolated func diskUsage(of id: String) -> Int64 {
        guard let repo = Repo.ID(rawValue: id) else { return 0 }
        let blobs = cache.blobsDirectory(repo: repo, kind: .model)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: blobs, includingPropertiesForKeys: Array(keys))
        else { return 0 }
        return files.reduce(Int64(0)) { total, url in
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { return total }
            return total + Int64(values?.fileSize ?? 0)
        }
    }

    /// Ids of curated models that are fully downloaded.
    public nonisolated func downloadedModels() -> [String] {
        catalog.map(\.id).filter(isDownloaded)
    }

    // MARK: - Downloads

    /// Whether a download of `id` is in progress.
    public func isDownloading(_ id: String) -> Bool { downloads[id] != nil }

    /// Latest progress of an in-progress download of `id`.
    public func currentProgress(of id: String) -> ModelDownloadProgress? {
        downloads[id]?.fanOut.latest
    }

    /// Progress of the in-progress download of `id`; finishes when the download ends (or at
    /// once if none is running). Lets any view mirror a download another view started.
    public func progressUpdates(of id: String) -> AsyncStream<ModelDownloadProgress> {
        let (stream, continuation) = AsyncStream<ModelDownloadProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        guard let active = downloads[id] else {
            continuation.finish()
            return stream
        }
        let token = UUID()
        active.fanOut.add(token, onFinish: { continuation.finish() }) { continuation.yield($0) }
        continuation.onTermination = { [fanOut = active.fanOut] _ in fanOut.remove(token) }
        return stream
    }

    /// Downloads `id` (or joins the download already in progress) and returns its local folder.
    ///
    /// `progress` is called with byte progress, on an arbitrary thread. Cancelling the calling
    /// task stops waiting but does not stop the transfer; use ``cancelDownload(_:)`` for that.
    @discardableResult
    public func download(
        _ id: String,
        progress: (@Sendable (ModelDownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        if let local = localDirectory(for: id) {
            let size = diskUsage(of: id)
            progress?(ModelDownloadProgress(completedBytes: size, totalBytes: size))
            return local
        }
        guard let repo = Repo.ID(rawValue: id) else { throw ModelManagerError.invalidModelID(id) }

        let active = downloads[id] ?? start(id: id, repo: repo)
        let token = UUID()
        if let progress { active.fanOut.add(token, progress) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    active.waiters[token] = continuation
                }
            }
        } onCancel: {
            Task { await self.stopWaiting(id: id, token: token) }
        }
    }

    /// Stops an in-progress download. Partial files are kept so a later download resumes.
    public func cancelDownload(_ id: String) {
        downloads[id]?.task?.cancel()
    }

    /// Deletes all local files of `id` (cancelling a download in progress). Unload the model
    /// from ``MLXModelHost`` first if it is loaded.
    public func delete(_ id: String) throws {
        guard let repo = Repo.ID(rawValue: id) else { throw ModelManagerError.invalidModelID(id) }
        downloads[id]?.task?.cancel()
        let folder = cache.repoDirectory(repo: repo, kind: .model)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Private

    private func start(id: String, repo: Repo.ID) -> ActiveDownload {
        let active = ActiveDownload()
        downloads[id] = active
        let client = self.client
        let fanOut = active.fanOut
        active.task = Task {
            let result: Result<URL, Error>
            do {
                _ = try await client.downloadSnapshot(
                    of: repo, kind: .model, revision: "main",
                    matching: Self.downloadPatterns,
                    progressHandler: { @MainActor progress in
                        let total = progress.totalUnitCount
                        let done = Int64(progress.fractionCompleted * Double(total))
                        fanOut.publish(ModelDownloadProgress(completedBytes: done, totalBytes: total))
                    })
                if let local = self.localDirectory(for: id) {
                    result = .success(local)
                } else {
                    result = .failure(ModelManagerError.incompleteDownload(id))
                }
            } catch {
                result = .failure(error)
            }
            self.finish(id: id, result: result)
        }
        return active
    }

    private func finish(id: String, result: Result<URL, Error>) {
        guard let active = downloads.removeValue(forKey: id) else { return }
        if case .success = result, let latest = active.fanOut.latest {
            active.fanOut.publish(
                ModelDownloadProgress(completedBytes: latest.totalBytes, totalBytes: latest.totalBytes))
        }
        active.fanOut.finishAll()
        for continuation in active.waiters.values {
            continuation.resume(with: result)
        }
        active.waiters.removeAll()
    }

    private func stopWaiting(id: String, token: UUID) {
        guard let active = downloads[id] else { return }
        active.fanOut.remove(token)
        active.waiters.removeValue(forKey: token)?.resume(throwing: CancellationError())
    }
}

/// Book-keeping for one in-progress download. Only touched on the ``ModelManager`` actor,
/// except `fanOut`, which is independently thread-safe.
private final class ActiveDownload {
    var task: Task<Void, Never>?
    var waiters: [UUID: CheckedContinuation<URL, Error>] = [:]
    let fanOut = ProgressFanOut()
}

extension ModelManager {
    /// Whether `snapshot` holds a config, tokenizer and every weight shard.
    static func isComplete(_ snapshot: URL) -> Bool {
        let files = FileManager.default
        func exists(_ name: String) -> Bool {
            files.fileExists(atPath: snapshot.appending(path: name).path)
        }
        guard exists("config.json"), exists("tokenizer.json") || exists("tokenizer_config.json")
        else { return false }

        let index = snapshot.appending(path: "model.safetensors.index.json")
        if let data = try? Data(contentsOf: index),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let weightMap = json["weight_map"] as? [String: String]
        {
            return Set(weightMap.values).allSatisfy(exists)
        }
        return exists("model.safetensors")
    }
}
