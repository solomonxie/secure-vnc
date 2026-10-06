import BigInt
import CommonCrypto
import CryptoKit
import Foundation

enum RFBAuth {
    /// Security type 2: DES-encrypt the 16-byte challenge with the bit-reversed password as key.
    static func vncResponse(challenge: [UInt8], password: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 8)
        for (i, b) in Array(password.utf8.prefix(8)).enumerated() { key[i] = reverseBits(b) }
        return crypt(challenge, key: key, algorithm: CCAlgorithm(kCCAlgorithmDES))
    }

    /// Security type 30 (Apple Remote Desktop): DH agreement, MD5(shared) as AES-128-ECB key over
    /// 64-byte username + 64-byte password. Returns ciphertext followed by our public key.
    static func appleResponse(generator: [UInt8], prime: [UInt8], serverKey: [UInt8],
                              username: String, password: String) -> [UInt8] {
        let keyLength = prime.count
        let p = BigUInt(Data(prime)), g = BigUInt(Data(generator))
        var secretBytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, secretBytes.count, &secretBytes)
        let secret = BigUInt(Data(secretBytes))
        let ours = g.power(secret, modulus: p)
        let shared = BigUInt(Data(serverKey)).power(secret, modulus: p)
        let aesKey = Array(Insecure.MD5.hash(data: pad(shared, keyLength)))

        var creds = [UInt8](repeating: 0, count: 128)
        _ = SecRandomCopyBytes(kSecRandomDefault, creds.count, &creds)
        place(username, into: &creds, at: 0)
        place(password, into: &creds, at: 64)
        return crypt(creds, key: aesKey, algorithm: CCAlgorithm(kCCAlgorithmAES)) + pad(ours, keyLength)
    }

    static func pad(_ n: BigUInt, _ length: Int) -> [UInt8] {
        let bytes = [UInt8](n.serialize())
        return [UInt8](repeating: 0, count: max(0, length - bytes.count)) + bytes.suffix(length)
    }

    private static func place(_ s: String, into buf: inout [UInt8], at offset: Int) {
        let bytes = Array(s.utf8.prefix(63)) + [0]
        buf.replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }

    private static func reverseBits(_ b: UInt8) -> UInt8 {
        var b = b, r: UInt8 = 0
        for _ in 0..<8 { r = r << 1 | b & 1; b >>= 1 }
        return r
    }

    static func crypt(_ input: [UInt8], key: [UInt8], algorithm: CCAlgorithm) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        CCCrypt(CCOperation(kCCEncrypt), algorithm, CCOptions(kCCOptionECBMode), key, key.count, nil,
                input, input.count, &out, out.count, &moved)
        return out
    }
}
