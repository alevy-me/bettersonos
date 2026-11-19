import Foundation

// Stands in for the iOS DiscoveryCoordinator, which the view model notifies when local speakers stop answering.
enum DiscoveryCoordinator {
    static let localNetworkUnreachable = Notification.Name("BonTonLocalNetworkUnreachable")
    static let localNetworkReachable = Notification.Name("BonTonLocalNetworkReachable")
}
