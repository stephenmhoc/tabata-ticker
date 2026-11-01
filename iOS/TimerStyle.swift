import SwiftUI

// Glass controls always sit on a dark phase gradient, so their content stays light.
let glassControlForeground = Color.white

// The phone and the iPad run the same screens at different sizes; keeping the numbers together makes
// the two layouts comparable instead of scattering a size-class check across every view.
struct TimerMetrics {
    private let isRegular: Bool

    init(horizontalSizeClass: UserInterfaceSizeClass?) {
        isRegular = horizontalSizeClass == .regular
    }

    var contentMaxWidth: CGFloat? { isRegular ? 720 : nil }
    var controlsMaxWidth: CGFloat? { isRegular ? 560 : 320 }
    var horizontalPadding: CGFloat { isRegular ? 48 : 20 }
    var verticalPadding: CGFloat { isRegular ? 56 : 24 }
    var verticalSpacing: CGFloat { isRegular ? 34 : 24 }
    var readoutSpacing: CGFloat { isRegular ? 22 : 18 }
    var titleSize: CGFloat { isRegular ? 64 : 50 }
    var primaryButtonHeight: CGFloat { isRegular ? 72 : 54 }
    var resetButtonHeight: CGFloat { isRegular ? 60 : 48 }
    var settingsButtonSize: CGFloat { isRegular ? 52 : 44 }

    var roundFont: Font { isRegular ? .title.weight(.semibold) : .title2.weight(.semibold) }
    var primaryButtonFont: Font { isRegular ? .title3.weight(.bold) : .headline.weight(.bold) }
    var settingsButtonFont: Font { isRegular ? .title2.weight(.semibold) : .title3.weight(.semibold) }
}

extension Color {
    init(_ tabataColor: TabataColor) {
        self.init(red: tabataColor.red, green: tabataColor.green, blue: tabataColor.blue)
    }
}
