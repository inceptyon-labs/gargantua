import SwiftUI

// Color and icon tokens for `ProcessInventoryRow`. Pulled into an extension
// file so the row body stays under SwiftLint's `file_length` cap and the
// row layout file can stay focused on layout.
extension ProcessInventoryRow {
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

    var confidenceBackground: Color {
        switch item.launchConfidence {
        case .exact: GargantuaColors.safe.opacity(0.18)
        case .path: GargantuaColors.accent.opacity(0.14)
        case .heuristic: GargantuaColors.review.opacity(0.14)
        case .unknown: GargantuaColors.ink4.opacity(0.18)
        }
    }

    var confidenceForeground: Color {
        switch item.launchConfidence {
        case .exact: GargantuaColors.safe
        case .path: GargantuaColors.accent
        case .heuristic: GargantuaColors.review
        case .unknown: GargantuaColors.ink2
        }
    }

    func chipBackground(for reason: ProcessReason) -> Color {
        switch reason {
        case .sensitiveVendor, .unsigned, .orphaned, .rootProcess:
            GargantuaColors.review.opacity(0.18)
        case .system:
            GargantuaColors.protected_.opacity(0.18)
        case .foregroundApp:
            GargantuaColors.accent.opacity(0.14)
        }
    }

    func chipForeground(for reason: ProcessReason) -> Color {
        switch reason {
        case .sensitiveVendor, .unsigned, .orphaned, .rootProcess:
            GargantuaColors.review
        case .system:
            GargantuaColors.protected_
        case .foregroundApp:
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
