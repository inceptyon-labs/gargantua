import SwiftUI

struct DashboardMCPStatusPresentation: Equatable {
    enum Tone: Equatable {
        case safe
        case review
        case protected
        case muted

        var color: Color {
            switch self {
            case .safe: return GargantuaColors.safe
            case .review: return GargantuaColors.review
            case .protected: return GargantuaColors.protected_
            case .muted: return GargantuaColors.ink4
            }
        }
    }

    let title: String
    let detail: String
    let clientSummary: String
    let actionLabel: String
    let actionSystemImage: String
    let tone: Tone
    let isActionEnabled: Bool

    static func make(from snapshot: MCPServerStatusSnapshot) -> DashboardMCPStatusPresentation {
        let clientSummary = Self.clientSummary(for: snapshot.clients)
        switch snapshot.state {
        case .starting:
            return DashboardMCPStatusPresentation(
                title: "Starting",
                detail: "Launching local SSE transport",
                clientSummary: clientSummary,
                actionLabel: "Starting",
                actionSystemImage: "hourglass",
                tone: .review,
                isActionEnabled: false
            )
        case .running:
            return DashboardMCPStatusPresentation(
                title: "Running",
                detail: "\(snapshot.transportMode.displayName) transport · \(clientSummary.lowercased())",
                clientSummary: clientSummary,
                actionLabel: "Stop",
                actionSystemImage: "stop.circle",
                tone: .safe,
                isActionEnabled: true
            )
        case .stopped:
            return DashboardMCPStatusPresentation(
                title: "Stopped",
                detail: "Local SSE transport idle",
                clientSummary: clientSummary,
                actionLabel: "Start",
                actionSystemImage: "play.circle",
                tone: .muted,
                isActionEnabled: true
            )
        case .error:
            return DashboardMCPStatusPresentation(
                title: "Needs attention",
                detail: snapshot.lastErrorMessage ?? "Server status unavailable.",
                clientSummary: clientSummary,
                actionLabel: "Retry",
                actionSystemImage: "arrow.clockwise.circle",
                tone: .review,
                isActionEnabled: true
            )
        }
    }

    private static func clientSummary(for clients: [MCPConnectedClient]) -> String {
        switch clients.count {
        case 0: return "No clients"
        case 1: return clients[0].displayName
        default: return "\(clients.count) clients"
        }
    }
}

struct DashboardMCPStatusCard: View {
    @ObservedObject var model: MCPServerStatusViewModel
    let onOpenAuditLog: () -> Void

    @State private var isExpanded = false
    @State private var showsStopConfirmation = false

    private var snapshot: MCPServerStatusSnapshot { model.snapshot }
    private var presentation: DashboardMCPStatusPresentation {
        DashboardMCPStatusPresentation.make(from: snapshot)
    }
    private var showsRecentActions: Bool { isExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            HStack(alignment: .center, spacing: GargantuaSpacing.space2) {
                Text("MCP SERVER")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(GargantuaColors.ink4)

                Circle()
                    .fill(presentation.tone.color)
                    .frame(width: 7, height: 7)

                Spacer(minLength: GargantuaSpacing.space2)

                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GargantuaColors.ink3)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide recent MCP actions" : "Show recent MCP actions")
            }

            Text(presentation.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(GargantuaColors.ink)
                .lineLimit(1)

            Text(presentation.detail)
                .font(GargantuaFonts.caption)
                .foregroundStyle(snapshot.state == .error ? GargantuaColors.review : GargantuaColors.ink3)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: GargantuaSpacing.space2) {
                MCPStatusMeta(text: snapshot.transportMode.displayName, systemImage: "terminal")
                MCPStatusMeta(text: presentation.clientSummary, systemImage: "person.2")
            }

            if !snapshot.clients.isEmpty {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    ForEach(snapshot.clients.prefix(2)) { client in
                        HStack(spacing: GargantuaSpacing.space1) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(GargantuaColors.accent)
                            Text(client.displayName)
                                .font(GargantuaFonts.caption)
                                .foregroundStyle(GargantuaColors.ink2)
                                .lineLimit(1)
                        }
                    }
                }
            }

            if showsRecentActions {
                recentActions
            }

            Spacer(minLength: 0)

            HStack(spacing: GargantuaSpacing.space2) {
                Button(action: requestControlAction) {
                    Label(presentation.actionLabel, systemImage: presentation.actionSystemImage)
                        .font(GargantuaFonts.caption)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(GargantuaColors.ink)
                        .padding(.horizontal, GargantuaSpacing.space3)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.surface3)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                        .overlay(
                            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                .stroke(GargantuaColors.borderEm, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!presentation.isActionEnabled)
                .opacity(presentation.isActionEnabled ? 1 : 0.6)

                Button(action: onOpenAuditLog) {
                    Label("MCP Audit", systemImage: "doc.text.magnifyingglass")
                        .font(GargantuaFonts.caption)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(GargantuaColors.accent)
                }
                .buttonStyle(.plain)
                .help("Open MCP audit log")
            }
        }
        .padding(GargantuaSpacing.space4)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(GargantuaColors.surface1)
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(presentation.tone.color)
                .frame(width: 28, height: 2)
                .padding(.horizontal, GargantuaSpacing.space4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        .confirmationDialog(
            "Stop MCP server?",
            isPresented: $showsStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Server", role: .destructive) {
                model.stop()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Connected MCP clients will disconnect.")
        }
    }

    private var recentActions: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            Text("RECENT MCP")
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink4)

            if snapshot.recentActions.isEmpty {
                Text("No recent MCP actions")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            } else {
                ForEach(snapshot.recentActions.prefix(3)) { action in
                    HStack(spacing: GargantuaSpacing.space2) {
                        Text(action.command)
                            .font(GargantuaFonts.monoPath)
                            .foregroundStyle(GargantuaColors.ink2)
                            .lineLimit(1)
                        Spacer(minLength: GargantuaSpacing.space2)
                        Text(action.clientID)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink3)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.top, GargantuaSpacing.space1)
    }

    private func requestControlAction() {
        guard presentation.isActionEnabled else { return }

        if snapshot.isRunning, !snapshot.clients.isEmpty {
            showsStopConfirmation = true
            return
        }

        if snapshot.isRunning {
            model.stop()
        } else {
            model.start()
        }
    }
}

struct MCPStatusMeta: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: GargantuaSpacing.space1) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .lineLimit(1)
        }
        .font(GargantuaFonts.caption)
        .foregroundStyle(GargantuaColors.ink3)
        .padding(.horizontal, GargantuaSpacing.space2)
        .padding(.vertical, GargantuaSpacing.space1)
        .background(GargantuaColors.surface3)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        )
    }
}
