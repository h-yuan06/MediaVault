import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("Usage: KeywordsGeneratorTool <input.md> <output.swift>\n", stderr)
    exit(1)
}

let inputURL  = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])

let raw = (try? String(contentsOf: inputURL, encoding: .utf8)) ?? ""
let keywords = raw
    .components(separatedBy: .newlines)
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && !$0.hasPrefix("#") }

let escaped = keywords.map { "        \"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"," }.joined(separator: "\n")

let swift = """
// Auto-generated from download-finished-keywords.md — do not edit.
enum DownloadFinishedKeywords {
    static let all: [String] = [
\(escaped)
    ]
}
"""

try swift.write(to: outputURL, atomically: true, encoding: .utf8)
