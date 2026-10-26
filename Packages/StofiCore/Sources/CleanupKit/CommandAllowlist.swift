import AnalysisKit
import Foundation

/// The only external commands the cleanup runs. Everything else — including commands from profile files —
/// is shown but never executed. Each entry fixes the program and its exact arguments.
enum CommandAllowlist {
    private struct Rule: Sendable {
        /// Allowed program locations; `~` is the home folder.
        let executables: [String]
        let matches: @Sendable ([String]) -> Bool
    }

    private static let rules: [Rule] = [
        Rule(executables: ["/usr/bin/xcrun"]) { $0 == ["simctl", "delete", "unavailable"] },
        Rule(executables: ["/usr/bin/xcrun"]) { $0 == ["simctl", "--set", "previews", "delete", "all"] },
        Rule(executables: ["/usr/bin/xcrun"]) { arguments in
            arguments.count == 4 && Array(arguments.prefix(3)) == ["simctl", "runtime", "delete"]
                && arguments[3].count == 36 && UUID(uuidString: arguments[3]) != nil
        },
        Rule(executables: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) { $0 == ["cleanup", "--prune=all"] },
        Rule(executables: ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                           "/Applications/Docker.app/Contents/Resources/bin/docker"]) { $0 == ["system", "prune", "--force"] },
        Rule(executables: ["~/miniconda3/bin/conda", "~/anaconda3/bin/conda", "~/miniforge3/bin/conda",
                           "~/opt/anaconda3/bin/conda", "~/opt/miniconda3/bin/conda", "/opt/homebrew/bin/conda"]) {
            $0 == ["clean", "--all", "--yes"]
        },
        Rule(executables: ["/opt/homebrew/bin/go", "/usr/local/go/bin/go", "/usr/local/bin/go"]) { $0 == ["clean", "-modcache"] },
    ]

    static func isAllowed(_ command: ExternalCommand, homeDirectory: String) -> Bool {
        rules.contains { rule in
            rule.executables.map { $0.hasPrefix("~/") ? homeDirectory + $0.dropFirst(1) : $0 }.contains(command.executable)
                && rule.matches(command.arguments)
        }
    }
}
