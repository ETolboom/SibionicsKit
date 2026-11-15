import Foundation
import SibionicsKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sibionics-decode: \(message)\n".utf8))
    exit(2)
}

var mac: String?
var transportKey = SibionicsCipher.transportKey
var quiet = false
var inputPath: String?

let arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--mac",
         "-m":
        guard index + 1 < arguments.count else { fail("--mac needs a value") }
        mac = arguments[index + 1]
        index += 2
    case "--key",
         "-k":
        guard index + 1 < arguments.count else { fail("--key needs a hex value") }
        let hex = arguments[index + 1].filter(\.isHexDigit)
        guard hex.count == 32 else { fail("--key must be 32 hex digits (AES-128)") }
        var bytes = [UInt8]()
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            bytes.append(UInt8(hex[cursor ..< next], radix: 16) ?? 0)
            cursor = next
        }
        transportKey = Data(bytes)
        index += 2
    case "--quiet",
         "-q":
        quiet = true
        index += 1
    case "--help",
         "-h":
        print("usage: sibionics-decode --mac AA:BB:CC:DD:EE:FF [--key <32 hex>] [capture.btsnoop] < capture.txt")
        exit(0)
    default:
        guard !argument.hasPrefix("-"), inputPath == nil else {
            fail("unexpected argument \(argument); try --help")
        }
        inputPath = argument
        index += 1
    }
}

guard let mac, !mac.isEmpty else { fail("--mac is required (the cipher IV is derived from it)") }
guard SibionicsCipher.isValidMAC(mac) else { fail("\"\(mac)\" is not a 12-hex-digit MAC") }

let cipher: SibionicsCipher
do {
    cipher = try SibionicsCipher(mac: mac, transportKey: transportKey)
} catch {
    fail("\(error)")
}

// MARK: - Load

let rawInput: Data
if let inputPath {
    guard let data = FileManager.default.contents(atPath: inputPath) else {
        fail("cannot read \(inputPath)")
    }
    rawInput = data
} else {
    rawInput = FileHandle.standardInput.readDataToEndOfFile()
}

guard !rawInput.isEmpty else { fail("no input (pass a .btsnoop file or pipe hex on stdin)") }

var captured: [SibionicsCaptureDecoder.Captured] = []
var source: String

if SibionicsBTSnoop.isBTSnoop(rawInput) || SibionicsPKLG.looksLikePKLG(rawInput) {
    do {
        let dump = SibionicsBTSnoop.isBTSnoop(rawInput)
            ? try SibionicsBTSnoop.parse(rawInput)
            : try SibionicsPKLG.parse(rawInput)
        captured = dump.frames
        source = (SibionicsBTSnoop.isBTSnoop(rawInput) ? "btsnoop" : "pklg")
            + ": \(captured.count) ATT value(s)"
        if let start = dump.startedAt, let end = dump.endedAt {
            source += String(format: ", %0.1fs", end.timeIntervalSince(start))
        }
        if dump.skipped > 0 { source += ", \(dump.skipped) ACL packet(s) skipped" }
    } catch {
        fail("\(error)")
    }
} else {
    guard let text = String(data: rawInput, encoding: .utf8) else {
        fail("unrecognised input: not btsnoop, not pklg, and not UTF-8 text")
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let parsed = SibionicsCaptureDecoder.parseLine(String(line)) else { continue }
        captured.append(SibionicsCaptureDecoder.Captured(direction: parsed.direction, value: parsed.bytes))
    }
    source = "text: \(captured.count) value(s)"
}

FileHandle.standardError.write(Data("sibionics-decode: \(source)\n".utf8))

// MARK: - Decode

var decodedCount = 0
var undecodable: [Data] = []

for entry in captured {
    guard let decoded = SibionicsCaptureDecoder.decode(entry.value, direction: entry.direction, cipher: cipher) else {
        undecodable.append(entry.value)
        continue
    }
    decodedCount += 1
    let direction = decoded.direction.map { "\($0.rawValue)" } ?? "?"
    print(String(
        format: "%@  ct=%dB pt=%dB  cmd=0x%02x",
        direction.padding(toLength: 6, withPad: " ", startingAt: 0),
        decoded.ciphertext.count, decoded.plaintext.count, decoded.reply.cmd
    ))
    if !quiet { print("        raw: \(decoded.plaintext.hexDescription)") }
    for note in decoded.notes { print("        \(note)") }
    print("")
}

FileHandle.standardError.write(Data(
    "sibionics-decode: \(decodedCount) frame(s) decoded, \(undecodable.count) not our traffic\n".utf8
))
if !undecodable.isEmpty, !quiet {
    let sample = undecodable.prefix(3).map { "\($0.count)B:\($0.prefix(8).hexDescription)…" }
    FileHandle.standardError.write(Data(
        "  e.g. \(sample.joined(separator: " "))\n".utf8
    ))
    FileHandle.standardError.write(Data(
        "  (other characteristics' traffic and a wrong MAC both look like this)\n".utf8
    ))
}

exit(decodedCount > 0 ? 0 : 1)
