import AppKit
import Darwin
import Foundation
import ReshCore

@MainActor
enum LaunchMetrics {
    static var processStarted = ProcessInfo.processInfo.systemUptime
    static var applicationReadyMilliseconds = 0.0
    static var stages: [String: Double] = [:]
    static func mark(_ name: String) {
        stages[name] = (ProcessInfo.processInfo.systemUptime - processStarted) * 1000
    }
}

private struct Options {
    var client: String?
    var session: String?
    var server: String?
    var connect: String?
    var name: String?
    var smokeTest: String?
    var sessions: [RexSession]?
    var diagnose = false
    var help = false
    var standby = false
    var once = false
    var quit = false
    var status = false
    var warmup = false
    var nativeHotkeySmoke = false

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
            case "--session": session = try value()
            case "--server": server = try value()
            case "--connect": connect = try value()
            case "--name": name = try value()
            case "--smoke-test": smokeTest = try value()
            case "--sessions-json": sessions = try JSONDecoder().decode([RexSession].self, from: Data(value().utf8))
            case "--diagnose": diagnose = true
            case "--standby": standby = true
            case "--once": once = true
            case "--quit": quit = true
            case "--status": status = true
            case "--warmup": warmup = true
            case "--native-hotkey-smoke": nativeHotkeySmoke = true; smokeTest = try value()
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
    private var hotkeyInFlight = false
    private var nativeSmokeReport: String?
    private var nativeHotkeyStarted: Double?
    private var dataConnection: RexDataConnection?

    init(service: ReshService, tools: Tools, options: Options) {
        self.service = service; self.tools = tools; self.options = options
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchMetrics.applicationReadyMilliseconds = (ProcessInfo.processInfo.systemUptime - LaunchMetrics.processStarted) * 1000
        LaunchMetrics.mark("applicationReady")
        trace("Application launched")
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/resh")
        do { try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true) }
        catch { fail(error); return }
        lockDescriptor = Darwin.open(cache.appendingPathComponent("panel.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0 else { fail(ReshError("Cannot create resh's panel lock.")); return }
        if !options.once, flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
            NSApp.terminate(nil)
            return
        }
        LaunchMetrics.mark("panelLock")
        controller = PanelController(service: service, tools: tools, sessions: options.sessions, smokeTest: options.smokeTest)
        controller?.terminateOnDismiss = options.once
        if options.once {
            controller?.show()
        } else {
            do {
                host = try LauncherHost()
                host?.onRequest = { [weak self] request in self?.handle(request) ?? ["error": "Host is stopping."] }
            } catch { fail(error); return }
        }
        installMenu()
        if !options.once {
            let connection = RexDataConnection(tools: tools)
            dataConnection = connection
            Task.detached { try? connection.warmup() }
            hotkey = RexHotkey()
            hotkey?.onPress = { [weak self] in self?.openFromNativeHotkey() }
        }
        LaunchMetrics.mark("menu")
    }
    // Hiding the accessory panel must not terminate its resident native controls.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        trace("Application terminating")
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); close(lockDescriptor) }
        host?.stop()
        hotkey?.stop()
        dataConnection?.stop()
    }
    private func openFromNativeHotkey() {
        guard !hotkeyInFlight, let controller else { return }
        if controller.panel.isVisible {
            controller.panel.makeKeyAndOrderFront(nil)
            return
        }
        hotkeyInFlight = true
        nativeHotkeyStarted = ProcessInfo.processInfo.systemUptime
        let smokeReport = nativeSmokeReport
        nativeSmokeReport = nil
        guard let appPID = NSWorkspace.shared.frontmostApplication?.processIdentifier, let dataConnection else {
            hotkeyInFlight = false
            return
        }
        Task {
            do {
                let snapshot = try await Task.detached { try dataConnection.snapshot(appPID: appPID) }.value
                _ = handle(LauncherRequest(client: snapshot.client, sessions: snapshot.sessions ?? [],
                    smokeTest: smokeReport, sentAt: nativeHotkeyStarted ?? ProcessInfo.processInfo.systemUptime))
            } catch { controller.present(error: error) }
            hotkeyInFlight = false
        }
    }
    private func handle(_ request: LauncherRequest) -> [String: Any] {
        guard let controller else { return ["error": "Panel is not ready."] }
        if request.operation == "quit" {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return ["stopping": true]
        }
        if request.operation == "nativeHotkeySmoke" {
            guard let hotkey, hotkey.isRegistered else { return ["error": "Rex must be frontmost for its scoped hotkey."] }
            nativeSmokeReport = request.smokeTest
            let status = hotkey.exerciseHandler()
            return status == 0 ? ["scheduled": true] : ["error": "Native handler returned \(status)."]
        }
        if request.operation == "show" {
            guard !controller.model.isConnecting, !controller.model.isPresentingConfirmation else {
                return ["error": "A session operation is still in progress."]
            }
            let target = RexTarget(clientID: request.client, sessionID: request.session, server: request.server)
            controller.prepare(service: ReshService(client: RexClient(tools: tools, target: target)), request: request)
            controller.nativeHotkeyStartedAt = nativeHotkeyStarted
            nativeHotkeyStarted = nil
            controller.show()
        }
        return ["running": true, "pid": getpid(), "visible": controller.panel.isVisible,
                "retainedSessions": controller.model.catalog.sessions.count,
                "retainedFolders": controller.model.catalog.directories.count,
                "query": controller.model.query,
                "nativeHotkeyRegistered": hotkey?.isRegistered ?? false,
                "nativeHotkeyStatus": hotkey?.registrationStatus ?? 0]
    }
    private func trace(_ message: String) {
        if options.smokeTest != nil { FileHandle.standardError.write(Data(("resh smoke: " + message + "\n").utf8)) }
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
        LaunchMetrics.processStarted = ProcessInfo.processInfo.systemUptime
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            LaunchMetrics.mark("options")
            if options.help {
                print("""
                resh — native, sesh-inspired session/folder picker for Rex

                resh [--client CLIENT_ID] [--session SESSION_ID] [--server ADDRESS]
                resh --connect DIRECTORY [--client CLIENT_ID]
                resh --name DIRECTORY
                resh --diagnose
                resh --status | --quit

                ⌘1 Sessions · ⌘2 All · ⌘3 Recent folders · ⌘4 Find folders
                ↑/↓ or Tab/Shift-Tab navigate · Return open · Esc dismiss
                ⌘⇧Backspace close a selected session (asks for confirmation)
                """)
                return
            }
            if !options.standby, !options.once, options.connect == nil, !options.diagnose, options.name == nil {
                var request = LauncherRequest(client: options.client, session: options.session, server: options.server,
                    sessions: options.sessions, smokeTest: options.smokeTest)
                if options.quit { request.operation = "quit" }
                if options.status { request.operation = "status" }
                if options.warmup { request.operation = "status" }
                if options.nativeHotkeySmoke { request.operation = "nativeHotkeySmoke" }
                if let output = options.smokeTest {
                    let report = URL(fileURLWithPath: output + ".json")
                    if FileManager.default.fileExists(atPath: report.path) { try FileManager.default.removeItem(at: report) }
                }
                var response = try LauncherIPC.send(request)
                if response == nil, request.operation == "show" || options.warmup {
                    try LauncherIPC.launchHost()
                    for _ in 0..<200 {
                        usleep(10_000)
                        response = try LauncherIPC.send(request)
                        if response != nil { break }
                    }
                    guard response != nil else { throw ReshError("The resh background panel did not start.") }
                }
                if options.status || options.quit {
                    let data = try JSONSerialization.data(withJSONObject: response ?? ["running": false])
                    FileHandle.standardOutput.write(data); print("")
                }
                if let output = options.smokeTest {
                    for _ in 0..<2000 {
                        if FileManager.default.fileExists(atPath: output + ".json") { return }
                        usleep(10_000)
                    }
                    throw ReshError("Timed out waiting for the UI smoke report.")
                }
                return
            }
            let tools = try Tools.discover()
            LaunchMetrics.mark("tools")
            if let path = options.name { print(SessionNamer().name(for: path)); return }
            let target = RexTarget(clientID: options.client, sessionID: options.session, server: options.server)
            let client = RexClient(tools: tools, target: target)
            let service = ReshService(client: client)
            if options.connect != nil || options.diagnose {
                Task.detached {
                    do {
                        let result: [String: Any]
                        if let path = options.connect {
                            let id = try await service.connect(path: path)
                            result = ["session_id": id, "path": PathIdentity.canonical(path)]
                        } else {
                            let catalog = try await service.catalog()
                            let app = try await service.resolveClient()
                            let theme = RexTheme.read(rexApp: tools.rexApp,
                                systemIsDark: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
                            result = ["rex": tools.rex, "client": app.id, "server": target.server,
                                "sessions": catalog.sessions.count, "directories": catalog.directories.count,
                                "theme": theme.name, "glass": theme.usesGlass, "warnings": catalog.warnings]
                        }
                        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                        FileHandle.standardOutput.write(data); print("")
                        exit(0)
                    } catch { report(error); exit(1) }
                }
                dispatchMain()
            }
            let app = NSApplication.shared
            LaunchMetrics.mark("applicationCreated")
            app.setActivationPolicy(.accessory)
            LaunchMetrics.mark("activationPolicy")
            let delegate = AppDelegate(service: service, tools: tools, options: options)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch { report(error); exit(1) }
    }
    nonisolated private static func report(_ error: Error) {
        FileHandle.standardError.write(Data(("resh: " + error.localizedDescription + "\n").utf8))
    }
}
