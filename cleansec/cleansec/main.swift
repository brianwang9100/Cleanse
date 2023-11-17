//
//  main.swift
//  cleansec
//
//  Created by Sebastian Edward Shanus on 5/6/20.
//  Copyright © 2020 Square. All rights reserved.
//

import Foundation
import ArgumentParser
import SwiftAstParser
import CleansecFramework

struct CLI: ParsableCommand {
    @Option(name: .long, parsing: .singleValue, help: "-dump-ast outfile file(s) to parse.")
    var astFile: [String]
    
    @Option(name: .long, parsing: .next, help: "Output path for generated module representation.")
    var moduleOutputPath: String
    
    @Option(name: .long, parsing: .singleValue, help: "Directory path(s) to search for emitted module representations when resolving graph.")
    var moduleSearchPath: [String]
    
    @Option(name: .long, default: nil, parsing: .next, help: "Plugin binary path to be executed.")
    var plugin: String?
    
    @Option(name: .long, parsing: .next)
    var moduleName: String
    
    @Flag(name: .shortAndLong, help: "Emits a readable format of each root compoment")
    var emitComponents: Bool
    
    @Option(name: .long, default: nil, parsing: .next, help: "Output path for writing cleanse provider information as a log file")
    var parsedProvidersOutputPath: String?
    
    @Flag(name: .shortAndLong, help: "When writing provider information, will output spreadsheet instead of log file")
    var outputParsedProvidersAsSpreadSheet: Bool
    
    @Flag(name: .shortAndLong, help: "When writing provider information as spreadsheet, will exclude types provided by mint containers")
    var excludeTypesProvidedByMintContainers: Bool
    
    var moduleRepresentationFilename: String {
        "\(moduleName).cleansecmodule.json"
    }
    
    var moduleSearchPathFiles: [URL] {
        return moduleSearchPath.flatMap { path -> [URL] in
            do {
                return try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil, options: .skipsSubdirectoryDescendants)
            } catch {
                return []
            }
        }
    }
    
    func run() throws {
        let syntax = try astFile
            .map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
            .map { SyntaxParser.parse(data: $0)}
            .flatMap { $0 }
        
        var pluginModuleRepresentations: [ModuleRepresentation] = []
        if let pluginPath = plugin {
            pluginModuleRepresentations = PluginRunner.run(plugin: pluginPath, astFiles: astFile)
        }
        
        let analyzedModuleRepresentation = Cleansec.analyze(syntax: syntax)
        let moduleRepresentation = ModuleRepresentation(
            files: analyzedModuleRepresentation.files + pluginModuleRepresentations.flatMap { $0.files }
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let moduleOutputUrl = URL(fileURLWithPath: moduleOutputPath).appendingPathComponent(moduleName).appendingPathExtension("cleansecmodule.json")
        let moduleData = try encoder.encode(moduleRepresentation.trimmed)
        if let jsonFormat = String(data: moduleData, encoding: .utf8) {
            try FileManager.default.createDirectory(
                atPath: moduleOutputPath,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try jsonFormat.write(to: moduleOutputUrl, atomically: true, encoding: .utf8)
        }
        
        let containsRoot = moduleRepresentation.files.flatMap { $0.components }.contains { $0.isRoot }
        guard containsRoot else {
            return
        }
        let availableModules = moduleSearchPathFiles
            .filter { !$0.absoluteString.hasSuffix(moduleRepresentationFilename) }
            .filter { $0.absoluteString.hasSuffix("cleansecmodule.json") }
        let loadedModules = try availableModules
            .map { try Data(contentsOf: $0) }
            .map { try JSONDecoder().decode(ModuleRepresentation.self, from: $0) }
        if let parsedProvidersOutputPath {
            let typesProvidedByMintContainer = findTypesProvidedByMintContainers(loadedModules: loadedModules)
            let providerAndModuleNames = loadedModules
                .flatMap { $0.files }
                .flatMap { file -> [ProviderAndModuleName] in
                    let providerAndModuleNames: [ProviderAndModuleName] = file.modules.flatMap { module in
                        module.providers.map { (provider: $0, moduleName: module.type) }
                    }
                    let providerAndComponentNames: [ProviderAndModuleName] = file.components.flatMap { component in
                        component.providers.map { (provider: $0, moduleName: component.type) }
                    }
                    return providerAndModuleNames + providerAndComponentNames
                }.compactMap { providerAndModuleName -> ProviderAndModuleName? in
                    // feature flag
                    guard excludeTypesProvidedByMintContainers else {
                        return providerAndModuleName
                    }
                    let (provider, moduleName) = providerAndModuleName
                    // exclude MintContainer providers
                    guard !provider.type.contains("MintContainer") else {
                        return nil
                    }
                    // exclude providers whose type is provided by mint container
                    guard !typesProvidedByMintContainer.contains(provider.type) else {
                        return nil
                    }
                    let filteredDependencies = provider.dependencies.filter { type in
                        if type.contains("Provider<") {
                            // remove Provider<> to get raw type
                            var copy = type
                            copy.removeFirst(9)
                            copy.removeLast()
                            return !typesProvidedByMintContainer.contains(copy)
                        } else {
                            return !typesProvidedByMintContainer.contains(type)
                        }
                    }
                    let providerExcludingTypeProvidedByMintContainers = StandardProvider(
                        type: provider.type,
                        dependencies: filteredDependencies,
                        tag: provider.tag,
                        scoped: provider.scoped,
                        collectionType: provider.collectionType
                    )
                    return (provider: providerExcludingTypeProvidedByMintContainers, moduleName: moduleName)
                }
                .sorted { $0.provider.dependencies.count < $1.provider.dependencies.count }
            
            if outputParsedProvidersAsSpreadSheet {
                try outputParsedProvidersAsSpreadsheet(
                    providerAndModuleNames: providerAndModuleNames,
                    moduleName: moduleName,
                    parsedProvidersOutputPath: parsedProvidersOutputPath
                )
            } else {
                try outputParsedProvidersAsSpreadsheet(
                    providerAndModuleNames: providerAndModuleNames,
                    moduleName: moduleName,
                    parsedProvidersOutputPath: parsedProvidersOutputPath
                )
            }
        }
        let linkedInterface = Cleansec.link(modules: loadedModules + [moduleRepresentation])
        let resolvedComponents = Cleansec.resolve(interface: linkedInterface)
        let errors = resolvedComponents.flatMap { $0.diagnostics }
        if emitComponents {
            resolvedComponents.forEach { (c) in
                print("------\n\(c)")
            }
        }
        guard !errors.isEmpty else {
            return
        }
        let stderr = FileHandle.standardError
        let error = CleansecError(resolutionErrors: errors)
        stderr.write(error.description.data(using: .utf8)!)
        throw CLIError()
    }
    
    private func findTypesProvidedByMintContainers(loadedModules: [ModuleRepresentation]) -> Set<String> {
        let allProviders = loadedModules.flatMap { $0.files }.flatMap { $0.modules.flatMap { $0.providers } + $0.components.flatMap { $0.providers} }
        let providersThatDependOnAnyMintContainer = allProviders.filter {
            // if dependencies have only one dependency, and that dependency is a MintContainer, then include it.
            $0.dependencies.count == 1 && $0.dependencies.first!.contains("MintContainer")
        }
        return Set(providersThatDependOnAnyMintContainer.map { $0.type })
    }
    
    private func outputParsedProvidersAsSpreadsheet(
        providerAndModuleNames: [ProviderAndModuleName],
        moduleName: String,
        parsedProvidersOutputPath: String
    ) throws {
        let spreadsheetString = providerAndModuleNames
        .map { "\($0.moduleName); \($0.provider.rowContent)" }
        .reduce("module_name; \(StandardProvider.columnTitles)") { "\($0)\n\($1)" }
        let parsedProvidersOutputPathUrl = URL(fileURLWithPath: parsedProvidersOutputPath).appendingPathComponent("\(moduleName)-parsed-providers").appendingPathExtension("csv")
        try FileManager.default.createDirectory(
            atPath: parsedProvidersOutputPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try spreadsheetString.write(to: parsedProvidersOutputPathUrl, atomically: true, encoding: .utf8)
    }
    
    private func outputParsedProvidersAsLog(
        providerAndModuleNames: [ProviderAndModuleName],
        moduleName: String,
        parsedProvidersOutputPath: String
    ) throws {
        let logString = providerAndModuleNames
            .map { "module_name: \($0.moduleName), \($0.provider.shortHandDescription)" }
            .reduce("") { "\($0)\n\($1)" }
        let parsedProvidersOutputPathUrl = URL(fileURLWithPath: parsedProvidersOutputPath).appendingPathComponent("\(moduleName)-parsed-providers").appendingPathExtension("log")
        try FileManager.default.createDirectory(
            atPath: parsedProvidersOutputPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try logString.write(to: parsedProvidersOutputPathUrl, atomically: true, encoding: .utf8)
    }
}

typealias ProviderAndModuleName = (provider: StandardProvider, moduleName: String)

fileprivate extension ModuleRepresentation {
    // Removes all files with empty modules and components
    var trimmed: ModuleRepresentation {
        return ModuleRepresentation(files: files.filter { !$0.components.isEmpty || !$0.modules.isEmpty })
    }
}

CLI.main()
