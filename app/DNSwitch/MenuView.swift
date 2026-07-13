import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var service: ServiceManager

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
        .frame(width: 320)
        .onAppear {
            model.onAppear()
            service.refresh()
            service.healIfNeeded() // re-register once if already enabled (picks up plist changes)
        }
    }

    // First-run / recovery: guide the user to install and approve the root
    // background service (docs/07 §1). Hidden once the daemon is enabled.
    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(service.busy)
            if let e = service.lastError {
                Text(e).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DNS 加密").font(.headline)
                Text(currentNode).font(.caption).foregroundStyle(.secondary)
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
        .padding(12)
    }

    private var currentNode: String {
        guard let s = model.state else { return "未连接引擎" }
        let name = providerInfo(s.provider)?.name ?? s.provider
        let proto = Proto(rawValue: s.proto)?.label ?? s.proto
        return "当前 · \(name) · \(proto)\(s.pinned ? "" : "（未启用）")"
    }

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

    private var providerList: some View {
        VStack(spacing: 0) {
            ForEach(providers) { p in providerRow(p) }
            if let e = model.lastError {
                Text(e).font(.caption2).foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.top, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func providerRow(_ p: ProviderInfo) -> some View {
        let selected = model.selectedProvider == p.id
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.selectProvider(p.id) // reconciles protocol if unsupported (S-3)
                if p.idField == nil { model.applySwitch() } // no id needed → switch now
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name)
                        Text(p.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if selected {
                protocolPicker(p)
                if p.idField != nil { idField(p) }
                if p.id == "nextdns" { deviceField() }
                if let up = model.state?.upstream, !up.isEmpty {
                    Text(up).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private func protocolPicker(_ p: ProviderInfo) -> some View {
        HStack(spacing: 6) {
            ForEach(Proto.allCases) { proto in
                let ok = p.protocols.contains(proto)
                Button(proto.label) {
                    model.selectedProto = proto
                    model.applySwitch()
                }
                .buttonStyle(.bordered)
                .tint(model.selectedProto == proto && ok ? .accentColor : .gray)
                .disabled(!ok) // DoQ greyed for Google/Cloudflare
            }
        }
    }

    private func idField(_ p: ProviderInfo) -> some View {
        let binding = p.id == "nextdns" ? $model.nextdnsID : $model.alidnsAcct
        return VStack(alignment: .leading, spacing: 2) {
            Text(p.idField ?? "").font(.caption2).foregroundStyle(.secondary)
            TextField(p.idField ?? "", text: binding)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.applySwitch() }
        }
    }

    // NextDNS-only: optional device name, reported per-device in NextDNS logs.
    private func deviceField() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("设备名（可选 · 上报到 NextDNS）").font(.caption2).foregroundStyle(.secondary)
            TextField("如 MacBook（空格会转成 --）", text: $model.nextdnsDevice)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.applySwitch() }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
        }
        .padding(12)
    }
}
