import SwiftUI

/// Where you paste the GitHub token once. It's stored in the Keychain on this phone only.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var token = Keychain.token ?? ""
    @State private var status: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("github_pat_…", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("GitHub token")
                } footer: {
                    Text("""
                    Lets the publish button add photos to slakdl/cloudcam. Make a fine-grained \
                    token on github.com with access to only that repository and \
                    "Contents: Read and write". It's kept in this phone's Keychain.
                    """)
                }

                if let status {
                    Section { Text(status) }
                }
            }
            .navigationTitle("Publishing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(checking ? "Checking…" : "Save", action: save)
                        .disabled(checking)
                }
            }
        }
    }

    private func save() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Keychain.token = nil
            dismiss()
            return
        }
        checking = true
        Task {
            let works = await Publisher.shared.check(token: trimmed)
            checking = false
            if works {
                Keychain.token = trimmed
                try? await Publisher.shared.sendWaiting()
                dismiss()
            } else {
                status = "That token can't reach slakdl/cloudcam. Check it has access to the repository."
            }
        }
    }
}
