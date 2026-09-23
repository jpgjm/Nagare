import SwiftUI

struct ExtensionsView: View {
    @ObservedObject private var manager = ExtensionManager.shared
    @State private var newURL = ""
    @State private var adding = false
    @State private var message: String?
    @State private var messageIsError = false

    /// Shiru リポジトリに含まれるダミー拡張（実在しないトレントを返す。検索〜結果表示の確認用）
    private let sampleSource = "gh:RockinChaos/Shiru/extensions"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("https://…/index.json、gh:…、npm:…", text: $newURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit { add(newURL) }
                    Button {
                        add(newURL)
                    } label: {
                        if adding { ProgressView() } else { Label("追加", systemImage: "plus.circle") }
                    }
                    .disabled(adding || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let message {
                        Text(message).font(.caption).foregroundStyle(messageIsError ? .red : .green)
                    }
                } header: {
                    Text("ソースを追加")
                } footer: {
                    Text("Shiru 互換の拡張機能マニフェスト、またはリポジトリ一覧を指定します。拡張機能はこのアプリには同梱されていません。")
                }

                Section {
                    if manager.sources.isEmpty {
                        Text("拡張機能はまだありません").foregroundStyle(.secondary)
                    }
                    ForEach(manager.sources) { source in
                        NavigationLink {
                            ExtensionDetailView(source: source)
                        } label: {
                            ExtensionRow(source: source)
                        }
                    }
                } header: {
                    Text("インストール済み")
                }

                ForEach(manager.repositories) { repo in
                    Section {
                        let pending = repo.entries.filter { !manager.isInstalled(manifestURL: $0) }
                        if !pending.isEmpty {
                            Button {
                                addAll(pending)
                            } label: {
                                Label("未追加の \(pending.count) 件をすべて追加", systemImage: "plus.square.on.square")
                            }
                            .disabled(adding)
                        }
                        ForEach(repo.entries, id: \.self) { entry in
                            HStack {
                                Text(entry).font(.caption).lineLimit(2)
                                Spacer()
                                if manager.isInstalled(manifestURL: entry) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                } else {
                                    Button("追加") { add(entry) }
                                        .buttonStyle(.borderless)
                                        .disabled(adding)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("リポジトリ: \(repo.url)").lineLimit(1)
                            Spacer()
                            Button(role: .destructive) {
                                manager.removeRepository(repo)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Section {
                    Button {
                        add(sampleSource)
                    } label: {
                        Label("動作確認用のダミー拡張を追加", systemImage: "testtube.2")
                    }
                    .disabled(adding)
                } footer: {
                    Text("Shiru の開発用サンプル（\(sampleSource)）。架空の検索結果を返すので、拡張の読み込み〜検索結果の表示までが動くかの確認に使えます（再生はできません）。")
                }
            }
            .navigationTitle("拡張機能")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await manager.reloadAll(reason: "手動") }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("すべて読み直す")
                }
            }
        }
    }

    private func addAll(_ urls: [String]) {
        adding = true
        message = nil
        Task {
            var failures: [String] = []
            for url in urls {
                if let error = await manager.addSource(url) { failures.append("\(url): \(error)") }
            }
            if failures.isEmpty {
                message = "\(urls.count) 件追加しました。一覧から有効にしてください"
                messageIsError = false
            } else {
                message = failures.joined(separator: "\n")
                messageIsError = true
            }
            adding = false
        }
    }

    private func add(_ url: String) {
        let target = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        adding = true
        message = nil
        Task {
            if let error = await manager.addSource(target) {
                message = error
                messageIsError = true
            } else {
                message = "追加しました。一覧から有効にしてください"
                messageIsError = false
                if target == newURL.trimmingCharacters(in: .whitespacesAndNewlines) { newURL = "" }
            }
            adding = false
        }
    }
}

private struct ExtensionRow: View {
    let source: ExtensionSource
    @ObservedObject private var manager = ExtensionManager.shared

    var body: some View {
        HStack(spacing: 12) {
            ExtensionIcon(source: source).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.name).font(.headline)
                    Text(source.version).font(.caption).foregroundStyle(.secondary)
                    if source.nsfw { Text("R18").font(.caption2).padding(.horizontal, 4).background(.red.opacity(0.2), in: Capsule()) }
                }
                StatusText(status: manager.runtime[source.key] ?? .disabled)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { manager.states[source.key]?.enabled ?? false },
                set: { value in Task { await manager.setEnabled(source, value) } }
            ))
            .labelsHidden()
        }
    }
}

struct StatusText: View {
    let status: ExtensionRuntimeStatus

    var body: some View {
        switch status {
        case .disabled: Text("無効").font(.caption).foregroundStyle(.secondary)
        case .loading: Text("読み込み中…").font(.caption).foregroundStyle(.orange)
        case .active: Text("有効").font(.caption).foregroundStyle(.green)
        case .failed(let m): Text("エラー: \(m)").font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }
}

struct ExtensionIcon: View {
    let source: ExtensionSource

    var body: some View {
        Group {
            if let data = source.iconData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else if let url = source.iconURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ExtensionDetailView: View {
    let source: ExtensionSource
    @ObservedObject private var manager = ExtensionManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false

    var body: some View {
        List {
            Section {
                LabeledContent("ID", value: source.extensionID)
                LabeledContent("バージョン", value: source.version)
                LabeledContent("種類", value: source.type)
                if let speed = source.speed { LabeledContent("速度", value: speed) }
                if let accuracy = source.accuracy { LabeledContent("精度", value: accuracy) }
                if source.deprecated { Label("非推奨の拡張です", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if source.unregulated { Label("無規制のソースを含みます", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if let d = source.descriptionText { Text(d).font(.callout) }
            }
            Section("状態") {
                Toggle("有効", isOn: Binding(
                    get: { manager.states[source.key]?.enabled ?? false },
                    set: { value in Task { await manager.setEnabled(source, value) } }
                ))
                StatusText(status: manager.runtime[source.key] ?? .disabled)
                if case .failed = manager.runtime[source.key] ?? .disabled {
                    Button("再読み込み") { Task { await manager.retry(source) } }
                }
            }

            let defs = source.settingDefs
            if !defs.isEmpty {
                Section("設定") {
                    ForEach(defs) { def in
                        SettingEditor(source: source, def: def)
                    }
                }
            }

            Section("取得元") {
                ForEach(source.updates, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                ForEach(source.mains, id: \.self) { Text("main: \($0)").font(.caption).textSelection(.enabled) }
                Text("key: \(source.key)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Section {
                Button("この拡張を削除", role: .destructive) { confirmRemove = true }
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("\(source.name) を削除しますか？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                Task {
                    await manager.removeSource(source)
                    dismiss()
                }
            }
        }
    }
}

private struct SettingEditor: View {
    let source: ExtensionSource
    let def: ExtensionSettingDef
    @ObservedObject private var manager = ExtensionManager.shared
    @State private var text = ""
    @State private var reveal = false

    private var value: JSONValue {
        manager.states[source.key]?.settings[def.key] ?? def.defaultValue
    }

    private func save(_ v: JSONValue) {
        Task { await manager.setSetting(source, key: def.key, value: v) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch def.kind {
            case .toggle:
                Toggle(def.label, isOn: Binding(get: { value.boolValue ?? false }, set: { save(.bool($0)) }))
            case .text:
                Text(def.label + (def.required ? " *" : "")).font(.subheadline)
                HStack {
                    Group {
                        if def.secret && !reveal {
                            SecureField(def.placeholder ?? "", text: $text)
                        } else {
                            TextField(def.placeholder ?? "", text: $text)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { save(.string(text)) }
                    if def.secret {
                        Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless)
                    }
                    Button("保存") { save(.string(text)) }
                        .buttonStyle(.borderless)
                        .disabled(text == (value.stringValue ?? ""))
                }
            case .dropdown:
                Picker(def.label, selection: Binding(get: { value.stringValue ?? "" }, set: { save(.string($0)) })) {
                    ForEach(def.options, id: \.value) { Text($0.label).tag($0.value) }
                }
            case .multiselect:
                Text(def.label).font(.subheadline)
                let selected = Set((value.arrayValue ?? []).compactMap(\.stringValue))
                ForEach(def.options, id: \.value) { option in
                    Button {
                        var next = selected
                        if next.contains(option.value) { next.remove(option.value) } else { next.insert(option.value) }
                        save(.array(def.options.map(\.value).filter(next.contains).map(JSONValue.string)))
                    } label: {
                        HStack {
                            Image(systemName: selected.contains(option.value) ? "checkmark.square.fill" : "square")
                            Text(option.label)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let d = def.description {
                Text(d).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { text = value.stringValue ?? "" }
    }
}
