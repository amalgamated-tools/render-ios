import SwiftUI

/// The app's visual constants in one place.
///
/// Everything here was previously an inline literal repeated across a handful of screens — three
/// different corner radii with no rule behind which went where, the same capsule geometry typed out
/// twice, `.opacity(0.12)` in five files. Naming them is not about the numbers being sacred; it is
/// about a change to the card radius being one edit rather than nine.
///
/// Deliberately small. A token nobody uses twice is a liability, so a constant only earns a name
/// here once a second call site wants it.
enum Theme {
    /// Corner radii. The previous 10/12/14 spread was ad-hoc; these collapse it to three rungs with
    /// a reason attached to each.
    enum Radius {
        /// Text fields and inline controls.
        static let control: CGFloat = 10
        /// List cards and grouped sections.
        static let card: CGFloat = 14
        /// Hero surfaces — the service-detail header, the onboarding panel.
        static let hero: CGFloat = 20
    }

    enum Spacing {
        static let tight: CGFloat = 6
        static let row: CGFloat = 12
        static let section: CGFloat = 20
    }

    /// Status pills and inline badges. Shared by ``StatusChip`` and the suspended/replica badges.
    enum Chip {
        static let horizontalPadding: CGFloat = 8
        static let verticalPadding: CGFloat = 3

        /// The tint opacity behind a chip's label. The same fill that reads correctly on white is
        /// nearly invisible against a dark background, hence the two values rather than one.
        static let fillOpacity: Double = 0.12
        static let darkFillOpacity: Double = 0.22

        static func fillOpacity(for scheme: ColorScheme) -> Double {
            scheme == .dark ? darkFillOpacity : fillOpacity
        }
    }

    /// Glyph tiles in list rows: a tinted rounded square behind the type symbol. A bare symbol
    /// floating in a row reads as unfinished; the same symbol on a tile reads as designed, and it
    /// costs one background modifier.
    enum Glyph {
        static let size: CGFloat = 34
        static let radius: CGFloat = 9
        static let fillOpacity: Double = 0.15
    }

    /// The brand gradient, for hero surfaces. Two stops and low contrast on purpose — a gradient
    /// that announces itself dates faster than one that just adds depth.
    static let brandGradient = LinearGradient(
        colors: [Color(.brand), Color(.brandDeep)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
