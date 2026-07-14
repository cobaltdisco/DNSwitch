import SwiftUI
import AppKit

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var service: ServiceManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?
    @State private var hint: String?          // transient: why the toggle refused
    @State private var hintTask: Task<Void, Never>?
    @State private var shakes = 0             // bump to replay the refusal shake

    private enum UI {
        static let width: CGFloat = 320
        static let hPad: CGFloat = 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: UI.width)
        .onAppear {
            model.onAppear()
            service.refresh()
            service.healIfNeeded()
        }
        .onDisappear {
            hovered = nil       // don't show a stale highlight on reopen
            hintTask?.cancel()
            hint = nil
        }
    }

    // Before the background service exists there is nothing to show but the way
    // to install it — no status blurbs, no "not connected" copy. Once it's up but
    // the engine hasn't answered yet (launch, restart), a quiet spinner stands in.
    @ViewBuilder
    private var content: some View {
        if !service.isEnabled {
            installSection
        } else if model.connected {
            providerList
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        }
    }

    // MARK: - Header / status

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("menu.title").font(.system(size: 14, weight: .semibold))
                // " " keeps the line's height reserved so showing/clearing the
                // hint doesn't resize the panel.
                Text(hint ?? statusLine ?? " ")
                    .font(.caption)
                    .foregroundStyle(hint == nil ? Color.secondary : Color.orange)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { model.state?.enabled ?? false },
                set: { on in
                    // Stays tappable while disconnected on purpose: a dead switch
                    // explains nothing. Refuse the press, say why, shake it back.
                    guard model.connected else { refuseToggle(); return }
                    model.setEnabled(on)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .modifier(ShakeEffect(animatableData: CGFloat(shakes)))
        }
        // +6 to line the title/status up with the provider rows, whose content
        // is inset by the row's 6px rounded-highlight margin on top of hPad.
        .padding(.horizontal, UI.hPad + 6)
        .padding(.vertical, 12)
    }

    private var statusLine: String? {
        guard model.connected, let s = model.state else { return nil }
        let word = s.enabled ? String(localized: "status.encrypted") : String(localized: "status.off")
        let name = providerInfo(s.provider)?.name ?? s.provider
        let proto = Proto(rawValue: s.proto)?.label ?? s.proto
        return "\(word) · \(name) · \(proto)"
    }

    /// The engine isn't reachable: shake the switch back off and say what's missing.
    private func refuseToggle() {
        hint = service.isEnabled
            ? String(localized: "toggle.starting")
            : String(localized: "toggle.needService")
        if !reduceMotion {
            withAnimation(.linear(duration: 0.4)) { shakes += 1 }
        }
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { hint = nil }
        }
    }

    // MARK: - Background-service setup (first run / recovery)

    private var installSection: some View {
        VStack(spacing: 8) {
            Button(service.needsApproval ? "service.approve" : "service.install") {
                if service.needsApproval { service.openLoginItemsSettings() }
                else { service.register() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(service.busy)
            // Only ever appears right after a press that failed — actionable, not
            // ambient status.
            if let e = service.lastError {
                Text(e).font(.caption2).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, UI.hPad)
        .padding(.vertical, 14)
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
        VStack(alignment: .leading, spacing: 0) {
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
                // Padding lives INSIDE the button so its whole highlighted area
                // is clickable — otherwise the row's edges light up on hover but
                // aren't part of the tap target, and edge clicks miss.
                .padding(.horizontal, UI.hPad)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if selected {
                protocolPicker(p)
                    .padding(.horizontal, UI.hPad)
                    .padding(.bottom, 8)
            }
        }
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
        // Always four equal slots in canonical order; a protocol the provider
        // doesn't offer (DoQ on Google/Cloudflare) is an empty slot, so the
        // visible buttons keep their size instead of stretching to fill the row.
        // The engine still supports DoQ — re-adding it is a model-only change.
        HStack(spacing: 6) {
            ForEach(Proto.allCases) { proto in
                if p.protocols.contains(proto) {
                    protocolButton(proto)
                } else {
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func protocolButton(_ proto: Proto) -> some View {
        let selected = model.selectedProto == proto
        return Button {
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
                        .fill(selected ? Color.accentColor : Color.secondary.opacity(0.12))
                )
                .foregroundStyle(selected ? Color.white : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

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

/// Horizontal wobble used to reject a toggle press. `animatableData` is the
/// refusal count: each +1 runs `shakes` full oscillations and lands back at 0,
/// so the switch always comes to rest where it started.
private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 5
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: travel * sin(animatableData * .pi * 2 * shakes), y: 0))
    }
}
