// apw-pinread --watch-chrome: keep Sammy's everyday Google Chrome paired with iCloud Passwords, no human.
// Apple's extension keeps its pairing key only in its service worker's memory, so every Chrome start asks each
// profile for a fresh 6-digit code. Measured on Chrome 157 (2026-11-21), and what this watcher is built on:
//   - AXPress on the pinned "iCloud Passwords" toolbar button opens that window's extension popup, also in a
//     background window of another profile. The popup is a small Chrome-owned window (AXSubrole AXUnknown).
//   - Chrome does NOT expose the popup's web content to AX (only empty AXGroups; AXEnhancedUserInterface is
//     refused), so the popup's state is read by OCR of that one window: "Enable Password AutoFill" = asking for
//     the code; "synced with iCloud Keychain" / a login list = paired. The popup's PIN boxes are empty, so this
//     never reads a code. Apple's code window belongs to a PasswordManagerBrowserExtensionHelper whose parent is
//     this Chrome (one helper per profile); apw's Chrome Beta helpers never match.
//   - The popup focuses its first PIN box itself and submits on the 6th digit keydown (an AXValue set never would).
// Loop: for each profile window not yet known paired, once the user is idle and Chrome is in front: press its
// button, OCR the popup. Paired -> close it (press again). Asking -> wait for Apple's code window, read the code
// (AX, else OCR of that window), and post the six digit keys to the Chrome process only (CGEvent.postToPid),
// checking before EVERY key that Chrome is frontmost and its focused window is that popup. Done when the code
// window closes and the popup stops asking. A code window Sammy summoned himself (in-page prompt) is filled the
// same way. The code is never logged or written anywhere.
import AppKit
import ApplicationServices
import Foundation

let dailyChromeBundle = "com.google.Chrome"

func ax(_ e: AXUIElement, _ k: String) -> CFTypeRef? {
  var v: CFTypeRef?
  return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil
}
func axS(_ e: AXUIElement, _ k: String) -> String? { ax(e, k) as? String }
func axKids(_ e: AXUIElement) -> [AXUIElement] { (ax(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func axSize(_ e: AXUIElement) -> CGSize? {
  guard let v = ax(e, kAXSizeAttribute) else { return nil }
  var s = CGSize.zero
  return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
}

/// "<page> - Google Chrome - <profile>" -> "<profile>"; a title without a profile suffix -> "".
func chromeWindowLabel(_ title: String) -> String {
  guard let r = title.range(of: " - Google Chrome - ", options: .backwards) else { return "" }
  return String(title[r.upperBound...])
}

enum PopupState: Equatable { case asking, paired, other(String) }

/// What the iCloud Passwords popup shows, from its OCR text (tests: --popup-state).
func popupState(_ text: String) -> PopupState {
  if text.contains("Enable Password AutoFill") || text.contains("Enable Password Autofill") { return .asking }
  if text.contains("synced with iCloud") || text.contains("Open Passwords") || text.contains("Choose an account") {
    return .paired
  }
  return .other(text.replacingOccurrences(of: #"\d"#, with: "#", options: .regularExpression)
    .replacingOccurrences(of: "\n", with: " | ").prefix(120).description)
}

/// Chrome's extension popup: an on-screen Chrome window much smaller than a browser window.
func popupWindow(_ pid: pid_t) -> (id: CGWindowID, size: CGSize)? {
  let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
  for w in info where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
      let id = w[kCGWindowNumber as String] as? CGWindowID
    else { continue }
    if r.width >= 200, r.width <= 520, r.height >= 60, r.height <= 600 { return (id, r.size) }
  }
  return nil
}

func toolbarButton(_ window: AXUIElement) -> AXUIElement? {
  func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
    if d > 20 { return nil }
    let role = axS(e, kAXRoleAttribute) ?? ""
    if role == "AXWebArea" { return nil }
    if role == "AXPopUpButton" || role == "AXButton",
      [kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { (axS(e, $0) ?? "").hasPrefix("iCloud Passwords") })
    {
      return e
    }
    for k in axKids(e) { if let b = find(k, d + 1) { return b } }
    return nil
  }
  return find(window, 0)
}

let digitKeyCodes: [Character: CGKeyCode] = [
  "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
]

/// One digit key press, delivered to the Chrome process only.
func postDigit(_ ch: Character, to pid: pid_t) {
  guard let key = digitKeyCodes[ch] else { return }
  let src = CGEventSource(stateID: .privateState)
  for down in [true, false] {
    guard let ev = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
    ev.flags = []
    var u = Array(String(ch).utf16)
    ev.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
    ev.postToPid(pid)
    usleep(20000)
  }
}

func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

func waitUntil(_ seconds: Double, _ cond: () -> Bool) -> Bool {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end {
    if cond() { return true }
    spin(0.1)
  }
  return cond()
}

func idleSeconds() -> Double {
  [CGEventType.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel].map {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
  }.min() ?? 0
}

func watchChrome(dryRun: Bool, dump _: Bool) -> Never {
  dump = false  // the shared AX/OCR readers print window text, which holds the code; this mode never does
  log("chrome: watching \(dailyChromeBundle) for iCloud Passwords pairing\(dryRun ? " (dry run: never presses or types)" : "")")
  var chromePid: pid_t = 0
  var app = AXUIElementCreateApplication(0)
  var known = Set<pid_t>()
  var paired = Set<String>()  // profile labels seen paired since the extension last (re)connected
  var tries: [String: (n: Int, at: Date)] = [:]
  var typed = Set<pid_t>()  // helpers whose current code window was already typed once
  var lastNote = ""
  func note(_ s: String) { if s != lastNote { log("chrome: \(s)"); lastNote = s } }

  func frontmost() -> Bool { (ax(app, "AXFrontmost") as? Bool) == true }
  func standardWindows() -> [(win: AXUIElement, label: String)] {
    ((ax(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).compactMap { w in
      guard axS(w, kAXSubroleAttribute) == "AXStandardWindow", let t = axS(w, kAXTitleAttribute) else { return nil }
      let l = chromeWindowLabel(t)
      return l.isEmpty ? nil : (w, l)
    }
  }
  func mainLabel() -> String? {
    guard let w = ax(app, kAXMainWindowAttribute), let t = axS(w as! AXUIElement, kAXTitleAttribute) else { return nil }
    let l = chromeWindowLabel(t)
    return l.isEmpty ? nil : l
  }
  /// Chrome is in front and its focused window is the popup (same size as the on-screen popup window).
  func popupHasFocus(_ size: CGSize) -> Bool {
    guard frontmost(), let f = ax(app, kAXFocusedWindowAttribute) else { return false }
    let w = f as! AXUIElement
    guard axS(w, kAXSubroleAttribute) != "AXStandardWindow", let s = axSize(w) else { return false }
    return abs(s.width - size.width) < 2 && abs(s.height - size.height) < 2
  }
  func codeWindowHelpers() -> [pid_t] { helperPids(parents: [chromePid]).filter { !windowIDs($0).isEmpty } }
  func readPopup() -> PopupState? {
    guard let p = popupWindow(chromePid), let t = windowText(p.id) else { return nil }
    return popupState(t)
  }

  /// The popup asks and helper `h` shows its code window: type the code. Returns true when paired.
  func typeCode(helper h: pid_t, label: String) -> Bool {
    let started = Date()
    guard let pop = popupWindow(chromePid) else { note("code window up (helper \(h)); no popup open"); return false }
    guard readPopup() == .asking else { note("code window up (helper \(h)); popup not asking"); return false }
    guard let code = viaAX(h) ?? windowIDs(h).lazy.compactMap(viaOCR).first, code.count == 6 else {
      note("code window up (helper \(h)); no code readable by AX or OCR"); return false
    }
    typed.insert(h)
    if dryRun { log("chrome: dry run: would type the code into profile '\(label)' popup"); return false }
    for (i, ch) in code.enumerated() {
      guard waitUntil(1.5, { popupHasFocus(pop.size) }) else {
        log("chrome: popup lost focus before digit \(i + 1); typed nothing more"); return false
      }
      postDigit(ch, to: chromePid)
      spin(0.08)
    }
    let ok = waitUntil(10) { windowIDs(h).isEmpty && (popupWindow(chromePid) == nil || readPopup() != .asking) }
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    if ok {
      paired.insert(label)
      log("chrome: paired profile '\(label)' with no human (\(ms) ms from code window to paired)")
      // A popup still open now shows "synced"; pressing the same button closes it.
      if popupWindow(chromePid) != nil, readPopup() == .paired,
        let w = standardWindows().first(where: { $0.label == label }), let b = toolbarButton(w.win)
      {
        AXUIElementPerformAction(b, kAXPressAction as CFString)
      }
    } else {
      log("chrome: typed the code for profile '\(label)' but it is still asking (\(ms) ms)")
    }
    return ok
  }

  while true {
    spin(0.5)
    guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: dailyChromeBundle)
      .first(where: { !$0.isTerminated })
    else {
      if chromePid != 0 { log("chrome: Google Chrome quit") }
      chromePid = 0
      continue
    }
    if chrome.processIdentifier != chromePid {
      chromePid = chrome.processIdentifier
      app = AXUIElementCreateApplication(chromePid)
      known = []; paired = []; tries = [:]; typed = []; lastNote = ""
      log("chrome: Google Chrome running (pid \(chromePid))")
    }
    let helpers = Set(helperPids(parents: [chromePid]))
    if !helpers.subtracting(known).isEmpty {
      log("chrome: extension connected to Apple's helper (pids \(helpers.sorted())); checking each profile")
      paired = []; tries = [:]
    }
    known = helpers
    typed.formIntersection(Set(codeWindowHelpers()))

    // A code window for this Chrome (ours or one Sammy summoned): fill the open popup.
    if let h = codeWindowHelpers().first(where: { !typed.contains($0) }) {
      guard idleSeconds() >= 1 else { note("code window up; waiting for Sammy to stop typing"); continue }
      _ = typeCode(helper: h, label: mainLabel() ?? "?")
      continue
    }
    guard codeWindowHelpers().isEmpty else { note("code window still up after one try; leaving it to Sammy"); continue }

    // No code window: check each profile window not known paired, one press at a time.
    guard !helpers.isEmpty else { note("waiting: extension not connected to Apple's helper"); continue }
    let todo = standardWindows().filter { !paired.contains($0.label) }
    var seen = Set<String>()
    guard let next = todo.first(where: { seen.insert($0.label).inserted && (tries[$0.label]?.n ?? 0) < 4
      && Date().timeIntervalSince(tries[$0.label]?.at ?? .distantPast) > 20 })
    else {
      if todo.isEmpty { note("all open profiles paired") }
      else if todo.allSatisfy({ (tries[$0.label]?.n ?? 0) >= 4 }) {
        note("gave up on \(Set(todo.map(\.label)).sorted()) after 4 tries each; click iCloud Passwords once there")
      }
      continue
    }
    guard frontmost() else { note("waiting: Chrome not in front (unchecked: \(Set(todo.map(\.label)).sorted()))"); continue }
    guard idleSeconds() >= 2 else { note("waiting: Sammy active (unchecked: \(Set(todo.map(\.label)).sorted()))"); continue }
    guard popupWindow(chromePid) == nil else { note("waiting: a popup is already open"); continue }
    let label = next.label
    tries[label] = ((tries[label]?.n ?? 0) + 1, Date())
    guard let b = toolbarButton(next.win) else {
      note("no pinned iCloud Passwords button in profile '\(label)'; pin it once"); tries[label] = (4, Date()); continue
    }
    if dryRun { note("dry run: would press iCloud Passwords in profile '\(label)'"); continue }
    let err = AXUIElementPerformAction(b, kAXPressAction as CFString)
    guard err == .success else { log("chrome: pressing iCloud Passwords in '\(label)' failed (AXError \(err.rawValue))"); continue }
    guard waitUntil(3, { popupWindow(chromePid) != nil }) else {
      log("chrome: pressed iCloud Passwords in '\(label)' (try \(tries[label]!.n)); no popup window appeared"); continue
    }
    spin(0.6)  // let the popup render before reading it
    var state = readPopup()
    if state != .asking && state != .paired { spin(1.5); state = readPopup() }
    switch state {
    case .paired?:
      paired.insert(label)
      if popupWindow(chromePid) != nil { AXUIElementPerformAction(b, kAXPressAction as CFString) }
      log("chrome: profile '\(label)' is paired")
    case .asking?:
      log("chrome: profile '\(label)' asks for the code (try \(tries[label]!.n)); waiting for Apple's code window")
      guard let h = waitUntil(6, { !codeWindowHelpers().isEmpty }) ? codeWindowHelpers().first : nil else {
        log("chrome: no code window appeared for '\(label)'"); continue
      }
      _ = typeCode(helper: h, label: label)
    case .other(let t)?:
      log("chrome: popup in '\(label)' shows neither state: \(t)")
      if popupWindow(chromePid) != nil { AXUIElementPerformAction(b, kAXPressAction as CFString) }
    case nil:
      log("chrome: popup in '\(label)' closed before it could be read")
    }
  }
}
