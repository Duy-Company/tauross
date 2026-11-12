import AppKit
import Combine
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    var prepareForInstallation: (() -> Void)?
    private var started = false
    #if canImport(Sparkle)
    private(set) var controller: SPUStandardUpdaterController!
    private var observations = Set<AnyCancellable>()
    #endif

    override init() {
        super.init()
        #if canImport(Sparkle)
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main).sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &observations)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main).sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }
            .store(in: &observations)
        #endif
    }

    func start() {
        guard !started, Bundle.main.object(forInfoDictionaryKey: "TaurossUpdatesEnabled") as? Bool == true else { return }
        started = true
        #if canImport(Sparkle)
        controller.startUpdater()
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        controller.checkForUpdates(nil)
        #endif
    }

    func setAutomaticChecks(_ enabled: Bool) {
        #if canImport(Sparkle)
        controller.updater.automaticallyChecksForUpdates = enabled
        #endif
    }
}

#if canImport(Sparkle)
extension AppUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        prepareForInstallation?()
    }
}
#endif
