/// User profile metadata published as the content of a kind-0 event (NIP-01).
///
/// All fields are optional; only the ones a user has set are present. The
/// `display_name` JSON key is mapped to ``displayName``.
public struct UserMetadata: Codable, Sendable {
    /// Short username shown alongside the user's posts.
    public var name: String?
    /// Free-form biography or description.
    public var about: String?
    /// URL of the user's avatar image.
    public var picture: String?
    /// NIP-05 internet identifier (e.g. `alice@example.com`) for verification.
    public var nip05: String?
    /// URL of a wide banner image for the user's profile.
    public var banner: String?
    /// Longer, human-friendly name shown in place of ``name`` when present.
    public var displayName: String?
    /// URL of the user's website.
    public var website: String?
    /// LUD-06 LNURL-pay string for receiving Lightning zaps (NIP-57).
    public var lud06: String?
    /// LUD-16 Lightning address (e.g. `alice@example.com`) for receiving zaps (NIP-57).
    public var lud16: String?

    enum CodingKeys: String, CodingKey {
        case name
        case about
        case picture
        case nip05
        case banner
        case displayName = "display_name"
        case website
        case lud06
        case lud16
    }

    public init(
        name: String? = nil,
        about: String? = nil,
        picture: String? = nil,
        nip05: String? = nil,
        banner: String? = nil,
        displayName: String? = nil,
        website: String? = nil,
        lud06: String? = nil,
        lud16: String? = nil
    ) {
        self.name = name
        self.about = about
        self.picture = picture
        self.nip05 = nip05
        self.banner = banner
        self.displayName = displayName
        self.website = website
        self.lud06 = lud06
        self.lud16 = lud16
    }
}
