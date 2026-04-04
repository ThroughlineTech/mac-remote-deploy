// Animated splash screen shown on first launch.
// Displays the app icon with a fade-in animation before transitioning to the main UI.
import SwiftUI

/// Splash screen with animated rocket icon and branding.
struct SplashView: View {
    @State private var iconScale: CGFloat = 0.6
    @State private var iconOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var subtitleOpacity: Double = 0

    /// Called when the splash animation completes.
    var onFinished: () -> Void

    var body: some View {
        ZStack {
            // Background gradient matching the app icon
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.10, blue: 0.44),
                    Color(red: 0.00, green: 0.48, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // App icon
                Image("AppIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 140, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 30))
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)

                // App name
                VStack(spacing: 6) {
                    Text("RemoteDeploy")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .opacity(titleOpacity)

                    Text("Build. Deploy. From anywhere.")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                        .opacity(subtitleOpacity)
                }

                Spacer()

                // Company branding
                Text("Throughline Tech, LLC")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .opacity(subtitleOpacity)
                    .padding(.bottom, 40)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                iconScale = 1.0
                iconOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.3)) {
                titleOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.5)) {
                subtitleOpacity = 1.0
            }
            // Transition to main UI after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                onFinished()
            }
        }
    }
}
