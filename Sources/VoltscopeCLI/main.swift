import Foundation

let exitCode = await VoltscopeCLI.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment,
    output: .standardOutput,
    errors: .standardError
)
exit(exitCode)
