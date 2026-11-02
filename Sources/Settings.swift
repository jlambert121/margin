import Cocoa

enum AppearanceChoice: String, CaseIterable {
    case light, dark, auto
    var title: String {
        rawValue.capitalized
    }

    var appearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .auto: return nil
        }
    }
}

struct Settings {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var appearance: AppearanceChoice {
        get { defaults.string(forKey: "appearance").flatMap(AppearanceChoice.init(rawValue:)) ?? .auto }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "appearance") }
    }

    // Document text size as a multiple of the default, stepped like a browser's zoom.
    static let textZoomSteps: [Double] = [0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    var textZoom: Double {
        get {
            let stored = defaults.double(forKey: "textZoom")
            return stored > 0 ? min(max(stored, Self.textZoomSteps.first!), Self.textZoomSteps.last!) : 1
        }
        nonmutating set { defaults.set(newValue, forKey: "textZoom") }
    }

    func zoomedIn() -> Double {
        Self.textZoomSteps.first { $0 > textZoom + 0.001 } ?? Self.textZoomSteps.last!
    }

    func zoomedOut() -> Double {
        Self.textZoomSteps.last { $0 < textZoom - 0.001 } ?? Self.textZoomSteps.first!
    }
}

final class SettingsWindowController: NSWindowController {
    let settings: Settings
    let onChange: () -> Void
    let appearanceControl = NSSegmentedControl(labels: AppearanceChoice.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)

    init(settings: Settings, onChange: @escaping () -> Void) {
        self.settings = settings; self.onChange = onChange
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        appearanceControl.target = self; appearanceControl.action = #selector(appearanceChanged(_:))

        let form = NSGridView(views: [[NSTextField(labelWithString: "Appearance:"), appearanceControl]])
        form.rowSpacing = 20; form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing
        form.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            form.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            form.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
        ])
        window.contentView = content
        refresh()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        appearanceControl.selectedSegment = AppearanceChoice.allCases.firstIndex(of: settings.appearance)!
    }

    @objc func appearanceChanged(_ sender: NSSegmentedControl) {
        settings.appearance = AppearanceChoice.allCases[sender.selectedSegment]
        onChange()
    }
}
