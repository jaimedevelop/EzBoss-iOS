import SwiftUI

@main
struct EzBossApp: App {
    var body: some Scene {
        WindowGroup { LaunchView() }
    }
}

struct LaunchView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("EzBoss").font(.largeTitle.bold())
                Text("Development build").font(.headline)
                Text("Sign-in and company workflows are being connected. This build does not access company data.")
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .navigationTitle("EzBoss")
        }
    }
}
