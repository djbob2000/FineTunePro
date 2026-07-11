// FineTune/Coordination/EventTapStatus.swift
import Foundation

/// Transient offline flag for a CGEventTap feature (kernel stall / double-disable path).
/// Accessibility revocation surfaces via the permission card instead — keep `isOffline` false there.
@Observable
@MainActor
final class EventTapStatus {
    var isOffline: Bool = false
}
