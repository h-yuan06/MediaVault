import PackagePlugin

@main
struct GenerateFinishedKeywords: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let sourceTarget = target as? SourceModuleTarget else { return [] }
        let inputFile  = sourceTarget.directory.appending("Resources/download-finished-keywords.md")
        let outputFile = context.pluginWorkDirectory.appending("DownloadFinishedKeywords.swift")
        let tool = try context.tool(named: "KeywordsGeneratorTool")
        return [.buildCommand(
            displayName: "Generate DownloadFinishedKeywords",
            executable: tool.path,
            arguments: [inputFile.string, outputFile.string],
            inputFiles: [inputFile],
            outputFiles: [outputFile]
        )]
    }
}
