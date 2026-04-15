import GargantuaCore
import SwiftUI

/// Root content view for the Gargantua window.
///
/// Fills the entire window with ``GargantuaColors/void_`` so no system
/// chrome is visible behind the transparent titlebar.
struct MainContentView: View {
    var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()
        }
    }
}
