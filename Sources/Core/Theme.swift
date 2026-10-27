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

// The small all-caps label above a group of rows.
struct SectionLabel: View {
    let text: String
    var color: Color = Palette.muted
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).tracking(1).foregroundStyle(color)
    }
}

// A dashboard section's title with a one-line explanation under it.
struct SectionHeading: View {
    let title: String
    let caption: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.muted)
            Text(caption).font(.system(size: 13)).foregroundStyle(Palette.muted)
        }
    }
}

// The bar at the top of a tool's page: "Area / Page", what it is doing or when it last checked, and actions.
struct ToolHeader<Actions: View>: View {
    let area: String
    let icon: String
    let page: String
    var working: String?
    var checked: String?
    @ViewBuilder let actions: Actions
    var body: some View {
        HStack {
            Label(area, systemImage: icon).foregroundStyle(Palette.muted).font(.system(size: 14, weight: .medium))
            Text("/").foregroundStyle(Palette.muted.opacity(0.5)).padding(.horizontal, 7)
            Text(page).font(.system(size: 14, weight: .medium))
            Spacer()
            if let working { ProgressView().controlSize(.small); Text(working).font(.system(size: 13)).foregroundStyle(Palette.muted) }
            else if let checked { Text(checked).font(.system(size: 13)).foregroundStyle(Palette.muted) }
            actions
        }.padding(.horizontal, 30).frame(height: 78)
    }
}

// A tool's errors and its dismissible notice: plain lines in the menu-bar panel, banners on a page.
struct MessageList: View {
    let errors: [String]
    let notice: String?
    var compact = false
    let dismiss: () -> Void
    var body: some View {
        ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
            if compact { Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            else { Banner(text: error, icon: "exclamationmark.triangle", color: .orange) }
        }
        if let notice {
            HStack(alignment: .top) {
                if compact { Text(notice).font(.system(size: 12)).foregroundStyle(Palette.mint).textSelection(.enabled) }
                else { Banner(text: notice, icon: "checkmark.circle", color: Palette.mint) }
                Spacer(minLength: 0)
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
                    .foregroundStyle(Palette.muted).padding(.top, compact ? 0 : 15).accessibilityLabel("Dismiss")
            }
        }
    }
}
