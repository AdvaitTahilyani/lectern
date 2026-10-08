import Foundation

/// Checks that a downloaded model snapshot is usable, not merely present: files exist, are not
/// empty, and have the structure the loader needs. Nothing here loads the model.
enum SnapshotValidation {
    /// Whether `snapshot` holds a parseable config, a tokenizer and every weight shard, complete.
    static func isComplete(_ snapshot: URL) -> Bool {
        invalidFiles(in: snapshot) == [] && hasEveryRequiredFile(snapshot)
    }

    /// Files that are present but unusable (empty, truncated or unparseable). They block the
    /// download client from fetching a good copy, so a repair deletes them first.
    static func invalidFiles(in snapshot: URL) -> [URL] {
        var bad: [URL] = []
        for name in ["config.json", "tokenizer_config.json", "tokenizer.json", "model.safetensors.index.json"] {
            let url = snapshot.appending(path: name)
            guard exists(url) else { continue }
            let valid = name == "tokenizer.json" ? hasContent(url) : isJSONObject(url)
            if !valid { bad.append(url) }
        }
        let shards = (try? FileManager.default.contentsOfDirectory(atPath: snapshot.path)) ?? []
        for name in shards where name.hasSuffix(".safetensors") {
            let url = snapshot.appending(path: name)
            if !isSafetensors(url) { bad.append(url) }
        }
        return bad
    }

    // MARK: Structure

    private static func hasEveryRequiredFile(_ snapshot: URL) -> Bool {
        func present(_ name: String) -> Bool { exists(snapshot.appending(path: name)) }
        guard present("config.json"), present("tokenizer.json") || present("tokenizer_config.json") else { return false }

        let index = snapshot.appending(path: "model.safetensors.index.json")
        if exists(index) {
            guard let json = jsonObject(index), let weightMap = json["weight_map"] as? [String: String],
                !weightMap.isEmpty
            else { return false }
            return Set(weightMap.values).allSatisfy { present($0) }
        }
        return present("model.safetensors")
    }

    // MARK: Files

    /// Follows symlinks, as the hub cache's snapshot entries point into `blobs/`.
    private static func resolved(_ url: URL) -> URL { url.resolvingSymlinksInPath() }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: resolved(url).path) }

    private static func size(of url: URL) -> Int {
        (try? resolved(url).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private static func hasContent(_ url: URL) -> Bool { size(of: url) > 0 }

    private static func jsonObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: resolved(url)), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func isJSONObject(_ url: URL) -> Bool { jsonObject(url) != nil }

    /// A safetensors file starts with an 8-byte little-endian header length, then that many bytes
    /// of JSON naming each tensor and its byte range. A usable file is at least as long as the
    /// furthest range it names, which catches empty and cut-off files without reading the weights.
    private static func isSafetensors(_ url: URL) -> Bool {
        let file = resolved(url)
        let total = size(of: file)
        guard total > 8, let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 8), prefix.count == 8 else { return false }
        let headerLength = prefix.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        guard headerLength > 0, headerLength <= 100_000_000, 8 + Int(headerLength) <= total,
            let header = try? handle.read(upToCount: Int(headerLength)), header.count == Int(headerLength),
            let json = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any]
        else { return false }
        var furthest = 0
        var tensors = 0
        for (key, value) in json where key != "__metadata__" {
            guard let entry = value as? [String: Any], let offsets = entry["data_offsets"] as? [Int], offsets.count == 2,
                offsets[0] >= 0, offsets[1] >= offsets[0]
            else { return false }
            furthest = max(furthest, offsets[1])
            tensors += 1
        }
        return tensors > 0 && 8 + Int(headerLength) + furthest <= total
    }
}
