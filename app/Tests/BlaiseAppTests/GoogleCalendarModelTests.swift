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

    @Test("persistence failure is surfaced via settingsError, and success clears it")
    func persistenceFailureSurfaces() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-gcal-tests-\(UUID().uuidString)")
        let database = try BlaiseDatabase(rootURL: root)
        let secrets = FlakySecretStore()
        let model = GoogleCalendarModel(
            settings: SettingsStore(database: database), secrets: secrets)

        secrets.failWrites = true
        model.clientSecret = "GOCSPX-will-fail"
        await model.saveSettings()
        #expect(model.settingsError != nil)

        secrets.failWrites = false
        await model.saveSettings()
        #expect(model.settingsError == nil)
        #expect(try secrets.get(key: GoogleCalendarModel.clientSecretKey) == "GOCSPX-will-fail")
    }

    @Test("a Keychain read failure at load never turns Save into secret deletion")
    func readFailureDoesNotDeleteSecret() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blaise-gcal-tests-\(UUID().uuidString)")
        let database = try BlaiseDatabase(rootURL: root)
        let secrets = FlakySecretStore()
        try secrets.set(key: GoogleCalendarModel.clientSecretKey, value: "GOCSPX-precious")
        let model = GoogleCalendarModel(
            settings: SettingsStore(database: database), secrets: secrets)

        secrets.failReads = true
        await model.load()
        #expect(model.clientSecret.isEmpty)

        // Save with the (unreadable, hence blank) field must not delete the
        // stored secret the read failed to retrieve.
        secrets.failReads = false
        await model.saveSettings()
        #expect(try secrets.get(key: GoogleCalendarModel.clientSecretKey) == "GOCSPX-precious")
    }
}

private struct FlakyError: Error {}

/// Secret store whose reads/writes can be made to fail, for exercising the
/// persistence-failure paths.
private final class FlakySecretStore: SecretStore, @unchecked Sendable {
    private let backing = InMemorySecretStore()
    var failReads = false
    var failWrites = false

    func get(key: String) throws -> String? {
        if failReads { throw FlakyError() }
        return try backing.get(key: key)
    }

    func set(key: String, value: String) throws {
        if failWrites { throw FlakyError() }
        try backing.set(key: key, value: value)
    }

    func delete(key: String) throws {
        if failWrites { throw FlakyError() }
        try backing.delete(key: key)
    }
}
