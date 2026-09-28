import SwiftUI

extension String {
    /// "climatise to 21.0 °C" → "Climatise to 21.0 °C".
    var capitalizingFirst: String { prefix(1).uppercased() + String(dropFirst()) }
}
