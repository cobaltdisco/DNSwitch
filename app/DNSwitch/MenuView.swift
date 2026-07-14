import SwiftUI
import AppKit

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var service: ServiceManager
    @State private var hovered: String?

    private enum UI {
        static let width: CGFloat = 320
        static let hPad: CGFloat = 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !service.isEnabled {
                serviceSection
                Divider()
            }
            if model.connected {
                providerList
            } else {
                notConnected
            }
            Divider()
            footer
        }
        .frame(width: UI.width)
        .onAppear {
            model.onAppear()
            service.refresh()
            service.healIfNeeded()
        }
    }

    // MARK: - Header / status

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 18))
                .foregroundStyle(statusColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("menu.title").font(.system(size: 14, weight: .semibold))
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { model.state?.enabled ?? false },
                set: { model.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(!model.connected)
        }
        .padding(.horizontal, UI.hPad)
        .padding(.vertical, 12)
    }

    private var statusIcon: String {
        guard model.connected else { return "shield.slash" }
        return model.state?.enabled == true ? "lock.shield.fill" : "shield"
    }

    private var statusColor: Color {
        guard model.connected else { return .secondary }
        return model.state?.enabled == true ? .green : .secondary
    }

    private var statusLine: String {
        guard model.connected, let s = model.state else {
            return String(localized: "status.disconnected")
        }
        let word = s.enabled ? String(localized: "status.encrypted") : String(localized: "status.off")
        let name = providerInfo(s.provider)?.name ?? s.provider
        let proto = Proto(rawValue: s.proto)?.label ?? s.proto
        return "\(word) · \(name) · \(proto)"
    }

    // MARK: - Background-service setup (first run / recovery)

    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: service.needsApproval
                      ? "exclamationmark.triangle.fill" : "gearshape")
                    .foregroundStyle(service.needsApproval ? .orange : .secondary)
                Text(service.statusText).font(.caption)
                Spacer()
            }
            Button(service.needsApproval ? "service.approve" : "service.install") {
                if service.needsApproval { service.openLoginItemsSettings() }
                else { service.register() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(service.busy)
            if let e = service.lastError {
                Text(e).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, UI.hPad)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(service.needsApproval ? 0.08 : 0))
    }

    // MARK: - Provider list

    private var providerList: some View {
        VStack(spacing: 2) {
            ForEach(providers) { providerRow($0) }
            if let e = model.lastError {
                Label(e, systemImage: "exclamationmark.circle")
                    .font(.caption2).foregroundStyle(.red)
                    .padding(.horizontal, UI.hPad).padding(.top, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func providerRow(_ p: ProviderInfo) -> some View {
        let selected = model.selectedProvider == p.id
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.selectProvider(p.id) // reconciles protocol if unsupported (S-3)
                model.applySwitch()        // id/device now come from Settings
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.45))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.system(size: 13, weight: .medium))
                        Text(LocalizedStringKey(p.subtitle)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    activeBadge(p)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if selected {
                VStack(alignment: .leading, spacing: 6) {
                    protocolPicker(p)
                    if let hint = configHint(p) {
                        Text(hint).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, UI.hPad)
        .padding(.vertical, 8)
        .background(rowBackground(selected: selected, hovered: hovered == p.id))
        .padding(.horizontal, 6)
        .onHover { hovered = $0 ? p.id : (hovered == p.id ? nil : hovered) }
    }

    private func rowBackground(selected: Bool, hovered: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.10)
                  : (hovered ? Color.secondary.opacity(0.12) : Color.clear))
    }

    // Which provider is actually live per engine state (distinct from selection).
    @ViewBuilder
    private func activeBadge(_ p: ProviderInfo) -> some View {
        if model.state?.provider == p.id {
            let on = model.state?.enabled == true
            Text(on ? "badge.inUse" : "badge.current")
                .font(.caption2).fontWeight(.medium)
                .foregroundStyle(on ? Color.green : Color.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill((on ? Color.green : Color.secondary).opacity(0.14)))
        }
    }

    // A one-line note about where this provider's config comes from (Settings),
    // shown under the selected NextDNS / AliDNS row now that fields moved there.
    private func configHint(_ p: ProviderInfo) -> LocalizedStringKey? {
        switch p.id {
        case "nextdns":
            return model.nextdnsID.trimmingCharacters(in: .whitespaces).isEmpty
                ? "menu.nextdns.free" : "menu.nextdns.profile"
        case "alidns":
            return model.alidnsAcct.trimmingCharacters(in: .whitespaces).isEmpty
                ? "menu.alidns.public" : "menu.alidns.enterprise"
        default:
            return nil
        }
    }

    private func protocolPicker(_ p: ProviderInfo) -> some View {
        HStack(spacing: 6) {
            ForEach(Proto.allCases) { proto in
                let available = p.protocols.contains(proto)
                let selected = model.selectedProto == proto && available
                Button {
                    model.selectedProto = proto
                    model.applySwitch()
                } label: {
                    Text(proto.label)
                        .font(.caption)
                        .fontWeight(selected ? .semibold : .regular)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? Color.accentColor
                                      : Color.secondary.opacity(available ? 0.12 : 0.05))
                        )
                        .foregroundStyle(selected ? Color.white
                                         : (available ? Color.primary : Color.secondary.opacity(0.4)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!available)
            }
        }
    }

    // MARK: - Empty / footer

    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("notConnected.title").font(.subheadline)
            Text(service.isEnabled ? "notConnected.connecting" : "notConnected.hint")
                .font(.caption).foregroundStyle(.secondary)
            if let e = model.lastError {
                Text(e).font(.caption2).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("menu.settings") { openSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Spacer()
            Button("menu.quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, UI.hPad)
        .padding(.vertical, 10)
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
