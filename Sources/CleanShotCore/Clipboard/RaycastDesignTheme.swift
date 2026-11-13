import SwiftUI
import AppKit

/// Raycast-inspired design tokens extracted from Raycast Desktop's visual styling:
/// dark smoked-glass surfaces, subtle 1px inner hairline borders, 3D inset keycap badges,
/// coral-red brand accent, and an 8-color semantic tag palette.
public enum RaycastTheme {
    public static let windowBackground = Color(red: 0.075, green: 0.082, blue: 0.102)       // #13151A
    public static let panelSurface = Color(red: 0.102, green: 0.114, blue: 0.141)           // #1A1D24
    public static let elevatedSurface = Color(red: 0.133, green: 0.149, blue: 0.184)        // #22262F
    public static let rowSelection = Color.white.opacity(0.11)
    public static let rowHover = Color.white.opacity(0.06)
    public static let borderSubtle = Color.white.opacity(0.10)
    public static let borderHighlight = Color.white.opacity(0.18)
    public static let textPrimary = Color.white.opacity(0.94)
    public static let textSecondary = Color.white.opacity(0.62)
    public static let textTertiary = Color.white.opacity(0.40)
    public static let accent = Color(red: 1.0, green: 0.388, blue: 0.388)                   // #FF6363

    public static let windowCornerRadius: CGFloat = 16
    public static let rowCornerRadius: CGFloat = 8
    public static let iconCornerRadius: CGFloat = 6

    public static func color(for tagColor: ClipboardTagColor) -> Color {
        switch tagColor {
        case .accent: return accent
        case .green: return Color(red: 0.25, green: 0.82, blue: 0.52)
        case .blue: return Color(red: 0.30, green: 0.62, blue: 1.00)
        case .yellow: return Color(red: 0.98, green: 0.80, blue: 0.24)
        case .orange: return Color(red: 1.00, green: 0.58, blue: 0.22)
        case .red: return Color(red: 0.96, green: 0.32, blue: 0.36)
        case .magenta: return Color(red: 0.92, green: 0.36, blue: 0.72)
        case .purple: return Color(red: 0.66, green: 0.44, blue: 0.98)
        }
    }

    public static func tagColor(for name: String) -> Color {
        let all = ClipboardTagColor.allCases
        var hash = 5381
        for byte in name.lowercased().utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        let idx = abs(hash) % all.count
        return color(for: all[idx])
    }
}

/// Authentic Raycast 3D inset-shadow keycap badge (`↵`, `⌘K`, `⇧⌘V`, etc.).
public struct RaycastKeycapBadge: View {
    public let keys: [String]

    public init(_ keys: [String]) {
        self.keys = keys
    }

    public init(_ single: String) {
        self.keys = [single]
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(RaycastTheme.textPrimary)
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, key.count > 1 ? 5 : 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [Color.white.opacity(0.28), Color.black.opacity(0.45)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ),
                                        lineWidth: 0.75
                                    )
                            )
                            .shadow(color: Color.black.opacity(0.45), radius: 0.5, x: 0, y: 1)
                    )
            }
        }
    }
}

/// Raycast colored capsule tag badge with dot indicator.
public struct RaycastTagPill: View {
    public let name: String
    public var onRemove: (() -> Void)?

    public init(name: String, onRemove: (() -> Void)? = nil) {
        self.name = name
        self.onRemove = onRemove
    }

    public var body: some View {
        let tint = RaycastTheme.tagColor(for: name)
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(RaycastTheme.textPrimary)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(RaycastTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(tint.opacity(0.16))
                .overlay(Capsule().strokeBorder(tint.opacity(0.32), lineWidth: 0.75))
        )
    }
}

/// Raycast 44pt frosted bottom action bar with command identity on the left and actions on the right.
public struct RaycastActionBar<TrailingContent: View>: View {
    public let title: String
    public let iconName: String
    @ViewBuilder public let trailing: () -> TrailingContent

    public init(title: String, iconName: String, @ViewBuilder trailing: @escaping () -> TrailingContent) {
        self.title = title
        self.iconName = iconName
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(RaycastTheme.accent.opacity(0.18))
                        .frame(width: 22, height: 22)
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RaycastTheme.accent)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RaycastTheme.textSecondary)
            }

            Spacer()

            trailing()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color.black.opacity(0.28))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(RaycastTheme.borderSubtle)
                .frame(height: 1)
        }
    }
}
