import SwiftUI

/// Colors only a label's icon. System green, orange, teal, and similar hues
/// fall below 4.5:1 contrast as small text, so the words keep the inherited
/// primary or secondary style and the icon carries the meaning.
struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        Label { configuration.title } icon: { configuration.icon.foregroundStyle(tint) }
    }
}

extension LabelStyle where Self == TintedIconLabelStyle {
    static func tintedIcon(_ tint: Color) -> TintedIconLabelStyle { TintedIconLabelStyle(tint: tint) }
}
