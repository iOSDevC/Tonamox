#if os(macOS)
import Foundation
import TerminalBridgeHelper

exit(await HelperCLI.main(Array(CommandLine.arguments.dropFirst())))
#else
print("tonamox-bridge only runs on macOS")
#endif
