import Foundation
import NostrCore

/// One fetch's snapshot of a NIP-29 group's relay-generated state.
///
/// Returned by ``NostrClient/fetchGroupState(for:authorPubkey:timeout:)``. Each field is
/// nil when the relay has not published that kind — for example the member list of a
/// private group, which relays may withhold from non-members.
///
/// https://github.com/nostr-protocol/nips/blob/master/29.md
public struct GroupState: Sendable, Hashable {
    /// The group's kind-39000 metadata, if the relay published it.
    public var metadata: Groups.Metadata?

    /// The group's kind-39001 admin list, if the relay published it.
    public var admins: Groups.AdminList?

    /// The group's kind-39002 member list, if the relay published it.
    public var members: Groups.MemberList?

    /// The group's kind-39003 role list, if the relay published it.
    public var roles: Groups.RoleList?

    /// The group's kind-39005 pin list, if the relay published it.
    public var pins: Groups.PinList?

    public init(
        metadata: Groups.Metadata? = nil,
        admins: Groups.AdminList? = nil,
        members: Groups.MemberList? = nil,
        roles: Groups.RoleList? = nil,
        pins: Groups.PinList? = nil
    ) {
        self.metadata = metadata
        self.admins = admins
        self.members = members
        self.roles = roles
        self.pins = pins
    }
}
