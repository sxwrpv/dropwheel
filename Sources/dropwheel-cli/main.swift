import DropwheelCore
import DropwheelEngines
import Foundation

// Headless access to Dropwheel's conversions, for scripting and testing.
//
//   dropwheel-cli targets <file>...          formats the selection can become
//   dropwheel-cli convert <format> <file>... convert each file, print output paths
//   dropwheel-cli tools                      which external tools were found

let usage = """
usage: dropwheel-cli targets <file>...
       dropwheel-cli convert <format> <file>...
       dropwheel-cli tools
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func absoluteURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage) }

switch command {
case "tools":
    for tool in ExternalTool.allCases {
        print("\(tool.rawValue): \(ToolLocator.url(for: tool)?.path ?? "not found — \(tool.installHint)")")
    }

case "targets":
    let files = arguments.dropFirst().map(absoluteURL)
    guard !files.isEmpty else { fail(usage) }
    let targets = ConversionMatrix.targets(for: files.map(ConversionService.selectionItem))
    print(targets.map(\.label).joined(separator: " "))

case "convert":
    guard arguments.count >= 3, let target = FileFormat(fileExtension: arguments[1]) ?? FileFormat(rawValue: arguments[1].lowercased()) else {
        fail(usage)
    }
    var failures = 0
    for file in arguments.dropFirst(2).map(absoluteURL) {
        do {
            let output = try await ConversionService().convert(file, to: target)
            print(output.path)
        } catch {
            failures += 1
            FileHandle.standardError.write(Data("\(file.lastPathComponent): \(error.localizedDescription)\n".utf8))
        }
    }
    exit(failures == 0 ? 0 : 1)

default:
    fail(usage)
}
