import SwiftUI

struct HeaderView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @State private var showingSettings = false
    @Namespace private var tabAnimation

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 0) {
                TabButton(
                    title: "Projects",
                    count: appState.projects.count,
                    isActive: appState.activeTab == .projects,
                    namespace: tabAnimation
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        appState.activeTab = .projects
                    }
                }

                TabButton(
                    title: "Artifacts",
                    count: appState.artifacts.count,
                    isActive: appState.activeTab == .artifacts,
                    namespace: tabAnimation
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        appState.activeTab = .artifacts
                    }
                }
            }

            Spacer()

            RelayStatusIndicator()
                .onTapGesture {
                    showingSettings.toggle()
                }
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                    RelaySettingsView()
                        .environmentObject(appState)
                        .frame(width: 320)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .padding(.top, floatingMode ? 8 : 0)
        .background(floatingMode ? Color.clear : Color.hudBackground)
    }
}

struct RelayStatusIndicator: View {
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false
    @State private var pulseAnimation = false

    private var statusColor: Color {
        appState.relayClient.isConnected ? .statusReady : .orange
    }

    var body: some View {
        HStack(spacing: 5) {
            if appState.relayClient.isConfigured {
                ZStack {
                    if appState.relayClient.isConnected {
                        Circle()
                            .fill(statusColor.opacity(0.4))
                            .frame(width: 12, height: 12)
                            .blur(radius: 4)
                            .scaleEffect(pulseAnimation ? 1.2 : 0.8)
                            .opacity(pulseAnimation ? 0.3 : 0.6)
                    }

                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .shadow(color: statusColor.opacity(0.5), radius: 2)
                }

                if appState.isRemoteMode {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(isHovered ? 0.7 : 0.5))
                }
            } else {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(isHovered ? 0.5 : 0.3))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(isHovered ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.white.opacity(isHovered ? 0.12 : 0), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
        .onAppear {
            if appState.relayClient.isConnected {
                withAnimation(
                    .easeInOut(duration: 1.5)
                    .repeatForever(autoreverses: true)
                ) {
                    pulseAnimation = true
                }
            }
        }
    }
}

struct TabButton: View {
    let title: String
    let count: Int
    let isActive: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: isActive ? .semibold : .medium))

                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(
                                    isActive
                                        ? LinearGradient(
                                            colors: [Color.hudAccent.opacity(0.35), Color.hudAccent.opacity(0.2)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                          )
                                        : LinearGradient(
                                            colors: [Color.white.opacity(0.12), Color.white.opacity(0.08)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                          )
                                )
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isActive ? Color.hudAccent.opacity(0.3) : Color.white.opacity(0.08),
                                    lineWidth: 0.5
                                )
                        )
                }
                .foregroundColor(isActive ? .white : .white.opacity(isHovered ? 0.75 : 0.55))

                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 2)

                    if isActive {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(
                                LinearGradient(
                                    colors: [Color.hudAccent, Color.hudAccent.opacity(0.7)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 20, height: 2)
                            .shadow(color: Color.hudAccent.opacity(0.5), radius: 4, y: 0)
                            .matchedGeometryEffect(id: "tabIndicator", in: namespace)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
