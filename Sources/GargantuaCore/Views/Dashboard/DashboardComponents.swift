import SwiftUI

struct DashboardSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            Text(title)
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink4)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DashboardEvidencePill: View {
    let text: String
    var monospaced: Bool = false

    var body: some View {
        Text(text)
            .font(monospaced ? GargantuaFonts.monoData : GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink2)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space1)
            .background(Capsule().fill(GargantuaColors.surface3))
    }
}
