import Foundation

@Observable
final class DataChangeTracker {
    private(set) var revision = 0

    func markChanged() {
        revision += 1
    }
}
