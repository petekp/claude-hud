import SwiftUI

struct HeaderView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @State private var showingSettings = false

    var body: some View {
        HStack(spacing: 16) {
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
        .padding(.vertical, 8)
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

