// apw-pinread --save-click: press "Save Password" / "Update Password" on Apple's helper alert for ONE save that
// `apw pw save` asked for, the instant the alert is on screen, then hand focus back. Runs as launchd job
// com.lod.apw-saveclick (same binary as apw-pinread, so it runs under apw-pinread's Accessibility grant).
//   1. reads ~/.apw/saveclick/request.json {id, host, user, expires} written by `apw pw save`; none or expired: exit 1,
//   2. writes ~/.apw/saveclick/<id>.json {state:"ready"}, then watches only the helpers whose parent is apw's own
//      browser (~/.apw/browser.pid) - Sammy's everyday Chrome and every other app are never looked at,
//   3. presses a button only in a NEW helper window (not on screen when it started) that is Apple's "Save Password?"
//      alert, or its update alert naming this user and site (saveAlertButton); never a default-button fallback,
//   4. restores the app that was frontmost, and writes the result (timings, alerts seen) to <id>.json.
// Never sees the password.
//   apw-pinread --classify-alert <desc> <text>... -- <button>...   print the button it would press, exit 1 if none
import AppKit
import ApplicationServices
import Foundation

func saveClickDir() -> String { "\(home)/.apw/saveclick" }

/// The button to press in a helper window, or nil. `texts` are the window's static texts, `host`/`user` the save
/// that was asked for. Apple's strings (PasswordManagerBrowserExtensionHelper en.lproj/Localizable.strings):
///   new login:      "Save Password?" + button "Save Password" (names no account)
///   existing login: "Do you want to update the password saved for “<user>” on “<site>”?" + button "Update Password",
///                   where <site> is the host or its base domain (measured: "lappsonlinedynamics.com").
/// An update alert for any other user or site, a user-less one, or any other window is left alone.
func saveAlertButton(desc: String, texts: [String], buttons: [String], host: String = "", user: String = "") -> String? {
  guard desc == "alert" else { return nil }
  let t = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  func ourSite(_ d: String) -> Bool { !d.isEmpty && (host == d || host.hasSuffix("." + d)) }
  if t.contains("Save Password?") {
    guard buttons.contains("Save Password") else { return nil }
    if t.contains(where: { quoted($0).contains { $0 != user && !ourSite($0) } }) { return nil }
    return "Save Password"
  }
  for s in t where s.hasPrefix("Do you want to update the password saved ") {
    let q = quoted(s)
    guard s.hasPrefix("Do you want to update the password saved for “"), q.count == 2, q[0] == user, ourSite(q[1]),
      buttons.contains("Update Password")
    else { return nil }
    return "Update Password"
  }
  return nil
}

/// Strings inside “…” or "…".
func quoted(_ s: String) -> [String] {
  var out: [String] = []
  for (open, close) in [("“", "”")] {
    var rest = Substring(s)
    while let a = rest.range(of: open) {
      let after = rest[a.upperBound...]
      guard let b = after.range(of: close) else { break }
      out.append(String(after[..<b.lowerBound]))
      rest = after[b.upperBound...]
    }
  }
  return out
}

func axTexts(_ e: AXUIElement, _ d: Int, _ texts: inout [String], _ buttons: inout [(String, AXUIElement)]) {
  if d > 15 { return }
  let role = axS(e, kAXRoleAttribute) ?? ""
  if role == "AXButton" { buttons.append((axS(e, kAXTitleAttribute) ?? "", e)) } else if role == "AXStaticText" {
    if let v = axS(e, kAXValueAttribute), !v.isEmpty { texts.append(v) }
  }
  for k in axKids(e) { axTexts(k, d + 1, &texts, &buttons) }
}

func writeJSON(_ path: String, _ obj: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
  let tmp = path + ".tmp"
  FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600])
  _ = rename(tmp, path)
}

func runSaveClick() -> Never {
  let t0 = Date()
  func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
  guard let data = FileManager.default.contents(atPath: "\(saveClickDir())/request.json"),
    let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
    let id = req["id"] as? String, id.range(of: "^[A-Za-z0-9-]{8,64}$", options: .regularExpression) != nil,
    let host = req["host"] as? String, let user = req["user"] as? String,
    let expires = req["expires"] as? Double
  else { log("save-click: no save request"); exit(1) }
  let out = "\(saveClickDir())/\(id).json"
  var result: [String: Any] = ["id": id, "state": "ready"]
  guard Date().timeIntervalSince1970 < expires else {
    result["state"] = "expired"; writeJSON(out, result); log("save-click: request \(id) expired"); exit(1)
  }
  guard AXIsProcessTrusted() else {
    result["state"] = "untrusted"; writeJSON(out, result)
    log("save-click: no Accessibility grant (System Settings > Privacy & Security > Accessibility: apw-pinread ON)")
    exit(1)
  }
  guard let browser = apwBrowserPid() else {
    result["state"] = "no-browser"; writeJSON(out, result); log("save-click: apw's browser is not running"); exit(1)
  }
  let frontAtStart = NSWorkspace.shared.frontmostApplication
  // Helper windows already up when we start are someone else's: never pressed.
  var old: [AXUIElement] = []
  for h in helperPids(parents: [browser]) {
    old += (ax(AXUIElementCreateApplication(h), kAXWindowsAttribute) as? [AXUIElement]) ?? []
  }
  let oldCG = Set(helperPids(parents: [browser]).flatMap(windowIDs))
  writeJSON(out, result)
  log("save-click: armed for \(host) / \(user) (request \(id))")

  var axAt: Int?, cgAt: Int?, pressAt: Int?, axGoneAt: Int?, cgGoneAt: Int?, lostAt: Int?, backAt: Int?
  var alert = "", pressed = "", ignored = 0, restored = false
  var seenCG = Set<CGWindowID>(), ignoredWins: [AXUIElement] = []
  let deadline = Date(timeIntervalSince1970: expires)
  while Date() < deadline {
    let pids = Set(helperPids(parents: [browser]))
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    if pids.contains(front) { if lostAt == nil { lostAt = ms() } } else if lostAt != nil, backAt == nil { backAt = ms() }
    let cg = Set(pids.flatMap(windowIDs)).subtracting(oldCG)
    if !cg.isEmpty { if cgAt == nil { cgAt = ms() }; seenCG.formUnion(cg); cgGoneAt = nil } else if cgAt != nil, cgGoneAt == nil {
      cgGoneAt = ms()
    }
    if pressAt == nil {
      for h in pids {
        for w in (ax(AXUIElementCreateApplication(h), kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
          if old.contains(where: { CFEqual($0, w) }) || ignoredWins.contains(where: { CFEqual($0, w) }) { continue }
          var texts: [String] = [], buttons: [(String, AXUIElement)] = []
          axTexts(w, 0, &texts, &buttons)
          let desc = axS(w, kAXDescriptionAttribute) ?? ""
          guard let want = saveAlertButton(desc: desc, texts: texts, buttons: buttons.map { $0.0 }, host: host, user: user)
          else {
            // Not (yet) our alert. A window with buttons is complete: leave it alone for good.
            if !buttons.isEmpty {
              ignored += 1; ignoredWins.append(w)
              log("save-click: left a helper window alone (\(desc), texts \(texts.map { $0.count }) chars, buttons \(buttons.map { $0.0 }))")
            }
            continue
          }
          if axAt == nil { axAt = ms() }
          // Pressed before the window server shows it, the save is lost (measured 2026-11-20): wait for it on screen.
          if cg.isEmpty && ms() - axAt! < 1500 { continue }
          let b = buttons.first { $0.0 == want }!.1
          let r = AXUIElementPerformAction(b, kAXPressAction as CFString)
          alert = want == "Save Password" ? "Save Password?" : "Update Password"
          pressed = r == .success ? want : "failed \(r.rawValue)"
          pressAt = ms()
          log("save-click: pressed \(want) -> \(r.rawValue)")
          break
        }
        if pressAt != nil { break }
      }
    } else {
      let left = pids.contains { !((ax(AXUIElementCreateApplication($0), kAXWindowsAttribute) as? [AXUIElement]) ?? []).filter { w in !old.contains { CFEqual($0, w) } }.isEmpty }
      if !left, axGoneAt == nil { axGoneAt = ms() }
      if axGoneAt != nil, !restored, let f = frontAtStart, pids.contains(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) {
        restored = f.activate(options: [])
      }
      if axGoneAt != nil, (cgGoneAt != nil || cgAt == nil), lostAt == nil || backAt != nil { break }
      if let a = axGoneAt, ms() - a > 1500 { break }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.005))
  }
  result["state"] = pressAt == nil ? "no-alert" : (pressed.hasPrefix("failed") ? "press-failed" : "pressed")
  result["alert"] = alert
  result["button"] = pressed
  result["alerts_seen"] = seenCG.count
  result["ignored_windows"] = ignored
  result["ax_ms"] = axAt ?? -1
  result["cg_ms"] = cgAt ?? -1
  result["press_ms"] = pressAt ?? -1
  result["visible_ms"] = cgAt.map { (cgGoneAt ?? ms()) - $0 } ?? 0
  result["focus_lost_ms"] = lostAt.map { (backAt ?? ms()) - $0 } ?? 0
  result["focus_restored"] = restored
  writeJSON(out, result)
  log("save-click: \(result["state"]!) visible_ms=\(result["visible_ms"]!) focus_lost_ms=\(result["focus_lost_ms"]!) alerts_seen=\(seenCG.count)")
  exit(pressAt != nil && !pressed.hasPrefix("failed") ? 0 : 1)
}

/// Test hook: `--classify-alert <desc> <text>... -- <button>...` [--host h --user u via env].
func classifyAlertCLI(_ rest: [String]) -> Never {
  guard let desc = rest.first else { exit(2) }
  let body = rest.dropFirst()
  let split = body.firstIndex(of: "--") ?? body.endIndex
  let env = ProcessInfo.processInfo.environment
  let b = saveAlertButton(
    desc: desc, texts: Array(body[..<split]), buttons: split < body.endIndex ? Array(body[(split + 1)...]) : [],
    host: env["SC_HOST"] ?? "", user: env["SC_USER"] ?? "")
  if let b = b { print(b); exit(0) }
  exit(1)
}
