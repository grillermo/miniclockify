import Foundation
import Observation

// @MainActor: consumed from the @MainActor AppState (later UI task) and mutates
// observable UI state; keeping it main-isolated avoids Swift strict-concurrency
// data-race diagnostics. Store test classes are annotated @MainActor to match.
@MainActor
@Observable
final class AuthManager {
    enum State: Equatable {
        case needsAuth(String?)          // optional error message
        case authenticated(ClockifyUser)
    }

    private(set) var state: State = .needsAuth(nil)
    private(set) var client: ClockifyAPI?

    private let keychain: KeychainStore
    private let makeClient: @Sendable (String) -> ClockifyAPI

    init(keychain: KeychainStore = KeychainStore(),
         makeClient: @escaping @Sendable (String) -> ClockifyAPI = { ClockifyClient(apiKey: $0) }) {
        self.keychain = keychain
        self.makeClient = makeClient
    }

    /// Called at launch. Validates any stored key.
    func bootstrap() async {
        guard let key = keychain.load() else { state = .needsAuth(nil); return }
        await validate(key: key, saveOnSuccess: false)
    }

    func submit(key: String) async {
        await validate(key: key, saveOnSuccess: true)
    }

    private func validate(key: String, saveOnSuccess: Bool) async {
        let client = makeClient(key)
        do {
            let user = try await client.currentUser()
            if saveOnSuccess { keychain.save(key) }
            self.client = client
            state = .authenticated(user)
        } catch ClockifyError.unauthorized {
            state = .needsAuth("Invalid API key.")
        } catch ClockifyError.server(let code) {
            state = .needsAuth("Clockify returned an error (\(code)). Try again shortly.")
        } catch ClockifyError.network {
            state = .needsAuth("Could not reach Clockify. Check your connection.")
        } catch ClockifyError.decoding {
            state = .needsAuth("Received an unexpected response from Clockify.")
        } catch {
            state = .needsAuth("Could not reach Clockify. Check your connection.")
        }
    }

    func signOut() {
        keychain.delete()
        client = nil
        state = .needsAuth(nil)
    }
}
