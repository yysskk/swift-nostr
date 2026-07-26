import Foundation
import NostrCore

// MARK: - Feature namespaces

/// The client's public API, grouped so a call site names the feature area it is in.
///
/// Every namespace is a `Sendable` value holding nothing but the client, so reading one is free
/// and it can be stored, passed to a view model, or held by a background task. Each also conforms
/// to a capability protocol (``NostrEventPublishing``, ``NostrMessaging``, …), so an app feature
/// can depend on the slice it needs instead of the whole client.
///
/// ```swift
/// let composer = MessageComposer(messages: client.messages)  // any NostrMessaging
/// ```
extension NostrClient {
    /// Signer management, the signer's identity, and NIP-42 relay authentication.
    public nonisolated var identity: NostrIdentityAPI { NostrIdentityAPI(client: self) }

    /// Relay pool membership and connection lifecycle, plus the underlying ``RelayPool``.
    public nonisolated var relays: NostrRelaysAPI { NostrRelaysAPI(client: self) }

    /// Authoring, publishing, and one-time fetching of events, including NIP-23 long-form content.
    public nonisolated var events: NostrEventsAPI { NostrEventsAPI(client: self) }

    /// Live subscriptions as async sequences.
    public nonisolated var subscriptions: NostrSubscriptionsAPI { NostrSubscriptionsAPI(client: self) }

    /// Relay discovery and routing: NIP-65 outbox/gossip and NIP-17 DM relay lists.
    public nonisolated var routing: NostrRoutingAPI { NostrRoutingAPI(client: self) }

    /// NIP-17 private direct messages.
    public nonisolated var messages: NostrMessagesAPI { NostrMessagesAPI(client: self) }

    /// NIP-29 relay-based groups and the NIP-51 group list that tracks membership.
    public nonisolated var groups: NostrGroupsAPI { NostrGroupsAPI(client: self) }

    /// NIP-51 lists and sets.
    public nonisolated var lists: NostrListsAPI { NostrListsAPI(client: self) }
}
