import Foundation

import CommonCrypto

/// Single-block AES-ECB, used only as the AES block primitive.
///
/// The one place it is used as a mode rather than a primitive is the
/// algorithm-glucose field mask, which the vendor defines as
/// `AES-128-ECB(algorithmKey, 0^16)`. That is a fixed 16-byte constant, not
/// a data path, so ECB there is harmless — do not reuse this for transport.
public enum AESECB {
    public enum ECBError: Error, CustomStringConvertible {
        case badKeyLength(Int)
        case badBlockLength(Int)
        case cryptoFailure(Int32)

        public var description: String {
            switch self {
            case let .badKeyLength(n): return "AES-ECB: key must be 16/24/32 bytes, got \(n)"
            case let .badBlockLength(n): return "AES-ECB: input must be a whole number of blocks, got \(n)"
            case let .cryptoFailure(s): return "AES-ECB: CommonCrypto failed (status \(s))"
            }
        }
    }

    public static func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        try crypt(plaintext, key: key, operation: CCOperation(kCCEncrypt))
    }

    public static func decrypt(_ ciphertext: Data, key: Data) throws -> Data {
        try crypt(ciphertext, key: key, operation: CCOperation(kCCDecrypt))
    }

    private static func crypt(_ input: Data, key: Data, operation: CCOperation) throws -> Data {
        switch key.count {
        case kCCKeySizeAES128,
             kCCKeySizeAES192,
             kCCKeySizeAES256: break
        default: throw ECBError.badKeyLength(key.count)
        }
        let blockSize = kCCBlockSizeAES128
        guard input.count % blockSize == 0 else { throw ECBError.badBlockLength(input.count) }
        guard !input.isEmpty else { return Data() }

        var out = Data(count: input.count + blockSize)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, key.count,
                        nil,
                        inPtr.baseAddress, input.count,
                        outPtr.baseAddress, outPtr.count,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess, moved == input.count else {
            throw ECBError.cryptoFailure(status)
        }
        out.removeSubrange(moved ..< out.count)
        return out
    }
}
