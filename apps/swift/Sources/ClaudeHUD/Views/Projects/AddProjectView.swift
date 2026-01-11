import SwiftUI

struct AddProjectView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode

    @State private var appeared = false
    @State private var isDragHovered = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                BackButton(title: "Projects") {
                    appState.showProjectList()
                }
                .keyboardShortcut("[", modifiers: .command)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Spacer()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.hudAccent.opacity(0.08))
                        .frame(width: 100, height: 100)
                        .blur(radius: 25)
                        .scaleEffect(appeared ? 1.0 : 0.5)
                        .opacity(appeared ? 1 : 0)

                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                            )
                            .foregroundColor(.white.opacity(isDragHovered ? 0.4 : 0.15))

                        VStack(spacing: 14) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(isDragHovered ? 0.7 : 0.4),
                                            .white.opacity(isDragHovered ? 0.5 : 0.25)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .scaleEffect(isDragHovered ? 1.1 : 1.0)

                            VStack(spacing: 4) {
                                Text("Drop folder here")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.6))

                                Text("or browse to add")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.35))
                            }
                        }
                    }
                    .frame(width: 180, height: 140)
                    .scaleEffect(appeared ? 1.0 : 0.9)
                    .opacity(appeared ? 1 : 0)
                }

                Text("Project discovery coming soon")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isDragHovered)

            Spacer()
        }
        .background(floatingMode ? Color.clear : Color.hudBackground)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.15)) {
                appeared = true
            }
        }
    }
}
