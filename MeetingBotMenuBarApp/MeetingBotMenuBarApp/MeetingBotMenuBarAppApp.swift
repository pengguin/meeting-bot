import AppKit
import Combine
import SwiftUI
import UserNotifications

@main
struct MeetingBotMenuBarAppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置...") {
                    appDelegate.openSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = BotRuntimeStore()
    private let libraryStore = MeetingLibraryStore()
    private let configStore = RuntimeConfigStore()
    private let templateStore = MeetingTemplateCatalogStore()
    private let bootstrapInstallerStore = BootstrapInstallerStore()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var popoverHostingController: NSHostingController<MeetingBotMenuView>?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var setupWizardWindow: NSWindow?
    private var bootstrapInstallWindow: NSWindow?
    private var newMeetingWindow: NSWindow?
    private var transcriptWindows: [String: NSWindow] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var acknowledgedStatusSignature: String?
    private var statusIconAnimationTimer: Timer?
    private var processingAnimationFrame = 0

    private static let processingAnimationFrameCount = 24

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        setupStatusItem()
        setupPopover()
        setupMainWindow()
        setupSettingsWindow()
        createSetupWizardWindow()
        createBootstrapInstallWindow()
        observeStatusIcon()
        observeAppearanceChanges()
        if bootstrapInstallerStore.needsInstallation {
            openBootstrapInstallWindow()
            runBootstrapInstall()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.presentInitialWindow()
            }
        }
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 440, height: 480)
        popover.behavior = .transient
        popover.animates = true
        let hostingController = NSHostingController(
            rootView: MeetingBotMenuView(
                store: store,
                openMainWindow: { [weak self] in
                    self?.openMainWindow()
                }
            )
        )
        popover.contentViewController = hostingController
        popoverHostingController = hostingController
        self.popover = popover
        updatePopoverSize()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else {
            return
        }

        button.image = makeStatusBarImage()
        button.contentTintColor = nil
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupMainWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "会议纪要助手"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: MainWindowView(
                runtimeStore: store,
                libraryStore: libraryStore,
                templateStore: templateStore,
                openTranscriptWindow: { [weak self] meeting in
                    self?.openTranscriptWindow(for: meeting)
                },
                openNewMeetingWindow: { [weak self] in
                    self?.openNewMeetingWindow()
                },
                openSettingsWindow: { [weak self] in
                    self?.openSettingsWindow()
                }
            )
        )
        self.mainWindow = window
    }

    private func setupSettingsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: SettingsWindowView(
                runtimeStore: store,
                libraryStore: libraryStore,
                configStore: configStore,
                templateStore: templateStore
            )
            .tint(.brandAccent)
        )
        self.settingsWindow = window
    }

    private var shouldPresentSetupWizard: Bool {
        !UserDefaults.standard.bool(forKey: "setupWizardCompleted")
            || !configStore.isCoreConfigComplete
    }

    private func createSetupWizardWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "首次启动配置"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: SetupWizardWindowView(
                runtimeStore: store,
                configStore: configStore,
                finish: { [weak self] in
                    self?.setupWizardWindow?.close()
                    self?.openMainWindow()
                }
            )
        )
        self.setupWizardWindow = window
    }

    private func createBootstrapInstallWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = bootstrapInstallerStore.installationModeTitle
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: BootstrapInstallWindowView(
                store: bootstrapInstallerStore,
                retry: { [weak self] in
                    self?.runBootstrapInstall()
                }
            )
        )
        self.bootstrapInstallWindow = window
    }

    private func observeStatusIcon() {
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusIcon()
                    if self?.popover?.isShown == true {
                        self?.updatePopoverSize()
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func observeAppearanceChanges() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func systemAppearanceChanged() {
        let preferredMode = UserDefaults.standard.string(forKey: "preferredMainColorScheme") ?? "system"
        if preferredMode == "system" {
            AppAppearance.synchronizeWindows(for: preferredMode)
        }
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        synchronizeStatusIconAnimation()
        renderStatusIcon()
    }

    private func renderStatusIcon() {
        statusItem?.button?.image = makeStatusBarImage()
        statusItem?.button?.contentTintColor = nil
    }

    private func makeStatusBarImage() -> NSImage? {
        let iconStyleRaw = UserDefaults.standard.string(forKey: AppPreferenceKeys.statusBarIconStyle)
            ?? StatusBarIconStyle.waveform.rawValue
        let iconStyle = StatusBarIconStyle(rawValue: iconStyleRaw) ?? .waveform
        let tintColor = statusBarIconColorMode().tintColor

        if shouldAnimateProcessingStatusIcon {
            return makeAnimatedProcessingStatusImage(
                iconStyle: iconStyle,
                tintColor: tintColor
            )
        }

        guard let image = NSImage(
            systemSymbolName: iconStyle.symbol(
                launchStatus: store.launchStatus,
                taskStatus: effectiveTaskStatusForStatusIcon
            ),
            accessibilityDescription: "会议纪要助手"
        ) else {
            return nil
        }

        if let configuredImage = image.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [tintColor])
        ) {
            configuredImage.isTemplate = false
            return configuredImage.tinted(with: tintColor)
        }

        return image.tinted(with: tintColor)
    }

    private func synchronizeStatusIconAnimation() {
        guard shouldAnimateProcessingStatusIcon else {
            statusIconAnimationTimer?.invalidate()
            statusIconAnimationTimer = nil
            processingAnimationFrame = 0
            return
        }

        guard statusIconAnimationTimer == nil else {
            return
        }

        processingAnimationFrame = 0
        let timer = Timer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(advanceProcessingAnimation),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        statusIconAnimationTimer = timer
    }

    @objc private func advanceProcessingAnimation() {
        processingAnimationFrame =
            (processingAnimationFrame + 1) % Self.processingAnimationFrameCount
        renderStatusIcon()
    }

    private var shouldAnimateProcessingStatusIcon: Bool {
        guard store.launchStatus != .missing,
              store.launchStatus != .stopped,
              let runtimeStatus = store.runtimeStatus else {
            return false
        }

        return runtimeStatus.taskStatus == "processing"
    }

    private func makeAnimatedProcessingStatusImage(
        iconStyle: StatusBarIconStyle,
        tintColor: NSColor
    ) -> NSImage? {
        let phase = CGFloat(processingAnimationFrame)
            / CGFloat(Self.processingAnimationFrameCount) * 2 * .pi

        switch iconStyle {
        case .waveform:
            return Self.equalizerStatusImage(tint: tintColor, phase: phase)
        case .pulse:
            return Self.bouncingDotsStatusImage(tint: tintColor, phase: phase)
        }
    }

    /// 均衡器样式：5 根圆角竖条按行波相位起伏，模拟正在播放的音频电平。
    private static func equalizerStatusImage(tint: NSColor, phase: CGFloat) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let barCount = 5
            let barWidth: CGFloat = 2.4
            let gap: CGFloat = 1.2
            let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
            var x = (size.width - totalWidth) / 2
            let midY = size.height / 2

            tint.setFill()
            for index in 0..<barCount {
                let wave = sin(phase - CGFloat(index) * 0.85)
                let height = 5 + 4.5 * (1 + wave)
                let rect = NSRect(
                    x: x,
                    y: midY - height / 2,
                    width: barWidth,
                    height: height
                )
                NSBezierPath(
                    roundedRect: rect,
                    xRadius: barWidth / 2,
                    yRadius: barWidth / 2
                ).fill()
                x += barWidth + gap
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "正在处理会议"
        return image
    }

    /// 脉冲样式：3 个圆点依次弹跳，类似输入中指示器。
    private static func bouncingDotsStatusImage(tint: NSColor, phase: CGFloat) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let dotCount = 3
            let radius: CGFloat = 2.1
            let spacing: CGFloat = 5.6
            let firstX = size.width / 2 - spacing

            tint.setFill()
            for index in 0..<dotCount {
                let bounce = abs(sin(phase - CGFloat(index) * 1.05))
                let centerY = 6.5 + 4.5 * bounce
                let rect = NSRect(
                    x: firstX + CGFloat(index) * spacing - radius,
                    y: centerY - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                NSBezierPath(ovalIn: rect).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "正在处理会议"
        return image
    }

    private func statusBarIconColorMode() -> StatusBarIconColorMode {
        let colorModeRaw = UserDefaults.standard.string(forKey: AppPreferenceKeys.statusBarIconColorMode)
            ?? StatusBarIconColorMode.white.rawValue
        return StatusBarIconColorMode(rawValue: colorModeRaw) ?? .white
    }

    private var statusIconAttentionSignature: String? {
        guard let runtimeStatus = store.runtimeStatus,
              runtimeStatus.taskStatus == "done" || runtimeStatus.taskStatus == "error" else {
            return nil
        }

        return [
            runtimeStatus.taskStatus,
            runtimeStatus.stage,
            runtimeStatus.sessionID,
            runtimeStatus.updatedAt,
        ].joined(separator: "|")
    }

    private var effectiveTaskStatusForStatusIcon: String? {
        guard let signature = statusIconAttentionSignature else {
            return store.runtimeStatus?.taskStatus
        }

        return acknowledgedStatusSignature == signature ? "idle" : store.runtimeStatus?.taskStatus
    }

    private func resetStatusIndicatorIfNeeded() {
        guard let signature = statusIconAttentionSignature else {
            return
        }

        acknowledgedStatusSignature = signature
        updateStatusIcon()
    }

    private func updatePopoverSize() {
        guard let popover, let popoverHostingController else {
            return
        }

        let fittingSize = popoverHostingController.sizeThatFits(
            in: NSSize(width: 440, height: 10_000)
        )
        let height = max(1, fittingSize.height)
        popover.contentSize = NSSize(width: 440, height: height)
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        resetStatusIndicatorIfNeeded()
        guard let event = NSApp.currentEvent else {
            guard ensureBootstrapReady() else {
                return
            }
            togglePopover(sender)
            return
        }

        if event.type == .rightMouseUp {
            showStatusMenu()
        } else {
            guard ensureBootstrapReady() else {
                return
            }
            togglePopover(sender)
        }
    }

    @objc private func openMainWindow() {
        guard ensureBootstrapReady() else {
            return
        }
        resetStatusIndicatorIfNeeded()
        revealMainWindow()
    }

    private func revealMainWindow() {
        resetStatusIndicatorIfNeeded()
        popover?.performClose(nil)
        store.refresh()
        libraryStore.reload()
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        mainWindow?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettingsWindow() {
        guard ensureBootstrapReady() else {
            return
        }
        popover?.performClose(nil)
        store.refresh()
        libraryStore.reloadMetadata()
        configStore.reload()
        templateStore.reload()
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSetupWizardWindow() {
        store.refresh()
        configStore.reload()
        NSApp.setActivationPolicy(.regular)
        setupWizardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openBootstrapInstallWindow() {
        NSApp.setActivationPolicy(.regular)
        bootstrapInstallWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func runBootstrapInstall() {
        bootstrapInstallerStore.start { [weak self] succeeded in
            guard let self, succeeded else {
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.configStore.reload()
                self.templateStore.reload()
                self.libraryStore.reload()
                self.store.refresh()
                self.presentInitialWindowAfterBootstrap()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.bootstrapInstallWindow?.close()
                    self.presentInitialWindowAfterBootstrap()
                }
            }
        }
    }

    private func presentInitialWindow() {
        if shouldPresentSetupWizard {
            openSetupWizardWindow()
        } else {
            openMainWindow()
        }
    }

    private func presentInitialWindowAfterBootstrap() {
        if shouldPresentSetupWizard {
            openSetupWizardWindow()
        } else {
            revealMainWindow()
        }
    }

    @discardableResult
    private func ensureBootstrapReady() -> Bool {
        guard bootstrapInstallerStore.needsInstallation else {
            return true
        }

        popover?.performClose(nil)
        openBootstrapInstallWindow()
        return false
    }

    private func openTranscriptWindow(for meeting: MeetingRecord) {
        if let existingWindow = transcriptWindows[meeting.sessionID] {
            NSApp.setActivationPolicy(.regular)
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "原始转录 - \(meeting.title)"
        window.identifier = NSUserInterfaceItemIdentifier(meeting.sessionID)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: TranscriptEditorWindowView(
                store: libraryStore,
                meeting: meeting
            )
            .tint(.brandAccent)
        )
        transcriptWindows[meeting.sessionID] = window

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openNewMeetingWindow() {
        if let newMeetingWindow {
            NSApp.setActivationPolicy(.regular)
            newMeetingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "新增会议"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: NewMeetingWindowView(
                store: libraryStore,
                templateStore: templateStore,
                onCompleted: { [weak self] result, openAfterCreation in
                    self?.completeNewMeeting(result: result, openAfterCreation: openAfterCreation)
                }
            )
            .tint(.brandAccent)
        )
        newMeetingWindow = window

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func completeNewMeeting(
        result: LocalMeetingCreationResult,
        openAfterCreation: MeetingOpenAfterCreation
    ) {
        newMeetingWindow?.close()
        revealMainWindow()
        if let url = result.fileURL(for: openAfterCreation) {
            NSWorkspace.shared.open(url)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        guard ensureBootstrapReady() else {
            return
        }
        guard let popover else {
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            store.refresh()
            updatePopoverSize()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showStatusMenu() {
        resetStatusIndicatorIfNeeded()
        popover?.performClose(nil)
        let menu = NSMenu()
        if bootstrapInstallerStore.needsInstallation {
            menu.addItem(
                NSMenuItem(
                    title: "继续\(bootstrapInstallerStore.installationModeTitle)",
                    action: #selector(openBootstrapInstallWindowFromMenu),
                    keyEquivalent: ""
                )
            )
            menu.addItem(.separator())
            menu.addItem(
                NSMenuItem(
                    title: "退出",
                    action: #selector(quitApp),
                    keyEquivalent: "q"
                )
            )
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
            return
        }

        menu.addItem(
            NSMenuItem(
                title: "打开主界面",
                action: #selector(openMainWindow),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "设置",
                action: #selector(openSettingsWindow),
                keyEquivalent: ","
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "退出",
                action: #selector(quitApp),
                keyEquivalent: "q"
            )
        )

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openBootstrapInstallWindowFromMenu() {
        openBootstrapInstallWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        resetStatusIndicatorIfNeeded()
        guard ensureBootstrapReady() else {
            return true
        }
        if !flag {
            openMainWindow()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        resetStatusIndicatorIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusIconAnimationTimer?.invalidate()
        store.stopServiceOnTerminationIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else {
            return
        }

        let otherWindowVisible =
            (closingWindow !== mainWindow && mainWindow?.isVisible == true)
            || (closingWindow !== settingsWindow && settingsWindow?.isVisible == true)
            || (closingWindow !== newMeetingWindow && newMeetingWindow?.isVisible == true)
            || transcriptWindows.values.contains(where: { $0 !== closingWindow && $0.isVisible })

        if closingWindow === newMeetingWindow {
            newMeetingWindow = nil
        }
        if let sessionID = transcriptWindows.first(where: { $0.value === closingWindow })?.key {
            transcriptWindows.removeValue(forKey: sessionID)
        }

        if !otherWindowVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            self.resetStatusIndicatorIfNeeded()
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                self.openMainWindow()
            }
            completionHandler()
        }
    }
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let output = NSImage(size: size)
        output.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        color.set()
        rect.fill()
        draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
        output.unlockFocus()
        output.isTemplate = false
        return output
    }

}
