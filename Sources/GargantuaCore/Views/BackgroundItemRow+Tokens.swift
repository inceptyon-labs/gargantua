import SwiftUI

extension BackgroundItemRow {
    var safetyColor: Color {
        switch item.safety {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }

    var safetyTint: Color {
        switch item.safety {
        case .safe: GargantuaColors.safeDim
        case .review: GargantuaColors.reviewDim
        case .protected_: GargantuaColors.protectedDim
        }
    }

    var safetySFSymbol: String {
        switch item.safety {
        case .safe: "checkmark.shield.fill"
        case .review: "questionmark.diamond.fill"
        case .protected_: "lock.fill"
        }
    }

    func chipBackground(for reason: BackgroundItemReason) -> Color {
        switch reason {
        case .sensitiveVendor, .unsigned, .orphaned, .orphanedVendor:
            GargantuaColors.review.opacity(0.18)
        case .system:
            GargantuaColors.protected_.opacity(0.18)
        case .disabledFlag:
            GargantuaColors.ink4.opacity(0.18)
        case .listensForRequests, .persistentlyRunning, .scheduled:
            GargantuaColors.accent.opacity(0.14)
        }
    }

    func chipForeground(for reason: BackgroundItemReason) -> Color {
        switch reason {
        case .sensitiveVendor, .unsigned, .orphaned, .orphanedVendor:
            GargantuaColors.review
        case .system:
            GargantuaColors.protected_
        case .disabledFlag:
            GargantuaColors.ink2
        case .listensForRequests, .persistentlyRunning, .scheduled:
            GargantuaColors.accent
        }
    }

    func vendorLabel(_ vendor: VendorClassification) -> String {
        switch vendor {
        case .apple: "Apple"
        case .thirdPartyKnown: "Third-party (known)"
        case .thirdPartyUnknown: "Third-party (unknown)"
        case .unsigned: "Unsigned / unverifiable"
        }
    }
}
