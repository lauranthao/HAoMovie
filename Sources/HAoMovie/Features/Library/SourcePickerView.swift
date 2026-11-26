import SwiftUI

/// 订阅管理：URL 导入、粘贴 JSON 导入、启用/停用、删除。
/// 多个订阅合并使用；App 自身不内置任何订阅。
struct SourcePickerView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var nameText = ""
    @State private var pasteText = ""
    @State private var showPaste = false
    @State private var isImporting = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section("导入订阅") {
                    TextField("订阅 JSON 地址（http/https）", text: $urlText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("名字（可选）", text: $nameText)
                    Button(isImporting ? "导入中…" : "从地址导入") {
                        Task { await importFromURL() }
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || isImporting)
                    Button("粘贴 JSON 导入") { showPaste = true }
                }

                Section("我的订阅") {
                    if subscriptions.subscriptions.isEmpty {
                        Text("暂无订阅")
                            .foregroundStyle(HaoMovieDesign.textSecondary)
                    }
                    ForEach(subscriptions.subscriptions) { sub in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sub.name)
                                    .font(.system(size: 15, weight: .semibold))
                                Text("\(subscriptions.sitesBySubscription[sub.id]?.count ?? 0) 个源" + (sub.isCoolingDown ? " · 冷却中" : ""))
                                    .font(.system(size: 12))
                                    .foregroundStyle(HaoMovieDesign.textSecondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { sub.enabled },
                                set: { subscriptions.setEnabled(sub, enabled: $0) }
                            ))
                            .labelsHidden()
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            subscriptions.remove(subscriptions.subscriptions[index])
                        }
                    }
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(HaoMovieDesign.textSecondary)
                    }
                }

                Section {
                    Text("只支持 JSON 源（type 1/4）。jar 插件源暂不支持。订阅与历史只存本机，不上传。")
                        .font(.system(size: 12))
                        .foregroundStyle(HaoMovieDesign.textSecondary)
                }
            }
            .navigationTitle("订阅管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showPaste) {
                pasteSheet
            }
        }
    }

    private var pasteSheet: some View {
        NavigationStack {
            VStack(spacing: HaoMovieDesign.space12) {
                TextEditor(text: $pasteText)
                    .font(.system(size: 13, design: .monospaced))
                    .overlay(
                        RoundedRectangle(cornerRadius: HaoMovieDesign.chipRadius)
                            .stroke(HaoMovieDesign.hairline)
                    )
                Button("导入") {
                    do {
                        let count = try subscriptions.importFromText(pasteText, name: nameText.isEmpty ? "粘贴的订阅" : nameText)
                        message = "已导入 \(count) 个源"
                        pasteText = ""
                        showPaste = false
                    } catch {
                        message = "导入失败：\(error.localizedDescription)"
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(HaoMovieDesign.accent)
                .disabled(pasteText.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            .padding(HaoMovieDesign.space16)
            .navigationTitle("粘贴 JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { showPaste = false }
                }
            }
        }
    }

    private func importFromURL() async {
        let url = urlText.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        isImporting = true
        message = nil
        do {
            let count = try await subscriptions.importFromURL(url, name: nameText.isEmpty ? nil : nameText)
            message = "已导入 \(count) 个源"
            urlText = ""
            nameText = ""
        } catch {
            message = "导入失败：\(error.localizedDescription)"
        }
        isImporting = false
    }
}
