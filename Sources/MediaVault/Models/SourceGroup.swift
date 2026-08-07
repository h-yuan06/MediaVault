import Foundation

struct SourceGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var sourceIds: [UUID]
    var isPrivate: Bool

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.sourceIds = []
        self.isPrivate = false
    }
}
