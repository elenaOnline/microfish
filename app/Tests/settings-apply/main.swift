import Foundation

// Test front end for SettingsApply: behaves like `apply-settings.py <draft>` (stdout, stderr, exit code),
// so the differential runner can drive the Python reference and the Swift port the same way.
// Paths come from MICROFISH_SUPPORT_DIR / MICROFISH_RESOURCES / MICROFISH_BRIDGE / MICROFISH_ENGINE / MICROFISH_LOG_DIR.
let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "--float-repr" {
    // stdin: one 64-bit pattern per line, in hex; stdout: the number as Python would print it.
    while let line = readLine() {
        print(SettingsApply.pythonFloatRepr(Double(bitPattern: UInt64(line, radix: 16) ?? 0)))
    }
    exit(0)
}
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: settings-apply-cli <draft.json>\n".utf8))
    exit(2)
}
let result = SettingsApply.run(draft: URL(fileURLWithPath: arguments[1]))
FileHandle.standardOutput.write(Data(result.stdout.utf8))
FileHandle.standardError.write(Data(result.stderr.utf8))
exit(result.status)
