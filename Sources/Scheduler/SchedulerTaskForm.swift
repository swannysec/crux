import SwiftUI

// MARK: - FormMode

enum SchedulerFormMode: Equatable {
    case create
    case edit(ScheduledTask)
}

// MARK: - CronPreset

enum CronPreset: String, CaseIterable, Identifiable {
    case everyMinute = "Every minute"
    case every5Minutes = "Every 5 minutes"
    case every15Minutes = "Every 15 minutes"
    case hourly = "Hourly"
    case dailyAtMidnight = "Daily at midnight"
    case weekdaysAt9AM = "Weekdays at 9 AM"
    case custom = "Custom"

    var id: String { rawValue }

    var expression: String? {
        switch self {
        case .everyMinute: return "*/1 * * * *"
        case .every5Minutes: return "*/5 * * * *"
        case .every15Minutes: return "*/15 * * * *"
        case .hourly: return "0 * * * *"
        case .dailyAtMidnight: return "0 0 * * *"
        case .weekdaysAt9AM: return "0 9 * * 1-5"
        case .custom: return nil
        }
    }

    static func preset(for expression: String) -> CronPreset {
        for preset in allCases where preset != .custom {
            if preset.expression == expression { return preset }
        }
        return .custom
    }
}

// MARK: - SchedulerTaskForm

struct SchedulerTaskForm: View {
    let mode: SchedulerFormMode
    let existingTasks: [ScheduledTask]
    let onSave: (ScheduledTask) -> Void
    let onSaveAndRun: (ScheduledTask) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var cronText: String = "*/5 * * * *"
    @State private var selectedPreset: CronPreset = .every5Minutes
    @State private var command: String = ""
    @State private var workingDirectory: String = ""

    // Task type
    @State private var taskType: TaskTypeMode = .claude

    // Claude fields
    @State private var claudeModel: ClaudeModel = .sonnet
    @State private var claudePrompt: String = ""
    @State private var claudeProject: String = ""
    @State private var claudePermission: ClaudePermissionMode = .fullAuto
    @State private var claudeMaxTurns: String = ""
    @State private var claudeMaxBudget: String = ""
    @State private var claudeToolPreset: ClaudeToolPreset = .standard
    @State private var claudeCustomTools: Set<String> = ["Read", "Glob", "Grep", "WebSearch"]

    // Advanced
    @State private var showAdvanced: Bool = false
    @State private var allowOverlap: Bool = false
    @State private var worktreeOption: WorktreeOption = .defaultOption
    @State private var onSuccessTaskId: UUID?
    @State private var onFailureTaskId: UUID?
    @State private var envRows: [EnvRow] = []

    // Validation
    @State private var nextFireDates: [Date] = []

    // Preserved for edit mode
    private var editingTaskId: UUID?
    private var editingCreatedAt: Date?

    init(
        mode: SchedulerFormMode,
        existingTasks: [ScheduledTask] = [],
        onSave: @escaping (ScheduledTask) -> Void,
        onSaveAndRun: @escaping (ScheduledTask) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.existingTasks = existingTasks
        self.onSave = onSave
        self.onSaveAndRun = onSaveAndRun
        self.onCancel = onCancel

        if case .edit(let task) = mode {
            self.editingTaskId = task.id
            self.editingCreatedAt = task.createdAt
        }
    }

    private var isEditMode: Bool { mode != .create }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title
                Text(isEditMode ? "Edit Task" : "New Task")
                    .font(.headline)

                // Task type toggle
                Picker("", selection: $taskType) {
                    ForEach(TaskTypeMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // Name
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Task name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                // Cron
                CronInputSection(
                    selectedPreset: $selectedPreset,
                    cronText: $cronText,
                    nextFireDates: nextFireDates
                )

                if taskType == .claude {
                    ClaudeFieldsSection(
                        claudeModel: $claudeModel,
                        claudePrompt: $claudePrompt,
                        claudeProject: $claudeProject,
                        claudePermission: $claudePermission,
                        claudeMaxTurns: $claudeMaxTurns,
                        claudeMaxBudget: $claudeMaxBudget
                    )
                } else {
                    // Command
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("e.g. echo hello", text: $command)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    // Working directory
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Working Directory")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("Optional", text: $workingDirectory)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                // Advanced section
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        if taskType == .claude {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Allowed tools")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $claudeToolPreset) {
                                    ForEach(ClaudeToolPreset.allCases) { preset in
                                        Text(preset.rawValue).tag(preset)
                                    }
                                }
                                .labelsHidden()

                                if claudeToolPreset == .custom {
                                    LazyVGrid(
                                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                                        spacing: 4
                                    ) {
                                        ForEach(ClaudeTool.all) { tool in
                                            Toggle(tool.name, isOn: Binding(
                                                get: { claudeCustomTools.contains(tool.name) },
                                                set: { enabled in
                                                    if enabled {
                                                        claudeCustomTools.insert(tool.name)
                                                    } else {
                                                        claudeCustomTools.remove(tool.name)
                                                    }
                                                }
                                            ))
                                            .toggleStyle(.checkbox)
                                        }
                                    }
                                }
                            }
                        }

                        Toggle("Allow overlap", isOn: $allowOverlap)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Worktree isolation")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $worktreeOption) {
                                ForEach(WorktreeOption.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }

                        TaskChainPicker(
                            label: "On success",
                            selection: $onSuccessTaskId,
                            tasks: chainableTasks
                        )

                        TaskChainPicker(
                            label: "On failure",
                            selection: $onFailureTaskId,
                            tasks: chainableTasks
                        )

                        EnvironmentEditor(rows: $envRows)
                    }
                    .padding(.top, 8)
                }

                // Command preview (Claude mode)
                if taskType == .claude {
                    DisclosureGroup("Generated command") {
                        Text(generatedClaudeCommandPreview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                // Warning for Claude tasks
                if taskType == .claude {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("Scheduled Claude tasks run with full permissions and no human oversight. Review your prompt and cost controls carefully.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Divider()

                // Footer buttons
                HStack {
                    Button("Cancel") {
                        onCancel()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(isEditMode ? "Save & Run" : "Create & Run Now") {
                        onSaveAndRun(buildTask())
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isFormValid)

                    Button(isEditMode ? "Save" : "Create") {
                        onSave(buildTask())
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isFormValid)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if case .edit(let task) = mode {
                prefill(from: task)
            }
            updateNextFireDates()
        }
        .onChange(of: cronText) { _ in
            updateNextFireDates()
        }
        .onChange(of: selectedPreset) { _ in
            if let expr = selectedPreset.expression {
                cronText = expr
            }
        }
    }

    /// Tasks available for chaining (excludes the task being edited).
    private var chainableTasks: [ScheduledTask] {
        existingTasks.filter { $0.id != editingTaskId }
    }

    // MARK: - Validation

    private typealias Limits = ClaudeCommandBuilder

    private var isFormValid: Bool {
        let validCron = CronExpression(cronText) != nil
        if taskType == .claude {
            return !name.isEmpty
                && !claudePrompt.isEmpty
                && claudePrompt.count <= Limits.maxPromptLength
                && validCron
        } else {
            return !name.isEmpty && !command.isEmpty && command.count <= 65_536 && validCron
        }
    }

    // MARK: - Claude Command Generation

    private var claudeConfig: ClaudeCommandBuilder.Config {
        ClaudeCommandBuilder.Config(
            model: claudeModel,
            prompt: claudePrompt,
            permission: claudePermission,
            maxTurns: claudeMaxTurns,
            maxBudget: claudeMaxBudget,
            toolPreset: claudeToolPreset,
            customTools: claudeCustomTools
        )
    }

    /// Single-line command string for execution via shell.
    private var generatedClaudeCommand: String {
        ClaudeCommandBuilder.command(from: claudeConfig)
    }

    /// Multi-line display string for the preview panel.
    private var generatedClaudeCommandPreview: String {
        ClaudeCommandBuilder.commandPreview(from: claudeConfig)
    }

    // MARK: - Permission Confirmation

    // MARK: - Helpers

    private func prefill(from task: ScheduledTask) {
        name = task.name
        cronText = task.cronExpression
        selectedPreset = CronPreset.preset(for: task.cronExpression)
        command = task.command
        workingDirectory = task.workingDirectory ?? ""
        allowOverlap = task.allowOverlap
        worktreeOption = WorktreeOption.from(task.useWorktree)
        onSuccessTaskId = task.onSuccess.flatMap { UUID(uuidString: $0) }
        onFailureTaskId = task.onFailure.flatMap { UUID(uuidString: $0) }

        if let env = task.environment {
            envRows = env.map { EnvRow(key: $0.key, value: $0.value) }
        }

        if task.onSuccess != nil || task.onFailure != nil
            || task.allowOverlap || task.useWorktree != nil
            || (task.environment?.isEmpty == false)
        {
            showAdvanced = true
        }

        // Detect Claude mode from existing command
        if task.command.hasPrefix("claude ") {
            taskType = .claude
            let config = ClaudeCommandBuilder.parseCommand(task.command)
            claudeModel = config.model
            claudePrompt = config.prompt
            claudePermission = config.permission
            claudeMaxTurns = config.maxTurns
            claudeMaxBudget = config.maxBudget
            claudeToolPreset = config.toolPreset
            claudeCustomTools = config.customTools
            claudeProject = task.workingDirectory ?? ""
        } else {
            taskType = .general
        }
    }

    private func updateNextFireDates() {
        guard let cron = CronExpression(cronText) else {
            nextFireDates = []
            return
        }
        var dates: [Date] = []
        var reference = Date()
        let twoYearsFromNow = Calendar.current.date(byAdding: .year, value: 2, to: Date()) ?? Date()
        for _ in 0..<3 {
            guard let next = cron.nextFireDate(after: reference),
                  next <= twoYearsFromNow else { break }
            dates.append(next)
            reference = next
        }
        nextFireDates = dates
    }

    private static func resolveDirectory(_ raw: String, requireAbsolute: Bool = false) -> String? {
        guard !raw.isEmpty else { return nil }
        let path = raw.hasPrefix("~") ? NSString(string: raw).expandingTildeInPath : raw
        if requireAbsolute && !path.hasPrefix("/") { return nil }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func buildTask() -> ScheduledTask {
        let env: [String: String]? = envRows.isEmpty ? nil : Dictionary(
            envRows
                .filter { !$0.key.isEmpty && ClaudeCommandBuilder.isValidEnvKeyName($0.key) && !ClaudeCommandBuilder.isBlockedEnvKey($0.key) }
                .map { ($0.key, $0.value) },
            uniquingKeysWith: { _, last in last }
        )

        let finalCommand: String
        let finalWorkingDir: String?

        if taskType == .claude {
            finalCommand = generatedClaudeCommand
            finalWorkingDir = Self.resolveDirectory(claudeProject, requireAbsolute: true)
        } else {
            finalCommand = command
            finalWorkingDir = Self.resolveDirectory(workingDirectory)
        }

        return ScheduledTask(
            id: editingTaskId ?? UUID(),
            name: name,
            cronExpression: cronText,
            command: finalCommand,
            workingDirectory: finalWorkingDir,
            environment: env,
            isEnabled: true,
            allowOverlap: allowOverlap,
            useWorktree: worktreeOption.toBool,
            onSuccess: onSuccessTaskId?.uuidString,
            onFailure: onFailureTaskId?.uuidString,
            createdAt: editingCreatedAt ?? Date()
        )
    }
}

// MARK: - WorktreeOption

enum WorktreeOption: String, CaseIterable, Identifiable {
    case defaultOption = "Default"
    case always = "Always"
    case never = "Never"

    var id: String { rawValue }
    var label: String { rawValue }

    var toBool: Bool? {
        switch self {
        case .defaultOption: return nil
        case .always: return true
        case .never: return false
        }
    }

    static func from(_ value: Bool?) -> WorktreeOption {
        switch value {
        case .none: return .defaultOption
        case .some(true): return .always
        case .some(false): return .never
        }
    }
}

// MARK: - CronInputSection

private struct CronInputSection: View {
    @Binding var selectedPreset: CronPreset
    @Binding var cronText: String
    let nextFireDates: [Date]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Schedule")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Preset", selection: $selectedPreset) {
                ForEach(CronPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .labelsHidden()

            TextField("Cron expression", text: $cronText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onChange(of: cronText) { _ in
                    selectedPreset = CronPreset.preset(for: cronText)
                }

            if CronExpression(cronText) == nil && !cronText.isEmpty {
                Text("Invalid expression")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if !nextFireDates.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next runs:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(nextFireDates, id: \.self) { date in
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - EnvRow

struct EnvRow: Identifiable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
}

// MARK: - EnvironmentEditor

private struct EnvironmentEditor: View {
    @Binding var rows: [EnvRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Environment Variables")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    rows.append(EnvRow())
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
            }

            ForEach($rows) { $row in
                HStack(spacing: 4) {
                    TextField("KEY", text: $row.key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("=")
                        .foregroundStyle(.secondary)
                    TextField("value", text: $row.value)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - ClaudeFieldsSection

private struct ClaudeFieldsSection: View {
    @Binding var claudeModel: ClaudeModel
    @Binding var claudePrompt: String
    @Binding var claudeProject: String
    @Binding var claudePermission: ClaudePermissionMode
    @Binding var claudeMaxTurns: String
    @Binding var claudeMaxBudget: String

    var body: some View {
        // Model
        VStack(alignment: .leading, spacing: 4) {
            Text("Model")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("", selection: $claudeModel) {
                ForEach(ClaudeModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        // Project directory
        VStack(alignment: .leading, spacing: 4) {
            Text("Project Directory")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("~/code/myproject", text: $claudeProject)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }

        // Permission mode
        VStack(alignment: .leading, spacing: 4) {
            Text("Permission Mode")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("", selection: $claudePermission) {
                ForEach(ClaudePermissionMode.allCases) { perm in
                    Text(perm.displayName).tag(perm)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        // Prompt
        VStack(alignment: .leading, spacing: 4) {
            Text("Prompt")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextEditor(text: $claudePrompt)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .frame(minHeight: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.secondary.opacity(0.3))
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }

        // Cost controls
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Max turns")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("unlimited", text: $claudeMaxTurns)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Max budget")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    Text("$")
                        .foregroundStyle(.secondary)
                    TextField("unlimited", text: $claudeMaxBudget)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
    }
}

// MARK: - TaskChainPicker

private struct TaskChainPicker: View {
    let label: String
    @Binding var selection: UUID?
    let tasks: [ScheduledTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("", selection: $selection) {
                Text("None").tag(UUID?.none)
                ForEach(tasks) { task in
                    Text(task.name).tag(UUID?.some(task.id))
                }
            }
            .labelsHidden()
        }
    }
}
