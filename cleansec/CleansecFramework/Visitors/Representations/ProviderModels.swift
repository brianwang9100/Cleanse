import Foundation

/// Full provider representation bound into object graph.
public struct StandardProvider: Equatable, Codable {
    public let type: String
    public let dependencies: [String]
    public let tag: String?
    public let scoped: String?
    public let collectionType: String?
    public let debugData: DebugData
    
    public init(type: String, dependencies: [String], tag: String?, scoped: String?, collectionType: String?, debugData: DebugData = .empty) {
        self.type = type
        self.dependencies = dependencies
        self.tag = tag
        self.scoped = scoped
        self.collectionType = collectionType
        self.debugData = debugData
    }
}

public extension StandardProvider {
    var shortHandDescription: String {
        "type: \(type), num_dependencies: \(dependencies.count), tag: \(tag ?? "none"), scoped: \(scoped ?? "none"), collectionType: \(collectionType ?? "none")"
    }
    
    // used to output spreadsheet
    // have to use semi-colon because dependencies will be outputted as an array with commas
    static var columnTitles: String {
        "type; dependencies; num_dependencies; tag; scoped; collection_type"
    }
    
    // used to output spreadsheet
    // have to use semi-colon because dependencies will be outputted as an array with commas
    var rowContent: String {
        "\(type); \(dependencies.joined(separator: ",")); \(dependencies.count); \(tag ?? "none"); \(scoped ?? "none"); \(collectionType ?? "none")"
    }
}

/// Partial provider presentation with known dependencies, but isn't bound into object graph yet.
/// In Cleanse this is usually a provider implementation created as a function.
public struct DanglingProvider: Equatable, Codable {
    public let type: String
    public let dependencies: [String]
    public let debugData: DebugData
    
    public init(type: String, dependencies: [String], debugData: DebugData = .empty) {
        self.type = type
        self.dependencies = dependencies
        self.debugData = debugData
    }
}
