import SwiftUI

struct HeaderView: View {
    @Environment(\.floatingMode) private var floatingMode

    private let headerBlurHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                AddProjectButton()
            }
            .padding(.horizontal, 12)
            .padding(.top, floatingMode ? 12 : 8)
            .padding(.bottom, 8)

            if floatingMode {
                Spacer()
                    .frame(height: headerBlurHeight - 44)
            }
        }
        .frame(height: floatingMode ? headerBlurHeight : nil)
        .background {
            if !floatingMode {
                Color.hudBackground
            }
        }
    }
}
