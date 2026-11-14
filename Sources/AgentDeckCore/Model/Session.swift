import Foundation

public enum SessionState: String, Codable, Sendable {
    case idle, working, needsYou, waitingInCursor, yourTurn, error, ended, quiet
}

public struct TaskProgress: Codable, Equatable, Sendable {
    public var done: Int
    public var total: Int
    public init(done: Int, total: Int) { self.done = done; self.total = total }
}

public struct Step: Equatable, Sendable {
    public var label: String
    public var tool: String
    public var toolUseId: String?
    public var startedAt: Date
    public var failed: Bool
    /// When the step was observed to finish; nil when it only stopped being reported (e.g. quiet).
    public var finishedAt: Date?
    public init(label: String, tool: String, toolUseId: String? = nil, startedAt: Date, failed: Bool = false, finishedAt: Date? = nil) {
        self.label = label; self.tool = tool; self.toolUseId = toolUseId; self.startedAt = startedAt; self.failed = failed
        self.finishedAt = finishedAt
    }
}

public struct Agent: Equatable, Sendable, Identifiable {
    public var id: String
    public var type: String
    public var state: SessionState
    public var currentStep: Step?
    public var stepCount: Int
    public var startedAt: Date
    public var endedAt: Date?
    public var summary: String?
    public init(id: String, type: String, state: SessionState = .working, currentStep: Step? = nil, stepCount: Int = 0,
                startedAt: Date, endedAt: Date? = nil, summary: String? = nil) {
        self.id = id; self.type = type; self.state = state; self.currentStep = currentStep; self.stepCount = stepCount
        self.startedAt = startedAt; self.endedAt = endedAt; self.summary = summary
    }
}

public struct Session: Equatable, Sendable, Identifiable {
    public let id: String
    public var project: String
    public var cwd: String
    /// First workspace folder reported for this session; never follows later tool cwd changes. Used for labels and navigation.
    public var workspaceRoot: String?
    public var transcriptPath: String?
    public var pid: Int32?
    public var host: String?
    public var entrypoint: String?
    public var title: String?
    public var goal: String?
    public var latestAsk: String?
    public var model: String?
    public var state: SessionState
    public var currentStep: Step?
    /// Last step that stopped being current (G-NOW "Last:"); memory only, like currentStep.
    public var lastStep: Step?
    public var stepCount: Int
    public var failureStreak: Int
    public var progress: TaskProgress?
    public var activity: [Int]
    public var summary: String?
    public var hooksDegraded: Bool
    /// Detail behind `hooksDegraded` (memory only; docs/hook-health.md). `hooksDegraded == hookHealth.degraded`.
    public var hookHealth = HookHealth()
    public var subagents: [Agent]
    public var pending: [Request]
    public var startedAt: Date
    public var lastEventAt: Date
    public var endedAt: Date?

    public init(id: String, project: String = "", cwd: String = "", workspaceRoot: String? = nil, transcriptPath: String? = nil, pid: Int32? = nil,
                host: String? = nil, entrypoint: String? = nil, title: String? = nil, goal: String? = nil,
                latestAsk: String? = nil, model: String? = nil, state: SessionState = .idle, currentStep: Step? = nil,
                stepCount: Int = 0, failureStreak: Int = 0, progress: TaskProgress? = nil,
                activity: [Int] = Array(repeating: 0, count: 30), summary: String? = nil, hooksDegraded: Bool = false,
                subagents: [Agent] = [], pending: [Request] = [], startedAt: Date, lastEventAt: Date, endedAt: Date? = nil) {
        self.id = id; self.project = project; self.cwd = cwd; self.workspaceRoot = workspaceRoot; self.transcriptPath = transcriptPath; self.pid = pid
        self.host = host; self.entrypoint = entrypoint; self.title = title; self.goal = goal; self.latestAsk = latestAsk
        self.model = model; self.state = state; self.currentStep = currentStep; self.stepCount = stepCount
        self.failureStreak = failureStreak; self.progress = progress; self.activity = activity; self.summary = summary
        self.hooksDegraded = hooksDegraded; self.subagents = subagents; self.pending = pending
        self.startedAt = startedAt; self.lastEventAt = lastEventAt; self.endedAt = endedAt
    }
}
