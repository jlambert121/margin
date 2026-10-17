import Cocoa

enum AppearanceChoice: String, CaseIterable {
    case light, dark, auto
    var title: String { rawValue.capitalized }
    var appearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .auto: return nil
        }
    }
}

// Raw values match the PNG names written by scripts/make-icon.swift.
enum AppIconChoice: String, CaseIterable {
    case night, serif, ruled, note, offset, quote
    var title: String {
        switch self {
        case .night: return "Night"
        case .serif: return "Serif"
        case .ruled: return "Ruled"
        case .note: return "Note"
        case .offset: return "Page"
        case .quote: return "Quote"
        }
    }
    var image: NSImage? {
        Bundle.main.url(forResource: rawValue, withExtension: "png", subdirectory: "Icons").flatMap(NSImage.init(contentsOf:))
    }
    // Night is the bundle icon, so it needs no runtime override.
    var dockImage: NSImage? { self == .night ? nil : image }
}

struct Settings {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var appearance: AppearanceChoice {
        get { defaults.string(forKey: "appearance").flatMap(AppearanceChoice.init(rawValue:)) ?? .auto }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "appearance") }
    }
    var appIcon: AppIconChoice {
        get { defaults.string(forKey: "appIcon").flatMap(AppIconChoice.init(rawValue:)) ?? .night }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "appIcon") }
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
    func zoomedIn() -> Double { Self.textZoomSteps.first { $0 > textZoom + 0.001 } ?? Self.textZoomSteps.last! }
    func zoomedOut() -> Double { Self.textZoomSteps.last { $0 < textZoom - 0.001 } ?? Self.textZoomSteps.first! }
}

final class SettingsWindowController: NSWindowController {
    let settings: Settings
    let onChange: () -> Void
    let appearanceControl = NSSegmentedControl(labels: AppearanceChoice.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private(set) var iconTiles: [AppIconChoice: NSBox] = [:]

    init(settings: Settings, onChange: @escaping () -> Void) {
        self.settings = settings; self.onChange = onChange
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        appearanceControl.target = self; appearanceControl.action = #selector(appearanceChanged(_:))

        let icons = NSGridView(numberOfColumns: 3, rows: 0)
        icons.rowSpacing = 6; icons.columnSpacing = 6
        let choices = AppIconChoice.allCases
        for start in stride(from: 0, to: choices.count, by: 3) { icons.addRow(with: choices[start..<min(start + 3, choices.count)].map(iconTile)) }
        let note = NSTextField(wrappingLabelWithString: "Shown in the Dock while Margin is running. Finder and Launchpad always show Night.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize); note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 300
        let iconColumn = NSStackView(views: [icons, note])
        iconColumn.orientation = .vertical; iconColumn.alignment = .leading; iconColumn.spacing = 8

        let form = NSGridView(views: [[NSTextField(labelWithString: "Appearance:"), appearanceControl], [NSTextField(labelWithString: "App icon:"), iconColumn]])
        form.rowSpacing = 20; form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing
        form.row(at: 1).yPlacement = .top
        form.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            form.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            form.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30)
        ])
        window.contentView = content
        refresh()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func iconTile(_ choice: AppIconChoice) -> NSBox {
        let button = NSButton(title: choice.title, image: choice.image ?? NSImage(), target: self, action: #selector(iconChosen(_:)))
        button.tag = AppIconChoice.allCases.firstIndex(of: choice)!
        button.isBordered = false
        button.imagePosition = .imageAbove
        button.imageScaling = .scaleProportionallyUpOrDown
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.setAccessibilityLabel("\(choice.title) app icon")
        button.translatesAutoresizingMaskIntoConstraints = false
        let tile = NSBox()
        tile.boxType = .custom; tile.borderWidth = 0; tile.cornerRadius = 10
        tile.contentViewMargins = NSSize(width: 6, height: 6)
        tile.contentView?.addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 80), button.heightAnchor.constraint(equalToConstant: 96),
            button.centerXAnchor.constraint(equalTo: tile.contentView!.centerXAnchor), button.centerYAnchor.constraint(equalTo: tile.contentView!.centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 92), tile.heightAnchor.constraint(equalToConstant: 108)
        ])
        iconTiles[choice] = tile
        return tile
    }
    func refresh() {
        appearanceControl.selectedSegment = AppearanceChoice.allCases.firstIndex(of: settings.appearance)!
        for (choice, tile) in iconTiles {
            let selected = choice == settings.appIcon
            tile.fillColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.25) : .clear
            (tile.contentView?.subviews.first as? NSButton)?.setAccessibilityValue(selected ? "Selected" : "")
        }
    }
    @objc func appearanceChanged(_ sender: NSSegmentedControl) {
        settings.appearance = AppearanceChoice.allCases[sender.selectedSegment]
        onChange()
    }
    @objc func iconChosen(_ sender: NSButton) {
        settings.appIcon = AppIconChoice.allCases[sender.tag]
        refresh(); onChange()
    }
}
