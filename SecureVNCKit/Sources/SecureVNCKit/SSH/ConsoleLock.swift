import Foundation

extension SSHTunnel {
    /// Whether the macOS console session's screen is locked, from the kernel registry
    /// (readable from any SSH session). Nil when the host isn't a Mac or has no console user.
    public func macScreenLocked() async throws -> Bool? {
        let result = try await exec(RemoteFiles.command(#"""
        command -v ioreg >/dev/null || exit 0
        ioreg -n Root -d1 | grep -o '"IOConsoleUsers" = \|"CGSSessionScreenIsLocked"=Yes' | sort -u
        """#, []))
        let out = result.text
        guard out.contains("IOConsoleUsers") else { return nil }
        return out.contains("CGSSessionScreenIsLocked\"=Yes")
    }
}
