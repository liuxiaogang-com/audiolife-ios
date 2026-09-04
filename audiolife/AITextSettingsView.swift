import SwiftUI

struct AITextSettingsView: View {
    @AppStorage(AITextSettingsKey.enabled) private var isEnabled = false
    @AppStorage(AITextSettingsKey.automatic) private var automaticallyOrganizes = true
    @AppStorage(AITextSettingsKey.preset) private var presetRawValue = AITextProviderPreset.deepSeek.rawValue
    @AppStorage(AITextSettingsKey.baseURL) private var baseURL = AITextProviderPreset.deepSeek.defaultBaseURL
    @AppStorage(AITextSettingsKey.model) private var model = AITextProviderPreset.deepSeek.defaultModel

    @State private var apiKey = ""
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var isTesting = false
    @State private var showModelPicker = false
    @State private var statusTitle: String?
    @State private var statusMessage = ""

    private var preset: AITextProviderPreset {
        AITextProviderPreset(rawValue: presetRawValue) ?? .deepSeek
    }

    var body: some View {
        Form {
            Section {
                Toggle("启用 AI 文本理解", isOn: $isEnabled)
                Toggle("录音转写完成后自动整理", isOn: $automaticallyOrganizes)
                    .disabled(!isEnabled)
            } footer: {
                Text("自动整理会发送转写文本，生成标题、摘要、标签和待办建议，不会上传录音文件。")
            }

            Section {
                Picker("接口预设", selection: $presetRawValue) {
                    ForEach(AITextProviderPreset.allCases) { item in
                        Text(item.title).tag(item.rawValue)
                    }
                }

                LabeledContent("接口地址") {
                    TextField("https://…/v1", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }

                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if !apiKey.isEmpty {
                    Button("清除已保存的 Key", role: .destructive) {
                        clearKey()
                    }
                }
            } header: {
                Text("服务商")
            } footer: {
                Text("预设会自动填写地址。Key 只保存在这台 iPhone 的系统钥匙串中；此直连方式适合个人测试，正式发布仍建议使用后端代理。")
            }

            Section {
                TextField("模型名称", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    loadModels()
                } label: {
                    HStack {
                        Label("获取可用模型", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if isLoadingModels {
                            ProgressView()
                                .controlSize(.small)
                        } else if !availableModels.isEmpty {
                            Text("\(availableModels.count) 个")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isLoadingModels || apiKey.trimmed.isEmpty || baseURL.trimmed.isEmpty)

                if !availableModels.isEmpty {
                    Button {
                        showModelPicker = true
                    } label: {
                        LabeledContent("从列表选择") {
                            Text(model.isEmpty ? "请选择" : model)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                Text("模型")
            } footer: {
                Text("通用接口会尝试 GET /models；DeepSeek 原生支持；千问会改用百炼模型列表接口。若服务商没有开放列表，仍可直接手填模型名。")
            }

            Section {
                Button {
                    saveConfiguration(showConfirmation: true)
                } label: {
                    Label("保存配置", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    testConnection()
                } label: {
                    HStack {
                        Spacer()
                        if isTesting {
                            ProgressView()
                                .padding(.trailing, 5)
                        }
                        Text(isTesting ? "正在测试…" : "测试连接")
                        Spacer()
                    }
                }
                .disabled(isTesting || !configurationFromForm.isReady)
            }
        }
        .navigationTitle("AI 文本理解")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = KeychainStore.string(for: AITextConfiguration.apiKeyAccount) ?? ""
            if baseURL.isEmpty { baseURL = preset.defaultBaseURL }
            if model.isEmpty { model = preset.defaultModel }
        }
        .onChange(of: presetRawValue) { oldValue, _ in
            guard oldValue != presetRawValue else { return }
            baseURL = preset.defaultBaseURL
            model = preset.defaultModel
            availableModels = []
        }
        .sheet(isPresented: $showModelPicker) {
            AIModelPickerSheet(models: availableModels, selection: $model)
        }
        .alert(
            statusTitle ?? "提示",
            isPresented: Binding(
                get: { statusTitle != nil },
                set: { if !$0 { statusTitle = nil } }
            )
        ) {
            Button("好") {}
        } message: {
            Text(statusMessage)
        }
    }

    private var configurationFromForm: AITextConfiguration {
        AITextConfiguration(
            isEnabled: isEnabled,
            automaticallyOrganizes: automaticallyOrganizes,
            preset: preset,
            baseURL: baseURL.trimmed,
            model: model.trimmed,
            apiKey: apiKey.trimmed
        )
    }

    private func saveConfiguration(showConfirmation: Bool) {
        do {
            let key = apiKey.trimmed
            if key.isEmpty {
                try KeychainStore.delete(AITextConfiguration.apiKeyAccount)
            } else {
                try KeychainStore.save(key, for: AITextConfiguration.apiKeyAccount)
            }
            baseURL = baseURL.trimmed
            model = model.trimmed
            if showConfirmation {
                statusTitle = "已保存"
                statusMessage = "API 配置已保存到这台设备。"
            }
        } catch {
            statusTitle = "保存失败"
            statusMessage = error.localizedDescription
        }
    }

    private func clearKey() {
        do {
            try KeychainStore.delete(AITextConfiguration.apiKeyAccount)
            apiKey = ""
            availableModels = []
        } catch {
            statusTitle = "清除失败"
            statusMessage = error.localizedDescription
        }
    }

    private func loadModels() {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        Task {
            defer { isLoadingModels = false }
            do {
                try KeychainStore.save(apiKey.trimmed, for: AITextConfiguration.apiKeyAccount)
                let models = try await OpenAICompatibleTextService.shared.fetchModels(
                    preset: preset,
                    baseURL: baseURL,
                    apiKey: apiKey.trimmed
                )
                guard !models.isEmpty else {
                    throw AITextServiceError.invalidResponse
                }
                availableModels = models
                showModelPicker = true
            } catch {
                statusTitle = "无法获取模型"
                statusMessage = error.localizedDescription + "\n\n你仍可以手动填写模型名。"
            }
        }
    }

    private func testConnection() {
        guard !isTesting else { return }
        saveConfiguration(showConfirmation: false)
        isTesting = true
        let configuration = configurationFromForm
        Task {
            defer { isTesting = false }
            do {
                let response = try await OpenAICompatibleTextService.shared.test(
                    configuration: configuration
                )
                statusTitle = "连接成功"
                statusMessage = "模型 \(configuration.model) 返回：\(response)"
            } catch {
                statusTitle = "连接失败"
                statusMessage = error.localizedDescription
            }
        }
    }
}

private struct AIModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let models: [String]
    @Binding var selection: String
    @State private var searchText = ""

    private var filteredModels: [String] {
        guard !searchText.isEmpty else { return models }
        return models.filter { $0.localizedStandardContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List(filteredModels, id: \.self) { model in
                Button {
                    selection = model
                    dismiss()
                } label: {
                    HStack {
                        Text(model)
                            .foregroundStyle(.primary)
                        Spacer()
                        if model == selection {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索模型")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
