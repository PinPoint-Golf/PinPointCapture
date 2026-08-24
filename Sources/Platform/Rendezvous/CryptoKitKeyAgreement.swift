//  CryptoKitKeyAgreement.swift
//  `PPCP-RV` §11.11 / CR-01 CA1 — the device's half of the X25519 seam.
//
//  ⛔ **X25519 IS NOT IN `libppcp` AND NEVER WILL BE** (ground rule 13, CA1). Two
//  values in `RV` §11 need key agreement — this peer's public key `pk` and the
//  shared secret `Z` — and both are **parameters**, exactly as `psk`, `sid`, `rn`
//  and `rn2` already are. This file computes them with the cryptography the
//  application already links and passes 32 octets in. Nothing else crosses
//  (11.11d): `BK`, `sas_raw`, the digits, `K_c`, either MAC, `sid` and `PRK` are
//  all `libppcp`'s.
//
//  ⛔ **11.11f, AND THIS PLATFORM IS THE "THROW" HALF.** `CryptoKit` raises
//  `underlyingCoreCryptoError(-7)` for each of RFC 7748 §6.1's small-order
//  u-coordinates rather than returning an all-zero `Z`; OpenSSL fails the call;
//  something else may yet return zeros. **All three are the same event and all
//  three are `invalid_key`** (11.6b). The library can only see the zero and this
//  side can only see the throw, which is why E36 says neither can implement the
//  clause alone.
//
//  ⛔ **AND IT IS NEVER RETRIED** (trap 7). A rejected key is an **attack
//  signal**, not a transport error. There is no `catch` here that returns a
//  retryable error and no loop around the agreement, because a retry loop eats
//  3.7b's single-attempt bound and that bound is what makes §11.8's argument
//  *"one million operator confirmations, not one million packets"*.
//
//  ⚠ **11.11h1 IS THE REASON `Z` IS NEVER RETURNED, ONLY LENT.** `CryptoKit`'s
//  `PrivateKey` and `SharedSecret` expose no zeroise and Apple documents
//  zero-on-release for `SymmetricKey` but not for those two, so 11.11h is partly
//  an obligation on a closed-source framework here and that is recorded rather
//  than assumed away. The mitigation the erratum names is what this file does:
//  derive into a `SymmetricKey`, which *is* documented to zero, and let
//  `SharedSecret` go out of scope at once. Returning a `Data` would put `Z` into
//  a Swift value with no zeroise and an unknowable number of copies, and would be
//  worse than the framework's own hold.
//
//  ⛔ **11.5a — ONE OF THESE PER ATTEMPT.** The keypair is drawn fresh for every
//  attempt, used once, and never reused or persisted. `Curve25519.KeyAgreement
//  .PrivateKey()` draws from the platform CSPRNG, which is 7.2a's obligation.
//  There is deliberately no way to construct this from stored bytes: E38 records
//  that the confirmation MACs make a recorded transcript an **offline verifier
//  for `Z`**, so a repeated or weak ephemeral is recoverable by a passive
//  observer months later, and neither peer retains anything that would reveal it
//  had happened.
//
//  Spec: `RV` §11.11, 11.5a, 11.6a, 11.6b, 7.2a. Plan D11, decision CA1. RT-21.

import CryptoKit
import Foundation
import CaptureCore

/// `RV` §11.11's two values, from the framework this application already links.
///
/// ⚠ A `final class` and not a `struct`: the private scalar must have exactly one
/// owner and a defined end of life, and a value type would be copied into every
/// closure that touched it.
public final class CryptoKitKeyAgreement: BootstrapKeyAgreement {

    private let priv: Curve25519.KeyAgreement.PrivateKey
    private let pk: Data

    /// ⛔ 11.5a — a **fresh** keypair, from the platform CSPRNG, for **this
    /// attempt only**. There is no initialiser that takes stored bytes.
    public init() {
        priv = Curve25519.KeyAgreement.PrivateKey()
        pk = priv.publicKey.rawRepresentation
    }

    /// 11.11a — 32 octets. ⛔ Read before the exchange begins, which is what makes
    /// 11.5c's ordering unreachable to violate (trap 2).
    public var publicKey: Data { pk }

    public func withSharedSecret<T>(
        peerPublicKey: Data,
        _ body: (UnsafeRawBufferPointer) throws -> T
    ) throws -> T {
        guard peerPublicKey.count == 32 else {
            throw BootstrapAgreementFailure.wrongKeyLength(peerPublicKey.count)
        }
        let key: SymmetricKey
        do {
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
            // ⛔ 11.11f — a throw from either of these two lines is `invalid_key`
            // and nothing else. It is not caught and translated into a transport
            // failure, it is not logged with the key that caused it (7.2b), and it
            // is not tried again.
            let shared = try priv.sharedSecretFromKeyAgreement(with: peer)
            // 11.11h1's mitigation, in one line: into a type documented to zero,
            // and `shared` is released at the end of this scope.
            key = SymmetricKey(data: shared)
        } catch {
            throw BootstrapAgreementFailure.invalidKey
        }
        return try key.withUnsafeBytes { try body($0) }
    }
}
