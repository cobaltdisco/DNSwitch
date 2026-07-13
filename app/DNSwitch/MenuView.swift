import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.connected {
                providerList
            } else {
                notConnected
            }
            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear { model.onAppear() }
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
            Text("请先在终端运行 `sudo ./engine`").font(.caption).foregroundStyle(.secondary)
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
                model.selectedProvider = p.id
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
