import AppKit
import Darwin
import Foundation
import ReshCore

private enum ServiceOperation: String { case start, stop, restart, status }

private struct Options {
    var client: String?
    var currentSessionID: String?
    var server: String?
    var connect: String?
    var last = false
    var name: String?
    var diagnose = false
    var debug = false
    var help = false
    var serve = false
    var serviceOperation: ServiceOperation?
    var config: String?
    var checkConfig = false
    var action: String?
    var actionArguments: [String: KeyArgument] = [:]

    init(_ arguments: [String]) throws {
        var arguments = arguments
        if arguments.first == "serve" {
            serve = true
            arguments.removeFirst()
        } else if arguments.first == "service" {
            arguments.removeFirst()
            if arguments.first == "--help" || arguments.first == "-h" { help = true; return }
            guard let command = arguments.first, let operation = ServiceOperation(rawValue: command) else {
                throw ReshError("Usage: resh service start|stop|restart|status")
            }
            serviceOperation = operation
            arguments.removeFirst()
        }
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
            case "--current-session": currentSessionID = try value()
            case "--server": server = try value()
            case "--connect": connect = try value()
            case "--last": last = true
            case "--name": name = try value()
            case "--diagnose": diagnose = true
            case "--debug": debug = true
            case "--config": config = URL(fileURLWithPath: (try value() as NSString).expandingTildeInPath).standardizedFileURL.path
            case "--check-config": checkConfig = true
            case "--action": action = try value()
            case "--args": actionArguments = try JSONDecoder().decode([String: KeyArgument].self, from: Data(try value().utf8))
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
    private var openingID: UUID?
    private let dataConnection: RexDataConnection
    private var rexMonitor: RexAppMonitor?
    private var isStopping = false
    private var isExecutingCommand = false

    init(service: ReshService, tools: Tools, options: Options, dataConnection: RexDataConnection) {
        self.service = service; self.tools = tools; self.options = options
        self.dataConnection = dataConnection
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
            controller = PanelController(service: service, tools: tools,
                configurationURL: options.config.map { URL(fileURLWithPath: $0) },
                snapshotProvider: dataConnection)
            controller?.onDismiss = { [weak self] in
                guard let self else { return }
                if self.openingID != nil { self.dataConnection.stop() }
                self.openingID = nil
                DebugLog.shared.setEnabled(self.options.debug)
            }
            host = try LauncherHost()
            host?.onRequest = { [weak self] request in await self?.handle(request) ?? ["error": "Host is stopping."] }
        } catch { fail(error); return }
        installMenu()
        rexMonitor = RexAppMonitor()
        rexMonitor?.onChange = { [weak self] available in
            guard let self, !self.isStopping else { return }
            if available {
                self.controller?.model.startBackground()
                self.dataConnection.prepare(server: self.controller?.model.service.target.server ?? self.service.target.server)
            } else {
                self.dataConnection.stop()
                self.openingID = nil
                self.controller?.dismiss(focusRex: false)
                self.controller?.model.stopBackground()
            }
        }
        rexMonitor?.refresh()
    }
    // Hiding the accessory panel must not terminate its resident native controls.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DebugLog.shared.record("Application termination requested", source: "lifecycle")
        guard controller != nil else { return .terminateNow }
        guard !isStopping else { return .terminateLater }
        isStopping = true
        openingID = nil
        rexMonitor?.stop()
        dataConnection.stop()
        controller?.dismiss(focusRex: false)
        let connections = (controller?.stopAttention() ?? []) + (controller?.model.stopBackground() ?? [])
        controller?.model.clear()
        let connection = dataConnection
        DispatchQueue.global(qos: .userInitiated).async {
            connection.waitUntilStopped()
            for connection in connections { connection.waitUntilStopped() }
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
        dataConnection.stop()
        controller?.stopAttention()
        controller?.model.stopBackground()
    }
    private func toggle(_ request: LauncherRequest) -> Bool {
        guard !isStopping, !isExecutingCommand, let controller else { return false }
        return controller.toggle { open(request) }
    }

    private func open(_ request: LauncherRequest) -> Bool {
        guard !isStopping, !isExecutingCommand, openingID == nil, let controller,
              !controller.model.isConnecting else { return false }
        DebugLog.shared.setEnabled(request.debug ?? options.debug)
        DebugLog.shared.record("Opening panel", source: "panel")
        let started = ProcessInfo.processInfo.systemUptime
        let target = RexTarget(clientID: request.client, server: request.server)
        let frontmost = NSWorkspace.shared.frontmostApplication
        let rexAppPID = target.clientID == nil && frontmost?.bundleIdentifier == RexAppMonitor.bundleIdentifier
            ? frontmost?.processIdentifier : nil
        let currentSessionID = request.currentSessionID ?? controller.model.focusedSessionID(rexAppPID: rexAppPID)
        controller.model.configure(target: target)
        controller.model.startBackground()
        dataConnection.prepare(server: target.server)
        if let snapshot = controller.model.catalog.snapshot(clientID: target.clientID, rexAppPID: rexAppPID) {
            let selected = RexTarget(clientID: snapshot.client, server: target.server)
            let service = service.at(selected)
            controller.prepare(service: service, snapshot: snapshot,
                recentSessionIDs: controller.model.catalog.recentSessionIDs, currentSessionID: currentSessionID)
            controller.show()
            DebugLog.shared.record("Catalog ready; panel displayed in \((ProcessInfo.processInfo.systemUptime - started) * 1000) ms", source: "panel")
            return true
        }
        let id = UUID()
        openingID = id
        let connection = dataConnection
        controller.presentLoading()
        Task { [self] in
            defer {
                if openingID == id { openingID = nil }
            }
            do {
                let fetched = try await Task.detached { try connection.snapshot(target: target, rexAppPID: rexAppPID) }.value
                guard openingID == id, !controller.model.isConnecting else { return }
                let snapshot = controller.model.catalog.snapshot(clientID: target.clientID, rexAppPID: rexAppPID) ?? fetched
                let selected = RexTarget(clientID: snapshot.client, server: target.server)
                let service = service.at(selected)
                controller.prepare(service: service, snapshot: snapshot,
                    recentSessionIDs: controller.model.catalog.recentSessionIDs, currentSessionID: currentSessionID)
                controller.model.reportDiagnostic(nil, source: "connection")
                controller.show()
            } catch {
                guard openingID == id, !controller.model.isConnecting else { return }
                controller.present(error: error) { [weak self] in _ = self?.open(request) }
            }
        }
        return true
    }
    private func handle(_ request: LauncherRequest) async -> [String: Any] {
        guard let controller else { return ["error": "Panel is not ready."] }
        if request.operation == "quit" {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return ["stopping": true]
        }
        if let path = request.config,
           URL(fileURLWithPath: path).standardizedFileURL != controller.model.configurationURL {
            return ["error": "To change the configuration file, run resh service restart --config \"\(path)\"."]
        }
        if request.operation == "connect", let error = controller.model.configurationError {
            return ["error": error]
        }
        if let action = request.action {
            guard !isStopping, controller.panel.isVisible else { return ["error": "Open the resh picker first."] }
            guard request.client == nil || request.client == controller.model.service.target.clientID else {
                return ["error": "The resh picker belongs to another Rex client."]
            }
            guard let shortcut = action.shortcut else { return ["error": "Unknown picker action or invalid arguments: \(action.action)"] }
            controller.perform(shortcut)
            return ["accepted": true]
        }
        if request.changesSession {
            guard !isStopping, !isExecutingCommand, openingID == nil, !controller.model.isConnecting else {
                return ["error": "A session operation is still in progress."]
            }
            isExecutingCommand = true
            controller.model.isConnecting = true
            DebugLog.shared.setEnabled(request.debug ?? options.debug)
            defer {
                isExecutingCommand = false
                controller.model.isConnecting = false
                DebugLog.shared.setEnabled(options.debug)
            }
            do {
                var command = request
                let sameServer = controller.model.service.target.server == (request.server ?? service.target.server)
                if command.currentSessionID == nil, sameServer {
                    let clients = controller.model.catalog.clients.filter { request.client == nil || $0.client == request.client }
                    if clients.count == 1 { command.currentSessionID = controller.model.focusedSessionID(rexAppPID: clients[0].rexAppPID) }
                }
                let commands = LauncherCommands(service: service, configuration: controller.model.configuration,
                    sessions: sameServer ? controller.model.sessionCandidates : [])
                let result = try await commands.run(command)
                controller.model.catalog.refreshState()
                if result["session_id"] != nil, controller.panel.isVisible { controller.dismiss(focusRex: false) }
                return result
            } catch {
                DebugLog.shared.record(error, source: "command:\(request.operation)")
                return ["error": error.localizedDescription]
            }
        }
        guard request.operation == "show" || request.operation == "status" else {
            return ["error": "Unknown resh command: \(request.operation)"]
        }
        if request.operation == "show", !toggle(request) {
            return ["error": "A session operation is still in progress."]
        }
        let connectionState: String
        if isStopping { connectionState = "stopping" }
        else if controller.model.catalog.isConnected { connectionState = "ready" }
        else { connectionState = rexMonitor?.isAvailable == true ? "unavailable" : "waitingForRex" }
        return ["running": true, "pid": getpid(), "visible": controller.panel.isVisible,
                 "stopping": isStopping, "connectionState": connectionState,
                 "dataProcessID": controller.model.catalog.processID as Any? ?? NSNull(),
                 "sessions": controller.model.sessionCount,
                 "keymapReady": controller.model.isKeymapReady,
                 "keymapError": controller.model.keymapError as Any? ?? NSNull(),
                 "configPath": controller.model.configurationURL.path,
                 "statePath": service.stateURL?.path as Any? ?? NSNull(),
                 "stateError": controller.model.catalog.stateError as Any? ?? NSNull(),
                 "panelError": controller.model.error as Any? ?? NSNull()]
    }
    private func fail(_ error: Error) {
        DebugLog.shared.record(error, source: "startup")
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
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "setup" {
                try setup(Array(arguments.dropFirst()))
                return
            }
            let options = try Options(arguments)
            DebugLog.shared.setEnabled(options.debug)
            if options.debug {
                FileHandle.standardError.write(Data(("resh: Debug log: \(DebugLog.shared.url.path)\n").utf8))
            }
            if options.help {
                print("""
                resh — macOS session manager for Rex, inspired by sesh

                resh [--client CLIENT_ID] [--current-session SESSION_ID] [--server ADDRESS] [--debug]
                resh --connect DIRECTORY [--client CLIENT_ID] [--current-session SESSION_ID]
                resh --last [--client CLIENT_ID] [--current-session SESSION_ID]
                resh --action ACTION [--args JSON] [--client CLIENT_ID]
                resh --name DIRECTORY
                resh --diagnose
                resh setup [--config REX_CONFIG_FILE] [--yes]
                resh service start|stop|restart|status [--config FILE] [--debug]
                resh serve [--config FILE] [--debug]
                resh --check-config [--config FILE]

                Config: ~/.config/resh/config.toml (or $RESH_CONFIG / --config FILE)
                Shortcuts: Rex init.lua; apply with rex config reload.
                Apply TOML changes with resh service restart.
                --debug: write diagnostics to ~/Library/Logs/resh/debug.log

                ⌘S open/close resh in Rex · ⌘L previous session in Rex
                ⌘E Sessions · ⌘A Agents · ⌘R Recent · ⌘F Find · ⌘P Projects
                ⌘1…9 open a result · ⌘⇧P pin/unpin a session (memory only)
                ⌘⇧N create a session named after the search text
                ↑/↓ or Ctrl+P/Ctrl+N navigate · Enter open · Esc or Ctrl+[ dismiss
                ⌘⇧D immediately close a selected session
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
            if let path = options.name { print(SessionNamer().name(for: path)); return }
            if !options.serve, !options.diagnose {
                var request = LauncherRequest(client: options.client, server: options.server, config: configURL?.path,
                    debug: options.debug ? true : nil)
                request.currentSessionID = options.currentSessionID
                if let action = options.action {
                    request.operation = "action"
                    request.action = KeyInvocation(action: action, args: options.actionArguments)
                }
                if options.last { request.operation = "last" }
                else if let path = options.connect {
                    request.operation = "connect"
                    request.path = path
                    request.cwd = FileManager.default.currentDirectoryPath
                }
                if options.serviceOperation == .stop {
                    try ServiceLauncher().stop()
                    print("{\"running\":false}")
                    return
                }
                if options.serviceOperation != nil { request.operation = "status" }
                let startsService = options.serviceOperation == .start || options.serviceOperation == .restart
                if startsService {
                    try LauncherIPC.launchHost(configurationPath: configURL?.path,
                        restart: options.serviceOperation == .restart, debug: options.debug)
                    request.operation = "status"
                }
                var response = try LauncherIPC.send(request)
                if request.action != nil, response == nil { throw ReshError("Open the resh picker first.") }
                if response == nil, request.operation == "show" || request.changesSession || startsService {
                    if !startsService { try LauncherIPC.launchHost(configurationPath: configURL?.path) }
                    for _ in 0..<200 {
                        usleep(10_000)
                        response = try LauncherIPC.send(request)
                        if response != nil { break }
                    }
                    guard response != nil else { throw ReshError("The resh service did not start.") }
                }
                if options.serviceOperation == .status {
                    let data = try JSONSerialization.data(withJSONObject: response ?? ["running": false])
                    FileHandle.standardOutput.write(data); print("")
                } else if request.changesSession, let response, !response.isEmpty {
                    let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
                    FileHandle.standardOutput.write(data); print("")
                }
                return
            }
            let tools = try Tools.discover()
            let target = RexTarget(clientID: options.client, server: options.server)
            let connection = RexDataConnection(tools: tools)
            let client = RexClient(tools: tools, target: target, apiCaller: connection)
            let service = ReshService(client: client)
            if options.diagnose {
                Task.detached {
                    do {
                        let app = try await service.resolveClient()
                        defer { connection.stop() }
                        let snapshot = try connection.snapshot(target: RexTarget(clientID: app.id, server: target.server))
                        let folders = try SourceLoader(tools: tools).load(.directories, configuration: .defaults, sessions: [])
                        let theme = try RexTheme.read(rexApp: tools.rexApp,
                            systemIsDark: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
                        let result: [String: Any] = ["rex": tools.rex, "client": app.id, "server": target.server,
                            "sessions": snapshot.sessions.count, "directories": folders.entries.count,
                            "theme": theme.name, "glass": theme.usesGlass, "warnings": folders.warnings]
                        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                        FileHandle.standardOutput.write(data); print("")
                        exit(0)
                    } catch { report(error); exit(1) }
                }
                dispatchMain()
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate(service: service, tools: tools, options: options, dataConnection: connection)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch { report(error); exit(1) }
    }
    nonisolated private static func setup(_ arguments: [String]) throws {
        guard let script = Bundle.module.url(forResource: "setup", withExtension: "sh"),
              let executable = Bundle.main.executableURL else {
            throw ReshError("The resh setup resources are missing. Reinstall resh.")
        }
        let directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let argv = (["/bin/bash", script.path, "--source", directory.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        // Keep the foreground terminal so setup can read confirmation from /dev/tty.
        _ = argv.withUnsafeBufferPointer { execv("/bin/bash", $0.baseAddress!) }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    nonisolated private static func report(_ error: Error) {
        DebugLog.shared.record(error, source: "cli")
        FileHandle.standardError.write(Data(("resh: " + error.localizedDescription + "\n").utf8))
    }
}
