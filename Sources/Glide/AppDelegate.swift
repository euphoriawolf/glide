import AppKit
import AVFoundation
import Carbon
import GlideCore
import GlideVision
import Speech
import Vision

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let pipeline = Pipeline()
    private let settings = Settings.shared
    private let dictation = Dictation()
    private var statusItem: NSStatusItem!
    private var preview: PreviewPanel?
    private var overlay: ScreenOverlay?
    private var pill: ListeningPill?
    private var onboarding: OnboardingWindow?
    private var settingsWindow: SettingsWindow?
    private var testSession: TestSessionWindow?
    private var playground: PlaygroundWindow?
    private var hotKeys: [HotKey] = []
    private var holdKey: HoldKey?
    private var trustTimer: Timer?
    /// Recording while Glide works normally. GlideReplay shows what happened and when.
    private var useRecording: Date?
    private var useTimer: Timer?

    private var enabled = true
    private var mode: GestureMode = .idle
    private var cameraFailed = false
    /// --dictation-test: listen for 6 s and log the text, without typing it anywhere.
    private let dictationTest = CommandLine.arguments.contains("--dictation-test")

    private var cameraAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    private var trusted: Bool { AXIsProcessTrusted() }
    private var needsSetup: Bool { !cameraAllowed || !trusted || cameraFailed }
    /// In a lesson: gestures are seen but not acted on. The last screen of setup is not a lesson.
    private var practicing: Bool { (onboarding?.isVisible ?? false) && onboarding?.model.step != .done }

    /// A menu bar app has no menus, so ⌘V, ⌘C and ⌘Z do nothing in its own windows.
    /// This hidden Edit menu gives the playground's text box paste, which dictation uses.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        hotKeys = [
            HotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] in self?.toggleEnabled() },
            HotKey(keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey) { [weak self] in self?.togglePreview() },
        ]

        pipeline.apply(settings)
        settings.onChange = { [weak self] in
            guard let self else { return }
            self.pipeline.apply(self.settings)
            self.holdKey?.keyCode = self.settings.dictationKey.keyCode
            self.onboarding?.model.keyName = self.settings.dictationKey.title
        }
        pipeline.onSnapshot = { [weak self] s in self?.handle(s) }
        pipeline.onAction = { [weak self] a in
            guard let self else { return }
            switch a {
            case .talkStart: self.beginTalk()
            case .talkEnd: self.dictation.stop()
            case .pause(let paused):
                self.enabled = !paused
                self.refreshIcon()
                self.pill?.placeOnPointerScreen()
                self.dictation.model.flash(paused ? "Glide paused" : "Glide on")
            case .swipe(let d) where self.playground?.isKeyWindow == true:
                self.playground?.model.swipe(d)
                self.overlay?.show(a)
            default: if !self.practicing { self.overlay?.show(a) }
            }
        }

        overlay = ScreenOverlay()
        overlay?.orderFrontRegardless()
        setUpDictation()

        if cameraAllowed { startCamera() }
        if !settings.onboarded || needsSetup {
            showOnboarding()
        } else if settings.showPreview {
            setPreviewVisible(true)
        }
        watchTrust()
        refreshIcon()

        if CommandLine.arguments.contains("--playground") { showPlayground() }
        if dictationTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.dictation.start() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { self.dictation.stop() }
        }
        // Opens the test session and starts it at once. Used to check recording end to end.
        if CommandLine.arguments.contains("--record-test"), cameraAllowed {
            showTestSession()
            testSession?.model.begin()
        }
    }

    private func handle(_ s: TrackingSnapshot) {
        if s.enabled != enabled {
            enabled = s.enabled
            refreshIcon()
        }
        if s.mode != mode {
            mode = s.mode
            refreshIcon()
        }
        if let preview, preview.isVisible { preview.tracking.update(s) }
        if let testSession, testSession.isVisible { testSession.tracking.update(s) }
        if let playground, playground.isVisible {
            playground.tracking.update(s)
            playground.model.handSeen(s.palm != nil)
        }
        if practicing {
            onboarding?.update(s)
        } else {
            overlay?.update(s)
        }
    }

    // MARK: - Dictation

    private func setUpDictation() {
        pill = ListeningPill(model: dictation.model)
        let key = HoldKey(keyCode: settings.dictationKey.keyCode)
        key.onDown = { [weak self] in self?.beginTalk() }
        key.onUp = { [weak self] in self?.dictation.stop() }
        key.onCancel = { [weak self] in self?.dictation.cancel() }
        holdKey = key

        dictation.onFinal = { [weak self] text in
            guard let self else { return }
            if self.dictationTest {
                DictationLog.write("self-test result: \(text)")
            } else if self.practicing {
                self.onboarding?.model.voiceHeard(text)
            } else {
                TextInserter.insert(text)
            }
            self.refreshIcon()
        }
        // Feed the level to the voice practice ring.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.practicing, self.dictation.model.state == .listening else { return }
            self.onboarding?.model.voiceListening(self.dictation.model.level)
        }
    }

    /// Two fingers up, or the dictation key. Only into a text input.
    private func beginTalk() {
        guard Dictation.micAllowed else {
            DictationLog.write("talk: no microphone permission")
            return
        }
        if practicing {
            guard onboarding?.model.step == .voice else { return }
            dictation.start()
            return
        }
        let input = FocusedInput.current()
        pill?.placeOnPointerScreen()
        // nil: the app does not report its focus (some web and Electron apps). Allow it.
        DictationLog.write("talk: focused input isText=\(String(describing: input.isText))")
        if input.isText == false {
            dictation.model.flash("Click a text field first")
            return
        }
        dictation.start(fieldText: input.textBeforeCursor)
        refreshIcon()
    }

    private func requestMic() {
        Dictation.requestMic { [weak self] granted in
            if granted, SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                SFSpeechRecognizer.requestAuthorization { _ in }
            }
            self?.onboarding?.model.micGranted(granted)
        }
    }

    // MARK: - Camera and permissions

    private func startCamera() {
        cameraFailed = !pipeline.start()
        refreshIcon()
    }

    private func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                if granted { self.startCamera() }
                self.onboarding?.model.cameraGranted(granted)
                self.refreshIcon()
            }
        }
    }

    private func requestAccessibility() {
        // Adds Glide to the Accessibility list and shows the system prompt.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func watchTrust() {
        guard !trusted, trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self, self.trusted else { return }
            t.invalidate()
            self.trustTimer = nil
            self.refreshIcon()
        }
    }

    // MARK: - Onboarding

    @objc private func showOnboarding() {
        if onboarding == nil {
            let model = OnboardingModel(showPreview: settings.showPreview)
            model.keyName = settings.dictationKey.title
            model.requestCamera = { [weak self] in self?.requestCamera() }
            model.requestAccess = { [weak self] in self?.requestAccessibility() }
            model.requestMic = { [weak self] in self?.requestMic() }
            model.setPrimary = { [weak self] c in
                guard let self, c != .unknown else { return }
                self.settings.primaryHand = PrimaryHand(c)
            }
            model.setPreview = { [weak self] on in self?.settings.showPreview = on }
            model.finish = { [weak self] in self?.finishOnboarding() }
            model.onStep = { [weak self] step in
                guard let self else { return }
                // Lessons: practice only. The last screen: Glide is on, so a pinch presses Done.
                self.pipeline.setPractice(step != .done)
                if step == .done { self.settings.onboarded = true }
            }
            onboarding = OnboardingWindow(session: pipeline.session, model: model)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: onboarding, queue: .main) { [weak self] _ in
                self?.pipeline.setPractice(false)
            }
        }
        onboarding?.model.begin()
        pipeline.setPractice(true)
        setPreviewVisible(false)
        NSApp.activate(ignoringOtherApps: true)
        onboarding?.makeKeyAndOrderFront(nil)
    }

    /// Opens the lessons at any time after setup.
    @objc private func learnGestures() {
        showOnboarding()
        onboarding?.model.go(.raise)
    }

    private func finishOnboarding() {
        settings.onboarded = true
        onboarding?.close()
        pipeline.setPractice(false)
        setPreviewVisible(settings.showPreview)
        refreshIcon()
    }

    // MARK: - Status item

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let listening = dictation.model.state != .idle
        let symbol: String
        if listening {
            symbol = "waveform"
        } else {
            switch mode {
            case .idle: symbol = "hand.pinch"
            case .hover, .pinch, .drag: symbol = "hand.pinch.fill"
            case .grab: symbol = "hand.draw.fill"
            case .talk: symbol = "waveform"
            }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Glide")
        let accent = (mode == .pinch || mode == .drag || listening) && enabled && !needsSetup
        image?.isTemplate = !accent
        button.image = accent ? image?.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor])) : image
        button.appearsDisabled = !enabled || needsSetup
        if useRecording != nil {
            let rec = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Glide is recording")
            rec?.isTemplate = false
            button.image = rec?.withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if needsSetup || !settings.onboarded {
            menu.addItem(item("Finish Setup…", #selector(showOnboarding)))
            menu.addItem(.separator())
        }

        let on = item("Glide", #selector(toggleEnabled), key: " ", mods: [.control, .option])
        on.state = enabled ? .on : .off
        menu.addItem(on)

        let show = item("Tracking Preview", #selector(togglePreview), key: "p", mods: [.control, .option])
        show.state = (preview?.isVisible ?? false) ? .on : .off
        menu.addItem(show)

        menu.addItem(.separator())
        if settings.onboarded && !needsSetup { menu.addItem(item("Learn Gestures…", #selector(learnGestures))) }
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        // A guided recording of the hand, for tuning with GlideReplay.
        menu.addItem(item("Playground…", #selector(showPlayground)))
        menu.addItem(item("Record Test Session…", #selector(showTestSession)))
        let use = item(useRecording == nil ? "Record While Using" : "Stop Recording", #selector(toggleUseRecording))
        menu.addItem(use)
        menu.addItem(.separator())
        menu.addItem(item("Quit Glide", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return i
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        enabled.toggle()
        pipeline.setEnabled(enabled)
        refreshIcon()
    }

    @objc private func togglePreview() {
        settings.showPreview = !(preview?.isVisible ?? false)
        setPreviewVisible(settings.showPreview)
    }

    private func setPreviewVisible(_ on: Bool) {
        if on {
            if preview == nil { preview = PreviewPanel(session: pipeline.session) }
            preview?.orderFrontRegardless()
        } else {
            preview?.orderOut(nil)
        }
    }

    @objc private func showTestSession() {
        if testSession == nil {
            let w = TestSessionWindow(session: pipeline.session)
            w.model.start = { [weak self] in
                self?.pipeline.setPractice(true)
                return self?.pipeline.startSession()
            }
            w.model.setLabel = { [weak self] label in self?.pipeline.setSessionLabel(label) }
            w.model.stop = { [weak self] done in
                self?.pipeline.stopSession {
                    self?.pipeline.setPractice(false)
                    done()
                }
            }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                guard let self, let w = self.testSession else { return }
                if w.model.running { w.model.cancel() }
                self.pipeline.setPractice(false)
            }
            testSession = w
        }
        NSApp.activate(ignoringOtherApps: true)
        testSession?.makeKeyAndOrderFront(nil)
    }

    /// Records camera video while Glide controls the pointer as usual. Stops itself after 3 minutes.
    @objc private func toggleUseRecording() {
        if useRecording != nil {
            stopUseRecording()
            return
        }
        guard pipeline.startSession() != nil else { return }
        pipeline.setSessionLabel("use")
        useRecording = Date()
        useTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in self?.stopUseRecording() }
        refreshIcon()
    }

    private func stopUseRecording() {
        useTimer?.invalidate()
        useTimer = nil
        useRecording = nil
        refreshIcon()
        pipeline.stopSession {}
    }

    /// A small desktop with real controls. Glide works on it as usual; a recording keeps what each object saw.
    @objc private func showPlayground() {
        if playground == nil {
            let w = PlaygroundWindow(session: pipeline.session)
            w.model.start = { [weak self] in self?.pipeline.startSession() }
            w.model.setLabel = { [weak self] label in self?.pipeline.setSessionLabel(label) }
            w.model.log = { [weak self] e in self?.pipeline.logEvent(e) }
            w.model.stop = { [weak self] done in self?.pipeline.stopSession(done) }
            let center = NotificationCenter.default
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
                self?.pipeline.setSwipesToApp(true)
            }
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
                self?.pipeline.setSwipesToApp(false)
            }
            center.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                guard let w = self?.playground else { return }
                if w.model.recording { w.model.end() }
                self?.pipeline.setSwipesToApp(false)
            }
            playground = w
        }
        NSApp.activate(ignoringOtherApps: true)
        playground?.makeKeyAndOrderFront(nil)
    }

    @objc private func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindow() }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
