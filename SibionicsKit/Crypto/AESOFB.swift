import Foundation

import CommonCrypto

/// AES-128-OFB with a *per-packet* IV reset, which is what the GS3 V3
/// transport uses: every frame restarts the same keystream, so two
/// ciphertexts from one sensor XOR to the XOR of their plaintexts. That is
/// a property of the vendor protocol, not of this implementation; see
/// `/Users/erik/BuildTrio/GS3/GS3-protocol-notes.md`.
///
/// CryptoKit has no OFB mode, so the keystream is generated with a single
/// AES-ECB encryptor fed its own output. ECB itself is only used as the
/// block primitive here, never as the transport mode.
public struct AESOFB: Sendable {
    public enum OFBError: Error, CustomStringConvertible {
        case badKeyLength(Int)
        case badIVLength(Int)
        case cryptoFailure(Int32)

        public var description: String {
            switch self {
            case let .badKeyLength(n): return "AES-OFB: key must be 16 bytes, got \(n)"
            case let .badIVLength(n): return "AES-OFB: iv must be 16 bytes, got \(n)"
            case let .cryptoFailure(s): return "AES-OFB: CommonCrypto failed (status \(s))"
            }
        }
    }

    public static let blockSize = kCCBlockSizeAES128

    private let key: Data

    public init(key: Data) throws {
        guard key.count == kCCKeySizeAES128 else { throw OFBError.badKeyLength(key.count) }
        self.key = key
    }

    /// XORs `input` with the OFB keystream. OFB is its own inverse, so this
    /// both encrypts and decrypts. The final block may be partial.
    public func apply(_ input: Data, iv: Data) throws -> Data {
        guard iv.count == Self.blockSize else { throw OFBError.badIVLength(iv.count) }
        guard !input.isEmpty else { return Data() }

        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyPtr in
            CCCryptorCreate(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionECBMode),
                keyPtr.baseAddress, key.count,
                nil,
                &cryptor
            )
        }
        guard createStatus == kCCSuccess, let cryptor else {
            throw OFBError.cryptoFailure(createStatus)
        }
        defer { CCCryptorRelease(cryptor) }

        var keystream = [UInt8](iv)
        var output = [UInt8]()
        output.reserveCapacity(input.count)

        var offset = input.startIndex
        while offset < input.endIndex {
            // O_i = E(O_{i-1}); ECB mode so the cryptor is stateless per block.
            var next = [UInt8](repeating: 0, count: Self.blockSize)
            var written = 0
            let status = keystream.withUnsafeBytes { inPtr in
                next.withUnsafeMutableBytes { outPtr in
                    CCCryptorUpdate(
                        cryptor,
                        inPtr.baseAddress, Self.blockSize,
                        outPtr.baseAddress, Self.blockSize,
                        &written
                    )
                }
            }
            guard status == kCCSuccess, written == Self.blockSize else {
                throw OFBError.cryptoFailure(status)
            }
            keystream = next

            let end = min(offset + Self.blockSize, input.endIndex)
            for i in offset ..< end {
                output.append(input[i] ^ keystream[i - offset])
            }
            offset = end
        }
        return Data(output)
    }
}
