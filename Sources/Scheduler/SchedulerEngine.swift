import Foundation
import Combine

// MARK: - SchedulerEngine

/// Core scheduling engine that evaluates cron schedules on a 30-second timer,
/// creates TaskRun records for due tasks, and manages run lifecycle.
///
/// Injected as `.environmentObject(SchedulerEngine.shared)` at both
/// `cmuxApp.swift` and `AppDelegate.swift` (required for multi-window support).
@MainActor
final class SchedulerEngine: ObservableObject {
    static let shared = SchedulerEngine()

    @Published var tasks: [ScheduledTask] = []
    @Published var runs: [TaskRun] = []

    /// Maximum number of concurrently running tasks. Prevents runaway resource usage.
    var maxConcurrentTasks: Int = 10

    /// Tracks the last time schedules were evaluated, preventing duplicate fires
    /// when the timer ticks faster than the cron resolution (1 minute).
    var lastEvaluatedAt: Date

    /// Called when a task is due and a TaskRun has been created.
    /// Wired to `executeTask(_:run:)` via `onTaskDue` in production;
    /// left nil in tests for pure evaluation logic testing.
    var onTaskDue: ((ScheduledTask, TaskRun) -> Void)?

    /// Maps panelId -> runId for tracking which terminal surface belongs to which run.
    var panelToRunId: [UUID: UUID] = [:]

    /// Maps runId -> worktree info for cleanup after task completion.
    var runWorktreeInfo: [UUID: (repoPath: String, worktreePath: String)] = [:]

    /// Injectable git command runner (swapped in tests).
    var gitRunner: GitCommandRunner = ProcessGitCommandRunner()

    /// Maps runId -> workspaceId for per-run workspace tracking (used by Focus).
    var runToWorkspaceId: [UUID: UUID] = [:]

    /// Maps taskId -> workspaceId for the most recent run's workspace.
    /// Used to close the previous workspace when a new run starts for the same task.
    var taskToWorkspaceId: [UUID: UUID] = [:]

    private var timer: DispatchSourceTimer?
    private let persistenceFileURL: URL?

    /// Whether the evaluation timer is currently running.
    var isTimerRunning: Bool { timer != nil }

    /// Interval between schedule evaluations (30 seconds).
    static let evaluationInterval: TimeInterval = 30

    /// Maximum chain depth for onSuccess/onFailure task chaining.
    /// Prevents infinite loops (e.g., A -> B -> A -> B ...).
    static let maxChainDepth = 3

    /// Maximum number of completed runs to retain in memory.
    /// Oldest completed runs are pruned when this limit is exceeded.
    static let maxCompletedRuns = 500

    /// Shared date formatter for ISO8601 serialization.
    private static let isoFormatter = ISO8601DateFormatter()

    /// Directory for session memory context files.
    static let contextDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("cmux/scheduler-context", isDirectory: true)
    }()

    // MARK: - Init

    init(persistenceFileURL: URL? = nil, now: Date = Date()) {
        self.persistenceFileURL = persistenceFileURL
        self.lastEvaluatedAt = now
        loadTasks()
        cleanupStaleRuns()
    }

    // MARK: - Timer

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(
            deadline: .now() + Self.evaluationInterval,
            repeating: Self.evaluationInterval,
            leeway: .seconds(2)
        )
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.checkRunCompletions()
            self.evaluateSchedules()
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Completion Polling

    /// Check for marker files written by initial_input when tasks complete.
    /// Each running task writes its exit code to a .done file; this method
    /// reads those files and updates run status accordingly.
    func checkRunCompletions() {
        for i in runs.indices where runs[i].status == .running {
            let markerPath = Self.contextDirectory
                .appendingPathComponent("\(runs[i].id.uuidString).done")
            guard let data = try? String(contentsOf: markerPath, encoding: .utf8) else { continue }
            let exitCode = Int32(data.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1

            let runId = runs[i].id
            let wsId = runToWorkspaceId[runId] ?? UUID()
            let panelId = runs[i].panelId

            runs[i].status = exitCode == 0 ? .succeeded : .failed
            runs[i].exitCode = exitCode
            runs[i].completedAt = Date()

            cleanupRunResources(runId: runId, panelId: panelId)
            try? FileManager.default.removeItem(at: markerPath)

            // Notification
            let task = tasks.first(where: { $0.id == runs[i].taskId })
            let taskName = task?.name ?? "Unknown Task"
            let statusText = exitCode == 0 ? "completed successfully" : "failed (exit \(exitCode))"
            TerminalNotificationStore.shared.addNotification(
                tabId: wsId,
                surfaceId: panelId ?? UUID(),
                title: taskName,
                subtitle: "Scheduled Task",
                body: "Task \(statusText)"
            )

            pruneCompletedRuns()
        }
    }

    // MARK: - Evaluation

    /// Evaluate all enabled tasks and fire any that are due.
    /// Returns the list of newly created TaskRun records (useful for testing).
    @discardableResult
    func evaluateSchedules(now: Date = Date()) -> [TaskRun] {
        var newRuns: [TaskRun] = []
        let runningCount = runs.filter { $0.status == .running }.count

        for task in tasks {
            guard task.isEnabled else { continue }

            // Check if this task is due: its next fire date (after last evaluation) is <= now
            guard let nextFire = task.nextFireDate(after: lastEvaluatedAt),
                  nextFire <= now else { continue }

            // Check overlap: skip if already running and overlap not allowed
            if !task.allowOverlap {
                let alreadyRunning = runs.contains { $0.taskId == task.id && $0.status == .running }
                if alreadyRunning { continue }
            }

            // Check concurrent task limit
            if runningCount + newRuns.count >= maxConcurrentTasks { break }

            // Create a new run
            let run = TaskRun(taskId: task.id, startedAt: now)
            runs.append(run)
            newRuns.append(run)

            onTaskDue?(task, run)
        }

        lastEvaluatedAt = now
        return newRuns
    }

    // MARK: - Run Pruning

    /// Remove oldest completed runs when the count exceeds `maxCompletedRuns`.
    private func pruneCompletedRuns() {
        let completedRuns = runs.filter { $0.status != .running }
        guard completedRuns.count > Self.maxCompletedRuns else { return }
        let sorted = completedRuns.sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
        let excess = completedRuns.count - Self.maxCompletedRuns
        let idsToRemove = Set(sorted.prefix(excess).map(\.id))
        runs.removeAll { idsToRemove.contains($0.id) }
    }

    // MARK: - Startup Cleanup

    /// Mark any stale `.running` records as `.cancelled` on startup.
    /// If the app crashed or was force-quit, these runs never completed.
    func cleanupStaleRuns() {
        for i in runs.indices {
            if runs[i].status == .running {
                cleanupRunResources(runId: runs[i].id, panelId: runs[i].panelId)
                runs[i].status = .cancelled
                runs[i].completedAt = Date()
            }
        }
        pruneCompletedRuns()
        cleanupOrphanedContextFiles()
    }

    /// Remove context files whose run IDs are not in the active runs list.
    private func cleanupOrphanedContextFiles() {
        let activeRunIds = Set(runs.map { $0.id.uuidString })
        let contextDir = Self.contextDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: contextDir,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "json" || file.pathExtension == "done" {
            let runId = file.deletingPathExtension().lastPathComponent
            if !activeRunIds.contains(runId) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Persistence

    func loadTasks() {
        tasks = SchedulerPersistenceStore.load(fileURL: persistenceFileURL)
    }

    func saveTasks() {
        SchedulerPersistenceStore.save(tasks, fileURL: persistenceFileURL)
    }

    // MARK: - Task Management

    func addTask(_ task: ScheduledTask) {
        tasks.append(task)
        saveTasks()
    }

    func removeTask(id: UUID) {
        tasks.removeAll { $0.id == id }
        saveTasks()
    }

    func updateTask(_ task: ScheduledTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
            saveTasks()
        }
    }

    // MARK: - Run Queries

    func activeRuns(for taskId: UUID) -> [TaskRun] {
        runs.filter { $0.taskId == taskId && $0.status == .running }
    }

    var runningTaskCount: Int {
        runs.filter { $0.status == .running }.count
    }

    // MARK: - Manual Run

    /// Trigger a manual "Run Now" with overlap and concurrent task limit checks.
    /// Returns the new TaskRun on success, or nil if blocked by constraints.
    func manuallyRunTask(_ task: ScheduledTask) -> TaskRun? {
        if !task.allowOverlap {
            let alreadyRunning = runs.contains { $0.taskId == task.id && $0.status == .running }
            if alreadyRunning { return nil }
        }
        if runningTaskCount >= maxConcurrentTasks { return nil }

        let run = TaskRun(taskId: task.id, startedAt: Date())
        runs.append(run)
        onTaskDue?(task, run)
        return run
    }

    // MARK: - Task Execution

    /// Execute a scheduled task by creating a dedicated workspace with a terminal
    /// that runs the command via Ghostty's native `config.command`.
    ///
    /// Each task run gets its own workspace so that Focus is a simple workspace
    /// switch — no bonsplit tab navigation required.
    func executeTask(_ task: ScheduledTask, run: TaskRun, tabManager: TabManager) {
        // Resolve working directory (may create a git worktree if isolation is enabled)
        let worktreeResult = WorktreeIsolation.resolveWorkingDirectory(
            task: task,
            runId: run.id,
            gitRunner: gitRunner
        )
        let effectiveWorkDir = worktreeResult.effectiveDirectory

        // Track worktree for cleanup after task completes
        if let wtPath = worktreeResult.worktreePath,
           let repoPath = task.workingDirectory {
            runWorktreeInfo[run.id] = (repoPath: repoPath, worktreePath: wtPath)
        }

        // Build environment with session memory context
        var env: [String: String] = task.environment ?? [:]
        env["CMUX_SCHEDULED_TASK_ID"] = task.id.uuidString
        env["CMUX_SCHEDULED_TASK_NAME"] = task.name
        env["CMUX_TASK_RUN_ID"] = run.id.uuidString
        if let wtPath = worktreeResult.worktreePath {
            env["CMUX_WORKTREE_PATH"] = wtPath
        }

        // Create session memory context file
        let contextFileURL = Self.contextDirectory
            .appendingPathComponent("\(run.id.uuidString).json")
        createContextFile(for: task, run: run, at: contextFileURL)
        env["CMUX_TASK_CONTEXT_FILE"] = contextFileURL.path

        // Close the previous workspace for this task (if any) to prevent accumulation.
        if let previousWsId = taskToWorkspaceId[task.id],
           let previousWs = tabManager.tabs.first(where: { $0.id == previousWsId }) {
            tabManager.closeTab(previousWs)
        }

        // Create a dedicated workspace for this run (non-intrusive: don't select it).
        let workspace = tabManager.addWorkspace(
            workingDirectory: effectiveWorkDir,
            select: false
        )
        workspace.customTitle = "[\(task.name)]"

        // Track workspace for this run and task
        runToWorkspaceId[run.id] = workspace.id
        taskToWorkspaceId[task.id] = workspace.id

        // Use initial_input to inject the command into the default shell.
        // This preserves the full shell environment so interactive tools render
        // correctly. A marker file signals completion to the polling timer.
        let safeName = ClaudeCommandBuilder.shellEscape(task.name)
        let markerFile = Self.contextDirectory
            .appendingPathComponent("\(run.id.uuidString).done").path
        let banner = "echo '---' \(safeName) '---'; echo ''"
        let doneMsg = "echo ''; echo \"--- Task finished (exit $CMUX_EXIT) ---\""
        let marker = "echo $CMUX_EXIT > \(ClaudeCommandBuilder.shellEscape(markerFile))"
        let fullCommand = "clear; \(banner); \(task.command); CMUX_EXIT=$?; \(doneMsg); \(marker)\n"

        let panel = TerminalPanel(
            workspaceId: workspace.id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            workingDirectory: effectiveWorkDir,
            initialInput: fullCommand,
            additionalEnvironment: env
        )

        // Add to workspace, then ensure bonsplit's focused pane and selected tab
        // point to the task terminal. Without focusPane, focusedPanelId returns nil
        // when the workspace is later selected, causing a transparent terminal.
        workspace.addTerminalPanel(panel, title: "[\(task.name)]")
        if let tabId = workspace.surfaceIdFromPanelId(panel.id) {
            // Find the pane containing the task terminal's tab
            let paneToFocus = workspace.bonsplitController.allPaneIds.first(where: { paneId in
                workspace.bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
            })
            if let paneToFocus {
                workspace.bonsplitController.focusPane(paneToFocus)
            }
            workspace.bonsplitController.selectTab(tabId)
        }

        // Scheduler workspaces are background workspaces — prevent ALL terminals
        // from stealing focus via ensureFocus retries. Focus is only granted
        // explicitly when the user clicks the Focus button.
        for ws_panel in workspace.panels.values {
            if let termPanel = ws_panel as? TerminalPanel {
                termPanel.unfocus()
            }
        }

        // Track panel -> run mapping
        panelToRunId[panel.id] = run.id

        // Update run with panel ID
        if let runIndex = runs.firstIndex(where: { $0.id == run.id }) {
            runs[runIndex].panelId = panel.id
        }
    }

    /// Shared cleanup for a completed/cancelled run: removes tracking map entries,
    /// cleans up worktree and context file.
    private func cleanupRunResources(runId: UUID, panelId: UUID?) {
        if let panelId {
            panelToRunId.removeValue(forKey: panelId)
        }
        runToWorkspaceId.removeValue(forKey: runId)
        if let wtInfo = runWorktreeInfo.removeValue(forKey: runId) {
            WorktreeIsolation.cleanupWorktree(
                repoPath: wtInfo.repoPath,
                worktreePath: wtInfo.worktreePath,
                gitRunner: gitRunner
            )
        }
        let contextFile = Self.contextDirectory.appendingPathComponent("\(runId).json")
        try? FileManager.default.removeItem(at: contextFile)
    }

    /// Handle COMMAND_FINISHED callback from Ghostty.
    /// Called from the action handler in GhosttyTerminalView.swift.
    func handleTaskCompletion(panelId: UUID, exitCode: Int32, workspaceId: UUID?) {
        guard let runId = panelToRunId[panelId],
              let runIndex = runs.firstIndex(where: { $0.id == runId }) else { return }

        // If the run was already cancelled (e.g., by cancelTask racing with COMMAND_FINISHED),
        // do not overwrite its status or re-trigger cleanup/chaining.
        guard runs[runIndex].status == .running else { return }

        let currentChainDepth = runs[runIndex].chainDepth

        runs[runIndex].status = exitCode == 0 ? .succeeded : .failed
        runs[runIndex].exitCode = exitCode
        runs[runIndex].completedAt = Date()

        cleanupRunResources(runId: runId, panelId: panelId)

        // Look up the task for notification and chaining
        let taskId = runs[runIndex].taskId
        let task = tasks.first(where: { $0.id == taskId })
        let taskName = task?.name ?? "Unknown Task"

        // Fire notification via TerminalNotificationStore
        let statusText = exitCode == 0 ? "completed successfully" : "failed (exit \(exitCode))"
        TerminalNotificationStore.shared.addNotification(
            tabId: workspaceId ?? UUID(),
            surfaceId: panelId,
            title: taskName,
            subtitle: "Scheduled Task",
            body: "Task \(statusText)"
        )

        // Task chaining: trigger onSuccess/onFailure follow-up task.
        // Apply the same guards (isEnabled, overlap, concurrency) as evaluateSchedules.
        if currentChainDepth < Self.maxChainDepth, let task = task {
            let chainTargetId: String? = exitCode == 0 ? task.onSuccess : task.onFailure
            if let targetIdString = chainTargetId,
               let targetId = UUID(uuidString: targetIdString),
               let targetTask = tasks.first(where: { $0.id == targetId }),
               targetTask.isEnabled {
                var blocked = false
                if !targetTask.allowOverlap {
                    blocked = runs.contains { $0.taskId == targetTask.id && $0.status == .running }
                }
                if !blocked && runningTaskCount >= maxConcurrentTasks {
                    blocked = true
                }
                if !blocked {
                    let chainRun = TaskRun(
                        taskId: targetTask.id,
                        startedAt: Date(),
                        chainDepth: currentChainDepth + 1
                    )
                    runs.append(chainRun)
                    onTaskDue?(targetTask, chainRun)
                }
            }
        }

        pruneCompletedRuns()
    }

    /// Cancel a running task by requesting its terminal surface to close.
    func cancelTask(runId: UUID) {
        guard let runIndex = runs.firstIndex(where: { $0.id == runId }),
              runs[runIndex].status == .running else { return }

        // Find the panel and request close on its surface
        if let panelId = runs[runIndex].panelId,
           let app = AppDelegate.shared,
           let tabManager = app.tabManager,
           let wsId = runToWorkspaceId[runId],
           let workspace = tabManager.tabs.first(where: { $0.id == wsId }),
           let panel = workspace.panels[panelId] as? TerminalPanel,
           let surface = panel.surface.surface {
            ghostty_surface_request_close(surface)
        }

        // Mark as cancelled regardless of whether we found the surface
        runs[runIndex].status = .cancelled
        runs[runIndex].completedAt = Date()

        cleanupRunResources(runId: runId, panelId: runs[runIndex].panelId)
        pruneCompletedRuns()
    }

    /// Focus a running task's terminal by switching to its dedicated workspace.
    func focusRunningTask(runId: UUID) {
        guard let runIndex = runs.firstIndex(where: { $0.id == runId }),
              runs[runIndex].status == .running,
              let workspaceId = runToWorkspaceId[runId],
              let app = AppDelegate.shared,
              let tabManager = app.tabManager else {
            return
        }

        // Each run has its own workspace — just switch to it.
        tabManager.selectedTabId = workspaceId
    }

    // MARK: - Session Memory

    /// Create a context file with task metadata for the running command to read.
    func createContextFile(for task: ScheduledTask, run: TaskRun, at url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let context: [String: Any] = [
            "task_id": task.id.uuidString,
            "task_name": task.name,
            "run_id": run.id.uuidString,
            "command": task.command,
            "working_directory": task.workingDirectory ?? "",
            "cron_expression": task.cronExpression,
            "started_at": Self.isoFormatter.string(from: run.startedAt),
        ]

        if let data = try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }

    // MARK: - App Quit Cleanup

    /// Persist state and cancel running tasks on app termination.
    func handleAppWillTerminate() {
        // Cancel all running tasks and clean up worktrees + context files
        for i in runs.indices {
            if runs[i].status == .running {
                runs[i].status = .cancelled
                runs[i].completedAt = Date()
                cleanupRunResources(runId: runs[i].id, panelId: runs[i].panelId)
            }
        }

        // Persist final task list
        saveTasks()

        // Stop the evaluation timer
        stop()
    }
}
