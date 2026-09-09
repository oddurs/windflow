import Foundation
import AppKit
import UniformTypeIdentifiers

/// Built in code rather than a nib. Nib loading from inside `legacyScreenSaver`
/// is a recurring source of "configure does nothing" bugs; a programmatic window
/// has no bundle lookup to get wrong.
final class ConfigSheetController: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    let window: NSWindow
    private let table = NSTableView()
    private var urls: [URL] = []
    private var valueLabels: [String: NSTextField] = [:]

    private struct Row {
        let key: String
        let title: String
        let range: ClosedRange<Double>
        let hint: String
        let format: (Double) -> String
    }

    private let rows: [Row] = [
        Row(key: Preferences.Key.density, title: "Streams", range: 0.25...2.5,
            hint: "How many lines are in the air at once",
            format: { String(format: "%.2f×", $0) }),
        Row(key: Preferences.Key.speed, title: "Wind speed", range: 0.25...3.0,
            hint: "How fast they travel",
            format: { String(format: "%.2f×", $0) }),
        Row(key: Preferences.Key.trail, title: "Trail length", range: 0.2...3.0,
            hint: "How long a streak stays lit behind the head",
            format: { String(format: "%.2f×", $0) }),
        Row(key: Preferences.Key.swirl, title: "Wander", range: 0.0...1.6,
            hint: "Turbulence layered over the photo's own structure",
            format: { String(format: "%.2f", $0) }),
        Row(key: Preferences.Key.drift, title: "Freedom", range: 0.0...1.0,
            hint: "0 traces the photo exactly, 1 lets open wind take over",
            format: { String(format: "%.2f", $0) }),
        Row(key: Preferences.Key.saturation, title: "Colour depth", range: 0.6...2.2,
            hint: "Saturation of the recovered image",
            format: { String(format: "%.2f", $0) }),
        Row(key: Preferences.Key.exposure, title: "Exposure", range: 0.4...2.0,
            hint: "Overall glyph coverage",
            format: { String(format: "%.2f", $0) }),
        Row(key: Preferences.Key.bloom, title: "Bloom", range: 0.0...2.0,
            hint: "Halo around the brightest lines",
            format: { String(format: "%.2f", $0) }),
        Row(key: Preferences.Key.secondsPerImage, title: "Time per image", range: 20.0...400.0,
            hint: "Includes the reveal and the hold before it dissolves",
            format: { String(format: "%.0f s", $0) }),
    ]

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                          styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.title = "Windflow"
        super.init()
        urls = ImageLibrary.urls()
        buildUI()
    }

    // MARK: - Layout

    private func buildUI() {
        let content = NSView(frame: window.contentLayoutRect)

        let heading = label("Windflow", size: 17, weight: .semibold)
        let sub = label("Aerial photographs, drawn by wind.", size: 11, weight: .regular)
        sub.textColor = .secondaryLabelColor

        // Left column: the photo library.
        let libraryTitle = label("Photographs", size: 11, weight: .semibold)
        libraryTitle.textColor = .secondaryLabelColor

        table.headerView = nil
        table.rowSizeStyle = .default
        table.allowsMultipleSelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 250
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = button("Add Photos…", #selector(addPhotos))
        let removeButton = button("Remove", #selector(removePhotos))
        let folderButton = button("Show in Finder", #selector(showFolder))
        let libraryButtons = NSStackView(views: [addButton, removeButton, folderButton])
        libraryButtons.orientation = .horizontal
        libraryButtons.spacing = 8

        let note = label("Photos are copied into Windflow's own folder so the "
                         + "screensaver can still read them while it runs.",
                         size: 10, weight: .regular)
        note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 3
        note.preferredMaxLayoutWidth = 260

        let leftColumn = NSStackView(views: [libraryTitle, scroll, libraryButtons, note])
        leftColumn.orientation = .vertical
        leftColumn.alignment = .leading
        leftColumn.spacing = 8
        leftColumn.translatesAutoresizingMaskIntoConstraints = false

        // Right column: tuning.
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        for row in rows {
            let title = label(row.title, size: 12, weight: .regular)
            title.toolTip = row.hint

            let slider = NSSlider(value: currentValue(row.key),
                                  minValue: row.range.lowerBound,
                                  maxValue: row.range.upperBound,
                                  target: self, action: #selector(sliderChanged(_:)))
            slider.isContinuous = true
            slider.identifier = NSUserInterfaceItemIdentifier(row.key)
            slider.toolTip = row.hint
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 200).isActive = true

            let value = label(row.format(currentValue(row.key)), size: 11, weight: .regular)
            value.textColor = .secondaryLabelColor
            value.alignment = .right
            value.translatesAutoresizingMaskIntoConstraints = false
            value.widthAnchor.constraint(equalToConstant: 56).isActive = true
            valueLabels[row.key] = value

            grid.addRow(with: [title, slider, value])
        }

        let shuffle = NSButton(checkboxWithTitle: "Shuffle photographs",
                               target: self, action: #selector(shuffleChanged(_:)))
        shuffle.state = Preferences.shared.shuffle ? .on : .off
        grid.addRow(with: [NSGridCell.emptyContentView, shuffle, NSGridCell.emptyContentView])

        let reset = button("Reset to Defaults", #selector(resetDefaults))
        grid.addRow(with: [NSGridCell.emptyContentView, reset, NSGridCell.emptyContentView])

        grid.translatesAutoresizingMaskIntoConstraints = false

        let columns = NSStackView(views: [leftColumn, grid])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 24
        columns.translatesAutoresizingMaskIntoConstraints = false

        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        let footer = NSStackView(views: [NSView(), done])
        footer.orientation = .horizontal
        footer.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [heading, sub, columns, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setCustomSpacing(2, after: heading)
        root.setCustomSpacing(18, after: sub)

        content.addSubview(root)
        window.contentView = content

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            columns.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 268),
            scroll.heightAnchor.constraint(equalToConstant: 330),
        ])
    }

    // MARK: - Actions

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let key = sender.identifier?.rawValue,
              let row = rows.first(where: { $0.key == key }) else { return }
        UserDefaults.standard.set(sender.doubleValue, forKey: key) // keeps preview apps in sync
        store(key, sender.doubleValue)
        valueLabels[key]?.stringValue = row.format(sender.doubleValue)
    }

    @objc private func shuffleChanged(_ sender: NSButton) {
        Preferences.shared.shuffle = sender.state == .on
    }

    @objc private func resetDefaults() {
        let p = Preferences.shared
        p.density = 1.0; p.speed = 1.0; p.trail = 1.0; p.exposure = 1.0
        p.swirl = 0.55; p.drift = 0.25; p.saturation = 1.45
        p.bloom = 0.9; p.secondsPerImage = 75.0
        window.contentView = nil
        valueLabels.removeAll()
        buildUI()
    }

    @objc private func addPhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose aerial photographs to add to Windflow."
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            for url in panel.urls { self.ingest(url) }
            self.urls = ImageLibrary.urls()
            self.table.reloadData()
        }
    }

    private func ingest(_ url: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            for item in items
            where ImageLibrary.allowedExtensions.contains(item.pathExtension.lowercased()) {
                ImageLibrary.importImage(from: item)
            }
        } else {
            ImageLibrary.importImage(from: url)
        }
    }

    @objc private func removePhotos() {
        for index in table.selectedRowIndexes.sorted(by: >) where index < urls.count {
            ImageLibrary.remove(urls[index])
        }
        urls = ImageLibrary.urls()
        table.reloadData()
    }

    @objc private func showFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([ImageLibrary.folder])
    }

    @objc private func close() {
        Preferences.shared.synchronize()
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { urls.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? { let c = NSTableCellView()
                 let t = NSTextField(labelWithString: "")
                 t.translatesAutoresizingMaskIntoConstraints = false
                 t.lineBreakMode = .byTruncatingMiddle
                 c.addSubview(t)
                 c.textField = t
                 NSLayoutConstraint.activate([
                    t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                    t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                    t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                 ])
                 c.identifier = id
                 return c }()
        cell.textField?.stringValue = urls[row].deletingPathExtension().lastPathComponent
        return cell
    }

    // MARK: - Helpers

    private func currentValue(_ key: String) -> Double {
        let p = Preferences.shared
        switch key {
        case Preferences.Key.density: return p.density
        case Preferences.Key.speed: return p.speed
        case Preferences.Key.trail: return p.trail
        case Preferences.Key.exposure: return p.exposure
        case Preferences.Key.swirl: return p.swirl
        case Preferences.Key.drift: return p.drift
        case Preferences.Key.saturation: return p.saturation
        case Preferences.Key.bloom: return p.bloom
        case Preferences.Key.secondsPerImage: return p.secondsPerImage
        default: return 0
        }
    }

    private func store(_ key: String, _ value: Double) {
        let p = Preferences.shared
        switch key {
        case Preferences.Key.density: p.density = value
        case Preferences.Key.speed: p.speed = value
        case Preferences.Key.trail: p.trail = value
        case Preferences.Key.exposure: p.exposure = value
        case Preferences.Key.swirl: p.swirl = value
        case Preferences.Key.drift: p.drift = value
        case Preferences.Key.saturation: p.saturation = value
        case Preferences.Key.bloom: p.bloom = value
        case Preferences.Key.secondsPerImage: p.secondsPerImage = value
        default: break
        }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }
}
