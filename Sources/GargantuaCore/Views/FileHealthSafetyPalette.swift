import SwiftUI

extension SafetyLevel {
    var tintColor: Color {
        switch self {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }

    var tintBackground: Color {
        switch self {
        case .safe: GargantuaColors.safeDim
        case .review: GargantuaColors.reviewDim
        case .protected_: GargantuaColors.protectedDim
        }
    }
}
