import SwiftUI

struct AuthWindow: View {
    let auth: AuthManager   // reads only; Observation tracks state in body
    @State private var key = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Clockify").font(.headline)
            Text("Paste your API key (Clockify → Profile Settings → API).")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("API key", text: $key)
                .textFieldStyle(.roundedBorder)
            if case .needsAuth(let msg?) = auth.state {
                Text(msg).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(busy ? "Checking…" : "Save") {
                    busy = true
                    Task { await auth.submit(key: key); busy = false }
                }
                .disabled(key.isEmpty || busy)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
