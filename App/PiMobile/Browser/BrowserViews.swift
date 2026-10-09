import SwiftUI
import WebKit

/// A full-screen browser: an agent's, which the user watches and can take control of, or the user's own on a profile.
struct BrowserScreen: View {
    @Bindable var browser: BrowserSession
    let profileName: String
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @FocusState private var editingAddress: Bool

    private var agentBrowser: Bool {
        if case .session = browser.owner { return true }
        return false
    }

    /// The user drives their own browser always, and an agent's only after taking control.
    private var interactive: Bool { !agentBrowser || browser.userHasControl }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Done") { dismiss() }.fontWeight(.semibold)
                addressBar
                tabsMenu
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            if let tab = browser.active {
                BrowserTabView(tab: tab, interactive: interactive)
                    .id(tab.id)
                    .overlay(alignment: .top) {
                        if tab.isLoading { ProgressView().progressViewStyle(.linear).tint(.accentColor) }
                    }
                    .overlay(alignment: .bottom) {
                        if let dialog = browser.pendingDialog { dialogBanner(dialog) }
                    }
            } else {
                ContentUnavailableView("No page open", systemImage: "globe", description: Text(agentBrowser
                    ? "Pages the agent opens show here."
                    : "Search or enter a website above."))
                    .frame(maxHeight: .infinity)
            }

            toolbar
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
        }
        .onAppear {
            address = browser.active?.url?.absoluteString ?? ""
            if !agentBrowser, browser.active?.url == nil { editingAddress = true }
        }
        .onChange(of: browser.active?.url) { if !editingAddress { address = browser.active?.url?.absoluteString ?? "" } }
        // Leaving the screen hands an agent's browser back.
        .onDisappear { browser.userHasControl = false }
    }

    /// A dialog the page is waiting on: answered by the agent, or by the user once they have control.
    private func dialogBanner(_ dialog: PageDialog) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dialog.host.isEmpty ? "The page asks" : "\(dialog.host) asks").font(.caption).foregroundStyle(.secondary)
            Text(dialog.message).font(.subheadline)
            if interactive {
                HStack {
                    Spacer()
                    if dialog.kind != .alert { Button("Cancel") { browser.answerDialog(.dismiss) } }
                    Button("OK") { browser.answerDialog(.accept(nil)) }.buttonStyle(.borderedProminent)
                }
            } else {
                Text("Waiting for pi to answer").font(.caption).foregroundStyle(.tint)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .padding()
    }

    @ViewBuilder
    private var addressBar: some View {
        if interactive {
            TextField("Search or enter website", text: $address)
                .focused($editingAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .onSubmit { browser.open(address) }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
        } else {
            HStack(spacing: 4) {
                Image(systemName: browser.active?.url?.scheme == "https" ? "lock.fill" : "globe").font(.caption2)
                Text(browser.active?.url?.host() ?? profileName).lineLimit(1)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
    }

    private var tabsMenu: some View {
        Menu {
            ForEach(Array(browser.tabs.enumerated()), id: \.element.id) { index, tab in
                Button {
                    browser.select(index)
                } label: {
                    Label(tab.title.isEmpty ? (tab.url?.host() ?? "New tab") : tab.title,
                          systemImage: index == browser.activeIndex ? "checkmark" : "square")
                }
            }
            if interactive {
                Divider()
                Button("New tab", systemImage: "plus") {
                    browser.openTab()
                    address = ""
                    editingAddress = true
                }
                .disabled(browser.tabs.count >= BrowserService.maxTabs)
                if let tab = browser.active {
                    Button("Close tab", systemImage: "xmark", role: .destructive) { browser.close(tab) }
                }
            }
        } label: {
            Image(systemName: "square.on.square")
                .overlay(alignment: .topTrailing) {
                    if browser.tabs.count > 1 {
                        Text("\(browser.tabs.count)").font(.caption2.bold()).offset(x: 6, y: -6)
                    }
                }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 22) {
            Button("Back", systemImage: "chevron.backward") { browser.active?.webView.goBack() }
                .disabled(!interactive || browser.active?.canGoBack != true)
            Button("Forward", systemImage: "chevron.forward") { browser.active?.webView.goForward() }
                .disabled(!interactive || browser.active?.canGoForward != true)
            Button("Reload", systemImage: "arrow.clockwise") { browser.active?.webView.reload() }
                .disabled(!interactive || browser.active == nil)
            Spacer()
            if agentBrowser {
                Button(browser.userHasControl ? "Hand back to pi" : "Take control") { browser.userHasControl.toggle() }
                    .buttonStyle(.borderedProminent)
                    .labelStyle(.titleOnly)
            } else {
                Text(profileName).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .labelStyle(.iconOnly)
    }
}

/// A tab's live web view. Leaving the screen parks the web view back in the window.
struct BrowserTabView: UIViewRepresentable {
    let tab: BrowserTab
    let interactive: Bool

    func makeCoordinator() -> BrowserTab { tab }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        attach(tab.webView, to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        container.isUserInteractionEnabled = interactive
        if tab.webView.superview !== container { attach(tab.webView, to: container) }
    }

    static func dismantleUIView(_ container: UIView, coordinator tab: BrowserTab) {
        if tab.webView.superview === container { BrowserService.park(tab.webView) }
    }

    private func attach(_ webView: WKWebView, to container: UIView) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}

/// Hosts parked web views in the window, behind everything.
struct BrowserParkingView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { BrowserService.parking }
    func updateUIView(_ uiView: UIView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? { CGSize(width: 1, height: 1) }
}

/// A session's browser above the composer: what the agent has open; tap to watch or take over.
struct BrowserCard: View {
    let browser: BrowserSession
    let profileName: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Group {
                    if let thumbnail = browser.thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: "globe").foregroundStyle(.tint)
                    }
                }
                .frame(width: 32, height: 44, alignment: .top)
                .background(Color(.tertiarySystemBackground))
                .clipShape(.rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(profileName) · \(browser.active?.url?.host() ?? "no page")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if browser.userHasControl {
                    Text("You have control").font(.caption2.bold()).foregroundStyle(.tint)
                }
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Browser: \(title). Open")
    }

    private var title: String {
        if let tab = browser.active, !tab.title.isEmpty { return tab.title }
        return browser.tabs.count > 1 ? "\(browser.tabs.count) tabs" : "Browser"
    }
}
