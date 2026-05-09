import Foundation

/// Main entry point for loading VRM 1.0 models
public final class VRM1Loader {

    public init() {}

    // MARK: - Async Loading

    /// Load a VRM model from a file URL asynchronously
    public func load(from url: URL) async throws -> VRM1Model {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let model = try self.loadSync(from: url)
                    continuation.resume(returning: model)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Load a VRM model from data asynchronously
    public func load(from data: Data) async throws -> VRM1Model {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let model = try self.loadSync(from: data)
                    continuation.resume(returning: model)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Completion Handler Loading

    /// Load a VRM model from a file URL with completion handler
    public func load(from url: URL, completion: @escaping (Result<VRM1Model, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let model = try self.loadSync(from: url)
                DispatchQueue.main.async {
                    completion(.success(model))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Load a VRM model from data with completion handler
    public func load(from data: Data, completion: @escaping (Result<VRM1Model, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let model = try self.loadSync(from: data)
                DispatchQueue.main.async {
                    completion(.success(model))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Synchronous Loading

    /// Load a VRM model from a file URL synchronously
    public func loadSync(from url: URL) throws -> VRM1Model {
        let parseResult = try GLTFBinaryParser.parse(url: url)
        return try VRM1Model(parseResult: parseResult)
    }

    /// Load a VRM model from data synchronously
    public func loadSync(from data: Data) throws -> VRM1Model {
        let parseResult = try GLTFBinaryParser.parse(data: data)
        return try VRM1Model(parseResult: parseResult)
    }

    // MARK: - Bundle Loading

    /// Load a VRM model from the app bundle
    public func loadFromBundle(named name: String, bundle: Bundle = .main) async throws -> VRM1Model {
        guard let url = bundle.url(forResource: name, withExtension: "vrm") else {
            throw VRM1Error.fileNotFound("\(name).vrm")
        }
        return try await load(from: url)
    }

    /// Load a VRM model from the app bundle synchronously
    public func loadFromBundleSync(named name: String, bundle: Bundle = .main) throws -> VRM1Model {
        guard let url = bundle.url(forResource: name, withExtension: "vrm") else {
            throw VRM1Error.fileNotFound("\(name).vrm")
        }
        return try loadSync(from: url)
    }
}

// MARK: - VRM Version Detection

public extension VRM1Loader {

    /// Detected VRM version
    enum VRMVersion {
        case vrm0x
        case vrm1x
        case notVRM
    }

    /// Detect VRM version from document
    static func detectVersion(document: GLTFDocument) -> VRMVersion {
        guard let extensionsUsed = document.extensionsUsed else {
            return .notVRM
        }

        if extensionsUsed.contains("VRMC_vrm") {
            return .vrm1x
        } else if extensionsUsed.contains("VRM") {
            return .vrm0x
        }

        return .notVRM
    }

    /// Detect VRM version from file URL
    static func detectVersion(from url: URL) throws -> VRMVersion {
        let parseResult = try GLTFBinaryParser.parse(url: url)
        return detectVersion(document: parseResult.document)
    }

    /// Detect VRM version from data
    static func detectVersion(from data: Data) throws -> VRMVersion {
        let parseResult = try GLTFBinaryParser.parse(data: data)
        return detectVersion(document: parseResult.document)
    }
}
