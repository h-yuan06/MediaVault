import Foundation

enum DownloadStatus: String, Codable {
    case pending
    case downloading
    case merging
    case paused
    case completed
    case failed
    case skipped

    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .downloading: return "Downloading"
        case .merging: return "Merging"
        case .paused: return "Paused"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .skipped: return "Already downloaded"
        }
    }

    var isActive: Bool { self == .downloading || self == .merging || self == .pending || self == .paused }
    var isFinished: Bool { self == .completed || self == .failed || self == .skipped }
}

@MainActor
class DownloadItem: Identifiable, ObservableObject {
    let id: UUID
    let sourceId: UUID
    let url: String
    @Published var title: String
    @Published var status: DownloadStatus
    @Published var progress: Double        // 0.0 – 1.0
    @Published var speedDescription: String
    @Published var etaDescription: String
    @Published var filePath: String?
    @Published var errorMessage: String?
    @Published var completedCount: Int
    @Published var currentFilename: String
    @Published var totalBytes: String
    @Published var outputLog: String          // raw live output from the subprocess
    let startedAt: Date

    init(sourceId: UUID, url: String, title: String = "") {
        self.id = UUID()
        self.sourceId = sourceId
        self.url = url
        self.title = title.isEmpty ? url : title
        self.status = .pending
        self.progress = 0
        self.speedDescription = ""
        self.etaDescription = ""
        self.completedCount = 0
        self.currentFilename = ""
        self.totalBytes = ""
        self.outputLog = ""
        self.startedAt = Date()
    }
}
