import Combine
import Foundation

public final class ResolverPresetStore: ObservableObject {
    public static let shared = ResolverPresetStore()

    @Published public private(set) var presets: [ResolverPreset]

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let fm = FileManager.default
            let directory = (try? fm.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = directory.appendingPathComponent("resolver-presets.json")
        }
        presets = []
        presets = loadFromDisk()
    }

    public var parents: [ResolverPreset] {
        presets.filter { $0.kind == .parent }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func children(of parentID: UUID) -> [ResolverPreset] {
        presets.filter { $0.parentID == parentID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func preset(id: UUID?) -> ResolverPreset? {
        guard let id else { return nil }
        return presets.first { $0.id == id }
    }

    @discardableResult
    public func save(_ preset: ResolverPreset) -> ResolverPreset {
        var value = preset
        value.updatedAt = Date()
        if let index = presets.firstIndex(where: { $0.id == value.id }) {
            presets[index] = value
        } else {
            presets.append(value)
        }
        persist()
        return value
    }

    @discardableResult
    public func createParent(name: String, endpoints: [ResolverEndpoint], source: String = "") -> ResolverPreset {
        save(ResolverPreset(name: name, endpoints: endpoints, sourceDescription: source))
    }

    @discardableResult
    public func createChild(
        parentID: UUID,
        name: String,
        endpoints: [ResolverEndpoint],
        evaluations: [ResolverEvaluation] = [],
        source: String = ""
    ) -> ResolverPreset {
        save(ResolverPreset(
            name: name,
            kind: .evaluatedSubset,
            parentID: parentID,
            endpoints: endpoints,
            evaluations: evaluations,
            sourceDescription: source
        ))
    }

    public func delete(_ id: UUID) {
        let childIDs = Set(presets.filter { $0.parentID == id }.map(\.id))
        presets.removeAll { $0.id == id || childIDs.contains($0.id) }
        persist()
    }

    public func replaceAllForTesting(_ values: [ResolverPreset]) {
        presets = values
        persist()
    }

    private func loadFromDisk() -> [ResolverPreset] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ResolverPreset].self, from: data)) ?? []
    }

    private func persist() {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(presets) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
