import AppKit
import Darwin
import Foundation
import ReshCore

private struct Options {
    var client: String?
    var server: String?
    var connect: String?
    var name: String?
    var diagnose = false
    var help = false
    var standby = false
    var quit = false
    var status = false
    var start = false
    var config: String?
    var checkConfig = false

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value() throws -> String {
                index += 1
                guard index < arguments.count else { throw ReshError("Missing value for \(argument)") }
                return arguments[index]
            }
            switch argument {
            case "--client": client = try value()
            case "--server": server = try value()
            case "--connect": connect = try value()
            case "--name": name = try value()
            case "--diagnose": diagnose = true
            case "--standby": standby = true
            case "--quit": quit = true
            case "--status": status = true
            case "--start": start = true
            case "--config": config = URL(fileURLWithPath: (try value() as NSString).expandingTildeInPath).standardizedFileURL.path
            case "--check-config": checkConfig = true
            case "--help", "-h": help = true
            default: throw ReshError("Unknown option: \(argument)")
            }
            index += 1
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let service: ReshService
    private let tools: Tools
    private let options: Options
    private var controller: PanelController?
    private var lockDescriptor: Int32 = -1
    private var host: LauncherHost?
    private var hotkey: RexHotkey?
    private var openingID: UUID?
    private let dataConnection: RexDataConnection
    private var warmupTask: Task<Void, Never>?
    private var rexMonitor: RexAppMonitor?
    private var isStopping = false

    init(service: ReshService, tools: Tools, options: Options) {
        self.service = service; self.tools = tools; self.options = options
        dataConnection = RexDataConnection(tools: tools)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/resh")
        do { try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true) }
        catch { fail(error); return }
        lockDescriptor = Darwin.open(cache.appendingPathComponent("panel.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0 else { fail(ReshError("Cannot create resh's panel lock.")); return }
        if flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
            NSApp.terminate(nil)
            return
        }
        do {
            controller = try PanelController(service: service, tools: tools,
                configurationURL: options.config.map { URL(fileURLWithPath: $0) },
                snapshotProvider: dataConnection)
            controller?.onDismiss = { [weak self] in
                guard let self else { return }
                if self.openingID != nil { self.dataConnection.stop() }
                self.openingID = nil
            }
            host = try LauncherHost()
            host?.onRequest = { [weak self] request in self?.handle(request) ?? ["error": "Host is stopping."] }
        } catch { fail(error); return }
        installMenu()
        hotkey = RexHotkey()
        hotkey?.onPress = { [weak self] in _ = self?.open(LauncherRequest()) }
        rexMonitor = RexAppMonitor()
        rexMonitor?.onChange = { [weak self] available in
            guard let self, !self.isStopping else { return }
            if available {
                let connection = self.dataConnection
                self.warmupTask = Task.detached { try? connection.warmup() }
            } else {
                self.warmupTask?.cancel(); self.warmupTask = nil
                self.dataConnection.stop()
                self.openingID = nil
                self.controller?.dismiss(focusRex: false)
            }
        }
        rexMonitor?.refresh()
    }
    // Hiding the accessory panel must not terminate its resident native controls.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller != nil else { return .terminateNow }
        guard !isStopping else { return .terminateLater }
        isStopping = true
        openingID = nil
        rexMonitor?.stop()
        hotkey?.stop()
        warmupTask?.cancel(); warmupTask = nil
        dataConnection.stop()
        controller?.dismiss(focusRex: false)
        let attention = controller?.stopAttention(), connection = dataConnection
        DispatchQueue.global(qos: .userInitiated).async {
            connection.waitUntilStopped()
            for connection in attention ?? [] { connection.waitUntilStopped() }
            let children = RexProcess.stopAll()
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            for child in children { _ = child.waitForExit(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime)) }
            // AppKit waits in a nested run loop, possibly inside a main-queue
            // block. Reply through that run loop, not the non-reentrant queue.
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        openingID = nil
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); close(lockDescriptor) }
        host?.stop()
        hotkey?.stop()
        dataConnection.stop()
        controller?.stopAttention()
    }
    private func open(_ request: LauncherRequest) -> Bool {
        guard !isStopping, openingID == nil, let controller,
              !controller.model.isConnecting, !controller.model.isPresentingConfirmation else { return false }
        if controller.panel.isVisible, controller.model.displayedError == nil,
           request.client == nil, request.server == nil, request.config == nil {
            controller.panel.makeKeyAndOrderFront(nil)
            return true
        }
        let id = UUID()
        openingID = id
        let target = RexTarget(clientID: request.client, server: request.server)
        let frontmost = NSWorkspace.shared.frontmostApplication
        let rexAppPID = target.clientID == nil && PanelShortcut.launcherIsEnabled(frontmostBundleID: frontmost?.bundleIdentifier)
            ? frontmost?.processIdentifier : nil
        let connection = dataConnection
        controller.presentLoading()
        Task { [self] in
            defer {
                if openingID == id { openingID = nil }
            }
            do {
                let snapshot = try await Task.detached { try connection.snapshot(target: target, rexAppPID: rexAppPID) }.value
                guard openingID == id, !controller.model.isConnecting, !controller.model.isPresentingConfirmation else { return }
                let selected = RexTarget(clientID: snapshot.client, server: target.server)
                controller.prepare(service: ReshService(client: RexClient(tools: tools, target: selected)), snapshot: snapshot,
                    configurationURL: request.config.map { URL(fileURLWithPath: $0) })
                controller.model.reportDiagnostic(nil, source: "connection")
                controller.show()
            } catch {
                guard openingID == id, !controller.model.isConnecting, !controller.model.isPresentingConfirmation else { return }
                controller.present(error: error) { [weak self] in _ = self?.open(request) }
            }
        }
        return true
    }
    private func handle(_ request: LauncherRequest) -> [String: Any] {
        guard let controller else { return ["error": "Panel is not ready."] }
        if request.operation == "quit" {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return ["stopping": true]
        }
        if request.operation == "show", !open(request) {
            return ["error": "A session operation is still in progress."]
        }
        let connectionState: String
        if isStopping { connectionState = "stopping" }
        else if dataConnection.isReady { connectionState = "ready" }
        else { connectionState = rexMonitor?.isAvailable == true ? "unavailable" : "waitingForRex" }
        return ["running": true, "pid": getpid(), "visible": controller.panel.isVisible,
                 "stopping": isStopping, "connectionState": connectionState,
                 "dataProcessID": dataConnection.processID as Any? ?? NSNull(),
                "configPath": (controller.model.configurationURL ?? ConfigurationFile.url()).path,
                "panelError": controller.model.displayedError as Any? ?? NSNull(),
                "nativeHotkeyRegistered": hotkey?.isRegistered ?? false,
                "nativeHotkeyStatus": hotkey?.registrationStatus ?? 0]
    }
    private func fail(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
        NSApp.terminate(nil)
    }
    private func installMenu() {
        let menu = NSMenu()
        let app = NSMenuItem(); menu.addItem(app)
        app.submenu = NSMenu(title: "resh")
        app.submenu?.addItem(withTitle: "Quit resh", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); menu.addItem(edit)
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
    }
}

@main
struct ReshMain {
    @MainActor
    static func main() {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            if options.help {
                print("""
                resh — native, sesh-inspired session/folder picker for Rex

                resh [--client CLIENT_ID] [--server ADDRESS]
                resh --connect DIRECTORY [--client CLIENT_ID]
                resh --name DIRECTORY
                resh --diagnose
                resh --status | --quit
                resh --start [--config FILE]
                resh --check-config [--config FILE]

                Config: ~/.config/resh/config.toml (or $RESH_CONFIG / --config FILE)

                ⌘1 Sessions · ⌘2 All · ⌘3 Recent folders · ⌘4 Find folders
                ↑/↓ or Tab/Shift-Tab navigate · Return open · Esc or Ctrl+[ dismiss
                ⌘⇧Backspace close a selected session (asks for confirmation)
                """)
                return
            }
            let configURL = (options.config ?? ProcessInfo.processInfo.environment["RESH_CONFIG"])
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
            if options.checkConfig {
                let config = try ConfigurationFile.load(configURL)
                print("Config: \((configURL ?? ConfigurationFile.url()).path)\nSources: \(config.visibleSources.map(\.id.rawValue).joined(separator: ", "))\nProjects: \(config.projects.count)\nValid")
                return
            }
            if !options.standby, options.connect == nil, !options.diagnose, options.name == nil {
                var request = LauncherRequest(client: options.client, server: options.server, config: configURL?.path)
                if options.quit {
                    try ResidentLauncher().stop()
                    print("{\"running\":false}")
                    return
                }
                if options.status { request.operation = "status" }
                if options.start {
                    try LauncherIPC.launchHost(configurationPath: configURL?.path, restart: true)
                    request.operation = "status"
                }
                var response = try LauncherIPC.send(request)
                if response == nil, request.operation == "show" || options.start {
                    if !options.start { try LauncherIPC.launchHost(configurationPath: configURL?.path) }
                    for _ in 0..<200 {
                        usleep(10_000)
                        response = try LauncherIPC.send(request)
                        if response != nil { break }
                    }
                    guard response != nil else { throw ReshError("The resh background panel did not start.") }
                }
                if options.status {
                    let data = try JSONSerialization.data(withJSONObject: response ?? ["running": false])
                    FileHandle.standardOutput.write(data); print("")
                }
                return
            }
            let tools = try Tools.discover()
            if let path = options.name { print(SessionNamer().name(for: path)); return }
            let target = RexTarget(clientID: options.client, server: options.server)
            let client = RexClient(tools: tools, target: target)
            let service = ReshService(client: client)
            if options.connect != nil || options.diagnose {
                Task.detached {
                    do {
                        let result: [String: Any]
                        if let path = options.connect {
                            let configuration = try ConfigurationFile.load(configURL)
                            let project = configuration.projects.first { $0.name == path } ?? configuration.project(at: path)
                            let directory = project?.path ?? PathIdentity.canonical(path)
                            let candidate = project?.candidate ?? Candidate(id: directory, kind: .directory,
                                title: directory, path: directory, startupCommand: configuration.defaultStartupCommand)
                            let id = try await service.connect(candidate)
                            result = ["session_id": id, "path": directory]
                        } else {
                            let app = try await service.resolveClient()
                            let connection = RexDataConnection(tools: tools)
                            defer { connection.stop() }
                            let snapshot = try connection.snapshot(target: RexTarget(clientID: app.id, server: target.server))
                            let folders = try SourceLoader(tools: tools).load(.directories, configuration: .defaults, sessions: [])
                            let theme = try RexTheme.read(rexApp: tools.rexApp,
                                systemIsDark: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
                            result = ["rex": tools.rex, "client": app.id, "server": target.server,
                                "sessions": snapshot.sessions.count, "directories": folders.entries.count,
                                "theme": theme.name, "glass": theme.usesGlass, "warnings": folders.warnings]
                        }
                        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                        FileHandle.standardOutput.write(data); print("")
                        exit(0)
                    } catch { report(error); exit(1) }
                }
                dispatchMain()
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate(service: service, tools: tools, options: options)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch { report(error); exit(1) }
    }
    nonisolated private static func report(_ error: Error) {
        FileHandle.standardError.write(Data(("resh: " + error.localizedDescription + "\n").utf8))
    }
}
