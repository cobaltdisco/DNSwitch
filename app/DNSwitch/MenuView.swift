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
    @State private var panel = PanelHandle()  // the NSWindow hosting this view

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
        .background(PanelWindowReader(handle: panel))
        .onAppear {
            model.beginLiveUpdates(watching: service) // 5s poll, only while open
            service.refresh()
        }
        .onDisappear {
            model.endLiveUpdates()  // idle menu-bar app => zero background cost
            hovered = nil           // don't show a stale highlight on reopen
            hintTask?.cancel()
            hint = nil
        }
    }

    // First run = nothing but the way forward: the install button, no status
    // blurbs, no "not connected" copy. A reachable engine always gets the provider
    // list, even when SMAppService isn't registered (dev `sudo ./engine`, or the
    // app was moved after registering) — there the install button rides above it.
    // Registered-but-silent is a restart in progress: a quiet spinner, escalating
    // to a real message once it's clearly not coming back (Fable B1/B2).
    @ViewBuilder
    private var content: some View {
        if model.connected {
            if !service.isEnabled {
                installSection
                Divider()
            }
            providerList
        } else if service.isEnabled {
            engineSilent
        } else {
            installSection
        }
    }

    // MARK: - Header / status

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("menu.title").font(.system(size: 14, weight: .semibold))
                // " " keeps the line's height reserved so showing/clearing the
                // hint doesn't resize the panel.
                Text(subtitle ?? " ")
                    .font(.caption)
                    .foregroundStyle(showingHint ? Color.orange : Color.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { encryptionActive(model, service) },
                set: { on in
                    // Stays tappable while disconnected on purpose: a dead switch
                    // explains nothing. Refuse the press, say why, shake it back.
                    guard model.connected else { refuseToggle(); return }
                    model.setEnabled(on)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(Text("menu.title"))
            .modifier(ShakeEffect(animatableData: CGFloat(shakes)))
        }
        // +6 to line the title/status up with the provider rows, whose content
        // is inset by the row's 6px rounded-highlight margin on top of hPad.
        .padding(.horizontal, UI.hPad + 6)
        .padding(.vertical, 12)
    }

    // A live status always wins over a refusal hint that hasn't expired yet.
    private var showingHint: Bool { hint != nil && !model.connected }
    private var subtitle: String? { showingHint ? hint : statusLine }

    private var statusLine: String? {
        guard model.connected, let s = model.state else { return nil }
        let word = s.enabled ? String(localized: "status.encrypted") : String(localized: "status.off")
        let name = providerInfo(s.provider)?.name ?? s.provider
        let proto = Proto(rawValue: s.proto)?.label ?? s.proto
        return "\(word) · \(name) · \(proto)"
    }

    /// The engine isn't reachable: shake the switch back off and say what's missing.
    private func refuseToggle() {
        let msg = refusalReason
        hint = msg
        if !reduceMotion {
            withAnimation(.linear(duration: 0.4)) { shakes += 1 }
        }
        // The shake is invisible to VoiceOver and the hint Text is never read out,
        // so announce the refusal explicitly (Fable B3).
        NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: [.announcement: msg,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { hint = nil }
        }
    }

    private var refusalReason: String {
        if service.needsApproval { return String(localized: "toggle.needApproval") }
        if !service.isEnabled    { return String(localized: "toggle.needService") }
        if model.stalled         { return String(localized: "service.silent") }
        return String(localized: "toggle.starting")
    }

    // MARK: - Background-service setup (first run / recovery)

    private var installSection: some View {
        VStack(spacing: 8) {
            Button(service.needsApproval ? "service.approve" : "service.install") {
                if service.needsApproval { service.openLoginItemsSettings() }
                else { service.register { model.refresh() } }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(service.busy)
            // Only ever appears after a press that actually failed — actionable,
            // not ambient status. (Landing in .requiresApproval is not a failure:
            // ServiceManager clears the error there.)
            if let e = service.lastError {
                Text(e).font(.caption2).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, UI.hPad)
        .padding(.vertical, 14)
    }

    /// Service registered, engine not answering. A restart takes a moment, so stay
    /// quiet at first; once AppModel calls it stalled (~20s, or a reply we couldn't
    /// decode) say so and offer the one repair that helps — re-registering, which
    /// re-points launchd at the current bundle (Fable B2).
    @ViewBuilder
    private var engineSilent: some View {
        if model.stalled {
            VStack(spacing: 8) {
                Text("service.silent")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("service.reinstall") { service.register { model.refresh() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(service.busy)
                if let e = service.lastError ?? model.lastError {
                    Text(e).font(.caption2).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, UI.hPad)
            .padding(.vertical, 14)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        }
    }

    // MARK: - Provider list

    private var providerList: some View {
        VStack(spacing: 2) {
            // AliDNS is filtered out unless unlocked or in use (see aliDNSVisible).
            ForEach(visibleProviders(model)) { providerRow($0) }
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

    // Opening Settings must also close this panel: SwiftUI only auto-dismisses a
    // .window-style MenuBarExtra on an *outside* interaction (click in another
    // app / app deactivation) or a second click on the status item. A sibling
    // window of the same app becoming key is neither — so without help the panel
    // just stays up over the freshly opened Settings window.
    //
    // macOS 14+: @Environment(\.openSettings) is the public programmatic way to
    // open the Settings scene (SettingsLink has no action hook, which forced a
    // simultaneousGesture and left no ordering control), and \.dismiss inside
    // MenuBarExtra content is the public way to close the panel. macOS 13 has a
    // public API for neither (verified against the SDK), so it keeps the legacy
    // selectors and closes the panel via the captured AppKit window.
    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14, *) {
            SettingsOpenButton(closePanelFallback: closePanel)
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else {
            Button("menu.settings") { openSettingsLegacy() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // macOS 13 fallback: try both selector spellings after activating (the
    // private selector's name has drifted across macOS releases), then close the
    // panel once the settings window has had its turn on the runloop.
    private func openSettingsLegacy() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
            closePanel()
        }
    }

    /// Close the MenuBarExtra panel — the exact window hosting this view, as
    /// captured by PanelWindowReader, so it cannot hit the Settings window or
    /// any other window. Deferred one runloop turn on purpose: the settings-open
    /// action must dispatch first (closing the panel before that could tear the
    /// pressed button down before its action ran), and closing the key panel
    /// *after* Settings is up simply hands key status to Settings — the app's
    /// only other visible window — so Settings ends up frontmost, not buried.
    /// No-op when the panel is already gone (the macOS 14+ dismiss() usually
    /// gets there first; this is its belt-and-braces fallback).
    private func closePanel() {
        DispatchQueue.main.async {
            guard let w = panel.window, w.isVisible else { return }
            w.close()
        }
    }
}

/// The macOS 14+ Settings button. A separate view because
/// @Environment(\.openSettings) is macOS 14-only and so cannot be declared as a
/// property of MenuView (deployment target 13.0).
@available(macOS 14.0, *)
private struct SettingsOpenButton: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    /// AppKit close of the captured panel window; internally deferred and a
    /// guarded no-op when dismiss() has already closed the panel.
    let closePanelFallback: () -> Void

    var body: some View {
        Button("menu.settings") {
            // Plain activate(): on 14+ the ignoringOtherApps flag is ignored
            // anyway and its variant is deprecated. Needed so the window comes
            // to the front for an accessory (LSUIElement) app.
            NSApp.activate()
            openSettings()
            // Next runloop turn, i.e. after the Settings window is up: \.dismiss
            // inside MenuBarExtra content closes the panel (public behavior
            // since macOS 14). Dismissing before openSettings has dispatched
            // could tear this button down with its action half-delivered.
            DispatchQueue.main.async { dismiss() }
            closePanelFallback()
        }
    }
}

/// Weak handle to the AppKit window hosting MenuView — i.e. the MenuBarExtra
/// panel itself. Captured from *inside* the view hierarchy, so it is that panel
/// by construction: no NSApp.keyWindow guessing (which, after Settings opens,
/// would name the Settings window) and no class-name sniffing of private AppKit
/// types. Weak so a closed panel is never kept alive or over-released.
private final class PanelHandle {
    weak var window: NSWindow?
}

private struct PanelWindowReader: NSViewRepresentable {
    let handle: PanelHandle
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak handle, weak v] in
            if let w = v?.window { handle?.window = w }
        }
        return v
    }
    // Re-capture on updates: SwiftUI may recreate the panel between opens.
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { [weak handle, weak v] in
            if let w = v?.window { handle?.window = w }
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
