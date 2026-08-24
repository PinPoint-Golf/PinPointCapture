//  ppcp-browse.swift
//  What is actually on the wire — `_ppcp._tcp`, as a browsing peer sees it.
//
//  ⚠ **A probe, not a peer.** It resolves nothing and connects to nothing, so
//  3.4c does not apply to it: it prints every instance it can see, including the
//  ones a real browse would refuse. That is the point — `PpcpBrowser.browse`
//  filters unresolvable instances out by design, so when it finds nothing there
//  is no way from inside the app to tell "the host is not there" from "the host
//  is there and this device holds no pairing for it". This answers that.
//
//  ⛔ It prints `rn` and `rid`, which are published in the clear by design
//  (3.3a) and are meaningless without a `K_id`. It prints no key material
//  because it holds none.
//
//  Usage:  swift tools/discovery/ppcp-browse.swift [seconds]

import Foundation
import Network

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 15
let serviceType = "_ppcp._tcp"

print("browsing \(serviceType) for \(Int(seconds))s — ^C to stop")

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []
    func isNew(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return names.insert(name).inserted
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return names.count }
}
let seen = Seen()

/// The four fields `PpcpBrowser.browse` requires before it will even try to
/// resolve an instance. A real advertisement that fails any of these would be
/// dropped silently inside the app, so they are checked here explicitly.
func report(name: String, txt: NWTXTRecord?) {
    print("\n• \(name)")
    guard let txt else { print("    ⛔ no TXT record — browse would skip this"); return }
    var fields: [String: String] = [:]
    for key in ["txtvers", "pv", "role", "rn", "rid"] {
        if let value = txt[key] { fields[key] = value }
    }
    for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
        print("    \(key) = \(value)")
    }
    var problems: [String] = []
    if fields["role"] == nil { problems.append("no `role` (3.3a)") }
    if fields["pv"] == nil { problems.append("no `pv` — 3.3e says ignore the advertisement") }
    if (fields["rn"]?.count ?? 0) != 16 { problems.append("`rn` is not 16 hex characters") }
    if (fields["rid"]?.count ?? 0) != 16 { problems.append("`rid` is not 16 hex characters") }
    if problems.isEmpty {
        let role = fields["role"] ?? "?"
        print("    ✔ well-formed; role = \(role)"
              + (role == "host" ? " — this is what (b) dials" : " — (b) skips this, 3.5e"))
    } else {
        for problem in problems { print("    ⛔ \(problem)") }
    }
}

let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: .tcp)
browser.browseResultsChangedHandler = { results, _ in
    for result in results {
        guard case let .service(name, _, _, _) = result.endpoint else { continue }
        guard seen.isNew(name) else { continue }
        if case let .bonjour(txt) = result.metadata { report(name: name, txt: txt) }
        else { report(name: name, txt: nil) }
    }
}
browser.stateUpdateHandler = { state in
    if case .failed(let error) = state { print("browser failed: \(error)") }
}
browser.start(queue: .main)

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    browser.cancel()
    print("\n\(seen.count) instance(s) seen in \(Int(seconds))s.")
    if seen.count == 0 {
        // ⛔ 3.6a — not an error, and this tool must not call it one either.
        print("Nothing advertised. That is an ordinary outcome of §3: no host running,")
        print("or a network that does not carry multicast between its clients.")
    }
    exit(0)
}
RunLoop.main.run()
