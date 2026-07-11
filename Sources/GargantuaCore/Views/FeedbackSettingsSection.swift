import GargantuaLicensing
import SwiftUI

/// Settings → About → Feedback. One row that opens the report sheet; reports
/// go to the private feedback tracker through the intake worker, no GitHub
/// account required.
struct FeedbackSettingsSection: View {
    @State private var isShowingSheet = false

    var body: some View {
        SettingsSectionContainer(
            "Feedback",
            subtitle: "Bugs and feature requests, straight to the developer."
        ) {
            HStack(spacing: GargantuaSpacing.space3) {
                SettingsRowIcon(systemName: "paperplane", size: 16)

                SettingsRowText(
                    title: "Report a bug or request a feature",
                    detail: "No account needed. Includes app version, macOS version, and build type."
                )

                Spacer(minLength: GargantuaSpacing.space3)

                GargantuaButton("Send Feedback", icon: "paperplane.fill", tone: .ghost(GargantuaColors.accent)) {
                    isShowingSheet = true
                }
                .help("Open the feedback form")
            }
        }
        .sheet(isPresented: $isShowingSheet) {
            FeedbackSheet(onDismiss: { isShowingSheet = false })
        }
    }
}

/// The report form. Self-contained: owns its draft, submission state, and the
/// client call.
struct FeedbackSheet: View {
    let onDismiss: () -> Void
    var client = FeedbackClient()

    @State private var kind: FeedbackReport.Kind = .bug
    @State private var titleDraft = ""
    @State private var detailsDraft = ""
    @State private var emailDraft = ""
    @State private var isSending = false
    @State private var didSend = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text("Send Feedback")
                    .font(GargantuaFonts.title)
                    .foregroundStyle(GargantuaColors.ink)

                Text("Filed directly into the tracker. This is the fastest way to reach the developer.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }

            Picker("Kind", selection: $kind) {
                Text("Bug").tag(FeedbackReport.Kind.bug)
                Text("Feature request").tag(FeedbackReport.Kind.feature)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(isSending || didSend)

            TextField(kind == .bug ? "What went wrong, in one line" : "What you'd like, in one line", text: $titleDraft)
                .textFieldStyle(.roundedBorder)
                .font(GargantuaFonts.body)
                .disabled(isSending || didSend)

            TextEditor(text: $detailsDraft)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink)
                .scrollContentBackground(.hidden)
                .padding(GargantuaSpacing.space2)
                .frame(minHeight: 120, maxHeight: 200)
                .background(GargantuaColors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .overlay(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .stroke(GargantuaColors.border, lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if detailsDraft.isEmpty {
                        Text(kind == .bug
                            ? "Steps to reproduce, what you expected, what happened instead."
                            : "The problem it solves and how you'd want it to work.")
                            .font(GargantuaFonts.body)
                            .foregroundStyle(GargantuaColors.ink4)
                            .padding(GargantuaSpacing.space2)
                            .padding(.top, 2)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(isSending || didSend)

            TextField("Email (optional) — only if you'd like a reply", text: $emailDraft)
                .textFieldStyle(.roundedBorder)
                .font(GargantuaFonts.body)
                .disabled(isSending || didSend)

            Text(
                "Attached automatically: \(diagnostics.appVersion) · macOS \(diagnostics.osVersion) "
                    + "· \(diagnostics.build) build. Nothing else leaves this Mac."
            )
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink4)

            if didSend {
                SettingsNoticeRow(
                    icon: "checkmark.circle.fill",
                    message: "Sent — thank you. It landed in the tracker.",
                    tone: .safe
                )
            } else if let errorMessage {
                SettingsNoticeRow(icon: "exclamationmark.triangle.fill", message: errorMessage, tone: .protected)
            }

            HStack(spacing: GargantuaSpacing.space3) {
                Spacer()

                if isSending {
                    AccretionDiskView(activityRate: 18, size: 12, color: GargantuaColors.accretion)
                }

                if didSend {
                    GargantuaButton("Done", tone: .primary) { onDismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    GargantuaButton("Cancel", tone: .neutral) { onDismiss() }
                        .keyboardShortcut(.cancelAction)

                    GargantuaButton(
                        isSending ? "Sending…" : "Send",
                        icon: "paperplane.fill",
                        tone: .primary,
                        isDisabled: isSending || !isSubmittable
                    ) {
                        send()
                    }
                }
            }
        }
        .padding(GargantuaSpacing.space5)
        .frame(width: 480)
        .background(GargantuaColors.surface3)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.large)
                .stroke(GargantuaColors.borderEm, lineWidth: 1)
        )
    }

    private var isSubmittable: Bool {
        !titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !detailsDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var diagnostics: FeedbackReport.Diagnostics {
        let bundle = Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return FeedbackReport.Diagnostics(
            appVersion: "\(short) (\(build))",
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            build: GargantuaBuildInfo.isLicensedBuild ? "licensed" : "source"
        )
    }

    private func send() {
        let email = emailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let report = FeedbackReport(
            kind: kind,
            title: titleDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            details: detailsDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.isEmpty ? nil : email,
            diagnostics: diagnostics
        )
        Task {
            isSending = true
            errorMessage = nil
            do {
                try await client.submit(report)
                didSend = true
            } catch FeedbackClientError.rateLimited {
                errorMessage = "Too many reports in a row — give it a minute and try again."
            } catch {
                errorMessage = "Couldn't send right now. Check your connection and try again."
            }
            isSending = false
        }
    }
}
