import AppKit
import SwiftUI

/// Local adaptation of the repository's Quiet Sidebar primitives. No engine dependency.
@MainActor
enum NativeStyle {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let rail = Color(nsColor: .underPageBackgroundColor)
    static let border = Color(nsColor: .separatorColor).opacity(0.55)
    static let blue = Color.accentColor
    static let radius: CGFloat = 10
}

extension View {
    @MainActor func nativePanel() -> some View {
        background(NativeStyle.surface, in: RoundedRectangle(cornerRadius: NativeStyle.radius))
            .overlay { RoundedRectangle(cornerRadius: NativeStyle.radius).strokeBorder(NativeStyle.border, lineWidth: 1) }
    }
}

struct NativeBrandMark: View {
    var size: CGFloat = 38
    private static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }()
    var body: some View {
        Group {
            if let image = Self.image { Image(nsImage: image).resizable().interpolation(.high) }
            else {
                // The packaged/fixture app supplies the real mark. A source run
                // without resources retains readable identity instead of a fake logo.
                Text("K").font(.system(size: size * 0.57, weight: .bold)).foregroundStyle(.white)
                    .frame(width: size, height: size).background(Color(red: 0.08, green: 0.13, blue: 0.17), in: RoundedRectangle(cornerRadius: size * 0.22))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct NativeStatusChip: View {
    let title: String
    let symbol: String
    var tint: Color = .secondary
    var body: some View {
        Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint).padding(.horizontal, 10).padding(.vertical, 6)
            .background(tint.opacity(0.08), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct NativeStep: View {
    let number: Int
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(number)).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary).frame(width: 25, height: 25)
                .background(.secondary.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
