//  BootstrapKeyAgreement.swift
//  `PPCP-RV` §11.11 / CR-01 CA1 — where X25519 comes from, and it is not here.
//
//  ⛔ **X25519 is a PARAMETER, not a dependency and not a callback.** §11.11 needs
//  exactly two values the rest of the protocol set does not: this peer's own
//  public key `pk`, and the shared secret `Z`. Each is 32 octets, and **only
//  those two cross this boundary** (11.11d) — `BK`, `sas_raw`, the digits, `K_c`,
//  either MAC, `sid` and `PRK` are all downstream of it and all belong to
//  `libppcp`. The boundary is **below** the derivation, not inside it.
//
//  ⛔ **A callback would be the wrong shape and 11.11's closing note says why.**
//  A callback is right when the library needs something *during a loop it owns* —
//  which is why 5.3a1's rejection sampling takes one. Key agreement has no loop:
//  the component holding the private scalar already has it and already has the
//  counterpart's public key off the wire, so it computes `Z` once and hands over
//  32 octets exactly as it hands over `psk`, `sid` and `rn`.
//
//  ⛔ **11.11f IS THE POINT OF THIS FILE AND IT SPLITS ACROSS THE BOUNDARY.** An
//  agreement that **fails** and one that returns an **all-zero `Z`** are the same
//  event and both are `invalid_key` (11.6b). `libppcp` can see only the zero;
//  only this side can see the failure. On this platform the failure is a
//  **throw** — `CryptoKit` raises `underlyingCoreCryptoError` for a small-order
//  public key rather than returning zeros, which both teams measured (E36) — so
//  the throw half of 11.11f is PinPointCapture's, and a boundary that dropped the
//  failure signal, or reported it as a transport error, would make 11.6b
//  unimplementable on the far side of it.
//
//  ⛔ **AND IT IS NEVER RETRIED (trap 7).** A rejected key is an **attack
//  signal**. A retry loop around it eats 3.7b's single-attempt bound, which is
//  what §11.8's whole argument rests on: the attacker's expected work is one
//  million *operator confirmations*, not one million packets, and it is only that
//  because a miss costs the attempt. `BootstrapAcceptor` maps a throw straight to
//  `invalid_key` and terminates; there is no path here that tries twice.
//
//  Spec: `RV` §11.11, 11.6b, 11.5a, 7.2a. Plan D11, decision CA1.

import Foundation

/// What the key agreement can report, and there is exactly one interesting case.
///
/// ⛔ 11.6b / 11.11f — a failed agreement and an all-zero `Z` are the **same**
/// event. There is deliberately no `.transportError`, no `.temporary` and no
/// `.retryable`: adding one would be trap 7 in the type system.
public enum BootstrapAgreementFailure: Error, Sendable, Equatable {
    /// ⛔ The agreement failed, or produced an all-zero `Z`. **`invalid_key`
    /// (11.6b), an attack signal, and never retried.**
    case invalidKey
    /// A public key that is not 32 octets (11.11a) — refused before it reaches
    /// the curve.
    case wrongKeyLength(Int)
}

/// The supplier of §11.11's two values.
///
/// ⛔ **11.5a — one of these per attempt, and never one more.** The keypair is
/// drawn **fresh from a CSPRNG for every attempt**, used for that attempt only,
/// and never reused or persisted. A reused ephemeral is not ephemeral: E38
/// records that the confirmation MACs descend from `Z` by public functions, so a
/// **recorded transcript is an offline verifier for `Z`** — an observer who kept
/// March's bytes recovers June's `PRK` if the ephemeral was ever weak or
/// repeated. That is the real force of 11.5a's MUST, and it is an obligation on
/// whoever implements this protocol, not on the engine, which cannot check it.
///
/// ⚠ **11.11g is an obligation on the supplier that nothing downstream can
/// check**: the agreement is constant-time with respect to the private scalar.
/// It is the reason this boundary exists at all.
///
/// ⚠ **11.11h1 — a bounded truth about what `11.11h`'s MUST can mean here, and
/// it is recorded rather than assumed away.** Where the agreement is supplied by
/// a system framework that both generates and retains the private scalar and
/// returns the shared secret as its own type, an implementation can guarantee it
/// holds no copy; it cannot guarantee the framework holds none, and it cannot
/// verify that from outside. The mitigation 11.11h1 names is real and is why the
/// shared secret is handed over as a **scoped buffer** below rather than as a
/// `Data`: derive into a type that *is* documented to zero, and let the
/// framework's own hold go out of scope at once. A `Data` return would put `Z`
/// into a Swift value with no zeroise and an unknowable number of copies.
public protocol BootstrapKeyAgreement: AnyObject {

    /// This peer's own public key — `pk_a` for an acceptor. Exactly 32 octets
    /// (11.11a), fresh for this attempt (11.5a).
    ///
    /// ⛔ **For an acceptor this is read before any frame exists, and that is
    /// what makes trap 2 unreachable.** 11.5c requires `bs_accept` to carry
    /// `pk_a` having seen only a **commitment** to `pk_i`; the key is therefore
    /// fixed at the moment the engine is built, so there is no code path that
    /// could choose it after seeing the counterpart's.
    var publicKey: Data { get }

    /// `Z = X25519(own private scalar, counterpart public key)` — 11.6a.
    ///
    /// The 32 octets are handed to `body` and **not** returned, so `Z` never
    /// lands in a Swift value this layer would then have to erase (11.11h1).
    ///
    /// - Throws: `BootstrapAgreementFailure.invalidKey` where the agreement
    ///   fails **or** yields an all-zero `Z`. ⛔ Never a transport error, and the
    ///   caller never retries (11.6b, 11.11f, trap 7).
    func withSharedSecret<T>(
        peerPublicKey: Data,
        _ body: (UnsafeRawBufferPointer) throws -> T
    ) throws -> T
}
