import SwiftUI

struct NotchStyleHUD: View {
    let sliderFraction: Float
    let mute: Bool
    let deviceName: String
    let notchWidth: CGFloat
    let menuBarHeight: CGFloat

    private static let percentageWidth: CGFloat = 40
    private static let bottomOverhang: CGFloat = 14
    private static let barHeight: CGFloat = 3

    private var displayFloat: Float {
        max(0, min(1, sliderFraction))
    }

    private var displayedPercent: Int {
        Int((displayFloat * 100).rounded())
    }

    private var percentageText: String {
        "\(displayedPercent)%"
    }

    private var waveIconName: String {
        switch displayedPercent {
        case 0:        return "speaker.fill"
        case 1...33:   return "speaker.wave.1.fill"
        case 34...66:  return "speaker.wave.2.fill"
        default:       return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        let pillWidth = notchWidth + 180
        let pillHeight = menuBarHeight + Self.bottomOverhang

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Left Canvas (90pt wide)
                HStack(spacing: 6) {
                    Image(systemName: mute ? "speaker.slash.fill" : waveIconName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(mute
                                         ? DesignTokens.Colors.mutedIndicator
                                         : DesignTokens.Colors.hudTileActive)
                        .frame(width: 16, height: 16)
                    
                    Text(deviceName.isEmpty ? "Unknown" : deviceName)
                        .font(DesignTokens.Typography.rowNameBold)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(width: 90, alignment: .leading)
                
                // Center Gap (notchWidth)
                Spacer()
                    .frame(width: notchWidth)
                
                // Right Canvas (90pt wide)
                HStack(spacing: 0) {
                    Text(percentageText)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(mute
                                         ? DesignTokens.Colors.mutedIndicator
                                         : DesignTokens.Colors.textPrimary)
                        .frame(width: Self.percentageWidth, alignment: .trailing)
                }
                .frame(width: 90, alignment: .trailing)
            }
            .frame(height: menuBarHeight)
            .padding(.horizontal, 16)
            
            Spacer(minLength: 0)
            
            // Bottom Progress Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DesignTokens.Colors.textSecondary.opacity(0.2))
                        .frame(height: Self.barHeight)
                    Capsule()
                        .fill(DesignTokens.Colors.hudTileActive)
                        .frame(width: geo.size.width * CGFloat(displayFloat), height: Self.barHeight)
                }
            }
            .frame(height: Self.barHeight)
            .padding(.horizontal, 16)
            .padding(.bottom, 5)
        }
        .frame(width: pillWidth, height: pillHeight)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(
            bottomLeadingRadius: 12,
            bottomTrailingRadius: 12
        ))
    }
}
