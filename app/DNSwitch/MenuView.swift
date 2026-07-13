import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var service: ServiceManager

    // Shared spacing so paddings stay consistent across sections.
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
            service.healIfNeeded() // re-register once if already enabled (picks up plist changes)
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
                Text("DNS 加密").font(.system(size: 14, weight: .semibold))
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
        guard model.connected, let s = model.state else { return "未连接引擎" }
        let name = providerInfo(s.provider)?.name ?? s.provider
        let proto = Proto(rawValue: s.proto)?.label ?? s.proto
        return (s.enabled ? "已加密 · " : "未启用 · ") + "\(name) · \(proto)"
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
            Button(service.needsApproval ? "在系统设置中批准" : "安装后台服务") {
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
                if p.idField == nil { model.applySwitch() } // no id needed → switch now
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.45))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.system(size: 13, weight: .medium))
                        Text(p.subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    activeBadge(p)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if selected {
                VStack(alignment: .leading, spacing: 8) {
                    protocolPicker(p)
                    if p.idField != nil { idField(p) }
                    if p.id == "nextdns" { deviceField() }
                }
            }
        }
        .padding(.horizontal, UI.hPad)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .padding(.horizontal, 6)
    }

    // Marks which provider is actually live per engine state (distinct from the
    // radio, which shows the user's current selection).
    @ViewBuilder
    private func activeBadge(_ p: ProviderInfo) -> some View {
        if model.state?.provider == p.id {
            let on = model.state?.enabled == true
            Text(on ? "使用中" : "当前")
                .font(.caption2).fontWeight(.medium)
                .foregroundStyle(on ? Color.green : Color.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(
                    Capsule().fill((on ? Color.green : Color.secondary).opacity(0.14))
                )
        }
    }

    // Segmented protocol selector: filled accent when selected, subtle when
    // available, clearly dimmed when the provider doesn't offer it (e.g. DoQ on
    // Google/Cloudflare).
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
                .help(available ? "" : "\(p.name) 不提供 \(proto.label)")
            }
        }
    }

    private func idField(_ p: ProviderInfo) -> some View {
        let binding = p.id == "nextdns" ? $model.nextdnsID : $model.alidnsAcct
        return VStack(alignment: .leading, spacing: 3) {
            Text(p.idField ?? "").font(.caption2).foregroundStyle(.secondary)
            TextField(p.idField ?? "", text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { model.applySwitch() }
        }
    }

    // NextDNS-only: optional device name, reported per-device in NextDNS logs.
    private func deviceField() -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("设备名（可选 · 上报到 NextDNS）").font(.caption2).foregroundStyle(.secondary)
            TextField("如 MacBook（空格会转成 --）", text: $model.nextdnsDevice)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { model.applySwitch() }
        }
    }

    // MARK: - Empty / footer

    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("未连接到引擎").font(.subheadline)
            if service.isEnabled {
                Text("后台服务已启用，正在连接…").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("请先安装并批准后台服务（见上），或在终端 `sudo ./engine`（开发）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let e = model.lastError {
                Text(e).font(.caption2).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var footer: some View {
        VStack(spacing: 7) {
            if let up = model.state?.upstream, !up.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "link").font(.caption2).foregroundStyle(.tertiary)
                    Text(up).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("DNSwitch").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.caption)
            }
        }
        .padding(.horizontal, UI.hPad)
        .padding(.vertical, 10)
    }
}
