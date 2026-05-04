import AppKit

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    private var permissionTimer: Timer?
    private var permissionStatusLabel: NSTextField?
    private var permissionButton: NSButton?
    private var permissionCard: NSView?
    private var permissionIcon: NSImageView?

    private static let W: CGFloat = 880
    private static let H: CGFloat = 600
    private static let hPad: CGFloat = 40
    private static let colGap: CGFloat = 40
    private static var colWidth: CGFloat { (W - 2 * hPad - colGap) / 2 }
    private static var leftColX: CGFloat { hPad }
    private static var rightColX: CGFloat { hPad + colWidth + colGap }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.W, height: Self.H),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L.s("Приветствие", "Welcome", "欢迎")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.center()

        self.init(window: window)
        window.delegate = self
        setupContent()
        refreshPermissionState()
    }

    func windowWillClose(_ notification: Notification) {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    /// Convert top-origin y to AppKit bottom-origin y.
    private func top(_ topY: CGFloat, _ height: CGFloat) -> CGFloat {
        Self.H - topY - height
    }

    private func setupContent() {
        guard let window, let content = window.contentView else { return }

        // Background blur
        let effect = NSVisualEffectView(frame: content.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .windowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        content.addSubview(effect)

        addHeroGlow(to: content)
        addHero(to: content)
        addLanguageSwitcher(to: content)
        addDivider(to: content, atTopY: 220)

        // Two-column section labels at the same y, columns side by side.
        addSectionLabel(L.s("Как это работает", "How it works", "工作原理"),
                        to: content, atTopY: 234, x: Self.leftColX)
        addSectionLabel(L.s("Возможности", "Features", "功能"),
                        to: content, atTopY: 234, x: Self.rightColX)

        addSteps(to: content, startTopY: 262)
        addFeatures(to: content, startTopY: 262)

        addDivider(to: content, atTopY: 446)
        addPermissionCard(to: content, topY: 462)
        addFooter(to: content)
    }

    // MARK: - Hero glow

    /// Soft radial accent halo behind the app icon. Anchors the icon visually so it
    /// doesn't float in space.
    private func addHeroGlow(to content: NSView) {
        let glowSize: CGFloat = 260
        let glow = NSView(frame: NSRect(
            x: (Self.W - glowSize) / 2,
            y: top(20, glowSize),
            width: glowSize, height: glowSize
        ))
        glow.wantsLayer = true
        let layer = CAGradientLayer()
        layer.frame = glow.bounds
        layer.type = .radial
        layer.colors = [
            NSColor.controlAccentColor.withAlphaComponent(0.32).cgColor,
            NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor,
            NSColor.controlAccentColor.withAlphaComponent(0).cgColor
        ]
        layer.locations = [0.0, 0.5, 1.0]
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 1)
        glow.layer?.addSublayer(layer)
        content.addSubview(glow)
    }

    // MARK: - Hero

    private func addHero(to content: NSView) {
        let W = Self.W

        // App icon
        let iconSize: CGFloat = 96
        let iconView = NSImageView(frame: NSRect(
            x: (W - iconSize) / 2, y: top(44, iconSize),
            width: iconSize, height: iconSize
        ))
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: path) {
            iconView.image = icon
        } else {
            let cfg = NSImage.SymbolConfiguration(pointSize: 72, weight: .medium)
            iconView.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
            iconView.contentTintColor = .controlAccentColor
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(iconView)

        // Title
        let title = NSTextField(labelWithString: L.s(
            "Добро пожаловать в WindowLayout",
            "Welcome to WindowLayout",
            "欢迎使用 WindowLayout"
        ))
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = .labelColor
        title.alignment = .center
        title.frame = NSRect(x: 20, y: top(156, 28), width: W - 40, height: 28)
        content.addSubview(title)

        // Subtitle
        let sub = NSTextField(wrappingLabelWithString: L.s(
            "Расставил окна один раз — они возвращаются сами, как только подключишь тот же монитор.",
            "Arrange once — your windows come back the same way every time you reconnect.",
            "布置一次,重连显示器时窗口自动回到原位。"
        ))
        sub.font = .systemFont(ofSize: 13)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        sub.isSelectable = false
        sub.frame = NSRect(x: 70, y: top(192, 38), width: W - 140, height: 38)
        content.addSubview(sub)
    }

    // MARK: - Language switcher

    private func addLanguageSwitcher(to content: NSView) {
        let popup = NSPopUpButton(frame: NSRect(
            x: Self.W - 132, y: top(16, 22), width: 116, height: 22
        ))
        popup.bezelStyle = .rounded
        popup.addItems(withTitles: L.Lang.allCases.map(\.displayName))
        if let idx = L.Lang.allCases.firstIndex(of: L.userPreference) {
            popup.selectItem(at: idx)
        }
        popup.target = self
        popup.action = #selector(changeLanguage(_:))
        content.addSubview(popup)
    }

    // MARK: - Steps

    private func addSteps(to content: NSView, startTopY: CGFloat) {
        let steps: [(symbol: String, title: String, body: String)] = [
            (
                "macwindow.on.rectangle",
                L.s("Расставь окна",
                    "Arrange your windows",
                    "布置好窗口"),
                L.s("Подключи мониторы и открой приложения так, как привык работать.",
                    "Plug in your monitors, open your apps, set them up how you like.",
                    "接好显示器，按你的习惯打开应用。")
            ),
            (
                "square.and.arrow.down.fill",
                L.s("Сохрани расположение",
                    "Save the layout",
                    "保存布局"),
                L.s("Кликни иконку в статус-баре → «Сохранить». Можно держать несколько — для работы, звонков, отдыха.",
                    "Click the menu bar icon → Save. Keep several — one for work, one for calls, one for chilling.",
                    "点击状态栏图标 →「保存」。可保存多个布局——工作、会议、休闲。")
            ),
            (
                "arrow.triangle.2.circlepath",
                L.s("Уходи и возвращайся",
                    "Walk away, come back",
                    "走开，回来"),
                L.s("Отключил монитор — свернул ноут. Подключил обратно — окна уже на местах.",
                    "Unplug, roam, plug back in. Windows are exactly where you left them.",
                    "拔掉显示器带着笔记本走。重新连接时，窗口原样还原。")
            )
        ]

        let rowH: CGFloat = 58
        for (i, item) in steps.enumerated() {
            addIconRow(to: content,
                       symbol: item.symbol,
                       tint: .controlAccentColor,
                       title: item.title,
                       body: item.body,
                       rowTop: startTopY + CGFloat(i) * rowH,
                       colX: Self.leftColX, colW: Self.colWidth)
        }
    }

    // MARK: - Features

    /// Same icon-in-tinted-circle pattern as steps, but each feature uses its own
    /// hue so the row carries some color variety instead of all-blue.
    private func addFeatures(to content: NSView, startTopY: CGFloat) {
        let items: [(symbol: String, tint: NSColor, title: String, body: String)] = [
            (
                "icloud.fill", .systemBlue,
                L.s("iCloud-синхронизация",
                    "iCloud sync",
                    "iCloud 同步"),
                L.s("Расположения переносятся между всеми твоими Маками.",
                    "Layouts follow you between all your Macs.",
                    "布局在所有 Mac 之间同步。")
            ),
            (
                "command", .systemIndigo,
                L.s("Глобальные хоткеи",
                    "Global hotkeys",
                    "全局快捷键"),
                "⌘⇧⌥S — " + L.s("сохранить", "save", "保存")
                    + " · ⌘⇧⌥R — " + L.s("восстановить", "restore", "还原") + "."
            ),
            (
                "rectangle.stack.fill", .systemPurple,
                L.s("Дружит со Stage Manager",
                    "Stage Manager aware",
                    "支持 Stage Manager"),
                L.s("Когда он активен, автовосстановление приостанавливается.",
                    "Auto-restore pauses when Stage Manager is on.",
                    "Stage Manager 开启时暂停自动还原。")
            )
        ]

        let rowH: CGFloat = 58
        for (i, item) in items.enumerated() {
            addIconRow(to: content,
                       symbol: item.symbol,
                       tint: item.tint,
                       title: item.title,
                       body: item.body,
                       rowTop: startTopY + CGFloat(i) * rowH,
                       colX: Self.rightColX, colW: Self.colWidth)
        }
    }

    // MARK: - Shared icon row

    /// One row of: 36×36 tinted circle with SF Symbol + bold title + secondary body.
    /// Used by both Steps and Features for visual consistency.
    /// `colX` and `colW` allow placing the row in either the left or right column.
    private func addIconRow(to content: NSView, symbol: String, tint: NSColor,
                            title: String, body: String, rowTop: CGFloat,
                            colX: CGFloat, colW: CGFloat) {
        let circleSize: CGFloat = 36
        let circle = NSView(frame: NSRect(
            x: colX, y: top(rowTop + 4, circleSize),
            width: circleSize, height: circleSize
        ))
        circle.wantsLayer = true
        circle.layer?.cornerRadius = circleSize / 2
        circle.layer?.backgroundColor = tint.withAlphaComponent(0.15).cgColor
        content.addSubview(circle)

        let iconSize: CGFloat = 18
        let iconView = NSImageView(frame: NSRect(
            x: 0, y: (circleSize - iconSize) / 2,
            width: circleSize, height: iconSize
        ))
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iconView.contentTintColor = tint
        iconView.imageAlignment = .alignCenter
        circle.addSubview(iconView)

        let textX = colX + circleSize + 14
        let textW = colW - circleSize - 14

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: textX, y: top(rowTop + 3, 18), width: textW, height: 18)
        content.addSubview(titleLabel)

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.isSelectable = false
        bodyLabel.frame = NSRect(x: textX, y: top(rowTop + 23, 30), width: textW, height: 30)
        content.addSubview(bodyLabel)
    }

    // MARK: - Permission card

    private func addPermissionCard(to content: NSView, topY: CGFloat) {
        let cardH: CGFloat = 56
        let card = NSView(frame: NSRect(
            x: Self.hPad, y: top(topY, cardH),
            width: Self.W - 2 * Self.hPad, height: cardH
        ))
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        // Tint adjusted dynamically in refreshPermissionState — green when granted,
        // neutral grey when not.
        card.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.10).cgColor
        content.addSubview(card)
        permissionCard = card

        let iconSize: CGFloat = 22
        let lockIcon = NSImageView(frame: NSRect(
            x: 16, y: (cardH - iconSize) / 2, width: iconSize, height: iconSize
        ))
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        lockIcon.image = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconCfg)
        lockIcon.contentTintColor = .controlAccentColor
        card.addSubview(lockIcon)
        permissionIcon = lockIcon

        let permTitle = NSTextField(labelWithString: L.s(
            "Универсальный доступ",
            "Accessibility Access",
            "辅助功能权限"
        ))
        permTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        permTitle.textColor = .labelColor
        permTitle.frame = NSRect(x: 48, y: cardH - 26, width: 240, height: 18)
        card.addSubview(permTitle)

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 48, y: 10, width: 300, height: 14)
        card.addSubview(statusLabel)
        permissionStatusLabel = statusLabel

        let btn = NSButton(title: L.s("Разрешить", "Grant", "授权"),
                           target: self, action: #selector(grantPermission))
        btn.bezelStyle = .rounded
        btn.controlSize = .regular
        let btnW: CGFloat = 96
        let btnH: CGFloat = 26
        btn.frame = NSRect(x: card.frame.width - btnW - 14, y: (cardH - btnH) / 2,
                           width: btnW, height: btnH)
        card.addSubview(btn)
        permissionButton = btn
    }

    // MARK: - Footer

    private func addFooter(to content: NSView) {
        let footerTop: CGFloat = 540
        let footerH: CGFloat = 32

        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let version = NSTextField(labelWithString: "v\(v) · MIT License · Open Source")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .tertiaryLabelColor
        version.frame = NSRect(x: Self.hPad, y: top(footerTop + 6, 16),
                               width: 260, height: 16)
        content.addSubview(version)

        let btn = NSButton(title: L.s("Начать", "Get Started", "开始"),
                           target: self, action: #selector(getStarted))
        btn.bezelStyle = .rounded
        btn.keyEquivalent = "\r"
        btn.controlSize = .large
        let btnW: CGFloat = 128
        btn.frame = NSRect(x: Self.W - Self.hPad - btnW,
                           y: top(footerTop, footerH),
                           width: btnW, height: footerH)
        content.addSubview(btn)
    }

    // MARK: - Section label

    private func addSectionLabel(_ text: String, to content: NSView, atTopY topY: CGFloat,
                                  x: CGFloat? = nil, width: CGFloat? = nil) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .tertiaryLabelColor
        let fx = x ?? Self.hPad
        let fw = width ?? (Self.W - 2 * Self.hPad)
        label.frame = NSRect(x: fx, y: top(topY, 14), width: fw, height: 14)
        content.addSubview(label)
    }

    // MARK: - Divider

    private func addDivider(to content: NSView, atTopY topY: CGFloat) {
        let div = NSBox(frame: NSRect(
            x: Self.hPad, y: top(topY, 1),
            width: Self.W - 2 * Self.hPad, height: 1
        ))
        div.boxType = .separator
        content.addSubview(div)
    }

    // MARK: - Permission logic

    private func refreshPermissionState() {
        let granted = AXIsProcessTrusted()
        if granted {
            permissionStatusLabel?.stringValue = L.s("Разрешено — можно работать",
                                                     "Granted — you're good to go",
                                                     "已授权 — 可以开始使用")
            permissionStatusLabel?.textColor = .systemGreen
            permissionButton?.isHidden = true
            // Green tint when granted — calmer, less attention-grabbing.
            permissionCard?.layer?.backgroundColor =
                NSColor.systemGreen.withAlphaComponent(0.10).cgColor
            permissionIcon?.image = NSImage(systemSymbolName: "checkmark.shield.fill",
                                            accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .medium))
            permissionIcon?.contentTintColor = .systemGreen
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else {
            permissionStatusLabel?.stringValue = L.s(
                "Нужно, чтобы двигать окна за тебя",
                "So the app can actually move windows for you",
                "需要此权限以便替你移动窗口"
            )
            permissionStatusLabel?.textColor = .secondaryLabelColor
            permissionButton?.isHidden = false
            // Yellow/orange tint when missing — gently flags it as actionable.
            permissionCard?.layer?.backgroundColor =
                NSColor.systemOrange.withAlphaComponent(0.12).cgColor
            permissionIcon?.image = NSImage(systemSymbolName: "lock.shield.fill",
                                            accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .medium))
            permissionIcon?.contentTintColor = .systemOrange
        }
    }

    @objc private func grantPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        startPolling()
    }

    private func startPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if AXIsProcessTrusted() {
                DispatchQueue.main.async { self.refreshPermissionState() }
            }
        }
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
        refreshPermissionState()
    }

    @objc private func getStarted() {
        window?.close()
    }

    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0 && idx < L.Lang.allCases.count else { return }
        L.userPreference = L.Lang.allCases[idx]

        let delegate = NSApp.delegate as? AppDelegate
        delegate?.statusBarController?.refreshMenu()

        window?.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            delegate?.showOnboarding()
        }
    }
}
