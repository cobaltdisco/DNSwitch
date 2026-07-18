import SwiftUI
import AppKit

/// The ⌘, settings window: per-provider config moved out of the menu. Binds to
/// the shared AppModel; edits persist and auto-apply (debounced) to the live
/// provider. Language is auto-detected from the system (no manual override).
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var service: ServiceManager
    @State private var confirmRemove = false

    // MARK: - AliDNS easter egg
    //
    // AliDNS ships hidden (aliDNSVisible). One double-click on the "Engine"
    // label toggles it. The original two-double-clicks reveal was unreliable:
    // rapid clicks 3/4 chain into the first double-click (NSEvent clickCount
    // keeps rising within the system double-click interval), so
    // TapGesture(count: 2) never fires a second time and the reveal "sometimes"
    // did nothing. Hiding is refused while AliDNS is selected/running — the
    // inUse valve would keep the row visible and the flag would desync
    // invisibly (see eggDoubleClick).

    var body: some View {
        Form {
            Section("settings.nextdns.header") {
                TextField("settings.nextdns.profileID", text: $model.nextdnsID,
                          prompt: Text(verbatim: "abc123"))
                TextField("settings.nextdns.device", text: $model.nextdnsDevice,
                          prompt: Text("settings.nextdns.devicePrompt"))
                    .disabled(model.nextdnsID.trimmingCharacters(in: .whitespaces).isEmpty)
                Text(nextdnsHint).font(.caption).foregroundStyle(.secondary)
            }

            // Only once the egg is unlocked — or AliDNS is what's actually running,
            // in which case its subdomain must stay editable.
            if aliDNSVisible(model) {
                Section("settings.alidns.header") {
                    TextField("settings.alidns.acct", text: $model.alidnsAcct,
                              prompt: Text(verbatim: "779231-xxxxxxxx"))
                    Text("settings.alidns.hint").font(.caption).foregroundStyle(.secondary)
                }
            }

            // Deleting the app does NOT remove the root daemon — launchd keeps the
            // registration, so this is the only in-app way out. It's also the safe
            // order: turn encryption off (system DNS restored over the live socket)
            // and only then unregister.
            Section("settings.service.header") {
                HStack {
                    Text("settings.service.remove")
                    Spacer()
                    if service.busy { ProgressView().controlSize(.small) }
                    Button("settings.service.removeButton", role: .destructive) {
                        confirmRemove = true
                    }
                    .disabled(service.busy || service.status == .notRegistered)
                }
                Text("settings.service.hint").font(.caption).foregroundStyle(.secondary)
                if let e = service.lastError {
                    Text(e).font(.caption2).foregroundStyle(.red)
                }
            }

            // Versions, so a running build is identifiable at a glance: the app
            // (from its bundle) plus the engine daemon's build version and the
            // AdGuard dnsproxy it embeds (both reported over the socket — "—" when
            // the engine isn't reachable).
            Section("settings.about.header") {
                LabeledContent("settings.about.appVersion") {
                    Text(verbatim: appVersion).textSelection(.enabled)
                }
                LabeledContent {
                    Text(verbatim: engineVersion).textSelection(.enabled)
                } label: {
                    // Carries the AliDNS easter egg (see eggDoubleClick). Nothing
                    // about the label hints at it — that's the point — so it must
                    // stay a plain, correct-looking row.
                    Text("settings.about.engineVersion")
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: eggDoubleClick)
                }
                LabeledContent("settings.about.dnsproxyVersion") {
                    Text(verbatim: dnsproxyVersion).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        // The grouped Form rides an NSScrollView. Animating the egg section
        // in/out interpolates the document and clip heights independently, and
        // sub-point rounding (±0.2pt, measured frame-by-frame) makes the
        // document transiently "taller" — every such frame AppKit unhides the
        // overlay scroller, so a scrollbar flickers in and out for the whole
        // animation (the user's diagnosis; confirmed by hierarchy probing on
        // macOS 26, where this modifier removes the NSScroller outright, so
        // nothing is left to flash). The window sizes to content (fixedSize
        // below), so the form never legitimately scrolls. Deliberately NOT
        // .scrollDisabled: on a display too short for the window, trackpad
        // scrolling must keep working — only the indicator goes.
        .scrollIndicators(.never)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        // Poll runs only while the menu panel is open, so state can be stale here;
        // refresh both the service status and the engine state (which carries the
        // versions) when the settings window appears.
        .onAppear { service.refresh(); model.refresh() }
        .confirmationDialog("settings.service.confirmTitle", isPresented: $confirmRemove) {
            Button("settings.service.removeButton", role: .destructive) {
                service.removeService(disabling: model)
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.service.confirmMsg")
        }
    }

    private func eggDoubleClick() {
        if model.showAliDNS {
            // Refuse a hide that can't take visible effect. While AliDNS is the
            // selected/running provider the inUse valve keeps the row on screen,
            // so flipping the flag would change nothing visible while silently
            // desyncing it — and with a toggle, every further double-click would
            // flip the hidden parity (Fable finding 3).
            guard !aliDNSInUse(model) else { return }
            setEgg(false)
        } else {
            setEgg(true)
        }
    }

    private func setEgg(_ on: Bool) {
        // Plain symmetric animation, both directions. The reveal's visible
        // glitch was never dropped frames from AppKit construction (the
        // earlier theory, and the reason a .delay(0.1) briefly lived here) —
        // it was the Form's overlay scroller flickering for the full length
        // of the animation, which no start delay could touch. That is fixed
        // at the source by .scrollIndicators(.never) on the Form (see body),
        // so the delay would be pure added latency and is gone. If a residual
        // first-frame hitch ever resurfaces, the agreed fallback is dropping
        // withAnimation entirely (both directions — they must stay symmetric),
        // not reinstating the delay.
        withAnimation { model.showAliDNS = on }
        // A section silently appearing or vanishing is invisible to VoiceOver, and
        // the gesture is undiscoverable by design, so say what happened (same
        // reasoning as the toggle-refusal announcement in MenuView, Fable B3).
        // Read the real predicate rather than `on`: the caller's guard makes the two
        // agree today, and if that ever slips the announcement stays truthful.
        let shown = aliDNSVisible(model)
        let msg = String(localized: shown ? "egg.alidns.shown" : "egg.alidns.hidden")
        NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: [.announcement: msg,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private var nextdnsHint: LocalizedStringKey {
        model.nextdnsID.trimmingCharacters(in: .whitespaces).isEmpty
            ? "settings.nextdns.emptyHint"
            : "settings.nextdns.setHint"
    }

    /// "<marketing> (<build>)", e.g. "0.2 (2)" — CFBundleShortVersionString is
    /// what a user reads as "the version"; CFBundleVersion distinguishes rebuilds
    /// of the same version. Not localized (it's an identifier).
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }

    // From the engine's status; "—" when it isn't reachable (or an old engine
    // that predates these fields, which omits them).
    private var engineVersion: String { orDash(model.state?.engineVersion) }
    private var dnsproxyVersion: String { orDash(model.state?.dnsproxyVersion) }
    private func orDash(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "—" }
        return s
    }
}
