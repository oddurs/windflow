import AppKit
import ScreenSaver

// A plain windowed harness for the same view the .saver installs. Iterating on
// the simulation through System Settings means reinstalling and logging out;
// this runs it in a resizable window in about a second.
//
//   space  next photograph        f  toggle full screen
//   c      configuration sheet    r  restart with current settings
//   q      quit

final class Harness: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var saver: WindflowView!

    func applicationDidFinishLaunching(_ note: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Windflow — preview"
        window.center()
        window.delegate = self
        window.backgroundColor = .black

        saver = WindflowView(frame: frame, isPreview: false)!
        saver.autoresizingMask = [.width, .height]
        window.contentView = saver
        window.makeKeyAndOrderFront(nil)

        saver.startAnimation()
        NSApp.activate(ignoringOtherApps: true)

        // Easy to stare at the procedural stand-in for a while wondering why the
        // photographs look nothing like photographs.
        let library = ImageLibrary.urls()
        if library.isEmpty {
            print("No photographs in the library, so this is the procedural stand-in.")
            print("Press c to add some, or drop files into:")
            print("  " + ImageLibrary.folder.path)
        } else {
            print("\(library.count) photograph(s) in \(ImageLibrary.folder.path)")
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": saver.advanceImage(); return true
        case "f": window.toggleFullScreen(nil); return true
        case "r": saver.reloadSettings(); return true
        case "q": NSApp.terminate(nil); return true
        case "c":
            if let sheet = saver.configureSheet {
                window.beginSheet(sheet, completionHandler: { _ in })
            }
            return true
        default: return false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let harness = Harness()
app.delegate = harness
app.setActivationPolicy(.regular)
app.run()
