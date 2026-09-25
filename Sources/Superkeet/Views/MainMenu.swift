import AppKit

/// Superkeet is an accessory (menu bar) app, so its main menu is never shown. It still has to exist:
/// AppKit routes key equivalents such as ⌘C/⌘V/⌘A/⌘Z/⌘W through `NSApp.mainMenu`, and without one
/// those shortcuts do nothing in the Settings, History and Setup windows.
@MainActor
enum MainMenu {
    static func install() {
        dispatchPrecondition(condition: .onQueue(.main))
        let mainMenu = NSMenu()
        mainMenu.addItem(submenuItem(appMenu()))
        mainMenu.addItem(submenuItem(editMenu()))
        mainMenu.addItem(submenuItem(windowMenu()))
        NSApp.mainMenu = mainMenu
    }

    static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Superkeet")
        let settings = NSMenuItem(title: "Settings…", action: #selector(MenuBarManager.openSettings), keyEquivalent: ",")
        settings.target = MenuBarManager.shared
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Superkeet", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Superkeet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pasteMatch = menu.addItem(
            withTitle: "Paste and Match Style",
            action: #selector(NSTextView.pasteAsPlainText(_:)),
            keyEquivalent: "v"
        )
        pasteMatch.keyEquivalentModifierMask = [.command, .option, .shift]
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = menu
        return menu
    }

    private static func submenuItem(_ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}
