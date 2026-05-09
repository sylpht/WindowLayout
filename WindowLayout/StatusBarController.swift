import AppKit
import ServiceManagement

class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        setupIcon()
        menu.minimumWidth = 280
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshMenu()
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutsChanged),
            name: LayoutManager.didChangeNotification, object: nil
        )
    }

    @objc private func layoutsChanged() { refreshMenu() }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
    }

    private func setupIcon() {
        guard let button = statusItem.button else { return }
        button.image = defaultIconImage()
        button.image?.isTemplate = true
        button.toolTip = L.s("WindowLayout — расположения окон",
                             "WindowLayout — window arrangements",
                             "WindowLayout — 窗口布局")
    }

    private func defaultIconImage() -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        return NSImage(systemSymbolName: "macwindow", accessibilityDescription: "WindowLayout")?
            .withSymbolConfiguration(cfg)
    }

    /// Briefly replace the menu bar icon with a checkmark as visual confirmation.
    /// Uses a generation counter so rapid back-to-back flashes don't leave the icon
    /// stuck — only the LATEST scheduled revert actually fires.
    private var flashGeneration: Int = 0

    func flashIconSuccess() {
        guard let button = statusItem.button else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let check = NSImage(systemSymbolName: "checkmark.circle.fill",
                            accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        check?.isTemplate = true
        button.image = check

        flashGeneration &+= 1
        let myGen = flashGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.flashGeneration == myGen else { return }
            let img = self.defaultIconImage()
            img?.isTemplate = true
            self.statusItem.button?.image = img
        }
    }

    func refreshMenu() {
        menu.removeAllItems()

        let isAccessible = AXIsProcessTrusted()
        let currentProfiles = LayoutManager.shared.profilesForCurrentSetup()

        menu.addItem(makeHeader(isAccessible: isAccessible, profileCount: currentProfiles.count))
        menu.addItem(.separator())

        if !isAccessible {
            menu.addItem(action(
                L.s("Разрешить Универсальный доступ →", "Enable Accessibility Access →", "开启辅助功能权限 →"),
                symbol: "lock.open",
                sel: #selector(openAccessibilitySettings)
            ))
            menu.addItem(.separator())
        } else {
            menu.addItem(action(
                L.s("Сохранить новое расположение…", "Save New Layout…", "保存新布局…"),
                symbol: "square.and.arrow.down",
                sel: #selector(promptSaveLayout),
                key: "s"
            ))

            if !currentProfiles.isEmpty {
                menu.addItem(.separator())
                menu.addItem(sectionHeader(L.s("СОХРАНЁННЫЕ РАСПОЛОЖЕНИЯ", "SAVED LAYOUTS", "已保存的布局")))
                for p in currentProfiles {
                    addProfileItems(p)
                }
            }

            menu.addItem(.separator())
        }

        let stageActive = WindowEnvironment.isStageManagerActive
        let auto = action(
            L.s("Автовосстановление при подключении", "Auto-restore on reconnect", "重新连接时自动还原"),
            symbol: "display.and.arrow.down",
            sel: #selector(toggleAutoRestore)
        )
        // When Stage Manager is on, auto-restore is a no-op — disable the toggle
        // visually so the ON state doesn't contradict the warning row below.
        auto.state = (UserDefaults.standard.bool(forKey: "autoRestore") && !stageActive) ? .on : .off
        auto.isEnabled = !stageActive
        menu.addItem(auto)

        if stageActive {
            let warn = NSMenuItem(
                title: L.s("⚠︎ Stage Manager активен — автовосстановление пропускается",
                           "⚠︎ Stage Manager active — auto-restore skipped",
                           "⚠︎ Stage Manager 已开启 — 自动还原已跳过"),
                action: nil, keyEquivalent: ""
            )
            warn.isEnabled = false
            warn.image = symbol("exclamationmark.triangle")
            menu.addItem(warn)
        }

        // Hotkeys hint (disabled, informative)
        let hint = NSMenuItem(
            title: L.s("Хоткеи: ⌘⇧⌥S — сохранить, ⌘⇧⌥R — восстановить",
                       "Hotkeys: ⌘⇧⌥S save · ⌘⇧⌥R restore",
                       "快捷键:⌘⇧⌥S 保存 · ⌘⇧⌥R 还原"),
            action: nil, keyEquivalent: ""
        )
        hint.isEnabled = false
        hint.image = symbol("keyboard")
        menu.addItem(hint)

        let login = action(
            L.s("Запускать при входе", "Launch at Login", "登录时启动"),
            symbol: "arrow.up.circle",
            sel: #selector(toggleLaunchAtLogin)
        )
        login.state = isLoginEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(makeSyncMenuItem())

        // Excluded apps submenu (only when we have AX — otherwise useless)
        if isAccessible {
            menu.addItem(makeExcludedAppsMenu())
        }

        // Language submenu
        menu.addItem(makeLanguageMenu())

        menu.addItem(action(
            L.s("Показать приветствие…", "Show Welcome…", "显示欢迎页…"),
            symbol: "questionmark.circle",
            sel: #selector(showWelcome)
        ))

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: L.s("Закрыть WindowLayout", "Quit WindowLayout", "退出 WindowLayout"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.image = symbol("power")
        menu.addItem(quit)
    }

    // MARK: - Header

    private func makeHeader(isAccessible: Bool, profileCount: Int) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 50))

        let title = NSTextField(labelWithString: DisplayConfiguration.friendlyName())
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 14, y: 28, width: 252, height: 17)
        view.addSubview(title)

        let sub = NSTextField(labelWithString: headerSubtitle(isAccessible: isAccessible, count: profileCount))
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = isAccessible ? .secondaryLabelColor : .systemOrange
        sub.frame = NSRect(x: 14, y: 8, width: 252, height: 15)
        view.addSubview(sub)

        item.view = view
        return item
    }

    private func headerSubtitle(isAccessible: Bool, count: Int) -> String {
        if !isAccessible {
            return L.s("⚠️  Нужен Универсальный доступ",
                       "⚠️  Accessibility access required",
                       "⚠️  需要辅助功能权限")
        }
        if count == 0 {
            return L.s("Нет сохранённых расположений",
                       "No layouts saved for this setup",
                       "此配置尚无保存的布局")
        }
        let hint = L.s("· ⌥ удалить · ⌘ переименовать",
                       "· ⌥ delete · ⌘ rename",
                       "· ⌥ 删除 · ⌘ 重命名")
        return "\(L.layoutsCount(count)) \(hint)"
    }

    private func sectionHeader(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.frame = NSRect(x: 14, y: 2, width: 252, height: 14)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 18))
        view.addSubview(label)
        item.view = view
        return item
    }

    // MARK: - Profile items

    private func addProfileItems(_ profile: LayoutProfile) {
        let age = L.timeAgo(Int(Date().timeIntervalSince(profile.capturedAt)))

        let restore = NSMenuItem(title: profile.name, action: #selector(restoreProfile(_:)), keyEquivalent: "")
        restore.target = self
        restore.representedObject = profile.id.uuidString
        restore.image = symbol("arrow.counterclockwise.circle.fill")
        restore.attributedTitle = layoutTitleAttributed(name: profile.name, age: age)
        menu.addItem(restore)

        let deleteWord = L.s("Удалить", "Delete", "删除")
        let del = NSMenuItem(title: "\(deleteWord) «\(profile.name)»",
                             action: #selector(deleteProfile(_:)), keyEquivalent: "")
        del.target = self
        del.representedObject = profile.id.uuidString
        del.keyEquivalentModifierMask = .option
        del.isAlternate = true
        del.image = symbol("trash.fill")
        menu.addItem(del)

        let renameWord = L.s("Переименовать", "Rename", "重命名")
        let ren = NSMenuItem(title: "\(renameWord) «\(profile.name)»…",
                             action: #selector(renameProfile(_:)), keyEquivalent: "")
        ren.target = self
        ren.representedObject = profile.id.uuidString
        ren.keyEquivalentModifierMask = .command
        ren.isAlternate = true
        ren.image = symbol("pencil")
        menu.addItem(ren)
    }

    private func layoutTitleAttributed(name: String, age: String) -> NSAttributedString {
        let padding = String(repeating: " ", count: max(0, 28 - name.count))
        let full = "\(name)\(padding)\(age)"
        let attr = NSMutableAttributedString(string: full)
        attr.addAttributes([
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ], range: NSRange(location: 0, length: name.count))
        attr.addAttributes([
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ], range: NSRange(location: name.count, length: full.count - name.count))
        return attr
    }

    // MARK: - Excluded apps submenu

    private func makeExcludedAppsMenu() -> NSMenuItem {
        let parent = NSMenuItem(
            title: L.s("Исключённые приложения", "Excluded Apps", "排除的应用"),
            action: nil, keyEquivalent: ""
        )
        parent.image = symbol("hand.raised")

        let sub = NSMenu()
        sub.autoenablesItems = false

        let excluded = Set(UserDefaults.standard.stringArray(forKey: "excludedApps") ?? [])
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        if apps.isEmpty {
            let empty = NSMenuItem(title: L.s("Нет запущенных", "None running", "无运行中"),
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        } else {
            for app in apps {
                guard let name = app.localizedName, let bid = app.bundleIdentifier else { continue }
                let it = NSMenuItem(title: name, action: #selector(toggleExcludedApp(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = bid
                it.state = excluded.contains(bid) ? .on : .off
                sub.addItem(it)
            }
        }

        if !excluded.isEmpty {
            sub.addItem(.separator())
            let clear = NSMenuItem(
                title: L.s("Очистить список", "Clear all exclusions", "清除全部"),
                action: #selector(clearExcludedApps), keyEquivalent: ""
            )
            clear.target = self
            sub.addItem(clear)
        }

        parent.submenu = sub
        return parent
    }

    @objc private func toggleExcludedApp(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        var set = Set(UserDefaults.standard.stringArray(forKey: "excludedApps") ?? [])
        if set.contains(bid) { set.remove(bid) } else { set.insert(bid) }
        UserDefaults.standard.set(Array(set), forKey: "excludedApps")
        refreshMenu()
    }

    @objc private func clearExcludedApps() {
        UserDefaults.standard.removeObject(forKey: "excludedApps")
        refreshMenu()
    }

    // MARK: - Language submenu

    private func makeLanguageMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: L.s("Язык", "Language", "语言"),
                                action: nil, keyEquivalent: "")
        parent.image = symbol("globe")

        let sub = NSMenu()
        let current = L.userPreference
        for lang in L.Lang.allCases {
            let item = NSMenuItem(title: lang.displayName,
                                  action: #selector(setLanguage(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = lang.rawValue
            item.state = (lang == current) ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let lang = L.Lang(rawValue: raw) else { return }
        L.userPreference = lang
        refreshMenu()
        // Update tooltip after language change
        if let button = statusItem.button {
            button.toolTip = L.s("WindowLayout — расположения окон",
                                 "WindowLayout — window arrangements",
                                 "WindowLayout — 窗口布局")
        }
    }

    // MARK: - Helpers

    private func action(_ title: String, symbol: String, sel: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        mi.image = self.symbol(symbol)
        return mi
    }

    private func symbol(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }

    // MARK: - Launch at Login

    private var isLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @objc private func toggleLaunchAtLogin() {
        do {
            if isLoginEnabled { try SMAppService.mainApp.unregister() }
            else              { try SMAppService.mainApp.register() }
        } catch { }
        refreshMenu()
    }

    // MARK: - Actions

    @objc private func promptSaveLayout() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = L.s("Сохранить расположение", "Save Layout", "保存布局")
        alert.informativeText = L.s(
            "Назови это расположение окон. Можешь восстановить его в любой момент.",
            "Name this window arrangement. You can restore it anytime.",
            "为此布局命名。你可以随时还原。"
        )
        alert.alertStyle = .informational

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = LayoutManager.shared.suggestedNameForNewLayout()
        input.placeholderString = L.s("Название", "Layout name", "布局名称")
        input.bezelStyle = .roundedBezel
        alert.accessoryView = input

        alert.addButton(withTitle: L.s("Сохранить", "Save", "保存"))
        alert.addButton(withTitle: L.s("Отмена", "Cancel", "取消"))

        DispatchQueue.main.async { input.selectText(nil) }

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = name.isEmpty ? LayoutManager.shared.suggestedNameForNewLayout() : name
            if LayoutManager.shared.saveCurrentLayout(name: finalName) != nil {
                flashIconSuccess()
                refreshMenu()
            } else {
                // Empty capture — usually means AX permission missing or every app excluded.
                let warn = NSAlert()
                warn.messageText = L.s("Не удалось сохранить расположение",
                                       "Couldn't save the layout",
                                       "无法保存布局")
                warn.informativeText = L.s(
                    "Не получилось захватить ни одного окна. Проверь, что Универсальный доступ разрешён в Системных настройках, и что не все приложения исключены.",
                    "Couldn't capture any windows. Check that Accessibility access is granted in System Settings and that not every app is on the exclusion list.",
                    "未能捕获任何窗口。请检查系统设置中是否已授予辅助功能权限,以及是否所有应用都被排除了。"
                )
                warn.alertStyle = .warning
                warn.runModal()
            }
        }
    }

    @objc private func restoreProfile(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString) else { return }
        LayoutManager.shared.restoreLayout(id: id)
        // Same gate as the hotkey path — don't claim success when AX is denied or
        // every captured app has since quit (nothing to move).
        if LayoutManager.shared.lastApplyMovedWindows {
            flashIconSuccess()
        }
    }

    @objc private func deleteProfile(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString) else { return }
        LayoutManager.shared.deleteProfile(id: id)
        refreshMenu()
    }

    @objc private func renameProfile(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString),
              let profile = LayoutManager.shared.profile(id: id) else { return }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = L.s("Переименовать расположение", "Rename Layout", "重命名布局")
        alert.informativeText = L.s("Введи новое название.", "Enter a new name.", "请输入新名称。")
        alert.alertStyle = .informational

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = profile.name
        input.bezelStyle = .roundedBezel
        alert.accessoryView = input

        alert.addButton(withTitle: L.s("Сохранить", "Save", "保存"))
        alert.addButton(withTitle: L.s("Отмена", "Cancel", "取消"))

        DispatchQueue.main.async { input.selectText(nil) }

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                LayoutManager.shared.renameProfile(id: id, to: name)
                refreshMenu()
            }
        }
    }

    @objc private func toggleAutoRestore() {
        let key = "autoRestore"
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        refreshMenu()
    }

    // MARK: - iCloud sync menu

    private func makeSyncMenuItem() -> NSMenuItem {
        let sync = iCloudSync.shared
        let count = LayoutManager.shared.allProfiles.filter { $0.deletedAt == nil && $0.isAutoSnapshot != true }.count

        let title: String
        if !sync.isAvailable {
            title = L.s("Синхронизация iCloud (iCloud Drive выключен)",
                        "Sync via iCloud (iCloud Drive disabled)",
                        "iCloud 同步(iCloud Drive 未启用)")
        } else if sync.enabled, let date = sync.lastSyncedAt {
            let age = L.timeAgo(Int(Date().timeIntervalSince(date)))
            title = L.s("Синхронизация iCloud · \(count) · \(age)",
                        "Sync via iCloud · \(count) layouts · \(age)",
                        "iCloud 同步 · \(count) 个 · \(age)")
        } else if sync.enabled {
            title = L.s("Синхронизация iCloud · ожидает первого сохранения",
                        "Sync via iCloud · waiting for first save",
                        "iCloud 同步 · 等待首次保存")
        } else {
            title = L.s("Синхронизация iCloud",
                        "Sync via iCloud",
                        "iCloud 同步")
        }
        let item = action(title, symbol: "icloud", sel: #selector(toggleSync))
        item.state = sync.enabled ? .on : .off
        item.isEnabled = sync.isAvailable

        if sync.enabled, sync.isAvailable {
            // Submenu: reveal in Finder + folder path
            let sub = NSMenu()
            let reveal = NSMenuItem(
                title: L.s("Показать в Finder", "Reveal in Finder", "在 Finder 中显示"),
                action: #selector(revealSyncFolder), keyEquivalent: ""
            )
            reveal.target = self
            sub.addItem(reveal)
            item.submenu = sub
        }
        return item
    }

    @objc private func toggleSync() {
        let wasEnabled = iCloudSync.shared.enabled
        iCloudSync.shared.enabled.toggle()
        if iCloudSync.shared.enabled {
            // Push current profiles so the iCloud copy reflects current state.
            LayoutManager.shared.kickPush()
            // Visual confirmation — same flash as save/restore so user knows it worked.
            flashIconSuccess()
            // If folder was just created, reveal it so the user can see it exists.
            if !wasEnabled, let folder = iCloudSync.shared.syncFolderURL,
               FileManager.default.fileExists(atPath: folder.path) {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }
        refreshMenu()
    }

    @objc private func revealSyncFolder() {
        guard let folder = iCloudSync.shared.syncFolderURL else { return }
        // Folder may be missing if sync was just disabled and macOS hasn't created it yet,
        // or if the user manually deleted it. Create on demand so Finder always opens
        // *something* and the user gets visible feedback.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func showWelcome() {
        (NSApp.delegate as? AppDelegate)?.showOnboarding()
    }
}
