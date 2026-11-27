import SwiftUI

@main
struct AiboApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Color.sea)
                .task { await model.boot() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.resume() } }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                Avatar(size: 96)
                    .tilt("aibo", by: 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .paper()
            case .signedOut:
                SignInView()
            case .onboarding:
                OnboardingView()
            case .ready:
                HomeView()
            case .failed(let message):
                VStack(spacing: 16) {
                    Avatar(size: 96).tilt("aibo", by: 6).saturation(0.3)
                    Text("Can't reach \(model.characterName) right now")
                        .font(.aiboTitle)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(.aiboCallout)
                        .foregroundStyle(Color.inkSoft)
                        .multilineTextAlignment(.center)
                    WideButton(title: "Try again", symbol: "arrow.clockwise") { Task { await model.boot() } }
                        .padding(.top, 8)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .paper()
            }
        }
        .animation(.snappy, value: model.phase)
    }
}
