import Foundation

/// VRM 1.0 model metadata
public struct VRMMeta {
    /// Name of the model
    public let name: String?

    /// Version of the model
    public let version: String?

    /// Authors of the model
    public let authors: [String]

    /// Copyright holder
    public let copyrightInformation: String?

    /// Contact information
    public let contactInformation: String?

    /// Reference URLs
    public let references: [String]

    /// Third party licenses
    public let thirdPartyLicenses: String?

    /// Thumbnail image index (in glTF images array)
    public let thumbnailImage: Int?

    /// License URL
    public let licenseUrl: String?

    /// Avatar permission for the model
    public let avatarPermission: AvatarPermission

    /// Commercial usage permission
    public let commercialUsage: CommercialUsage

    /// Credit notation requirement
    public let creditNotation: CreditNotation

    /// Modification permission
    public let modification: Modification

    /// Other license URL
    public let otherLicenseUrl: String?

    // MARK: - Permission Types

    public enum AvatarPermission: String {
        case onlyAuthor
        case onlySeparatelyLicensedPerson
        case everyone
        case unknown

        init(from string: String?) {
            guard let string = string else {
                self = .unknown
                return
            }
            self = AvatarPermission(rawValue: string) ?? .unknown
        }
    }

    public enum CommercialUsage: String {
        case personalNonProfit
        case personalProfit
        case corporation
        case unknown

        init(from string: String?) {
            guard let string = string else {
                self = .unknown
                return
            }
            self = CommercialUsage(rawValue: string) ?? .unknown
        }
    }

    public enum CreditNotation: String {
        case required
        case unnecessary
        case unknown

        init(from string: String?) {
            guard let string = string else {
                self = .unknown
                return
            }
            self = CreditNotation(rawValue: string) ?? .unknown
        }
    }

    public enum Modification: String {
        case prohibited
        case allowModification
        case allowModificationRedistribution
        case unknown

        init(from string: String?) {
            guard let string = string else {
                self = .unknown
                return
            }
            self = Modification(rawValue: string) ?? .unknown
        }
    }

    // MARK: - Initialization

    init(from dict: [String: Any]) {
        self.name = dict["name"] as? String
        self.version = dict["version"] as? String
        self.authors = dict["authors"] as? [String] ?? []
        self.copyrightInformation = dict["copyrightInformation"] as? String
        self.contactInformation = dict["contactInformation"] as? String
        self.references = dict["references"] as? [String] ?? []
        self.thirdPartyLicenses = dict["thirdPartyLicenses"] as? String
        self.thumbnailImage = dict["thumbnailImage"] as? Int
        self.licenseUrl = dict["licenseUrl"] as? String
        self.avatarPermission = AvatarPermission(from: dict["avatarPermission"] as? String)
        self.commercialUsage = CommercialUsage(from: dict["commercialUsage"] as? String)
        self.creditNotation = CreditNotation(from: dict["creditNotation"] as? String)
        self.modification = Modification(from: dict["modification"] as? String)
        self.otherLicenseUrl = dict["otherLicenseUrl"] as? String
    }
}
