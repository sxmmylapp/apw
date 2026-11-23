// apw-pinread --watch-chrome: keep Sammy's everyday Google Chrome paired with iCloud Passwords, no human.
// Apple's extension keeps its pairing key only in its service worker's memory (background.js g_secretSession; every
// new native port resets it), so every Chrome start asks each profile for a fresh 6-digit code. Chrome also destroys
// a profile when its last window closes (feature DestroyProfileOnBrowserClose): the worker dies, the helper reads EOF
// and exits, and the next window of that profile asks again while Chrome never quit. Measured 2026-11-21 (Chrome
// Beta 159, A/B twice): closing the only window ends the helper within 10 s; with
// --disable-features=DestroyProfileOnBrowserClose the helper and worker stay, and chrome://restart keeps the flag.
// So a daily Chrome running without that flag is relaunched with it: at once when it was just started (a Dock, Spotlight
// or link launch after a real quit; no policy, Local State flag or launch-time setting can disable a feature on stable
// Chrome, and a wrapper app would change the Dock icon), else the first time it has had no window for 30 s while another
// app is in front (its new window hidden). Either way no download in progress, at most once per 10 min; from then on
// only a real Chrome quit re-pairs. A fresh Chrome whose extension has not yet started Apple's helper is woken by
// pressing its toolbar button (the same press a check makes), so no click is needed after a launch.
// Measured on Chrome 157 (2026-11-21), and what this watcher is built on:
//   - AXPress on the pinned "iCloud Passwords" toolbar button opens that window's extension popup, also in a
//     background window of another profile. The popup is a small Chrome-owned window (AXSubrole AXUnknown).
//   - Chrome does NOT expose the popup's web content to AX (only empty AXGroups; AXEnhancedUserInterface is
//     refused), so the popup's state is read by OCR of that one window: "Enable Password AutoFill" = asking for
//     the code; "synced with iCloud Keychain" / a login list = paired. The popup's PIN boxes are empty, so this
//     never reads a code. Apple's code window belongs to a PasswordManagerBrowserExtensionHelper whose parent is
//     this Chrome (one helper per profile); apw's Chrome Beta helpers never match.
//   - The popup focuses its first PIN box itself and submits on the 6th digit keydown (an AXValue set never would).
// Loop: for each profile window not yet known paired, once Chrome is in front and the user idle 2 s (a press with
// another app in front pulls Chrome forward, measured 2026-11-21, so it never presses from the background): press
// its button, OCR the popup. Paired -> close it (press again). Asking -> wait for Apple's code window, type when
// Chrome is in front again. Then reopen the popup if Chrome closed it,
// read the code (AX, else OCR of that window), and post the six digit keys to the Chrome process only
// (CGEvent.postToPid), checking before EVERY key that Chrome is frontmost and its focused window is that popup. Done when the code
// window closes and the popup stops asking. A code window Sammy summoned himself (in-page prompt) is filled the
// same way. The code is never logged or written anywhere.
import AppKit
import ApplicationServices
import Foundation

let dailyChromeBundle = ProcessInfo.processInfo.environment["APW_CHROME_BUNDLE"] ?? "com.google.Chrome"  // env: tests only
// env: tests only. The daily Chrome is the instance started with exactly this --user-data-dir (else: none).
let dailyChromeDataDir = ProcessInfo.processInfo.environment["APW_CHROME_USER_DATA_DIR"]
let keepProfilesFeature = "DestroyProfileOnBrowserClose"

/// The arguments to start Chrome again with: its own switches, with keepProfilesFeature merged into its one
/// --disable-features (Chrome reads only the last one, so a second switch would undo the first).
func relaunchArgs(_ argv: [String]) -> [String] {
  var out: [String] = [], features: [String] = []
  for a in argv.dropFirst() where a.hasPrefix("--") {
    if a.hasPrefix("--disable-features=") {
      features += a.dropFirst("--disable-features=".count).split(separator: ",").map(String.init)
    } else {
      out.append(a)
    }
  }
  if !features.contains(keepProfilesFeature) { features.append(keepProfilesFeature) }
  return out + ["--disable-features=\(features.joined(separator: ","))"]
}

/// Chrome was started with --disable-features=...DestroyProfileOnBrowserClose..., so a closed window keeps its profile.
func keepsProfiles(_ pid: pid_t) -> Bool {
  processArgs(pid).contains { $0.hasPrefix("--disable-features=") && $0.contains(keepProfilesFeature) }
}

/// A Chrome download is running (a quit would cancel it): a .crdownload in ~/Downloads written in the last 2 min
/// (an old one left by a crash would otherwise block every relaunch forever).
func downloadInProgress() -> Bool {
  let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
  return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { name in
    guard name.hasSuffix(".crdownload") else { return false }
    let m = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.modificationDate] as? Date
    return Date().timeIntervalSince(m ?? .distantPast) < 120
  }
}

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

/// What a window's address bar shows (Chrome's omnibox, AX description "Address and search bar"), nil when empty.
func addressBarText(_ window: AXUIElement) -> String? {
  func find(_ e: AXUIElement, _ d: Int) -> String? {
    if d > 20 { return nil }
    let role = axS(e, kAXRoleAttribute) ?? ""
    if role == "AXWebArea" { return nil }
    if role == "AXTextField", axS(e, kAXDescriptionAttribute) == "Address and search bar" {
      let v = (axS(e, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespaces)
      return v.isEmpty ? nil : v
    }
    for k in axKids(e) { if let v = find(k, d + 1) { return v } }
    return nil
  }
  return find(window, 0)
}

/// Chrome's last-used profile opens with "Continue where you left off" (session.restore_on_startup 1): a relaunch
/// brings its tabs back by itself, so passing them again would open each twice.
func restoresSession(userDataDir: String) -> Bool {
  func json(_ path: String) -> [String: Any]? {
    (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
  }
  let last = ((json("\(userDataDir)/Local State")?["profile"] as? [String: Any])?["last_used"] as? String) ?? "Default"
  return ((json("\(userDataDir)/\(last)/Preferences")?["session"] as? [String: Any])?["restore_on_startup"] as? Int) == 1
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

/// The everyday Chrome: the pid already being watched while it is alive, else the running com.google.Chrome
/// started without --user-data-dir (a test or tool instance with its own profile dir is never the daily one).
/// NSRunningApplication's per-bundle list can come back empty for one pass while Chrome runs (seen 2026-11-21 as
/// "Google Chrome quit" then "running" with the same pid, which reset every profile's state), so a live pid wins.
func dailyChrome(current: pid_t, cached: NSRunningApplication? = nil) -> NSRunningApplication? {
  if current != 0, kill(current, 0) == 0 {
    if let a = NSRunningApplication(processIdentifier: current), a.bundleIdentifier == dailyChromeBundle, !a.isTerminated {
      return a
    }
    // LaunchServices can miss a live pid for a pass (the spurious "quit"/"running" pairs of 2026-11-21..23): the pid
    // answers kill(0) and its executable is still Chrome's, so it is the same Chrome. Keep the object already held.
    if let c = cached, c.processIdentifier == current, pidPath(current).contains("/Google Chrome.app/") { return c }
  }
  return NSRunningApplication.runningApplications(withBundleIdentifier: dailyChromeBundle)
    .filter { a in
      guard !a.isTerminated else { return false }
      let dirs = processArgs(a.processIdentifier).filter { $0.hasPrefix("--user-data-dir") }
      return dailyChromeDataDir.map { dirs == ["--user-data-dir=\($0)"] } ?? dirs.isEmpty
    }
    .min(by: { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) })
}

/// Executable path of a process ("" when unreadable).
func pidPath(_ pid: pid_t) -> String {
  var buf = [CChar](repeating: 0, count: 4096)
  return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
}

/// argv of a process (KERN_PROCARGS2), [] when unreadable.
func processArgs(_ pid: pid_t) -> [String] {
  var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
  var size = 0
  guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
  var buf = [UInt8](repeating: 0, count: size)
  guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
  let argc = buf.withUnsafeBytes { Int($0.load(as: Int32.self)) }
  var i = 4
  while i < size && buf[i] != 0 { i += 1 }  // exec path
  while i < size && buf[i] == 0 { i += 1 }
  var out: [String] = []
  while out.count < argc && i < size {
    var j = i
    while j < size && buf[j] != 0 { j += 1 }
    out.append(String(decoding: buf[i..<j], as: UTF8.self))
    i = j + 1
  }
  return out
}

func watchChrome(dryRun: Bool, dump _: Bool) -> Never {
  dump = false  // the shared AX/OCR readers print window text, which holds the code; this mode never does
  log("chrome: watching \(dailyChromeBundle) for iCloud Passwords pairing\(dryRun ? " (dry run: never presses or types)" : "")")
  var chromePid: pid_t = 0
  var app = AXUIElementCreateApplication(0)
  var known = Set<pid_t>()
  var paired = Set<String>()  // profile labels seen paired since the extension last (re)connected
  var tries: [String: (n: Int, at: Date)] = [:]
  var typed: [pid_t: Int] = [:]  // helper -> times its current code window was typed
  var pending: String?  // profile whose popup asked for the code
  var lastNote = "", lastFront = ""
  var windowlessSince: Date?  // Chrome without the keep-profiles flag has had no window, with another app in front
  var lastRelaunch = Date.distantPast
  var chromeApp: NSRunningApplication?  // the watched Chrome, kept across passes in which LaunchServices misses it
  var freshLaunch = false  // the watched Chrome was first seen without the flag; try relaunchIfFresh while young
  func note(_ s: String) { if s != lastNote { log("chrome: \(s)"); lastNote = s } }

  /// Chrome is the active app. Two independent reads; their raw values are logged whenever they change.
  func frontmost() -> Bool {
    let axv = ax(app, "AXFrontmost") as? Bool
    let ws = NSWorkspace.shared.frontmostApplication?.processIdentifier == chromePid
    let raw = "AXFrontmost=\(axv.map(String.init) ?? "nil") NSWorkspace.front=\(ws)"
    if raw != lastFront { log("chrome: front signals \(raw)"); lastFront = raw }
    return axv == true || ws
  }
  func standardWindows() -> [(win: AXUIElement, label: String)] {
    ((ax(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).compactMap { w in
      guard axS(w, kAXSubroleAttribute) == "AXStandardWindow", let t = axS(w, kAXTitleAttribute) else { return nil }
      let l = chromeWindowLabel(t)
      return l.isEmpty ? nil : (w, l)
    }
  }
  /// Every browser window, profile label or not (a one-profile Chrome titles its windows without one).
  func standardWindowsAny() -> [AXUIElement] {
    ((ax(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).filter { axS($0, kAXSubroleAttribute) == "AXStandardWindow" }
  }
  func mainLabel() -> String? {
    guard let w = ax(app, kAXMainWindowAttribute), let t = axS(w as! AXUIElement, kAXTitleAttribute) else { return nil }
    let l = chromeWindowLabel(t)
    return l.isEmpty ? nil : l
  }
  func button(_ label: String) -> AXUIElement? {
    standardWindows().first(where: { $0.label == label }).flatMap { toolbarButton($0.win) }
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
  func closePopup(_ label: String) {
    if popupWindow(chromePid) != nil, let b = button(label) { AXUIElementPerformAction(b, kAXPressAction as CFString) }
  }

  /// Chrome is in front, Sammy idle, helper `h` shows its code window: make sure `label`'s popup is open and
  /// asking, then type the code. Returns true when paired.
  func typeCode(helper h: pid_t, label: String) -> Bool {
    let started = Date()
    if popupWindow(chromePid) == nil {  // Chrome closes the popup when it loses focus; reopening shows the PIN boxes
      guard let b = button(label) else { note("code window up; no iCloud Passwords button for '\(label)'"); return false }
      AXUIElementPerformAction(b, kAXPressAction as CFString)
      guard waitUntil(3, { popupWindow(chromePid) != nil }) else { note("code window up; popup for '\(label)' would not open"); return false }
      spin(0.6)
    }
    guard let pop = popupWindow(chromePid) else { return false }
    guard readPopup() == .asking else { note("code window up (helper \(h)); the open popup is not asking"); return false }
    guard let code = viaAX(h) ?? windowIDs(h).lazy.compactMap(viaOCR).first, code.count == 6 else {
      note("code window up (helper \(h)); no code readable by AX or OCR"); return false
    }
    typed[h, default: 0] += 1
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
      pending = nil
      log("chrome: paired profile '\(label)' with no human (\(ms) ms from typing start to paired)")
      if readPopup() == .paired { closePopup(label) }
    } else {
      log("chrome: typed the code for profile '\(label)' but it is still asking (\(ms) ms)")
    }
    return ok
  }

  /// Chrome lacks the keep-profiles flag: once it has had no window for 30 s with another app in front, quit it
  /// (like Cmd+Q: nothing is open) and start it again hidden with the flag. At most once per 10 min.
  func relaunchIfWindowless(_ chrome: NSRunningApplication) -> Bool {
    var v: CFTypeRef?
    let read = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v)
    let windowless = read == .success && ((v as? [AXUIElement]) ?? []).isEmpty
    let away = NSWorkspace.shared.frontmostApplication?.processIdentifier != chromePid
    guard windowless, away else { windowlessSince = nil; return false }
    let since = windowlessSince ?? Date()
    windowlessSince = since
    guard Date().timeIntervalSince(since) >= 30, Date().timeIntervalSince(lastRelaunch) > 600 else { return false }
    guard idleSeconds() >= 5 else { return false }  // the new window can take the front for a moment
    guard !downloadInProgress() else { note("Chrome has no window but a download is running; not relaunching it"); return false }
    windowlessSince = nil
    return relaunch(chrome, hidden: true, why: "has had no window for 30 s")
  }

  /// Chrome was just started without the flag (a Dock, Spotlight or link launch after a real quit): quit it and
  /// start it again with the flag at once, before Sammy works in it; its session restore brings the windows back.
  /// Only while it is under 15 s old and no key has been typed since it started; at most once per 10 min.
  func relaunchIfFresh(_ chrome: NSRunningApplication) -> Bool {
    guard let started = chrome.launchDate else { freshLaunch = false; note("Chrome has no launch date; the idle fallback will relaunch it"); return false }
    let age = Date().timeIntervalSince(started)
    guard age < 15 else {
      freshLaunch = false
      note("fresh-launch relaunch gave up: Chrome is \(Int(age)) s old, launch finished: \(chrome.isFinishedLaunching), standard windows: \(standardWindowsAny().count); the idle fallback will relaunch it")
      return false
    }
    guard Date().timeIntervalSince(lastRelaunch) > 600 else {
      freshLaunch = false; note("Chrome started without the flag within 10 min of the last relaunch; not relaunching again"); return false
    }
    guard !downloadInProgress() else { freshLaunch = false; note("Chrome started without the flag but a download is running; not relaunching it"); return false }
    guard CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) > age else {
      freshLaunch = false; note("Chrome started without the flag and Sammy is already typing; relaunching later once it has no window"); return false
    }
    // A quit sent mid-launch is dropped, and a link that started Chrome is in its first window only once that is up.
    guard chrome.isFinishedLaunching, !standardWindowsAny().isEmpty else {
      note("fresh Chrome (\(Int(age)) s old) not ready to relaunch: launch finished: \(chrome.isFinishedLaunching), standard windows: \(standardWindowsAny().count)"); return false
    }
    spin(0.5)
    freshLaunch = false
    return relaunch(chrome, hidden: false, why: "was just started (\(Int(age * 1000)) ms ago)")
  }

  /// Convergence: a flagless Chrome that no earlier route relaunched (Sammy never closed every window, or it was
  /// not ready when started) is quit and started again with the flag and --restore-last-session, hidden, once
  /// Chrome is not in front, Sammy has been idle 60 s, no download runs, and the last relaunch is 10 min old.
  func relaunchIfIdle(_ chrome: NSRunningApplication) -> Bool {
    guard idleSeconds() >= 60 else { return false }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier != chromePid, !frontmost() else { return false }
    guard Date().timeIntervalSince(lastRelaunch) > 600 else { note("Chrome lacks the flag; within 10 min of the last relaunch, not relaunching it yet"); return false }
    guard !downloadInProgress() else { note("Chrome lacks the flag but a download is running; not relaunching it"); return false }
    return relaunch(chrome, hidden: true, restore: true, why: "lacks the flag and Sammy has been idle \(Int(idleSeconds())) s with Chrome in the background")
  }

  /// Quit Chrome (like Cmd+Q) and start it again with its own switches plus the flag. hidden: keep the new
  /// window out of sight and the front with the app Sammy had; else it comes up like the launch it replaces.
  func relaunch(_ chrome: NSRunningApplication, hidden: Bool, restore: Bool = false, why: String) -> Bool {
    guard let url = chrome.bundleURL else { return false }
    lastRelaunch = Date()
    let old = chromePid
    let argv = processArgs(old)
    var args = relaunchArgs(argv)
    // What the windows show goes along as URLs (a link that started Chrome would be lost: its default start page is
    // a new tab), unless the profile restores its session itself. A new tab shows an empty address bar.
    let dataDir = argv.first(where: { $0.hasPrefix("--user-data-dir=") }).map { String($0.dropFirst("--user-data-dir=".count)) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome").path
    let urls = hidden || restore || restoresSession(userDataDir: dataDir) ? [] : standardWindowsAny().compactMap(addressBarText)
    args += urls
    if restore { args.append("--restore-last-session") }
    if dryRun { log("chrome: dry run: would relaunch Chrome (pid \(old)), which \(why), with --disable-features=\(keepProfilesFeature)"); return false }
    log("chrome: Chrome (pid \(old)) \(why) and lacks --disable-features=\(keepProfilesFeature); relaunching it with the flag so closing a window no longer drops the pairing")
    let wasFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == old
    let t0 = Date()
    chrome.terminate()
    guard waitUntil(30, { kill(old, 0) != 0 }) else { log("chrome: Chrome (pid \(old)) did not quit within 30 s; left running"); return true }
    let before = NSWorkspace.shared.frontmostApplication
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.arguments = args
    cfg.activates = !hidden && wasFront  // hides = true would make Chrome start as a hidden login item: no window, then it quits
    cfg.addsToRecentItems = false
    cfg.createsNewApplicationInstance = true  // else a tool's Chrome of the same bundle (own --user-data-dir) is reused
    var done = false, launched: NSRunningApplication?
    NSWorkspace.shared.openApplication(at: url, configuration: cfg) { a, err in
      if a == nil { log("chrome: relaunching Chrome failed: \(err?.localizedDescription ?? "?")") }
      launched = a
      done = true
    }
    _ = waitUntil(30) { done }
    guard let a = launched else { return true }
    let axa = AXUIElementCreateApplication(a.processIdentifier)
    let windowUp = waitUntil(20) { !((ax(axa, kAXWindowsAttribute) as? [AXUIElement]) ?? []).isEmpty }
    let gapMs = Int(Date().timeIntervalSince(t0) * 1000)
    guard hidden else {
      let n = (ax(axa, kAXWindowsAttribute) as? [AXUIElement])?.count ?? 0
      log("chrome: relaunched Chrome (pid \(a.processIdentifier)) with the flag and \(urls.count) page(s) it showed; \(windowUp ? "\(n) window(s) back" : "no window seen in 20 s") \(gapMs) ms after the quit")
      return true
    }
    // Chrome's new window takes the front despite activates = false (measured 2026-11-21): hide Chrome and give
    // the front back to the app Sammy had, so nothing new shows until he clicks Chrome.
    _ = waitUntil(10) { a.isFinishedLaunching }
    var hideTries = 0
    let hid = waitUntil(5) {  // hide() is refused until Chrome is done launching its window
      if !a.isHidden, hideTries < 25 { hideTries += 1; _ = a.hide() }
      return a.isHidden
    }
    if let b = before, b.processIdentifier != a.processIdentifier, !b.isTerminated { b.activate() }
    let front = NSWorkspace.shared.frontmostApplication
    log("chrome: relaunched Chrome (pid \(a.processIdentifier)) with the flag; window \(windowUp ? "up" : "not seen in 20 s"), hidden: \(hid) after \(hideTries) tries, front: \(front?.localizedName ?? "?") (pid \(front?.processIdentifier ?? 0))")
    return true
  }
  func pass() {
    guard let chrome = dailyChrome(current: chromePid, cached: chromeApp) else {
      if chromePid != 0 { log("chrome: Google Chrome quit (pid \(chromePid), kill(0) alive: \(kill(chromePid, 0) == 0))") }
      chromePid = 0; chromeApp = nil
      return
    }
    chromeApp = chrome
    if chrome.processIdentifier != chromePid {
      chromePid = chrome.processIdentifier
      app = AXUIElementCreateApplication(chromePid)
      known = []; paired = []; tries = [:]; typed = [:]; pending = nil; lastNote = ""; lastFront = ""
      windowlessSince = nil
      freshLaunch = !keepsProfiles(chromePid)
      log("chrome: Google Chrome running (pid \(chromePid))\(freshLaunch ? " without --disable-features=\(keepProfilesFeature)" : "")")
    }
    if !keepsProfiles(chromePid) {
      if freshLaunch, relaunchIfFresh(chrome) { return }
      if freshLaunch { return }  // still launching: no presses into a Chrome about to be relaunched
      if relaunchIfWindowless(chrome) { return }
      if relaunchIfIdle(chrome) { return }
    }
    let helpers = Set(helperPids(parents: [chromePid]))
    if !helpers.subtracting(known).isEmpty {
      log("chrome: extension connected to Apple's helper (pids \(helpers.sorted())); checking each profile")
      paired = []; tries = [:]
    }
    known = helpers
    let showing = codeWindowHelpers()
    typed = typed.filter { showing.contains($0.key) }

    // A code window for this Chrome (ours or one Sammy summoned): typing is the one step that needs Chrome in front.
    if let h = showing.first(where: { (typed[$0] ?? 0) < 2 }) {
      let label = pending ?? mainLabel() ?? "?"
      guard frontmost(), idleSeconds() >= 1 else {
        note("code ready for '\(label)': Chrome needs you in front, hands off, for 3 s"); return
      }
      _ = typeCode(helper: h, label: label)
      return
    }
    guard showing.isEmpty else { note("code window still up after two tries; leaving it to Sammy"); return }

    // No code window: check each profile not known paired, one press at a time. Measured 2026-11-21: a press while
    // another app is in front brings Chrome to the front, so presses wait until Sammy has Chrome in front himself.
    // No helper yet (a fresh Chrome: the extension starts Apple's helper only when its popup opens): the same
    // press below wakes it, and the next passes pair as usual.
    let todo = standardWindows().filter { !paired.contains($0.label) }
    if helpers.isEmpty && todo.isEmpty { note("waiting: extension not connected to Apple's helper and no profile window to wake it in"); return }
    var seen = Set<String>()
    guard let next = todo.first(where: { seen.insert($0.label).inserted && (tries[$0.label]?.n ?? 0) < 4
      && Date().timeIntervalSince(tries[$0.label]?.at ?? .distantPast) > 20 })
    else {
      if todo.isEmpty { note("all open profiles paired") }
      else if todo.allSatisfy({ (tries[$0.label]?.n ?? 0) >= 4 }) {
        note("gave up on \(Set(todo.map(\.label)).sorted()) after 4 tries each; click iCloud Passwords once there")
      }
      return
    }
    let unchecked = Set(todo.map(\.label)).sorted()
    let what = helpers.isEmpty ? "wake the extension (not connected to Apple's helper) in" : "check"
    guard frontmost() else { note("waiting: Chrome in front, hands off for 2 s, to \(what) \(unchecked)"); return }
    guard idleSeconds() >= 2 else { note("waiting: Sammy active in Chrome (unchecked: \(unchecked))"); return }
    guard popupWindow(chromePid) == nil else { note("waiting: a popup is already open"); return }
    let label = next.label
    tries[label] = ((tries[label]?.n ?? 0) + 1, Date())
    guard let b = toolbarButton(next.win) else {
      // A just-started Chrome draws its extension buttons after the window (seen 2026-11-21): an ordinary try.
      note("no pinned iCloud Passwords button in profile '\(label)' yet (try \(tries[label]!.n)); pin it once if this stays"); return
    }
    if dryRun { note("dry run: would press iCloud Passwords in profile '\(label)'"); return }
    let wasFront = frontmost()
    if helpers.isEmpty { log("chrome: extension not connected to Apple's helper; pressing iCloud Passwords in '\(label)' to wake it") }
    let err = AXUIElementPerformAction(b, kAXPressAction as CFString)
    guard err == .success else { log("chrome: pressing iCloud Passwords in '\(label)' failed (AXError \(err.rawValue))"); return }
    guard waitUntil(3, { popupWindow(chromePid) != nil }) else {
      log("chrome: pressed iCloud Passwords in '\(label)' (try \(tries[label]!.n), Chrome front before: \(wasFront)); no popup window appeared"); return
    }
    spin(0.6)  // let the popup render before reading it
    var state = readPopup()
    if state != .asking && state != .paired { spin(1.5); state = readPopup() }
    let ctx = "Chrome front before: \(wasFront), after: \(frontmost())"
    switch state {
    case .paired?:
      paired.insert(label)
      closePopup(label)
      log("chrome: profile '\(label)' is paired (\(ctx))")
    case .asking?:
      pending = label
      log("chrome: profile '\(label)' asks for the code (try \(tries[label]!.n), \(ctx)); waiting for Apple's code window")
      if !waitUntil(6, { !codeWindowHelpers().isEmpty }) { log("chrome: no code window appeared for '\(label)'") }
    case .other(let t)?:
      log("chrome: popup in '\(label)' shows neither state (\(ctx)): \(t)")
      closePopup(label)
    case nil:
      log("chrome: popup in '\(label)' closed before it could be read (\(ctx))")
    }
  }

  // Each pass runs in its own autoreleasepool: AX, CGWindowList, NSRunningApplication and OCR objects are
  // autoreleased and this loop never returns to a pool-draining caller (measured 2026-11-21: ~135 MB/15 min
  // phys_footprint growth, 8.6 GB after a day, without it).
  while true {
    spin(0.5)
    autoreleasepool { pass() }
  }
}
