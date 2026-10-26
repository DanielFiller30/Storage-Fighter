import AnalysisKit
import Foundation
import Observation
import os

/// The user's activities (chosen in the onboarding) and the profiles shipped with the app.
@Observable
final class ProfileSettings {
    private static let selectionKey = "selectedActivityProfiles"
    private static let onboardingKey = "hasCompletedActivityOnboarding"

    let available: [ActivityProfile]
    private(set) var selectedIDs: Set<String>
    private(set) var hasCompletedOnboarding: Bool
    var isOnboardingPresented: Bool

    init(defaults: UserDefaults = .standard) {
        do {
            available = try ActivityProfiles.bundled()
        } catch {
            Logger(subsystem: "de.df.Stofi", category: "Profiles")
                .error("Profiles could not be loaded: \(error.localizedDescription, privacy: .public)")
            available = []
        }
        selectedIDs = Set(defaults.stringArray(forKey: Self.selectionKey) ?? [])
        hasCompletedOnboarding = defaults.bool(forKey: Self.onboardingKey)
        isOnboardingPresented = !defaults.bool(forKey: Self.onboardingKey)
        self.defaults = defaults
    }

    private let defaults: UserDefaults

    var selected: [ActivityProfile] { available.filter { selectedIDs.contains($0.id) } }

    func save(_ ids: Set<String>) {
        selectedIDs = ids
        hasCompletedOnboarding = true
        isOnboardingPresented = false
        defaults.set(Array(ids).sorted(), forKey: Self.selectionKey)
        defaults.set(true, forKey: Self.onboardingKey)
    }

    #if DEBUG
    /// Test hook: selects profiles for this run only, without writing the user's preferences.
    func useTemporarily(_ ids: Set<String>) {
        selectedIDs = ids
        isOnboardingPresented = false
    }
    #endif

    /// Closes the onboarding without a choice; it is not shown again automatically.
    func skip() {
        save(selectedIDs)
    }
}
