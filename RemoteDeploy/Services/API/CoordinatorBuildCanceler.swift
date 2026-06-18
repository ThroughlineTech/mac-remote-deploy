// Cancels the in-progress build by delegating to BuildCoordinator, which
// terminates the underlying xcodebuild process via the build engine. Replaces
// the no-op NoopBuildCanceler in production so Web/iOS "Cancel" actually stops a
// running build (TKT-054, Phase 1).
import Foundation

/// Real BuildCanceling implementation backed by the BuildCoordinator.
final class CoordinatorBuildCanceler: BuildCanceling, @unchecked Sendable {

    private let coordinator: BuildCoordinator

    init(coordinator: BuildCoordinator) {
        self.coordinator = coordinator
    }

    func cancelCurrentBuild() -> Bool {
        coordinator.cancelBuild()
    }
}
