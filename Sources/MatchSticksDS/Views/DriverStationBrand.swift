import SwiftUI
import DSCore

struct DriverStationBrandView: View {
    @Bindable var model: DSModel

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(nsImage: model.appIconCenter.artwork ?? NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            Text("MatchSticks Driver Station")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("driver-station-brand-name")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("MatchSticks Driver Station")
    }
}
