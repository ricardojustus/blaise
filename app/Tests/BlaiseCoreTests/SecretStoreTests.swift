import Foundation
import Testing
@testable import BlaiseCore

/// Keychain access probe, evaluated once. When the test host cannot use the
/// Keychain (e.g. sandbox/headless denial), the smoke test is SKIPPED with
/// this reason via `.enabled(if:)` — visible in the test report, never
/// silently green.
let keychainProbe: (accessible: Bool, reason: String) = {
    let store = KeychainSecretStore(service: "app.blaise.mac.tests")
    let probeKey = "probe.\(UUID().uuidString)"
    do {
        try store.set(key: probeKey, value: "probe")
        try store.delete(key: probeKey)
        return (true, "")
    } catch {
        return (false, "test host lacks keychain access: \(error)")
    }
}()

@Suite struct SecretStoreTests {
    @Test func inMemoryStoreSetGetDelete() throws {
        let store = InMemorySecretStore()
        #expect(try store.get(key: "engine.x.apiKey") == nil)

        try store.set(key: "engine.x.apiKey", value: "value-1")
        #expect(try store.get(key: "engine.x.apiKey") == "value-1")

        // Namespacing: two engines declaring `apiKey` never collide.
        try store.set(key: "engine.y.apiKey", value: "value-2")
        #expect(try store.get(key: "engine.x.apiKey") == "value-1")
        #expect(try store.get(key: "engine.y.apiKey") == "value-2")

        try store.set(key: "engine.x.apiKey", value: "value-1b") // overwrite
        #expect(try store.get(key: "engine.x.apiKey") == "value-1b")

        try store.delete(key: "engine.x.apiKey")
        #expect(try store.get(key: "engine.x.apiKey") == nil)
        try store.delete(key: "engine.x.apiKey") // idempotent
    }

    @Test(
        .enabled(
            if: keychainProbe.accessible,
            "Keychain smoke test skipped — test host denied keychain access (see keychainProbe.reason in SecretStoreTests.swift)"
        )
    )
    func keychainStoreSetGetDeleteSmokeTest() throws {
        // Dedicated test service: never touches the production
        // `app.blaise.mac` items; unique key per run, cleaned up after.
        let store = KeychainSecretStore(service: "app.blaise.mac.tests")
        let key = "engine.mock.apiKey.\(UUID().uuidString)"
        defer { try? store.delete(key: key) }

        #expect(try store.get(key: key) == nil)
        try store.set(key: key, value: "secret-1")
        #expect(try store.get(key: key) == "secret-1")
        try store.set(key: key, value: "secret-2") // update path (SecItemUpdate)
        #expect(try store.get(key: key) == "secret-2")
        try store.delete(key: key)
        #expect(try store.get(key: key) == nil)
        try store.delete(key: key) // idempotent
    }

    @Test func engineConfigurationRoutesByDescriptorKind() async throws {
        let database = try makeDatabase()
        let settings = SettingsStore(database: database)
        let secrets = InMemorySecretStore()
        let descriptors = [
            EngineConfigDescriptor(key: "apiKey", label: "API key", kind: .secret, required: true),
            EngineConfigDescriptor(key: "endpoint", label: "Endpoint", kind: .string, required: false),
        ]
        let config = EngineConfiguration(
            engineID: "mock-cloud",
            descriptors: descriptors,
            settings: settings,
            secrets: secrets
        )

        #expect(try await config.value(for: "apiKey") == nil)
        #expect(try await config.value(for: "endpoint") == nil)

        try secrets.set(key: "engine.mock-cloud.apiKey", value: "sk-redacted")
        try await settings.set("engine.mock-cloud.endpoint", to: "https://example.test")

        #expect(try await config.value(for: "apiKey") == "sk-redacted")
        #expect(try await config.value(for: "endpoint") == "https://example.test")

        // Secrets never land in SQLite: the secret key is absent from app_setting.
        let secretInDB: String? = try await settings.get("engine.mock-cloud.apiKey")
        #expect(secretInDB == nil)
    }
}
