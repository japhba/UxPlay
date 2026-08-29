// UxPlayMenuBar.swift -- the CFBundleExecutable of UxPlay.app.
//
// A LSUIElement (menu-bar / "accessory") AppKit app that runs the bundled
// uxplay-bin helper as a child process, surfaces its state (idle / waiting /
// pairing PIN / streaming) in an NSStatusItem menu, and can update itself
// from GitHub Releases.  It replaces the old Terminal-window launcher; the
// environment it hands the child is exactly what Resources/run-uxplay.sh set.
//
// Build:  xcrun swiftc -O -o UxPlay UxPlayMenuBar.swift   (links AppKit +
// Foundation automatically; no extra frameworks -- notifications use the
// deprecated-but-dependency-free NSUserNotification).
//
// Single file on purpose: it is compiled straight into the bundle by
// packaging/macos/build-app.sh.

import AppKit
import Foundation
import Darwin       // openpty(), winsize, read(), close()

// ===========================================================================
// MARK: - Bundle layout
// ===========================================================================

/// Absolute paths to the pieces of the bundle the app needs at runtime, all
/// resolved from Bundle.main so the app is relocatable.
enum BundleLayout {
    static let contents = Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true)
    static let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
    static let plugins = contents.appendingPathComponent("PlugIns", isDirectory: true)
    static let resources = contents.appendingPathComponent("Resources", isDirectory: true)

    static let uxplayBin = macOS.appendingPathComponent("uxplay-bin")
    static let scanner = macOS.appendingPathComponent("gst-plugin-scanner")
    static let fonts = resources.appendingPathComponent("fonts", isDirectory: true)

    static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
    static var bundleVersion: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? shortVersion
    }
}

// ===========================================================================
// MARK: - Small utilities
// ===========================================================================

/// Split a string into arguments the way a shell would for simple cases:
/// whitespace separates, and single/double quotes group.  Used for the
/// optional UXPLAY_ARGS environment variable so e.g.
/// `-vs "osxvideosink foo=bar"` stays one argument.
func shellSplit(_ s: String) -> [String] {
    var args: [String] = []
    var cur = ""
    var inSingle = false, inDouble = false, has = false
    var it = s.makeIterator()
    while let c = it.next() {
        if inSingle {
            if c == "'" { inSingle = false } else { cur.append(c) }
        } else if inDouble {
            if c == "\"" { inDouble = false }
            else if c == "\\" { if let n = it.next() { cur.append(n) } }
            else { cur.append(c) }
        } else if c == "'" { inSingle = true; has = true }
        else if c == "\"" { inDouble = true; has = true }
        else if c == "\\" { if let n = it.next() { cur.append(n); has = true } }
        else if c == " " || c == "\t" || c == "\n" {
            if has { args.append(cur); cur = ""; has = false }
        } else { cur.append(c); has = true }
    }
    if has { args.append(cur) }
    return args
}

/// Post a Notification Center banner.  NSUserNotification is deprecated but
/// needs no extra framework or authorization prompt, which is why it is used.
func notify(title: String, body: String) {
    let n = NSUserNotification()
    n.title = title
    n.informativeText = body
    n.soundName = nil
    NSUserNotificationCenter.default.deliver(n)
}

// ===========================================================================
// MARK: - Server state
// ===========================================================================

enum ServerState: Equatable {
    case starting
    case waiting                  // server up, no client yet
    case pairing(pin: String)     // client is pairing; PIN must be entered
    case streaming(device: String)
    case stopped                  // exited unexpectedly
    case receiverDisabled         // AirPlay Receiver is off in System Settings

    var menuText: String {
        switch self {
        case .starting: return "Starting server…"
        case .waiting: return "Waiting for a client"
        case .pairing: return "Waiting for a client"
        case .streaming(let d): return "Streaming from \(d)"
        case .stopped: return "Server stopped"
        case .receiverDisabled: return "Enable AirPlay Receiver in System Settings"
        }
    }
}

// ===========================================================================
// MARK: - Server controller
// ===========================================================================

/// Owns the uxplay-bin child process: launches it with the bundled GStreamer
/// environment, tees its combined stdout/stderr to ~/Library/Logs/UxPlay,
/// parses PIN / connection lines out of the stream, and cleans the child up.
final class ServerController {
    private(set) var state: ServerState = .starting
    private(set) var currentPIN: String?

    /// Called on the main thread whenever `state` or `currentPIN` changes.
    var onChange: (() -> Void)?

    private var process: Process?
    private var lineBuffer = Data()
    private var logHandle: FileHandle?
    private var sawReceiverDisabled = false
    private var userStopped = false
    // Termination is finalized only once the child has exited AND its output
    // has been fully drained, so late lines (e.g. the receiver-disabled error)
    // are parsed before we decide the resulting state.
    private var procTerminated = false
    private var readerDone = false
    private var finalized = false
    private var lastExitStatus: Int32 = 0
    private var fallbackPipe: Pipe?

    let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/UxPlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("uxplay.log")
    }()

    var isRunning: Bool { process?.isRunning ?? false }

    // -- lifecycle ---------------------------------------------------------

    func start() {
        guard !isRunning else { return }
        userStopped = false
        sawReceiverDisabled = false
        procTerminated = false
        readerDone = false
        finalized = false
        lineBuffer.removeAll(keepingCapacity: true)
        setState(.starting, pin: nil)
        openLog()

        // Environment: exactly what run-uxplay.sh exports.
        var env = ProcessInfo.processInfo.environment
        env["GST_PLUGIN_SYSTEM_PATH_1_0"] = BundleLayout.plugins.path
        env["GST_PLUGIN_PATH_1_0"] = BundleLayout.plugins.path
        env["GST_PLUGIN_SCANNER_1_0"] = BundleLayout.scanner.path
        env["GST_PLUGIN_SCANNER"] = BundleLayout.scanner.path
        let registry = env["UXPLAY_GST_REGISTRY"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/com.japhba.uxplay/registry.bin").path
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: registry).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        env["GST_REGISTRY_1_0"] = registry
        if FileManager.default.fileExists(atPath: BundleLayout.fonts.path) {
            env["FONTCONFIG_PATH"] = BundleLayout.fonts.path
        }

        // Base arguments (identical to run-uxplay.sh) plus optional UXPLAY_ARGS.
        var args = ["-p2p", "-h265", "-vsync", "no",
                    "-vs", "osxvideosink force-aspect-ratio=true"]
        if let extra = env["UXPLAY_ARGS"], !extra.isEmpty { args += shellSplit(extra) }

        let proc = Process()
        proc.executableURL = BundleLayout.uxplayBin
        proc.arguments = args
        proc.environment = env
        // Relative output files (e.g. -mp4) should land in $HOME, as the
        // shell runner arranged with `cd "$HOME"`.
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        // uxplay-bin block-buffers stdout unless it is writing to a terminal,
        // so give it a pseudo-terminal: then it line-buffers and the PIN and
        // status lines reach us promptly.  stdout+stderr are merged onto the
        // single pty; a plain pipe is the fallback if openpty fails.
        var master: Int32 = -1, slave: Int32 = -1
        var ws = winsize(ws_row: 50, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
        var slaveToClose: Int32 = -1
        let readFD: Int32
        if openpty(&master, &slave, nil, nil, &ws) == 0 {
            let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
            proc.standardInput = slaveHandle
            proc.standardOutput = slaveHandle
            proc.standardError = slaveHandle
            readFD = master
            slaveToClose = slave       // parent closes its copy after launch
        } else {
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            fallbackPipe = pipe
            readFD = pipe.fileHandleForReading.fileDescriptor
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.procTerminated = true
                self?.lastExitStatus = p.terminationStatus
                self?.finalizeIfDone()
            }
        }

        do {
            try proc.run()
            process = proc
            if slaveToClose >= 0 { close(slaveToClose) }   // so master sees EOF on exit
            startReader(fd: readFD)
        } catch {
            appendLog("failed to launch uxplay-bin: \(error)\n")
            if slaveToClose >= 0 { close(slaveToClose) }
            close(master >= 0 ? master : -1)
            setState(.stopped, pin: nil)
        }
    }

    /// Drain the child's output on a background queue until EOF.
    private func startReader(fd: Int32) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buf, buf.count)
                if n > 0 { self?.ingest(Data(bytes: buf, count: n)) }
                else { break }                     // EOF or error: child is gone
            }
            close(fd)
            DispatchQueue.main.async {
                self?.readerDone = true
                self?.finalizeIfDone()
            }
        }
    }

    /// Stop the child: SIGTERM, then SIGKILL if it has not exited in time.
    func stop(userInitiated: Bool = true) {
        if userInitiated { userStopped = true }
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()                                     // SIGTERM
        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if proc.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Synchronous best-effort teardown for app termination.
    func terminateForQuit() {
        userStopped = true
        guard let proc = process, proc.isRunning else { return }
        let pid = proc.processIdentifier
        proc.terminate()
        for _ in 0..<20 { if !proc.isRunning { break }; usleep(100_000) }
        if proc.isRunning { kill(pid, SIGKILL) }
    }

    func restart() {
        stop(userInitiated: true)
        // give the OS a moment to release the sockets before relaunching
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.start() }
    }

    // -- output handling ---------------------------------------------------

    private func openLog() {
        let fm = FileManager.default
        // Rotate once the log passes ~1 MB so it cannot grow without bound.
        if let size = (try? fm.attributesOfItem(atPath: logURL.path)[.size]) as? Int, size > 1_000_000 {
            let rotated = logURL.deletingLastPathComponent().appendingPathComponent("uxplay.log.1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: logURL, to: rotated)
        }
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        logHandle = try? FileHandle(forWritingTo: logURL)
        _ = try? logHandle?.seekToEnd()
        let stamp = ISO8601DateFormatter().string(from: Date())
        appendLog("\n=== UxPlay.app \(BundleLayout.bundleVersion) started \(stamp) ===\n")
    }

    private func appendLog(_ s: String) { logHandle?.write(Data(s.utf8)) }

    /// Tee raw bytes to the log and split into lines for parsing.
    private func ingest(_ data: Data) {
        logHandle?.write(data)
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8) {
                DispatchQueue.main.async { [weak self] in self?.parse(line) }
            }
        }
    }

    /// A meaningful event recognised in one line of uxplay output.
    enum LogEvent: Equatable {
        case pin(String)          // client is pairing; this is the PIN to enter
        case streaming(String)    // a client connected (device name)
        case accepted             // a client socket was accepted (pairing done)
        case serverReady          // "Initialized server socket(s)"
        case receiverDisabled     // AirPlay Receiver is off (uxplay error + exit)
        case none
    }

    private static let pinRegex = try! NSRegularExpression(pattern: #"PIN = "([0-9]{3,6})""#)

    /// Pure classification of one output line -- no side effects, so it can be
    /// unit-tested (see runSelfTest()).
    static func classify(_ raw: String) -> LogEvent {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // The AirplayReceiverEnabled *error* lines (LOGE, "*** ERROR:") mean the
        // receiver is off.  The success line ("... is true", LOGI) must NOT be
        // treated as disabled, so require the ERROR marker.
        if line.contains("AirplayReceiverEnabled") && line.contains("ERROR") {
            return .receiverDisabled
        }

        // PIN, e.g.:  *** CLIENT MUST NOW ENTER PIN = "3939" AS AIRPLAY PASSWORD
        if let m = pinRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let r = Range(m.range(at: 1), in: line) {
            return .pin(String(line[r]))
        }

        // Client connected:  connection request from <name> (<model>) with ...
        if let range = line.range(of: "connection request from ") {
            var name = String(line[range.upperBound...])
            if let paren = name.range(of: " (") { name = String(name[..<paren.lowerBound]) }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return .streaming(name.isEmpty ? "client" : name)
        }
        if line.contains("Accepted") && line.contains("client") { return .accepted }
        if line.contains("Initialized server socket(s)") { return .serverReady }
        return .none
    }

    /// Apply a classified line to the live state (main thread).
    private func parse(_ line: String) {
        switch ServerController.classify(line) {
        case .receiverDisabled:
            sawReceiverDisabled = true
        case .pin(let pin):
            setState(.pairing(pin: pin), pin: pin)
            notify(title: "UxPlay pairing — enter PIN \(pin)",
                   body: "Type \(pin) as the AirPlay password on your device.")
        case .streaming(let device):
            setState(.streaming(device: device), pin: nil)
        case .accepted:
            if currentPIN != nil, case .pairing = state { setState(.waiting, pin: nil) }
        case .serverReady:
            if case .starting = state { setState(.waiting, pin: nil) }
        case .none:
            break
        }
    }

    /// Decide the resulting state once the child has exited and all of its
    /// output has been read (both flags set).
    private func finalizeIfDone() {
        guard procTerminated, readerDone, !finalized else { return }
        finalized = true
        fallbackPipe = nil
        process = nil
        logHandle?.write(Data("=== uxplay-bin exited (status \(lastExitStatus)) ===\n".utf8))
        try? logHandle?.close()
        logHandle = nil
        if userStopped { return }                       // expected: menu shows "Start Server"
        if sawReceiverDisabled {
            setState(.receiverDisabled, pin: nil)
            notify(title: "UxPlay: AirPlay Receiver is off",
                   body: "Enable AirPlay Receiver in System Settings, then start the server.")
        } else {
            // Do NOT auto-restart: a failing binary would crash-loop.  The
            // user restarts from the menu ("Restart Server").
            setState(.stopped, pin: nil)
            notify(title: "UxPlay server stopped",
                   body: "The receiver stopped unexpectedly. Use the menu to restart it.")
        }
    }

    private func setState(_ s: ServerState, pin: String?) {
        state = s
        currentPIN = pin
        onChange?()
    }
}

// ===========================================================================
// MARK: - Updater  (GitHub Releases)
// ===========================================================================
//
// Security note: the app is ad-hoc signed (no Developer ID), so there is no
// code-signing / notarization check available on the downloaded build.  The
// updater relies solely on HTTPS to api.github.com / the GitHub release CDN
// for authenticity, and refuses to update a translocated or read-only copy
// (which would silently fail anyway).  This is documented in the README.

struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
    let assets: [Asset]
    struct Asset: Decodable { let name: String; let browser_download_url: String }
}

final class Updater {
    static let repo = "japhba/UxPlay"
    static let assetPattern = try! NSRegularExpression(pattern: #"^UxPlay-.*-macos-arm64\.zip$"#)
    private static let lastCheckKey = "lastUpdateCheck"

    private let session = URLSession(configuration: .ephemeral)
    private var busy = false

    // -- version comparison ------------------------------------------------

    /// Dotted-integer components of a version/tag, ignoring a leading "v" and
    /// any non-numeric suffix (so "v1.75.0-p2p" -> [1,75,0]).
    static func versionComponents(_ raw: String) -> [Int] {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        var numeric = ""
        for ch in s { if ch.isNumber || ch == "." { numeric.append(ch) } else { break } }
        return numeric.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// True iff `latest` is strictly newer than `current`.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = versionComponents(latest), b = versionComponents(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // -- entry points ------------------------------------------------------

    /// Automatic check: at most once per 24h, silent unless a newer build
    /// exists.  Manual check: bypasses the throttle and always reports back.
    func check(manual: Bool) {
        if busy { return }
        if !manual {
            let last = UserDefaults.standard.double(forKey: Updater.lastCheckKey)
            if last > 0, Date().timeIntervalSince1970 - last < 24 * 3600 { return }
        }
        busy = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Updater.lastCheckKey)

        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!)
        req.setValue("UxPlay/\(BundleLayout.shortVersion) (macOS updater)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        session.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.busy = false
                self?.handleReleaseResponse(data: data, response: response, error: error, manual: manual)
            }
        }.resume()
    }

    private func handleReleaseResponse(data: Data?, response: URLResponse?, error: Error?, manual: Bool) {
        if let error = error {
            if manual { alert("Could not check for updates",
                              "\(error.localizedDescription)\n\nPlease check your network connection.") }
            return
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data = data, let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            if manual { alert("Could not check for updates",
                              "GitHub did not return a valid release. Please try again later.") }
            return
        }

        let current = BundleLayout.shortVersion
        guard Updater.isNewer(release.tag_name, than: current) else {
            if manual { alert("You’re up to date",
                              "UxPlay \(current) is the latest version.") }
            return
        }
        guard let asset = release.assets.first(where: { a in
            let r = NSRange(a.name.startIndex..., in: a.name)
            return Updater.assetPattern.firstMatch(in: a.name, range: r) != nil
        }), let url = URL(string: asset.browser_download_url) else {
            // Newer version exists but no matching arm64 zip: send them to the page.
            offerManualDownload(version: release.tag_name, page: release.html_url)
            return
        }
        promptAndInstall(version: release.tag_name, current: current, asset: url, page: release.html_url)
    }

    // -- install flow ------------------------------------------------------

    private func promptAndInstall(version: String, current: String, asset: URL, page: String) {
        let a = NSAlert()
        a.messageText = "UxPlay \(version) is available"
        a.informativeText = "You have \(current). Update now?"
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        // Refuse to self-replace a translocated or non-writable copy.
        if let reason = Updater.selfReplaceBlockedReason() {
            let b = NSAlert()
            b.messageText = "Can’t update this copy of UxPlay"
            b.informativeText = "\(reason)\n\nMove UxPlay.app to /Applications and open it from there, then try again. The download page will now open."
            b.runModal()
            if let u = URL(string: page) { NSWorkspace.shared.open(u) }
            return
        }
        download(asset: asset, version: version, page: page)
    }

    private func offerManualDownload(version: String, page: String) {
        let a = NSAlert()
        a.messageText = "UxPlay \(version) is available"
        a.informativeText = "An automatic download for this Mac isn’t attached to the release. Open the download page?"
        a.addButton(withTitle: "Open Page")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn, let u = URL(string: page) { NSWorkspace.shared.open(u) }
    }

    private func download(asset: URL, version: String, page: String) {
        var req = URLRequest(url: asset)
        req.setValue("UxPlay/\(BundleLayout.shortVersion) (macOS updater)", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: req) { [weak self] tmp, response, error in
            // URLSession deletes `tmp` the moment this handler returns, so move
            // it to a stable path *synchronously* before hopping to the main
            // thread for the install.
            var staged: URL?
            if let tmp = tmp {
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("UxPlayDownload-\(UUID().uuidString).zip")
                if (try? FileManager.default.moveItem(at: tmp, to: dst)) != nil { staged = dst }
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                guard let self = self else { if let s = staged { try? FileManager.default.removeItem(at: s) }; return }
                guard error == nil, let staged = staged, statusCode == 200 else {
                    if let s = staged { try? FileManager.default.removeItem(at: s) }
                    self.alert("Download failed",
                               "Could not download UxPlay \(version).\n\(error?.localizedDescription ?? "")")
                    return
                }
                self.installDownloadedZip(at: staged, version: version, page: page)
            }
        }
        task.resume()
    }

    // -- the atomic self-replace (reviewed carefully) ----------------------

    /// Returns a human-readable reason the running bundle cannot replace
    /// itself in place, or nil if a self-replace should be safe to attempt.
    static func selfReplaceBlockedReason() -> String? {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") {
            return "UxPlay is running from a temporary, read-only location (App Translocation)."
        }
        // The parent directory must be writable to swap the bundle out.
        let parent = (path as NSString).deletingLastPathComponent
        if !FileManager.default.isWritableFile(atPath: parent) {
            return "The folder containing UxPlay (\(parent)) is not writable."
        }
        return nil
    }

    /// Unzip the downloaded build, validate it, and hand off to a detached
    /// helper script that waits for this process to quit, swaps the bundle in
    /// place, and relaunches it.
    private func installDownloadedZip(at zipTmp: URL, version: String, page: String) {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("UxPlayUpdate-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            // Give the download a .zip name ditto is happy with.
            let zip = work.appendingPathComponent("UxPlay.zip")
            try fm.moveItem(at: zipTmp, to: zip)

            // Unpack with ditto (handles the ditto-created zip cleanly).
            let unpack = work.appendingPathComponent("unpacked", isDirectory: true)
            try fm.createDirectory(at: unpack, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpack.path])

            // Locate UxPlay.app in the unpacked tree.
            guard let newApp = Updater.findApp(in: unpack, fm: fm) else {
                cleanup(work); alert("Update failed", "The downloaded archive did not contain UxPlay.app."); return
            }

            // Validate the payload before we destroy the running copy.
            let newBin = newApp.appendingPathComponent("Contents/MacOS/uxplay-bin")
            let newExec = newApp.appendingPathComponent("Contents/MacOS/UxPlay")
            guard fm.isExecutableFile(atPath: newBin.path),
                  fm.isExecutableFile(atPath: newExec.path) else {
                cleanup(work)
                alert("Update failed", "The downloaded UxPlay.app looks incomplete (its helper binary is missing).")
                return
            }

            // Strip quarantine so the replacement launches without a prompt.
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

            try launchSelfReplace(newApp: newApp, work: work)
        } catch {
            cleanup(work)
            alert("Update failed", "\(error.localizedDescription)\n\nYou can download the update manually.")
            if let u = URL(string: page) { NSWorkspace.shared.open(u) }
        }
    }

    /// Write and launch the detached shell script that performs the swap,
    /// then quit this app so the script can proceed.
    private func launchSelfReplace(newApp: URL, work: URL) throws {
        let oldApp = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let logPath = work.appendingPathComponent("update.log").path
        let scriptURL = work.appendingPathComponent("self-replace.sh")

        // The helper: wait for us to exit, back up + swap the bundle, relaunch,
        // then clean up.  If the swap fails, it restores the backup so the user
        // is never left without an app.
        let script = """
        #!/bin/bash
        set -u
        OLD=\(shArg(oldApp))
        NEW=\(shArg(newApp.path))
        WORK=\(shArg(work.path))
        PID=\(pid)
        LOG=\(shArg(logPath))
        exec >>"$LOG" 2>&1
        echo "self-replace: waiting for pid $PID to exit"
        for _ in $(seq 1 200); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$PID" 2>/dev/null; then
            echo "self-replace: old app still running, aborting"
            exit 1
        fi
        BACKUP="$WORK/backup.app"
        echo "self-replace: swapping $OLD"
        if ! /bin/mv "$OLD" "$BACKUP"; then
            echo "self-replace: could not move old app aside"; exit 1
        fi
        if /usr/bin/ditto "$NEW" "$OLD"; then
            /usr/bin/xattr -dr com.apple.quarantine "$OLD" 2>/dev/null || true
            echo "self-replace: installed new app, relaunching"
            /usr/bin/open "$OLD"
            /bin/rm -rf "$WORK"
        else
            echo "self-replace: install failed, restoring backup"
            /bin/rm -rf "$OLD"
            /bin/mv "$BACKUP" "$OLD"
            /usr/bin/open "$OLD"
        fi
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        // Launch detached so it survives our termination.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptURL.path]
        try p.run()

        // Hand control to the helper: stop the child server and quit.
        (NSApp.delegate as? AppDelegate)?.server.terminateForQuit()
        NSApp.terminate(nil)
    }

    // -- helpers -----------------------------------------------------------

    /// Single-quote a string for safe inclusion in the shell script.
    private func shArg(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func findApp(in dir: URL, fm: FileManager) -> URL? {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        if let direct = items.first(where: { $0.lastPathComponent == "UxPlay.app" }) { return direct }
        // ditto with --keepParent nests it; search one level down.
        for item in items where item.hasDirectoryPath {
            if let nested = findApp(in: item, fm: fm) { return nested }
        }
        return nil
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "UxPlayUpdater", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) failed (\(p.terminationStatus))"])
        }
    }

    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// ===========================================================================
// MARK: - App delegate / menu
// ===========================================================================

final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = ServerController()
    let updater = Updater()
    private var statusItem: NSStatusItem!
    private var clearTitleWork: DispatchWorkItem?
    private var signalSources: [DispatchSourceSignal] = []

    /// Terminate the uxplay-bin child and exit when the app is killed with
    /// SIGTERM/SIGINT, so no orphaned server survives an external `kill`.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.server.terminateForQuit()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(contentsOf: BundleLayout.resources.appendingPathComponent("menubarTemplate.png")) {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "AirPlay"
            }
            button.imagePosition = .imageLeft
        }

        server.onChange = { [weak self] in self?.serverStateChanged() }
        rebuildMenu()
        server.start()

        // Throttled automatic update check (once per 24h).
        updater.check(manual: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.terminateForQuit()
    }

    // -- status-item reflection -------------------------------------------

    private func serverStateChanged() {
        rebuildMenu()
        // Show the PIN next to the icon while pairing, then clear it.
        clearTitleWork?.cancel()
        if let pin = server.currentPIN {
            statusItem.button?.title = " \(pin)"
            let work = DispatchWorkItem { [weak self] in self?.statusItem.button?.title = "" }
            clearTitleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: work)
        } else {
            statusItem.button?.title = ""
        }
    }

    // -- menu --------------------------------------------------------------

    private func rebuildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: server.state.menuText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if let pin = server.currentPIN {
            let pinItem = NSMenuItem(title: "Pairing PIN: \(pin)", action: #selector(copyPIN), keyEquivalent: "")
            pinItem.target = self
            let bold = [NSAttributedString.Key.font: NSFont.menuBarFont(ofSize: NSFont.systemFontSize)]
            pinItem.attributedTitle = NSAttributedString(string: "Pairing PIN: \(pin)  (click to copy)", attributes: bold)
            menu.addItem(pinItem)
        }

        menu.addItem(.separator())

        let running = server.isRunning
        add(menu, "Restart Server", #selector(restartServer), enabled: running)
        add(menu, running ? "Stop Server" : "Start Server", #selector(toggleServer))

        menu.addItem(.separator())
        add(menu, "Show Log", #selector(showLog))
        add(menu, "Open AirPlay Receiver Settings", #selector(openReceiverSettings))

        menu.addItem(.separator())
        add(menu, "Check for Updates…", #selector(checkForUpdates))
        let version = NSMenuItem(title: "UxPlay \(BundleLayout.shortVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        add(menu, "Quit UxPlay", #selector(quit), key: "q")

        statusItem.menu = menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    // -- actions -----------------------------------------------------------

    @objc private func copyPIN() {
        guard let pin = server.currentPIN else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pin, forType: .string)
    }

    @objc private func restartServer() { server.restart() }

    @objc private func toggleServer() {
        if server.isRunning { server.stop(userInitiated: true) } else { server.start() }
    }

    @objc private func showLog() {
        NSWorkspace.shared.open(server.logURL)
    }

    @objc private func openReceiverSettings() {
        // Best effort: General is where "AirDrop & Handoff -> AirPlay Receiver"
        // lives on recent macOS.  Fall back to opening System Settings itself.
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.general",
            "x-apple.systempreferences:com.apple.SystemPreferences.AirDrop",
        ]
        for c in candidates where NSWorkspace.shared.open(URL(string: c)!) { return }
        if let u = URL(string: "x-apple.systempreferences:") { NSWorkspace.shared.open(u) }
    }

    @objc private func checkForUpdates() { updater.check(manual: true) }

    @objc private func quit() {
        server.terminateForQuit()
        NSApp.terminate(nil)
    }
}

// ===========================================================================
// MARK: - Self-test  (xcrun ... UxPlay --self-test ; runs headless, no GUI)
// ===========================================================================

/// Exercises the pure logic (line classification, version comparison, argument
/// splitting) with no window server needed.  Returns true if all checks pass.
func runSelfTest() -> Bool {
    var ok = true
    func check(_ cond: Bool, _ what: String) {
        print("\(cond ? "ok  " : "FAIL") \(what)")
        if !cond { ok = false }
    }

    // Line classification against verbatim uxplay output.
    check(ServerController.classify(#"*** CLIENT MUST NOW ENTER PIN = "3939" AS AIRPLAY PASSWORD"#) == .pin("3939"),
          "PIN line -> .pin(3939)")
    check(ServerController.classify("connection request from Jan’s iPad (iPad13,4) with deviceID = AA:BB") == .streaming("Jan’s iPad"),
          "connection line -> .streaming(device)")
    check(ServerController.classify("Accepted mirror client on socket 12, port 7100") == .accepted,
          "Accepted line -> .accepted")
    check(ServerController.classify("Initialized server socket(s)") == .serverReady,
          "server-ready line -> .serverReady")
    check(ServerController.classify("*** ERROR:  macOS host reported AirplayReceiverEnabled was not true") == .receiverDisabled,
          "receiver-off ERROR -> .receiverDisabled")
    check(ServerController.classify(" macOS host reported AirplayReceiverEnabled is true") == .none,
          "receiver-on line -> .none  (must NOT be .receiverDisabled)")
    check(ServerController.classify("some unrelated log line") == .none, "unrelated line -> .none")

    // Version comparison.
    check(Updater.isNewer("v1.75.0-p2p", than: "1.74.0"),  "1.75.0 newer than 1.74.0")
    check(Updater.isNewer("1.74.1-p2p", than: "1.74.0"),   "1.74.1 newer than 1.74.0")
    check(!Updater.isNewer("v1.74.0-p2p", than: "1.74.0"), "1.74.0 not newer than itself")
    check(!Updater.isNewer("1.73.6", than: "1.74.0"),      "1.73.6 not newer than 1.74.0")
    check(Updater.isNewer("v2.0.0", than: "1.74.0"),       "2.0.0 newer than 1.74.0")
    check(Updater.versionComponents("v1.74.0-p2p") == [1, 74, 0], "versionComponents strips v and -p2p")

    // Release-asset name matching.
    func matchesAsset(_ name: String) -> Bool {
        Updater.assetPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
    check(matchesAsset("UxPlay-1.75.0-p2p-macos-arm64.zip"), "matches a normal release asset")
    check(matchesAsset("UxPlay-1.74.0-p2p-dirty-macos-arm64.zip"), "matches a dirty-tagged asset")
    check(!matchesAsset("UxPlay-1.75.0-p2p-macos-x86_64.zip"), "does not match an x86_64 asset")
    check(!matchesAsset("Source code.zip"), "does not match unrelated assets")

    // Argument splitting (UXPLAY_ARGS).
    check(shellSplit(#"-n MyRoom -vs "osxvideosink foo=bar""#) == ["-n", "MyRoom", "-vs", "osxvideosink foo=bar"],
          "shellSplit keeps a quoted value as one argument")
    check(shellSplit("") == [], "shellSplit empty -> []")

    print(ok ? "\nSELF-TEST PASSED" : "\nSELF-TEST FAILED")
    return ok
}

// ===========================================================================
// MARK: - main
// ===========================================================================

if CommandLine.arguments.contains("--self-test") { exit(runSelfTest() ? 0 : 1) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)          // no Dock icon (also LSUIElement)
app.run()
