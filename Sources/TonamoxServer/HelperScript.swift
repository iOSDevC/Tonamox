import CryptoKit
import Foundation

/// A fixed shell script the server publishes at `GET /s/{name}` when ``ServerFeatures/scripts`` is on. Its bytes are
/// compiled into the SDK; ``sha256`` is the published hash a phone types along with the fetch line, so a
/// substituted script fails `shasum -c` before `sh` runs it.
public struct HelperScript: Sendable, Hashable, Identifiable {
    /// File name, also the last path component of its URL.
    public let name: String
    /// Lowercase hex SHA-256 of the served bytes; also the `ETag` value (quoted).
    public let sha256: String
    let bytes: Data

    public var id: String { name }

    /// `echo '<ingest-url>' | sh tnx-run.sh -- <command…>`: runs the command, posts its output with the exit status
    /// header, deletes its temporary file and exits with the command's status. POSIX `sh`, `umask 077`, `mktemp`.
    /// The URL is read from standard input and handed to curl with `-K -`, so the ticket never appears in `ps`.
    public static let tnxRun = HelperScript(name: "tnx-run.sh", sha256: tnxRunSHA256,
                                            bytes: Data(PackageResources.tnx_run_sh))

    /// The published hash of ``tnxRun``. A test checks it against the embedded bytes.
    public static let tnxRunSHA256 = "34232786fb359b7788d18f943a5f751b80fe773d7ed10b34766f8769b3740cf0"

    public static let all: [HelperScript] = [tnxRun]

    static func named(_ name: String) -> HelperScript? {
        all.first { $0.name == name }
    }

    /// SHA-256 of the bytes actually served.
    var servedHash: String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public func url(on endpoint: ServerEndpoint) -> URL {
        endpoint.baseURL.appendingPathComponent("s").appendingPathComponent(name)
    }

    /// The tool that checks the hash on the computer.
    public enum Verifier: Sendable, Hashable {
        /// macOS: `shasum -a 256 -c -`.
        case shasum
        /// Linux (coreutils): `sha256sum -c -`.
        case sha256sum

        var command: String {
            switch self {
            case .shasum: "shasum -a 256 -c -"
            case .sha256sum: "sha256sum -c -"
            }
        }
    }

    /// Downloads the script to a `mktemp` file and checks it against ``sha256``; `&&`-chain a run after it.
    public func fetchAndVerifyLine(on endpoint: ServerEndpoint, verifier: Verifier = .shasum) -> String {
        "f=$(mktemp) && curl -fsS \(url(on: endpoint).absoluteString) -o \"$f\" && echo '\(sha256)  '\"$f\" | "
            + verifier.command
    }

    /// The fetch-and-verify line followed by `echo '<ingest-url>' | sh "$f" -- <command>` (`echo` is a shell
    /// builtin, so no process carries the ticket in its arguments). The command is appended verbatim; the caller has
    /// already checked it against its own typed-line policy.
    public func runLine(on endpoint: ServerEndpoint, ticket: IngestTicket, command: String,
                        verifier: Verifier = .shasum) -> String {
        fetchAndVerifyLine(on: endpoint, verifier: verifier)
            + " && echo '\(ticket.url(on: endpoint).absoluteString)' | sh \"$f\" -- " + command
    }
}
