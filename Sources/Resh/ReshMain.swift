import AppKit
import Darwin
import Foundation
import ReshCore

private struct Options {
    var client: String?
    var session: String?
    var server: String?
    var connect: String?
    var name: String?
    var smokeTest: String?
    var diagnose = false
    var help = false

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
            case "--diagnose": diagnose = true
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
    private var reopenObserver: NSObjectProtocol?

    init(service: ReshService, tools: Tools, options: Options) {
        self.service = service; self.tools = tools; self.options = options
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        trace("Application launched")
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/resh")
        do { try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true) }
        catch { fail(error); return }
        lockDescriptor = Darwin.open(cache.appendingPathComponent("panel.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0 else { fail(ReshError("Cannot create resh's panel lock.")); return }
        if flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
            trace("Another panel owns the lock (errno \(errno))")
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("io.github.CruelAddict.resh.reopen"), object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        reopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.github.CruelAddict.resh.reopen"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    NSApp.activate(ignoringOtherApps: true)
                    self?.controller?.panel.makeKeyAndOrderFront(nil)
                }
            }
        installMenu()
        controller = PanelController(service: service, tools: tools, smokeTest: options.smokeTest)
        trace("Showing panel")
        controller?.show()
    }
    // Accessory panels are not normal document windows; dismissal owns termination.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        trace("Application terminating")
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); close(lockDescriptor) }
        if let reopenObserver { DistributedNotificationCenter.default().removeObserver(reopenObserver) }
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
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            if options.help {
                print("""
                resh — native, sesh-inspired project switcher for Rex

                resh [--client CLIENT_ID] [--session SESSION_ID] [--server ADDRESS]
                resh --connect DIRECTORY [--client CLIENT_ID]
                resh --name DIRECTORY
                resh --diagnose

                ⌃A All · ⌃T Sessions · ⌃X Recent folders · ⌃F Find folders
                ↑/↓ or Tab/Shift-Tab navigate · Return open · Esc dismiss
                ⌃D close a selected session (asks for confirmation)
                """)
                return
            }
            let tools = try Tools.discover()
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
