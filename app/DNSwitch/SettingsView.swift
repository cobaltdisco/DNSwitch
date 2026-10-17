import SwiftUI
import AppKit

/// The ⌘, settings window: per-provider config moved out of the menu. Binds to
/// the shared AppModel; edits persist and auto-apply (debounced) to the live
/// provider. Language is auto-detected from the system (no manual override).
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var service: ServiceManager
    @ObservedObject private var loginItem = LoginItem.shared
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

    // MARK: - Why three stacked Forms (measured, do not fold back into one)
    //
    // The reveal used to read as "the whole page refreshes". Frame-by-frame
    // probing of a real Settings scene on macOS 26 found two independent causes:
    //
    //  1. In a grouped Form, row identity is positional: inserting a section
    //     mid-form gives every FOLLOWING row a new identity, so Engine/About
    //     were torn down and rebuilt — two copies crossfading 129pt apart
    //     instead of sliding. Explicit .id() does not help; nor does keeping
    //     an empty Section slot (it also leaves a 31pt empty card when hidden).
    //  2. The Settings window's height follows max(target, live content):
    //     on reveal it snapped full-size in one frame while the content
    //     animated, and the (shorter) content was re-CENTERED in the taller
    //     window — the entire form jumped down ~62pt, then slid back up.
    //
    // Fix: split into three sibling grouped Forms in a plain VStack. VStack
    // children keep structural identity, so the Service/About form translates
    // as one unit and nothing is ever rebuilt (verified: stable AppKit view
    // identities through full reveal/hide round-trips). The AliDNS mini-form
    // is permanently mounted and collapsed by EggReveal (an Animatable height
    // fraction): because the fraction interpolates at MODEL level, the root's
    // natural height interpolates too, and the window GLIDES top-anchored in
    // sync with the content instead of snapping — both directions symmetric.
    // At rest the stack is pixel-identical (zero differing pixels, probed)
    // to the original single Form in both hidden and shown states, given the
    // formJunction constant below.

    // Two adjacent grouped Forms stack their own bottom+top content padding;
    // a single Form separates the same cards by that sum minus 10pt (probe-
    // calibrated on macOS 26: with 0 compensation every junction sat exactly
    // 10pt too wide, with -10 all offsets matched the single Form to 0.0pt).
    // Revisit after macOS design changes: if card gaps ever look off here,
    // re-measure this constant first.
    private static let formJunction: CGFloat = -10

    // Live-measured natural height of the AliDNS mini-form (its fixedSize
    // layout ignores the collapsed frame, so this is valid even while hidden,
    // and tracks locale / Dynamic Type automatically).
    @State private var aliFormHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Form {
                generalSection
                nextdnsSection
                controldSection
            }
                .formStyle(.grouped)
                .scrollIndicators(.never)
                .fixedSize(horizontal: false, vertical: true)

            // Permanently mounted (never inserted/removed — that is what makes
            // the siblings slide instead of crossfade); EggReveal collapses it
            // to zero height when locked. While hidden it must stay invisible
            // to every discovery channel or the easter egg leaks: no VoiceOver
            // node, no Tab focus, no hit-testing (the last is in EggReveal).
            Form { alidnsSection }
                .formStyle(.grouped)
                .scrollIndicators(.never)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    aliFormHeight = $0
                }
                .modifier(EggReveal(fraction: aliDNSVisible(model) ? 1 : 0,
                                    naturalHeight: aliFormHeight,
                                    junction: Self.formJunction))
                .disabled(!aliDNSVisible(model))
                .accessibilityHidden(!aliDNSVisible(model))

            Form {
                serviceSection
                aboutSection
            }
            .formStyle(.grouped)
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Self.formJunction)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(EndEditingOnOutsideClick())
        .background(HideWindowTitle())
        // Poll runs only while the menu panel is open, so state can be stale here;
        // refresh both the service status and the engine state (which carries the
        // versions) when the settings window appears.
        .onAppear { service.refresh(); model.refresh(); loginItem.refresh() }
        // Closing the window backs out of a half-finished uninstall: nothing was
        // unregistered, and leaving `uninstalling` set would keep the retry
        // block up the next time this view appears.
        .onDisappear {
            if service.uninstalling && !service.busy { service.cancelUninstall() }
        }
        .confirmationDialog("settings.service.confirmTitle", isPresented: $confirmRemove) {
            Button("settings.service.removeButton", role: .destructive) {
                service.removeService(disabling: model)
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.service.confirmMsg")
        }
    }

    // Each mini-form rides its own NSScrollView, so each needs the
    // .scrollIndicators(.never) above. Animating heights interpolates the
    // document and clip heights independently, and sub-point rounding (±0.2pt,
    // measured frame-by-frame) makes the document transiently "taller" — every
    // such frame AppKit unhides the overlay scroller, so a scrollbar flickers
    // for the whole animation. The modifier removes the NSScroller outright
    // (probed: zero scrollers in the hierarchy through full round-trips), so
    // nothing is left to flash. Deliberately NOT .scrollDisabled: on a display
    // too short for the window, trackpad scrolling must keep working — only
    // the indicator goes.

    private var nextdnsSection: some View {
        Section("settings.nextdns.header") {
            TextField("settings.nextdns.profileID", text: $model.nextdnsID,
                      prompt: Text("settings.optional"))
            TextField("settings.nextdns.device", text: $model.nextdnsDevice,
                      prompt: Text("settings.nextdns.devicePrompt"))
                .disabled(model.nextdnsID.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // Same shape as the NextDNS card (D8). Stays in the FIRST Form, below
    // NextDNS: the AliDNS mini-form only needs its upper neighbour to be the
    // first Form, so formJunction is untouched.
    private var controldSection: some View {
        Section("settings.controld.header") {
            TextField("settings.controld.resolverID", text: $model.controldID,
                      prompt: Text("settings.optional"))
            TextField("settings.controld.device", text: $model.controldDevice,
                      prompt: Text("settings.controld.devicePrompt"))
                .disabled(model.controldID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // Shown once the egg is unlocked — or AliDNS is what's actually running,
    // in which case its subdomain must stay editable (aliDNSVisible).
    private var alidnsSection: some View {
        Section("settings.alidns.header") {
            TextField("settings.alidns.acct", text: $model.alidnsAcct,
                      prompt: Text("settings.optional"))
        }
    }

    // First section, per the macOS convention (General up top, About last).
    // Lives inside the first Form, ABOVE the NextDNS section: the AliDNS egg
    // only requires that its mini-form's upper neighbour is the first Form
    // (General + NextDNS + Control D), so this placement leaves the calibrated
    // formJunction geometry alone.
    //
    // Launch at login is the APP's login item (SMAppService.mainApp), not the
    // engine: the root daemon already starts at boot on its own. This only
    // brings the menu-bar icon back after login.
    private var generalSection: some View {
        Section("settings.general.header") {
            Toggle("settings.general.launchAtLogin", isOn: Binding(
                get: { loginItem.enabled },
                set: { loginItem.setEnabled($0) }
            ))
            .disabled(loginItem.busy)
            if let e = loginItem.lastError {
                Text(e).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    // Deleting the app does NOT remove the root daemon — launchd keeps the
    // registration, so this is the only in-app way out. It's also the safe
    // order: turn encryption off (system DNS restored over the live socket)
    // and only then unregister.
    private var serviceSection: some View {
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
            if let stuck = service.restoreWarning {
                restoreEscapeHatch(stuck)
            }
        }
    }

    // Shown when the uninstall had to stop: the engine couldn't confirm the
    // restore and the system still points services at us. One way forward,
    // "Try again" (the whole uninstall once more); the body text covers a broken
    // engine (reinstall it, then uninstall again). Inline rather than a sheet so
    // the service names stay visible while the user acts on them.
    @ViewBuilder
    private func restoreEscapeHatch(_ stuck: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.restore.title")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            // The service names come from the local probe, so they name exactly
            // what is still affected.
            Text(verbatim: stuck.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("settings.restore.body").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("settings.restore.retry") { service.retryRestore(disabling: model) }
                    .buttonStyle(.borderedProminent)
                    .disabled(service.busy)
                if service.busy { ProgressView().controlSize(.small) }
            }
        }
        .padding(.vertical, 4)
    }

    // Versions, so a running build is identifiable at a glance: the app
    // (from its bundle) plus the engine daemon's build version and the
    // AdGuard dnsproxy it embeds (both reported over the socket — "—" when
    // the engine isn't reachable).
    private var aboutSection: some View {
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
        // Explicit symmetric curve, both directions. History: the reveal's
        // visible glitch was never AppKit construction cost (a .delay(0.1)
        // band-aid briefly lived here for that theory) — it was the overlay
        // scroller flicker (fixed by .scrollIndicators(.never)) plus the
        // window snap + whole-form re-centering, fixed structurally by the
        // three-form split and EggReveal (see the layout comment on body).
        // The explicit easeInOut matters: EggReveal's fraction and the sibling
        // slide interpolate along the same curve, and the window tracks that
        // model-level interpolation frame by frame.
        withAnimation(.easeInOut(duration: 0.25)) { model.showAliDNS = on }
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

    /// Shared with the engine-skew check, which compares this exact string
    /// against what the daemon reports (Models.swift).
    private var appVersion: String { appBuildVersion() }

    // From the engine's status; "—" when it isn't reachable (or an old engine
    // that predates these fields, which omits them).
    private var engineVersion: String { orDash(model.state?.engineVersion) }
    private var dnsproxyVersion: String { orDash(model.state?.dnsproxyVersion) }
    private func orDash(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "—" }
        return s
    }
}

/// Collapses the (fixedSize) AliDNS mini-form to `naturalHeight * fraction`.
/// The fraction is `animatableData`, so inside `withAnimation` it interpolates
/// at MODEL level: every animation frame is a real layout at a real height.
/// That is the whole trick — the Settings scene sizes its window to
/// max(target, live content), which snaps on grow for ordinary transitions,
/// but follows a model-level interpolation frame by frame, so the window edge
/// glides in both directions (probed: 511→640pt over ~250ms in ~15 monotonic
/// steps, top edge pinned, and the mirror on hide).
///
/// `junction` morphs in with the fraction: a visible mini-form must overlap
/// its neighbour by the calibration constant, a collapsed one must not.
/// At fraction 1 the height clamp is released (nil) so the revealed state is
/// exactly natural sizing — the measurement only steers mid-flight, where a
/// point of error is invisible.
private struct EggReveal: ViewModifier, Animatable {
    var fraction: CGFloat
    var naturalHeight: CGFloat
    var junction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(height: fraction >= 1 ? nil : max(0, naturalHeight * fraction),
                   alignment: .top)
            .clipped()
            .opacity(Double(fraction))
            .padding(.top, junction * fraction)
            .allowsHitTesting(fraction >= 1)
    }
}

/// Clicking anywhere in the window that isn't a text field ends editing.
/// AppKit's default keeps the field editor (and its caret) in the last text
/// field until another control takes first responder, and most of a grouped
/// Form — the gaps, the card backgrounds, the labels — never does. A local
/// monitor sees the click before AppKit routes it, ends editing, and passes
/// the event on unchanged, so a click on a toggle or button still lands.
private struct EndEditingOnOutsideClick: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { MonitorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class MonitorView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let window = self?.window, event.window === window,
                      window.firstResponder is NSText // a field editor is active
                else { return event }
                // The frame view has no superview, so its hitTest takes window
                // coordinates directly.
                let hit = window.contentView?.superview?.hitTest(event.locationInWindow)
                if !Self.isTextInput(hit) { window.makeFirstResponder(nil) }
                return event
            }
        }

        private static func isTextInput(_ view: NSView?) -> Bool {
            var v = view
            while let current = v {
                if current is NSTextField || current is NSText { return true }
                v = current.superview
            }
            return false
        }
    }
}

/// Hides the Settings window's title text. On macOS 26/27 every titlebar style
/// draws the title leading-aligned, which looked misplaced above this centered
/// single-column form (user decision, 2026-10-17). Only the drawing goes: the
/// window keeps its title for the Window menu, Mission Control and VoiceOver.
private struct HideWindowTitle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TitleHider() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class TitleHider: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titleVisibility = .hidden
        }
    }
}

