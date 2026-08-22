# PinPointCapture — PPCP conformance claim

**What this application claims of `ppcp/1.0`, and the command that reproduces each claim.**

| | |
|---|---|
| Implementation | PinPointCapture (iOS) |
| Role | `capture` |
| Against | `PPCP-CORE` revision 9, `PPCP-MSG`, `PPCP-ENC`, `PPCP-CONF` 1.0; `PPCP-RV` revision 8 |
| Companion | [`libppcp/docs/conformance/matrix.md`](https://github.com/PinPoint-Golf/libppcp) — the compliance record this file feeds |
| Status | **In progress.** Session S1 of the implementation programme: work packages **D0 and D1 landed**. |
| Depends on | `libppcp` — MIT, consumed as a SwiftPM package (plan A5), product `CPPCP`. Path `../../../libppcp` during co-development; `https://github.com/PinPoint-Golf/libppcp.git` once tagged. |
| Date | 22 August 2026 |

---

## 1. Profile set

`CORE` §2.2.3, "full mobile capture device".

| Profile | Claimed | Notes |
|---|---|---|
| **Core** | yes | The mandatory base. |
| **Capture** | yes | Clips as Captures, retained on device and transferred on the bulk channel. |
| **Detect** | yes | Acoustic onset nomination from the device microphone. |
| **Mint** | yes | Hostless operation mints its own Shots, `authority: device`. |
| **Live** | yes | Sessions with a host, sync, heartbeat, arm. |
| **Offline** | yes | The session store *is* the bundle (plan A9). |
| **Markup** | yes | Device-authored annotations, host annotations stored opaque. |
| **Arbitrate** | **no** | Host-only by `CORE` I20. The negative test applies: this application parses `capture_request` and **never originates it**, and never originates `session_link`. |

## 2. PPCP-RV

`RV` 9d requires an implementation to state which optional parts it provides.

| Part | Claimed | State |
|---|---|---|
| **Pairing code** (`RV` §4) — REQUIRED of any RV implementation | yes | D7. The device is the **scanner**, therefore the dialler and the TLS client (`RV` 2d, 5.2g). |
| **Key derivation and TLS** (`RV` §5) | yes | D0 + D1 landed. The derivation is `libppcp`'s (`ppcp_rv_derive`, `ppcp_rv_psk_identity`); TLS lives in the application and never in the library (plan A7). |
| **Security model** (`RV` §7) | yes | D1 landed the transport half; the secret-handling half is D7. |
| **Service discovery** (`RV` §3) | **intended, and now in doubt** | See the finding in §4. The device can advertise, but a Network.framework listener cannot accept a conformant rotating PSK identity, and on the discovery path the advertiser listens. |
| **Network join** (`RV` §6) | intended | D7. `NEHotspotConfiguration` with consent before the endpoint walk. |

---

## 3. Conformance rows

Rows in the format of [`matrix.md`](https://github.com/PinPoint-Golf/libppcp) §5, so they transplant into it unchanged. Only the **PinPointCapture** column is this file's to fill.

| Test | Method | Asserts | Work packages | `libppcp` | PinPointStudio | PinPointCapture |
|---|---|---|---|---|---|---|
| RT-1 | static | §10.1 derivation vectors | L12 | — | — | pass |
| RT-4 | injected | strongest mode negotiated, never plaintext, outcome surfaced | H1, D1 | n/a | — | impl |
| RT-10 | injected | `session_resume` refused without a completed handshake | H1, D1 | n/a | — | impl |
| RT-14 | static | §10.2 PSK identity; differs per connection; empty hint at TLS 1.2 | L12, H1, D1 | — | — | impl |
| RT-17 | **review** | every platform mode offered, from a capability query | H1, D1 | n/a | — | review |

### What each state rests on

**RT-1 — `pass — make test-core`.** `Packages/Core/Tests/CaptureCoreTests/RendezvousTests.swift`. `PRK`, `K_tls` and `K_id` reproduce byte for byte from the §10.1 `psk` and `sid`, through `libppcp`'s `ppcp_rv_derive` — not through an HKDF of this application's own, which is the point of plan A5. Re-deriving from a persisted `PRK` (5.1c) lands on the same two keys.

**RT-4 — `impl`.** Reproduce with `make test-app`
(`Tests/TransportLoopbackTests.swift`, commit `bb85a06`).

- *Never plaintext* (5.2f): held by construction — `Sources/Platform/Network/PpcpTransport.swift` contains no plaintext branch, and `PpcpByteChannel.open` has no return value meaning "connected without TLS". A mismatched `K_tls` fails closed, asserted.
- *Outcome surfaced* (5.4k): `NegotiatedSecurity` carries the achieved version, ciphersuite and key-exchange mode; both ends of the loopback agree on it. **Measured: TLS 1.2, `0x00A8`, `TLS_PSK_WITH_AES_128_GCM_SHA256`, no forward secrecy** — `RV` 5.4b1 reproduced exactly, on iOS 27.
- *Not yet demonstrated*: "a handshake negotiating a weaker mode than both peers can reach is refused" (5.2b1). Both ends of this loopback share the same platform limitation, so the pair cannot reach anything stronger and the assertion is vacuous here. It needs an instrumented counterpart or a wire capture (`RV` 5.2i) — `ppcp-conform` (L14), or the PinPointStudio leg where the counterpart *can* reach TLS 1.3 (S5 interop).

**RT-10 — `impl`.** Reproduce with `make test-app` and `make test-core`.

- The transport half is done and tested: a `PpcpByteChannel` refuses to carry a byte until its connection is `.ready` with TLS metadata (`RV` 1.3c, 7.7a), false start is disabled, and Network.framework exposes no 0-RTT switch to leave on (`RV` 7.5d).
- The message half — `session_resume` refused for a `sid` not bound to the connection (7.5b) — needs the peer engine (L6) and D6. Nothing to run yet.

**RT-14 — `impl`.** Reproduce with `make test-core` and `make test-app`.

- *Byte for byte*: `ppcp_rv_psk_identity` with §10.2's `rn2` produces `010f1e2d3c4b5a6978b355ada60b4b5aa8` exactly, and the result contains no `sid` (5.3e).
- *Differs across connections* (5.3a): sixty-four identities from the default `SystemRandomNumberGenerator` source are sixty-four distinct values, with only the `0x01` version octet stable.
- *Wire half*: the 17 octets are handed to the platform as bytes with no transcoding, no UTF-8 validation and no truncation (5.3f), and the §10.2 identity completes a handshake unchanged — 5.4b2 reproduced on iOS 27. A Core test asserts an identity that is deliberately invalid UTF-8 survives a round trip.
- *All that is left*: the **empty `psk_identity_hint`** at TLS 1.2 (5.2h property 3, RT-14's tail). The listener sets it explicitly to zero length rather than leaving it unset, but whether the platform sends it empty or omits it entirely is not observable from the API — `RV` 5.2i names this exact case. It needs a wire capture, and nothing else does.
- *Not this column*: "resolves under the correct `K_id` only" belongs to the resolver (`ppcp_rv_resolve_psk_identity`), which D7 exercises — and which, per the finding in §4, cannot be reached from inside a Network.framework handshake.

**RT-17 — `review`.** The code to read is the block at the top of `PpcpTlsProfile` in
`Sources/Platform/Network/PpcpTransport.swift`, commit `bb85a06`. ⚠ **A named reviewer is still to be assigned** — a `review` row is not discharged by its author.

What the reviewer is being asked to confirm:

- The version ceiling is `.TLSv13` set as a *maximum*, not a constant "use 1.2", so a platform that gains TLS 1.3 external PSK negotiates it with no edit.
- The offered ciphersuite set is walked from `tls_ciphersuite_group_t.init(rawValue:)` at run time, so it is derived from the platform's own enumeration rather than from a list in this repository, and an SDK that adds a group offers that group with no edit.
- Nothing is withheld: no group is skipped, and no suite is named as a constant anywhere in the offer path.
- ⚠ And that this changes nothing on iOS, which is the point. The platform's enumeration names no PSK suite at all, so the suite that negotiates cannot be requested or excluded — compliance with 5.2b1 **by construction** (`RV` 5.2i), which is why the row is `review` and not a test.

**Re-read this row whenever the TLS setup path is touched and whenever a platform SDK is updated.** RT-17 says so, and it is the requirement now carrying property 2 of 5.2h.

---

## 4. Findings against the specification

Raised from D1, reported rather than worked around (`libppcp` implementation plan ground rule 3).

**F-D1-1 — `RV` 5.3a/5.3b are not implementable in a Network.framework listener.**
Measured on iOS 27 (`Tests/TransportLoopbackTests.swift`): a listener refuses a PSK identity it did not register in advance, with `PSK_IDENTITY_NOT_FOUND` → alert 115 `unknown_psk_identity`. The only server-side entry point is `sec_protocol_options_add_pre_shared_key`, which registers a (key, identity) pair up front; `sec_protocol_options_set_pre_shared_key_selection_block` is documented as "invoked when **the client** must choose a PSK identity given a hint from its peer" and has no server-side counterpart. Since 5.3a makes the identity fresh per connection, a conformant client cannot reach a device listener, and 5.3b's resolver has nowhere to live. This bears on `RV` §3.5b, which recommends the **capture peer advertise** — making this device the listener on the discovery path it is least able to serve. The pairing-code path, which `RV` 2a makes the required one, is unaffected: there the device dials.

**F-D1-2 — `RV` 5.3c is unachievable on this platform, but the gap is not reachable through RV's own key schedule.**
Measured: an unresolvable identity fails early with alert 115; a resolved identity over a wrong key fails at Finished with `bad_record_mac`, alert 20. Different content, different timing, no interface to make them uniform, and 5.3c is a MUST.

⚠ The mitigation is in the specification already, and it is worth recording so the finding is not over-read. `K_tls` and `K_id` both expand from the same `PRK` (`RV` §5.1), so a peer holding the wrong secret computes the wrong identity tag *as well* — every real mismatch, whether a photographed code from another session or a revoked pairing, lands in the unresolvable case. The second case has to be constructed by hand (a registered identity paired with a key it was never derived from) and cannot be produced by a scanned code, a persisted pairing, or an attacker without `PRK`. Both cases are asserted in `Tests/TransportLoopbackTests.swift`.

The API gap remains real for any future derivation that separated the two keys. The matrix marks RT-11 `n/a` for this column, which is right for the pairing-code path where the device dials — and would not be for the discovery path, where it listens.

Neither finding is worked around in code. Both are recorded in the source at the point an implementer meets them.

---

## 5. Reproducing

```
make test-core      # the neutral layer and the RV §10 vectors, on the host
make test-app       # the TLS-PSK handshake, on a simulator
make gen && make build
```

`make test-core` needs a sibling `../libppcp` checkout until the package is tagged.
