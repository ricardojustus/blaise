import BlaiseCore
import Foundation
import Testing

@testable import BlaiseApp

/// Pins the client-secret persistence contract (issue #2): the secret lands in
/// the `SecretStore` (Keychain in production) — never in the settings database —
/// and round-trips through `saveSettings()`/`load()`.
@MainActor
struct GoogleCalendarModelTests {
    private func makeModel() throws -> (GoogleCalendarModel, InMemorySecretStore, SettingsStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-gcal-tests-\(UUID().uuidString)")
        let database = try BlaiseDatabase(rootURL: root)
        let settings = SettingsStore(database: database)
        let secrets = InMemorySecretStore()
        return (GoogleCalendarModel(settings: settings, secrets: secrets), secrets, settings)
    }

    @Test("client secret round-trips via the secret store, not the settings DB")
    func clientSecretRoundTrip() async throws {
        let (model, secrets, settings) = try makeModel()
        model.clientID = "  id-123.apps.googleusercontent.com "
        model.clientSecret = " GOCSPX-not-a-real-secret \n"
        await model.saveSettings()

        #expect(model.clientID == "id-123.apps.googleusercontent.com")
        #expect(model.clientSecret == "GOCSPX-not-a-real-secret")
        #expect(try secrets.get(key: GoogleCalendarModel.clientSecretKey) == "GOCSPX-not-a-real-secret")
        // The settings-DB row must not contain the secret.
        struct Probe: Codable { var clientID: String?; var clientSecret: String? }
        let stored = try await settings.get(GoogleCalendarModel.settingsKey, as: Probe.self)
        #expect(stored?.clientID == "id-123.apps.googleusercontent.com")
        #expect(stored?.clientSecret == nil)

        // A fresh model bound to the same stores sees the persisted values.
        let reloaded = GoogleCalendarModel(settings: settings, secrets: secrets)
        await reloaded.load()
        #expect(reloaded.clientSecret == "GOCSPX-not-a-real-secret")
        #expect(reloaded.clientID == "id-123.apps.googleusercontent.com")
    }

    @Test("clearing the secret deletes it from the secret store")
    func clearingSecretDeletes() async throws {
        let (model, secrets, _) = try makeModel()
        model.clientSecret = "GOCSPX-temp"
        await model.saveSettings()
        #expect(try secrets.get(key: GoogleCalendarModel.clientSecretKey) != nil)

        model.clientSecret = "   "
        await model.saveSettings()
        #expect(model.clientSecret.isEmpty)
        #expect(try secrets.get(key: GoogleCalendarModel.clientSecretKey) == nil)
    }
}
