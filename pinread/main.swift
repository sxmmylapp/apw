// apw-pinread: pair apw with no human. Reads the 6-digit code that Apple's PasswordManagerBrowserExtensionHelper
// shows in its "Enable Password AutoFill for <browser>" window, and sends it to the apw daemon.
// Read-only on the desktop: it never clicks or types. Only the helper whose parent is apw's own browser
// (~/.apw/browser.pid) counts, so a pairing window for Sammy's everyday Chrome is never read.
// Route 1: Accessibility text of that window. Route 2: screencapture of that one window + Vision OCR.
// Runs as launchd job com.lod.apw-pinread (started by the daemon) so macOS checks THIS binary's grant.
//   apw-pinread [--dump] [--no-send] [--timeout <s>]   exit 0 sent (or printed with --no-send); 1 no code; 2 send failed
//   apw-pinread --parse <text>                         print the code found in <text> (tests)
//   apw-pinread --window-label <title>                 print the Chrome profile label of a window title (tests)
//   apw-pinread --popup-state <ocr text>               asking | paired | other for the extension popup (tests)
//   apw-pinread --watch-chrome [--dry-run] [--dump]    keep the everyday Google Chrome paired (chrome.swift);
//                                                      runs as launchd job com.lod.apw-chromepair
//   apw-pinread --save-click                           press Apple's save alert for one `apw pw save` (saveclick.swift);
//                                                      runs as launchd job com.lod.apw-saveclick
import AppKit
import ApplicationServices
import Foundation
import Vision

let helperName = "PasswordManagerBrowserExtensionHelper"
let home = FileManager.default.homeDirectoryForCurrentUser.path
var dump = false, send = true, timeout = 30.0
var parseText: String?, labelText: String?, popupText: String?, relaunchArgv: [String]?
var watch = false, dryRun = false, saveClick = false
var classifyArgs: [String]?
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
  switch a {
  case "--dump": dump = true
  case "--no-send": send = false
  case "--timeout": if let v = args.next(), let t = Double(v) { timeout = t }
  case "--parse": parseText = args.next() ?? ""
  case "--window-label": labelText = args.next() ?? ""
  case "--popup-state": popupText = args.next() ?? ""
  case "--watch-chrome": watch = true
  case "--dry-run": dryRun = true
  case "--save-click": saveClick = true
  case "--relaunch-args": relaunchArgv = Array(CommandLine.arguments.drop { $0 != "--relaunch-args" }.dropFirst())
  case "--classify-alert": classifyArgs = Array(CommandLine.arguments.drop { $0 != "--classify-alert" }.dropFirst())
  default: break
  }
}
func log(_ s: String) {
  let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
  FileHandle.standardError.write("[\(f.string(from: Date()))] apw-pinread: \(s)\n".data(using: .utf8)!)
}

/// "227 621", "227621" or six one-digit cells. Never a longer digit run.
func code(in text: String) -> String? {
  if let r = text.range(of: #"(?<![\d])\d{3}[  ]?\d{3}(?![\d])"#, options: .regularExpression) {
    return text[r].filter { $0.isNumber }
  }
  return nil
}
if let t = parseText { if let c = code(in: t) { print(c); exit(0) }; exit(1) }
if let t = labelText { print(chromeWindowLabel(t)); exit(0) }
if let t = popupText {
  switch popupState(t) { case .asking: print("asking"); case .paired: print("paired"); case .other: print("other") }
  exit(0)
}
if let a = relaunchArgv { print(relaunchArgs(["chrome"] + a).joined(separator: "\n")); exit(0) }
if let a = classifyArgs { classifyAlertCLI(a) }

func parentPid(_ pid: pid_t) -> pid_t? {
  var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
  guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
  return info.kp_eproc.e_ppid
}

func apwBrowserPid() -> pid_t? {
  guard let s = try? String(contentsOfFile: "\(home)/.apw/browser.pid", encoding: .utf8) else { return nil }
  return pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Apple's helpers whose parent process is one of `parents` (a helper is spawned by the browser it serves).
func helperPids(parents: Set<pid_t>) -> [pid_t] {
  NSWorkspace.shared.runningApplications.filter { $0.executableURL?.lastPathComponent == helperName }
    .map { $0.processIdentifier }
    .filter { parentPid($0).map(parents.contains) ?? false }
}

func helperPids() -> [pid_t] { apwBrowserPid().map { helperPids(parents: [$0]) } ?? [] }

func axStrings(_ el: AXUIElement, _ depth: Int, _ out: inout [String]) {
  if depth > 25 { return }
  for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
    var v: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let s = v as? String, !s.isEmpty { out.append(s) }
  }
  var kids: CFTypeRef?
  if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success, let arr = kids as? [AXUIElement] {
    for k in arr { axStrings(k, depth + 1, &out) }
  }
}

func viaAX(_ pid: pid_t) -> String? {
  var wins: CFTypeRef?
  guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &wins) == .success,
    let list = wins as? [AXUIElement] else { if dump { log("ax[\(pid)]: no windows readable") }; return nil }
  for w in list {
    var out: [String] = []
    axStrings(w, 0, &out)
    if dump { log("ax[\(pid)] window strings=\(out)") }
    guard out.contains(where: { $0.contains("Password AutoFill") || $0.contains("Verification Code") }) else { continue }
    let cells = out.filter { $0.count == 1 && $0.first!.isNumber }.joined()
    if cells.count == 6 { return cells }
    for s in out { if let c = code(in: s) { return c } }
  }
  return nil
}

func windowIDs(_ pid: pid_t) -> [CGWindowID] {
  let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
  return info.compactMap { w in
    (w[kCGWindowOwnerPID as String] as? pid_t) == pid ? w[kCGWindowNumber as String] as? CGWindowID : nil
  }
}

/// All text Vision reads in one on-screen window (screencapture of that window only).
func windowText(_ wid: CGWindowID) -> String? {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("apw-pin-\(getpid())-\(wid).png")
  defer { try? FileManager.default.removeItem(at: url) }
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  p.arguments = ["-x", "-o", "-l", String(wid), url.path]
  guard (try? p.run()) != nil else { return nil }
  p.waitUntilExit()
  guard let img = NSImage(contentsOf: url), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
  let req = VNRecognizeTextRequest()
  req.recognitionLevel = .accurate
  req.usesLanguageCorrection = false
  try? VNImageRequestHandler(cgImage: cg).perform([req])
  return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

func viaOCR(_ wid: CGWindowID) -> String? {
  guard let text = windowText(wid) else { return nil }
  if dump { log("ocr[window \(wid)] text=\(text.debugDescription)") }
  return text.contains("AutoFill") || text.contains("Verification") ? code(in: text) : nil
}

/// One JSON line to the daemon's socket, like `apw auth response --pin`.
func sendPin(_ pin: String) -> String? {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { return nil }
  defer { close(fd) }
  var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
  let path = "\(home)/.apw/apw.sock"
  _ = withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) } }
  let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
  guard ok == 0 else { return nil }
  let msg = "{\"cmd\":2,\"pin\":\"\(pin)\"}\n"
  _ = msg.withCString { write(fd, $0, strlen($0)) }
  var buf = [UInt8](repeating: 0, count: 4096); var reply = ""
  while !reply.contains("\n") { let n = read(fd, &buf, buf.count); if n <= 0 { break }; reply += String(decoding: buf[0..<n], as: UTF8.self) }
  return reply.trimmingCharacters(in: .whitespacesAndNewlines)
}

let trusted = AXIsProcessTrusted()
if !trusted {
  // One-time: macOS shows its own "apw-pinread would like to control this computer using accessibility" prompt.
  _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
  log("no Accessibility grant for \(CommandLine.arguments[0]); trying screen OCR (System Settings > Privacy & Security > Accessibility: turn on apw-pinread)")
}
if watch { watchChrome(dryRun: dryRun, dump: dump) }
if saveClick { runSaveClick() }
let deadline = Date().addingTimeInterval(timeout)
var found: String?
repeat {
  let pids = helperPids()
  if dump { log("apw browser pid=\(apwBrowserPid().map(String.init) ?? "none") helper pids=\(pids) trusted=\(trusted)") }
  for pid in pids where found == nil {
    found = viaAX(pid) ?? windowIDs(pid).lazy.compactMap(viaOCR).first
  }
  if found == nil { Thread.sleep(forTimeInterval: 1) }
} while found == nil && Date() < deadline
guard let pin = found else { log("no pairing code on screen within \(Int(timeout))s"); exit(1) }
if !send { print(pin); exit(0) }
guard let reply = sendPin(pin) else { log("read a code but could not reach the apw daemon socket"); exit(2) }
log("sent the pairing code to apw: \(reply)")
exit(reply.contains("\"status\":0") ? 0 : 2)
