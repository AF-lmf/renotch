import AppKit
import CoreGraphics

struct DisplayOption: Identifiable, Hashable {
    let id: UInt32
    let name: String
    let frame: NSRect
}

@MainActor
final class ScreenManager: ObservableObject {
    @Published private(set) var displays: [DisplayOption] = []

    var onScreensChanged: (() -> Void)?
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.onScreensChanged?()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func screen(for displayID: UInt32?) -> NSScreen? {
        let screens = NSScreen.screens
        if let displayID,
           let matching = screens.first(where: { Self.displayID(for: $0) == displayID }) {
            return matching
        }
        let preferred = Self.defaultDisplayID(
            among: screens.compactMap(Self.displayID(for:)),
            focused: NSScreen.main.flatMap(Self.displayID(for:)),
            isBuiltin: { CGDisplayIsBuiltin($0) != 0 }
        )
        return screens.first { Self.displayID(for: $0) == preferred } ?? NSScreen.main ?? screens.first
    }

    /// Without a chosen (or connected) display the notch goes to the built-in panel,
    /// which has the hardware notch. With no built-in display online (a desktop Mac,
    /// or a closed lid) it uses the screen with keyboard focus, then the first screen.
    static func defaultDisplayID(
        among displayIDs: [UInt32],
        focused: UInt32?,
        isBuiltin: (UInt32) -> Bool
    ) -> UInt32? {
        displayIDs.first(where: isBuiltin) ?? focused ?? displayIDs.first
    }

    func refresh() {
        displays = NSScreen.screens.enumerated().compactMap { index, screen in
            guard let id = Self.displayID(for: screen) else { return nil }
            // In bare dev runs (no Info.plist) AppKit returns the English system name for the
            // built-in panel ("Built-in Retina Display"). Label it in Chinese to match Settings;
            // external monitors report model names (e.g. "S2716Q") that need no translation.
            let name: String
            if CGDisplayIsBuiltin(id) != 0 {
                name = "内建显示器"
            } else if screen.localizedName.isEmpty {
                name = "显示器 \(index + 1)"
            } else {
                name = screen.localizedName
            }
            return DisplayOption(id: id, name: name, frame: screen.frame)
        }
    }

    static func displayID(for screen: NSScreen) -> UInt32? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return number.uint32Value
    }
}
