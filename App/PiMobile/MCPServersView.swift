import PiEngineKit
import SwiftUI
import WebKit

/// Settings → MCP servers: the servers whose tools every session has. Add one by its URL (and a header, for an API
/// key), sign in where it asks (pi's OAuth flow, its page in a Safari sheet), turn it off, choose how its tools reach
/// the model, or remove it.
struct MCPServersView: View {
    @Bindable var app: AppModel
    @State private var adding = false

    var body: some View {
        List {
            Section {
                if app.mcpServers.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(app.mcpServers) { server in
                    NavigationLink {
                        MCPServerDetail(app: app, name: server.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                            MCPStateLine(server: server).font(.caption)
                        }
                    }
                    .accessibilityIdentifier("mcp-server-\(server.name)")
                }
                Button("Add server", systemImage: "plus") { adding = true }
            } footer: {
                Text("Remote MCP servers (Streamable HTTP). Their tools are in every session; sign-ins and keys stay in this device's Keychain, and the agent never sees them.")
            }
        }
        .navigationTitle("MCP servers")
        .task { await app.refreshMCP() }
        .refreshable { await app.refreshMCP() }
        .sheet(isPresented: $adding) { MCPServerEditor(app: app) }
    }
}

/// A server's state in a line: connected and how many tools, needs a sign-in, the error, ...
private struct MCPStateLine: View {
    let server: AppModel.MCPServerStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(server.state == "error" ? .red : .secondary).lineLimit(2)
        }
    }

    private var text: String {
        switch server.state {
        case "connected": "Connected · \(server.tools.count) tool\(server.tools.count == 1 ? "" : "s")\(server.effectiveExposure == "deferred" ? " · on demand" : "")"
        case "connecting": "Connecting…"
        case "disconnected": server.tools.isEmpty ? "Not connected" : "Reconnects when needed · \(server.tools.count) tools"
        case "sign-in": "Needs sign-in"
        case "disabled": "Off"
        default: server.error ?? "Error"
        }
    }

    private var color: Color {
        switch server.state {
        case "connected": .green
        case "connecting", "disconnected": .orange
        case "sign-in": .yellow
        case "disabled": .gray
        default: .red
        }
    }
}

private struct MCPServerDetail: View {
    @Bindable var app: AppModel
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var signingIn = false
    @State private var failure: String?
    @State private var editing = false

    private var server: AppModel.MCPServerStatus? { app.mcpServers.first { $0.name == name } }

    var body: some View {
        List {
            if let server {
                Section {
                    LabeledContent("URL") { Text(server.url).font(.footnote).textSelection(.enabled) }
                    MCPStateLine(server: server)
                    if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
                }
                Section {
                    if server.state == "sign-in" || server.state == "error" {
                        Button {
                            Task {
                                signingIn = true
                                failure = await app.signInMCP(name)
                                signingIn = false
                            }
                        } label: {
                            HStack {
                                Text("Sign in")
                                if signingIn { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(signingIn || !server.enabled)
                    }
                    if app.mcp.isSignedIn(name) {
                        Button("Sign out", role: .destructive) { Task { await app.signOutMCP(name) } }
                    }
                    Button("Reconnect") { Task { await app.reconnectMCP(name) } }.disabled(!server.enabled)
                    Toggle("On", isOn: Binding(get: { server.enabled }, set: { value in Task { await app.setMCPEnabled(name, value) } }))
                    Picker("Tools", selection: Binding(get: { server.exposure }, set: { value in Task { await app.setMCPExposure(name, value) } })) {
                        Text("Automatic").tag("auto")
                        Text("Always declared").tag("direct")
                        Text("On demand").tag("deferred")
                        Text("Hidden").tag("hidden")
                    }
                } footer: {
                    Text("Automatic declares a server's tools to the model when it has \(20) or fewer; with more, the agent searches them when it needs one. Either way they are named mcp__\(name)__<tool>.")
                }
                if !server.tools.isEmpty {
                    Section("Tools") {
                        ForEach(server.tools, id: \.name) { tool in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name).font(.callout.monospaced())
                                if !tool.description.isEmpty {
                                    Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Edit") { editing = true }
                    Button("Remove server", role: .destructive) {
                        Task {
                            await app.deleteMCP(name)
                            dismiss()
                        }
                    }
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) { MCPServerEditor(app: app, existing: app.mcp.entries.first { $0.name == name }) }
        .sheet(item: $app.mcpLogin, onDismiss: { Task { await app.cancelMCPSignIn() } }) { login in
            if let redirect = login.redirect {
                OAuthSignInView(url: login.url, redirect: redirect) { response in
                    Task { await app.mcpAuthorizationResponse(response) }
                }
            } else {
                SafariView(url: login.url).ignoresSafeArea()
            }
        }
    }
}

/// Adds a server, or edits one (its header value is kept unless a new one is typed).
private struct MCPServerEditor: View {
    @Bindable var app: AppModel
    var existing: MCPServersService.Entry?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var headerName = ""
    @State private var headerValue = ""
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var scope = ""
    @State private var redirectUrl = ""
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, such as linear", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(existing != nil)
                    TextField("https://mcp.example.com/mcp", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("Most servers ask you to sign in after adding them. Some take an API key in a header instead.")
                }
                Section {
                    TextField("Header, such as Authorization", text: $headerName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(existing?.headerNames.isEmpty == false ? "Value (unchanged)" : "Value, such as Bearer …", text: $headerValue)
                        .textContentType(.oneTimeCode)
                } header: {
                    Text("Header (optional)")
                }
                Section {
                    TextField("Client ID", text: $clientId)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(existing.map { app.mcp.hasClientSecret($0.name) } == true ? "Client secret (unchanged)" : "Client secret", text: $clientSecret)
                        .textContentType(.oneTimeCode)
                    TextField("Scopes, separated by spaces", text: $scope)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Redirect URL (optional)", text: $redirectUrl)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("OAuth app (optional)")
                } footer: {
                    Text("For a server without automatic client registration (Slack, HubSpot): the app you registered with it. Give it pi's redirect URL, http://127.0.0.1:33418/callback, or put the one the app already has here: a localhost one is served on the phone; any other is caught by pi's sign-in view before it loads.")
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle(existing == nil ? "Add MCP server" : "Edit \(existing!.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.isEmpty || url.isEmpty)
                }
            }
            .onAppear {
                guard let existing else { return }
                name = existing.name
                url = existing.url
                headerName = existing.headerNames.first ?? ""
                clientId = existing.oauthClientId ?? ""
                scope = existing.oauthScope ?? ""
                redirectUrl = existing.oauthRedirectUrl ?? ""
            }
        }
    }

    private func save() {
        var entry = existing ?? MCPServersService.Entry(name: name.trimmingCharacters(in: .whitespaces), url: "")
        entry.url = url.trimmingCharacters(in: .whitespaces)
        entry.oauthClientId = clientId
        entry.oauthScope = scope
        entry.oauthRedirectUrl = redirectUrl
        // A typed secret replaces the stored one; none keeps it, unless the client ID was cleared.
        let secret: String? = !clientSecret.isEmpty ? clientSecret : clientId.trimmingCharacters(in: .whitespaces).isEmpty ? "" : nil
        clientSecret = ""
        let header = headerName.trimmingCharacters(in: .whitespaces)
        // A new value replaces the header; none keeps what is stored, unless the header was removed.
        let headers: [String: String]? = !headerValue.isEmpty ? [header: headerValue]
            : header.isEmpty ? [:]
            : nil
        let value = headerValue
        headerValue = ""
        Task {
            do {
                try await app.saveMCP(entry, headers: value.isEmpty && !header.isEmpty ? nil : headers, clientSecret: secret)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// A server's authorization page for a redirect URL that isn't a loopback one (an https page or a custom scheme the
/// user's OAuth app has registered): navigating to it is caught here, never loaded, and its URL (code, state) handed to
/// pi, as pasting the redirect URL does in pi. Google's own sign-in refuses embedded views, so a server whose login
/// goes through it needs the default redirect instead.
private struct OAuthSignInView: View {
    let url: URL
    let redirect: URL
    let respond: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            OAuthWebView(url: url, redirect: redirect, respond: respond)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(url.host() ?? "Sign in")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct OAuthWebView: UIViewRepresentable {
    let url: URL
    let redirect: URL
    let respond: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(redirect: redirect, respond: respond) }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let redirect: URL
        let respond: (URL) -> Void
        private var responded = false

        init(redirect: URL, respond: @escaping (URL) -> Void) {
            self.redirect = redirect
            self.respond = respond
        }

        /// The redirect URL itself: same scheme, host, port, and path (the query carries the answer).
        private func isRedirect(_ url: URL) -> Bool {
            url.scheme?.lowercased() == redirect.scheme?.lowercased() && url.host()?.lowercased() == redirect.host()?.lowercased()
                && url.port == redirect.port && (url.path().isEmpty ? "/" : url.path()) == (redirect.path().isEmpty ? "/" : redirect.path())
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let target = action.request.url, isRedirect(target) else { return .allow }
            if !responded {
                responded = true
                respond(target)
            }
            return .cancel
        }
    }
}
