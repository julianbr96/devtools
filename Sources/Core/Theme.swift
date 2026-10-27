import SwiftUI

// The macOS 27 SDK declares @State as a macro, and the Command Line Tools ship without SwiftUI's
// macro plugin, so plain swiftc cannot expand it. Views use this alias for the State property wrapper.
typealias ViewState = SwiftUI.State

enum Palette {
    static let background = Color(red: 0.055, green: 0.067, blue: 0.083)
    static let sidebar = Color(red: 0.074, green: 0.087, blue: 0.106)
    static let surface = Color(red: 0.091, green: 0.106, blue: 0.125)
    static let border = Color.white.opacity(0.09)
    static let accent = Color(red: 0.94, green: 0.62, blue: 0.47)
    static let mint = Color(red: 0.48, green: 0.84, blue: 0.70)
    static let muted = Color(red: 0.62, green: 0.66, blue: 0.72)
    static func quota(_ remaining: Double?) -> Color {
        guard let remaining else { return muted }
        return remaining <= 10 ? .red.opacity(0.85) : remaining <= 30 ? .orange : mint
    }
}

struct ActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 15).padding(.vertical, 10)
            .foregroundStyle(primary ? Palette.background : Color.white.opacity(0.9))
            .background(primary ? Palette.accent : Color.white.opacity(configuration.isPressed ? 0.13 : 0.055))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(primary ? Color.clear : Palette.border))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.72 : 1)
    }
}

struct Tag: View {
    let text: String
    var color: Color = Palette.muted
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

struct Banner: View {
    let text: String
    let icon: String
    let color: Color
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).foregroundStyle(color).padding(.top, 2)
            Text(text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(15).background(color.opacity(0.065)).clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(color.opacity(0.17)))
    }
}
