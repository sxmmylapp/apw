// apw-pinread --watch-chrome: keep Sammy's everyday Google Chrome paired with iCloud Passwords, no human.
// Apple's extension keeps its pairing key only in its service worker's memory, so every Chrome start (and every
// time the extension reconnects to Apple's helper) asks for a fresh 6-digit code. This watcher:
//   1. sees a PasswordManagerBrowserExtensionHelper whose PARENT is the everyday Chrome (bundle com.google.Chrome
//      exactly; apw's own Chrome Beta and any other browser never match) showing its code window,
//   2. reads the code from that window (AX, else OCR of that one window), as apw-pinread does for apw,
//   3. finds Chrome's iCloud Passwords popup (chrome-extension://<ext>/page_popup.html) and its PIN0..PIN5 fields
//      through AX, and for each digit: AX-focuses the field, checks Chrome's focused element IS that field, then posts
//      the digit's key event to the Chrome process only (CGEvent.postToPid) - never to whatever app is frontmost.
//      The popup submits on the 6th keydown (Apple's code listens for keydown only; an AXValue set never submits).
//   4. opens that popup itself: when the extension has (re)connected and the front Chrome window's profile is not
//      paired yet, it AX-presses the pinned "iCloud Passwords" toolbar button once the user is idle, so the in-page
//      "Enable Password AutoFill" prompt never needs a click. A popup that shows no PIN fields means the profile is
//      already paired: it is closed with the popup's own dismiss link.
// The code is never logged or written anywhere.
import AppKit
import ApplicationServices
import Foundation

let dailyChromeBundle = "com.google.Chrome"
let icloudExtensionID = "pejdijmoenmkgeppbflobdenhhabjlaj"
let popupPath = "\(icloudExtensionID)/page_popup.html"

func ax(_ e: AXUIElement, _ k: String) -> CFTypeRef? {
  var v: CFTypeRef?
  return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil
}
func axS(_ e: AXUIElement, _ k: String) -> String? { ax(e, k) as? String }
func axKids(_ e: AXUIElement) -> [AXUIElement] { (ax(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func axURL(_ e: AXUIElement) -> String? {
  guard let u = ax(e, "AXURL") else { return nil }
  if CFGetTypeID(u) == CFURLGetTypeID() { return (u as! URL).absoluteString }
  return u as? String
}

/// "<page> - Google Chrome - <profile>" -> "<profile>"; a title without a profile suffix -> "".
func chromeWindowLabel(_ title: String) -> String {
  guard let r = title.range(of: " - Google Chrome - ", options: .backwards) else { return "" }
  return String(title[r.upperBound...])
}

struct Popup {
  let webArea: AXUIElement
  let pins: [AXUIElement]  // PIN0..PIN5 in order when the PIN box is showing, else empty
  let dismiss: AXUIElement?
}

/// The extension popup's web area. Never descends into other web areas, so a big page is not walked.
func findPopupWebArea(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
  if depth > 40 { return nil }
  if axS(e, kAXRoleAttribute) == "AXWebArea" { return (axURL(e) ?? "").contains(popupPath) ? e : nil }
  for k in axKids(e) { if let w = findPopupWebArea(k, depth + 1) { return w } }
  return nil
}

func webAreaOf(_ e: AXUIElement) -> AXUIElement? {
  var cur: AXUIElement? = e
  for _ in 0..<40 {
    guard let c = cur else { return nil }
    if axS(c, kAXRoleAttribute) == "AXWebArea" { return c }
    cur = ax(c, kAXParentAttribute).map { $0 as! AXUIElement }
  }
  return nil
}

func popupFrom(_ area: AXUIElement) -> Popup {
  var byID: [String: AXUIElement] = [:]
  func walk(_ e: AXUIElement, _ d: Int) {
    if d > 30 { return }
    if let id = axS(e, "AXDOMIdentifier"), id.hasPrefix("PIN") || id == "dismiss" { byID[id] = e }
    for k in axKids(e) { walk(k, d + 1) }
  }
  walk(area, 0)
  let pins = (0..<6).compactMap { byID["PIN\($0)"] }
  return Popup(webArea: area, pins: pins.count == 6 ? pins : [], dismiss: byID["dismiss"])
}

func findPopup(_ app: AXUIElement) -> Popup? {
  if let f = ax(app, kAXFocusedUIElementAttribute), let area = webAreaOf(f as! AXUIElement),
    (axURL(area) ?? "").contains(popupPath)
  {
    return popupFrom(area)
  }
  for w in (ax(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
    if let area = findPopupWebArea(w, 0) { return popupFrom(area) }
  }
  return nil
}

/// Chrome's focused element is PIN<i> inside the iCloud Passwords popup.
func focusIsPin(_ app: AXUIElement, _ i: Int) -> Bool {
  guard let f = ax(app, kAXFocusedUIElementAttribute) else { return false }
  let el = f as! AXUIElement
  guard axS(el, "AXDOMIdentifier") == "PIN\(i)", let area = webAreaOf(el) else { return false }
  return (axURL(area) ?? "").contains(popupPath)
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
    usleep(15000)
  }
}

func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

func waitUntil(_ seconds: Double, _ cond: () -> Bool) -> Bool {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end {
    if cond() { return true }
    spin(0.05)
  }
  return cond()
}

/// Types the code into the popup's six fields. Every keystroke is preceded by a check that Chrome's focused
/// element is the field it belongs in; any doubt stops typing.
func fillPIN(_ code: String, pid: pid_t, app: AXUIElement, popup: Popup) -> Bool {
  let digits = Array(code)
  guard digits.count == 6, popup.pins.count == 6 else { return false }
  for i in 0..<6 {
    let field = popup.pins[i]
    if !focusIsPin(app, i) {
      AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
      _ = waitUntil(0.5) { focusIsPin(app, i) }
    }
    guard focusIsPin(app, i) else { log("chrome: PIN field \(i + 1) would not take focus; typed nothing more"); return false }
    postDigit(digits[i], to: pid)
    let landed = waitUntil(1.5) {
      (axS(field, kAXValueAttribute) ?? "").count == 1 || (ax(field, kAXEnabledAttribute) as? Bool) == false
    }
    guard landed else { log("chrome: keystroke \(i + 1) did not reach the PIN field; typed nothing more"); return false }
  }
  return true
}

enum Press { case pressed, missing, failed(AXError) }

/// The pinned toolbar button; Chrome titles it "iCloud Passwords\nHas access to this site".
func pressToolbarButton(_ window: AXUIElement) -> Press {
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
  guard let b = find(window, 0) else { return .missing }
  let err = AXUIElementPerformAction(b, kAXPressAction as CFString)
  return err == .success ? .pressed : .failed(err)
}

func idleSeconds() -> Double {
  [CGEventType.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel].map {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
  }.min() ?? 0
}

/// Roles and DOM ids of the popup, never values (a field may hold a digit of the code).
func describePopup(_ p: Popup) -> String {
  var out: [String] = []
  func walk(_ e: AXUIElement, _ d: Int) {
    if d > 12 || out.count > 60 { return }
    out.append("\(String(repeating: " ", count: d))\(axS(e, kAXRoleAttribute) ?? "?")#\(axS(e, "AXDOMIdentifier") ?? "")")
    for k in axKids(e) { walk(k, d + 1) }
  }
  walk(p.webArea, 0)
  return "url=\(axURL(p.webArea) ?? "?") pins=\(p.pins.count) dismiss=\(p.dismiss != nil)\n" + out.joined(separator: "\n")
}

func watchChrome(dryRun: Bool, dump showPopup: Bool) -> Never {
  dump = false  // the shared AX/OCR readers print window text, which holds the code; this mode never does
  log("chrome: watching \(dailyChromeBundle) for iCloud Passwords pairing\(dryRun ? " (dry run: never presses or types)" : "")")
  var chromePid: pid_t = 0
  var app = AXUIElementCreateApplication(0)
  var webAX = false
  var known = Set<pid_t>()
  var paired = Set<String>()  // profile labels paired since the extension last (re)connected
  var presses: [String: (n: Int, at: Date)] = [:]
  var pressedLabel: (label: String, at: Date)?
  var codeSeen: [pid_t: Date] = [:]
  var attempts: [pid_t: Int] = [:]

  func setWebAX(_ on: Bool) {
    guard webAX != on else { return }
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    webAX = on
  }
  func mainLabel() -> String? {
    guard let w = ax(app, kAXMainWindowAttribute) else { return nil }
    let win = w as! AXUIElement
    guard axS(win, kAXSubroleAttribute) == "AXStandardWindow", let t = axS(win, kAXTitleAttribute) else { return nil }
    return chromeWindowLabel(t)
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
      webAX = false
      known = []; paired = []; presses = [:]; codeSeen = [:]; attempts = [:]; pressedLabel = nil
      log("chrome: Google Chrome running (pid \(chromePid))")
    }
    let helpers = Set(helperPids(parents: [chromePid]))
    if !helpers.subtracting(known).isEmpty {
      log("chrome: iCloud Passwords extension connected to Apple's helper (pids \(helpers.sorted())); pairing needed")
      paired = []; presses = [:]
    }
    known = helpers

    // A code window from a helper of THIS Chrome: fill it into the popup.
    let showing = helpers.filter { !windowIDs($0).isEmpty }
    for h in showing where codeSeen[h] == nil { codeSeen[h] = Date() }
    for h in Array(codeSeen.keys) where !showing.contains(h) { codeSeen[h] = nil; attempts[h] = nil }
    if let h = showing.max(by: { codeSeen[$0]! < codeSeen[$1]! }) {
      guard (attempts[h] ?? 0) < 2 else { continue }
      setWebAX(true)
      guard let popup = findPopup(app), popup.pins.count == 6,
        popup.pins.allSatisfy({ (ax($0, kAXEnabledAttribute) as? Bool) != false }),
        (axS(popup.pins[0], kAXValueAttribute) ?? "").isEmpty
      else { continue }  // the popup is not asking yet
      if showPopup { log("chrome: popup \(describePopup(popup))") }
      guard let code = viaAX(h) ?? windowIDs(h).lazy.compactMap(viaOCR).first else { continue }
      attempts[h, default: 0] += 1
      let label = pressedLabel.flatMap { Date().timeIntervalSince($0.at) < 60 ? $0.label : nil } ?? mainLabel() ?? ""
      if dryRun { log("chrome: dry run: would type the code into profile '\(label)' popup"); attempts[h] = 2; continue }
      guard fillPIN(code, pid: chromePid, app: app, popup: popup) else { continue }
      let ok = waitUntil(10) {
        guard let p = findPopup(app) else { return true }
        return p.pins.isEmpty
      }
      let ms = Int(Date().timeIntervalSince(codeSeen[h] ?? Date()) * 1000)
      if ok {
        paired.insert(label)
        pressedLabel = nil
        log("chrome: paired Google Chrome profile '\(label)' with no human, \(ms) ms after the code window appeared")
        setWebAX(false)
      } else {
        log("chrome: typed the code for profile '\(label)' but the popup still asks for it (\(ms) ms)")
      }
      continue
    }

    // No code window: open the popup ourselves when the front window's profile is not paired yet.
    guard !helpers.isEmpty, chrome.isActive, idleSeconds() >= 2, let label = mainLabel(), !paired.contains(label)
    else { continue }
    let prev = presses[label] ?? (0, .distantPast)
    guard prev.n < 3, Date().timeIntervalSince(prev.at) > 30 else { continue }
    setWebAX(true)
    if findPopup(app) != nil { continue }  // a popup is already open
    presses[label] = (prev.n + 1, Date())
    if dryRun { log("chrome: dry run: would press iCloud Passwords in profile '\(label)'"); continue }
    guard let w = ax(app, kAXMainWindowAttribute) else { continue }
    switch pressToolbarButton(w as! AXUIElement) {
    case .pressed: break
    case .missing:
      log("chrome: no pinned iCloud Passwords button in profile '\(label)' front window")
      presses[label] = (3, Date())
      continue
    case .failed(let err):
      log("chrome: pressing iCloud Passwords in profile '\(label)' failed (AXError \(err.rawValue))")
      continue
    }
    pressedLabel = (label, Date())
    let challenged = waitUntil(5) { helpers.contains { !windowIDs($0).isEmpty } }
    if challenged { continue }  // the next pass types the code
    if let p = findPopup(app), p.pins.isEmpty {
      paired.insert(label)
      if let d = p.dismiss { AXUIElementPerformAction(d, kAXPressAction as CFString) }
      log("chrome: profile '\(label)' is already paired")
      setWebAX(false)
    }
  }
}
