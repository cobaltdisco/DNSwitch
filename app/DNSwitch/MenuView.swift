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
        .onDisappear { hovered = nil } // don't show a stale highlight on reopen
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
                    Text(displayName(p)).font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if selected {
                protocolPicker(p)
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

    // The provider's display name, with the configured id/subdomain appended so
    // the list shows which profile is in use, e.g. "NextDNS (abc123)".
    private func displayName(_ p: ProviderInfo) -> String {
        let extra: String
        switch p.id {
        case "nextdns": extra = model.nextdnsID.trimmingCharacters(in: .whitespaces)
        case "alidns":  extra = model.alidnsAcct.trimmingCharacters(in: .whitespaces)
        default:        extra = ""
        }
        return extra.isEmpty ? p.name : "\(p.name) (\(extra))"
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
            settingsButton
            Spacer()
            Button("menu.quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, UI.hPad)
        .padding(.vertical, 10)
    }

    // SettingsLink is the reliable way to open the Settings scene from a
    // MenuBarExtra (the private showSettingsWindow: selector is flaky and its
    // name has drifted across macOS releases). The tap also activates the app so
    // the window comes to the front for an accessory (LSUIElement) app.
    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14, *) {
            SettingsLink { Text("menu.settings") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .simultaneousGesture(TapGesture().onEnded {
                    NSApp.activate(ignoringOtherApps: true)
                })
        } else {
            Button("menu.settings") { openSettingsLegacy() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // macOS 13 fallback: try both selector spellings after activating.
    private func openSettingsLegacy() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
    }
}
