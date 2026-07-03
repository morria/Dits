import SwiftUI

struct RootView: View {
    @EnvironmentObject private var radio: RadioController

    enum Route: Hashable {
        case conversation(String)
        case monitor
    }

    @State private var path: [Route] = []
    @State private var showSettings = false
    @State private var showNewConversation = false
    @State private var showOnboarding = false

    var body: some View {
        NavigationStack(path: $path) {
            ConversationListView(
                openConversation: { path.append(.conversation($0)) },
                openMonitor: { path.append(.monitor) }
            )
            .navigationTitle("Dits")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .conversation(let counterparty):
                    ConversationView(counterparty: counterparty)
                case .monitor:
                    // openConversation (not a bare path append) so the thread
                    // exists and appears in the list even before a first send.
                    MonitorView(openConversation: { path.append(.conversation(radio.openConversation($0))) })
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { path.append(.monitor) } label: {
                        Label("Band Monitor", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Button { showNewConversation = true } label: {
                        Label("New Message", systemImage: "square.and.pencil")
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                StatusBarView()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showNewConversation) {
            NewConversationSheet { counterparty in
                path.append(.conversation(radio.openConversation(counterparty)))
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingSheet()
        }
        .onAppear {
            #if DEBUG
            let demo = ProcessInfo.processInfo.environment["DITS_DEMO"] == "1"
            if !demo { radio.startIfNeeded() }
            DispatchQueue.main.async { applyLaunchRouting() }
            #else
            radio.startIfNeeded()
            #endif
            if !radio.settings.isConfigured {
                showOnboarding = true
            }
        }
    }

    #if DEBUG
    /// Lets screenshot tooling jump straight to a screen, e.g.
    /// `--open monitor|settings|chat`.
    private func applyLaunchRouting() {
        switch ProcessInfo.processInfo.environment["DITS_OPEN"] {
        case "monitor":
            path = [.monitor]
        case "settings":
            showSettings = true
        case "chat":
            if let first = radio.conversations.first {
                path = [.conversation(first.counterparty)]
            }
        default:
            break
        }
    }
    #endif
}
