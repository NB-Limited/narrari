import Foundation
import HuggingFace
import MLXLMCommon
import Tokenizers

public struct ModelReference: Sendable, Equatable {
    public let id: String
    public let revision: String

    // Written as "org/name@revision"; without a revision the moving "main" branch is used.
    public init(_ text: String) {
        let parts = text.split(separator: "@", maxSplits: 1)
        id = parts.first.map(String.init) ?? ""
        revision = parts.count == 2 ? String(parts[1]) : "main"
    }

    // "mlx-community/Qwen3.5-2B-MLX-8bit" reads as "Qwen3.5 2B".
    public var displayName: String {
        let repo = id.split(separator: "/").last.map(String.init) ?? id
        let base = repo.components(separatedBy: "-MLX").first ?? repo
        return base.replacingOccurrences(of: "-", with: " ")
    }
}

// mlx-swift-lm 3 ships no downloader or tokenizer; these adapt swift-huggingface and swift-transformers to its protocols.
struct ModelHub: MLXLMCommon.Downloader {
    // A fixed literal, so it always parses.
    static let host = URL(string: "https://huggingface.co")!

    let cache: HubCache

    init(store: ModelStore) {
        cache = HubCache(cacheDirectory: store.directory(named: "huggingface"))
    }

    func directory(of id: String) throws -> URL {
        cache.repoDirectory(repo: try repo(id), kind: .model)
    }

    // The ids of the models in the cache. A folder counts only if the hub's own naming leads back to it,
    // so a delete built from an id can only ever reach a model folder.
    func cachedModelIDs() -> [String] {
        let prefix = "\(Repo.Kind.model.pluralized)--"
        let folders = (try? FileManager.default.contentsOfDirectory(at: cache.cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> String? in
            let name = folder.lastPathComponent
            guard name.hasPrefix(prefix) else { return nil }
            let parts = name.dropFirst(prefix.count).split(separator: "--", maxSplits: 1)
            guard parts.count == 2, let repo = Repo.ID(rawValue: "\(parts[0])/\(parts[1])"),
                  cache.repoDirectory(repo: repo, kind: .model).lastPathComponent == name
            else { return nil }
            return repo.rawValue
        }
        .sorted()
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let client = HubClient(host: Self.host, cache: cache)
        return try await client.downloadSnapshot(
            of: try repo(id),
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { progress in progressHandler(progress) }
        )
    }

    private func repo(_ id: String) throws -> Repo.ID {
        guard let repo = Repo.ID(rawValue: id) else {
            throw CleanupEngineError.modelUnavailable
        }
        return repo
    }
}

struct TokenizerFiles: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        LoadedTokenizer(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct LoadedTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
