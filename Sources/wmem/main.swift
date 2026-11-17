import Foundation
import SiriusMemory

// The working-memory CLI the agents run from their shell (Wmem). Hand-parsed
// rather than ArgumentParser, so its usage, messages and exit codes stay
// those of the Python script it replaces.
let environment = ProcessInfo.processInfo.environment
let wmem = Wmem(file: Wmem.file(environment: environment),
                out: { FileHandle.standardOutput.write(Data($0.utf8)) },
                err: { FileHandle.standardError.write(Data($0.utf8)) })
exit(wmem.run(Array(CommandLine.arguments.dropFirst())))
