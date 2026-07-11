import SwiftUI

struct RootView: View {
    @EnvironmentObject private var radio: RadioController

    enum Route: Hashable {
        case conversation(UUID)
        case monitor
    }

    @State private var path: [Route] = []
    @State private var showSettings = false
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
                case .conversation(let id):
                    ConversationView(conversationID: id)
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
                    // Band Monitor's sole entry point is the pinned home
                    // row (with its live preview) — one concept, one place.
                    //
                    // Straight into a fresh CQ thread: on CW you can't address
                    // a station you haven't heard, so asking for a callsign
                    // up front was a question with no useful answer. You
                    // work stations by answering them (from the monitor or
                    // an existing thread); a new message is a general call.
                    Button { path.append(.conversation(radio.startNewConversation())) } label: {
                        Label("New Call", systemImage: "square.and.pencil")
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
                path = [.conversation(first.id)]
            }
        default:
            break
        }
    }
    #endif
}
