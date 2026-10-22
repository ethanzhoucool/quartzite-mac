import Foundation

/// A Quartzite project with one or more schematic sheets, like a Quartus project with
/// several .bdf files. Each sheet is a `Project`; its `entityName` is both the entity and
/// the .bdf file name. Saved as format version 2; version 1 files hold a single bare
/// `Project` and are wrapped on load.
struct DesignProject: Codable {
    var formatVersion = 2
    /// The .qpf / .qsf name; defaults to the top entity.
    var name: String
    var device: String
    var topLevelEntity: String
    /// One per .bdf.
    var sheets: [Project]

    static let currentFormat = 2

    struct LoadError: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    init(name: String, device: String, topLevelEntity: String, sheets: [Project]) {
        self.name = name
        self.device = device
        self.topLevelEntity = topLevelEntity
        self.sheets = sheets
    }

    /// A one-sheet design (a version 1 file or a new project).
    init(single p: Project) {
        var p = p
        if p.id == nil { p.id = UUID() }
        self.init(name: p.name, device: p.device, topLevelEntity: p.entityName, sheets: [p])
    }

    enum CodingKeys: String, CodingKey { case formatVersion, name, device, topLevelEntity, sheets }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? DesignProject.currentFormat
        name = try c.decode(String.self, forKey: .name)
        device = try c.decode(String.self, forKey: .device)
        topLevelEntity = try c.decode(String.self, forKey: .topLevelEntity)
        sheets = try c.decode([Project].self, forKey: .sheets)
    }

    /// Reads a .qzproj of either format.
    static func load(_ data: Data) throws -> DesignProject {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError(message: "The file is not a Quartzite project")
        }
        guard dict["sheets"] != nil else {
            return DesignProject(single: try JSONDecoder().decode(Project.self, from: data))
        }
        if let v = dict["formatVersion"] as? Int, v > currentFormat {
            throw LoadError(message: "This project was made by a newer Quartzite (file format \(v)). Update Quartzite to open it.")
        }
        var d = try JSONDecoder().decode(DesignProject.self, from: data)
        for i in d.sheets.indices where d.sheets[i].id == nil { d.sheets[i].id = UUID() }
        let errors = d.structuralErrors
        guard errors.isEmpty else { throw LoadError(message: errors.joined(separator: "; ")) }
        return d
    }

    /// Version 2 JSON, as saved by File > Save.
    func encoded(pretty: Bool = true) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try enc.encode(self)
    }

    /// Problems that make the design unusable (checked on load, like `Project.structuralErrors`).
    var structuralErrors: [String] {
        var errors: [String] = []
        if sheets.isEmpty { errors.append("The design has no sheets") }
        for s in sheets {
            errors += s.structuralErrors.map { "\(s.entityName).bdf: \($0)" }
        }
        var seen: [String: String] = [:]
        for s in sheets {
            let key = s.entityName.lowercased()
            if let other = seen[key] { errors.append("Sheets \(other) and \(s.entityName) have the same entity name") }
            seen[key] = s.entityName
        }
        let ids = sheets.compactMap(\.id)
        if Set(ids).count != ids.count { errors.append("Duplicate sheet IDs") }
        if !sheets.isEmpty && top == nil { errors.append("The top-level entity '\(topLevelEntity)' is not a sheet of the design") }
        return errors
    }

    var top: Project? { sheet(named: topLevelEntity) }
    var topIndex: Int? { sheetIndex(named: topLevelEntity) }

    /// Case-insensitive, as Quartus (and Windows file names) treat entity names.
    func sheet(named n: String) -> Project? { sheetIndex(named: n).map { sheets[$0] } }
    func sheetIndex(named n: String) -> Int? {
        sheets.firstIndex { $0.entityName.caseInsensitiveCompare(n) == .orderedSame }
    }
    func sheetIndex(id: UUID) -> Int? { sheets.firstIndex { $0.id == id } }

    /// File-safe project name for the .qpf and .qsf (the same rules as `Project.entityName`).
    var projectName: String {
        var p = Project()
        p.name = name
        return p.entityName
    }
}
