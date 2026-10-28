// ShotQueue: снимает область экрана, размечает её на месте и хранит очередь снимков.
// Сборка: ./scripts/build.sh из корня зоны. Запуск: ./scripts/run.sh.

import AppKit
import Carbon
import ScreenCaptureKit
import CoreGraphics
import ApplicationServices

private enum MarkKind: String, Codable { case pin, rectangle, arrow }

private struct Mark: Codable {
    var kind: MarkKind
    var x: Double
    var y: Double
    var endX: Double
    var endY: Double
    var note: String
}

private struct Shot: Codable {
    var letter: String
    var file: String
    var width: Int
    var height: Int
    var marks: [Mark]
}

private final class ShotStore {
    let root: URL
    private(set) var shots: [Shot] = []

    init(root overrideRoot: URL? = nil) {
        let library = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = overrideRoot ?? library.appendingPathComponent("ShotQueue", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("session.json")
        if let data = try? Data(contentsOf: index), let loaded = try? JSONDecoder().decode([Shot].self, from: data) {
            shots = loaded.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.file).path) }
        }
    }

    var nextLetter: String? {
        guard shots.count < 26 else { return nil }
        return String(UnicodeScalar(65 + shots.count)!)
    }

    func append(image: CGImage, selection: NSRect, marks: [Mark], screenSize: NSSize) throws {
        guard let letter = nextLetter else { throw ShotError.queueFull }
        let scaleX = CGFloat(image.width) / screenSize.width
        let scaleY = CGFloat(image.height) / screenSize.height
        let pixels = CGRect(
            x: floor(selection.minX * scaleX),
            y: floor((screenSize.height - selection.maxY) * scaleY),
            width: ceil(selection.width * scaleX),
            height: ceil(selection.height * scaleY)
        ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let crop = image.cropping(to: pixels), pixels.width > 0, pixels.height > 0 else {
            throw ShotError.invalidSelection
        }
        let relative = marks.map { mark in
            Mark(kind: mark.kind, x: mark.x - selection.minX, y: mark.y - selection.minY,
                 endX: mark.endX - selection.minX, endY: mark.endY - selection.minY, note: mark.note)
        }
        guard let png = render(crop: crop, logicalSize: selection.size, marks: relative, letter: letter) else {
            throw ShotError.renderFailed
        }
        let file = "\(letter).png"
        try png.write(to: root.appendingPathComponent(file), options: .atomic)
        shots.append(Shot(letter: letter, file: file, width: crop.width, height: crop.height, marks: relative))
        try saveIndex()
        try markdown().write(to: root.appendingPathComponent("session.md"), atomically: true, encoding: .utf8)
    }

    func clear() throws {
        guard !shots.isEmpty else { return }
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
            .appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        for shot in shots {
            try FileManager.default.copyItem(at: root.appendingPathComponent(shot.file),
                                             to: archive.appendingPathComponent(shot.file))
        }
        try JSONEncoder().encode(shots).write(to: archive.appendingPathComponent("session.json"), options: .atomic)
        try markdown().write(to: archive.appendingPathComponent("session.md"), atomically: true, encoding: .utf8)
        for shot in shots { try FileManager.default.removeItem(at: root.appendingPathComponent(shot.file)) }
        shots.removeAll()
        try saveIndex()
        try markdown().write(to: root.appendingPathComponent("session.md"), atomically: true, encoding: .utf8)
    }

    func markdown() -> String {
        var lines = ["# Снимки ShotQueue", ""]
        for shot in shots {
            lines.append("## Снимок \(shot.letter): \(shot.file)")
            for (number, mark) in shot.marks.enumerated() where !mark.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("\(shot.letter)\(number + 1): \(mark.note)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func saveIndex() throws {
        let data = try JSONEncoder().encode(shots)
        try data.write(to: root.appendingPathComponent("session.json"), options: .atomic)
    }

    func imageData(for shot: Shot) -> Data? { try? Data(contentsOf: root.appendingPathComponent(shot.file)) }
}

private enum ShotError: LocalizedError {
    case queueFull, invalidSelection, renderFailed
    var errorDescription: String? {
        switch self {
        case .queueFull: return "В очереди уже 26 снимков. Скопируй или очисти её."
        case .invalidSelection: return "Не получилось вырезать выбранную область."
        case .renderFailed: return "Не получилось сохранить разметку."
        }
    }
}

private enum PasteError: LocalizedError {
    case noTarget, targetChanged, missingImage, eventFailed
    var errorDescription: String? {
        switch self {
        case .noTarget: return "Открой поле сообщения Codex в VS Code и нажми ⌥⌘V ещё раз."
        case .targetChanged: return "Во время вставки активное приложение изменилось. Очередь сохранена."
        case .missingImage: return "Один из снимков не найден на диске. Очередь сохранена."
        case .eventFailed: return "macOS не смогла отправить команду вставки. Очередь сохранена."
        }
    }
}

private func drawMarks(_ marks: [Mark], letter: String) {
    let color = NSColor(calibratedRed: 1, green: 0.22, blue: 0.18, alpha: 1)
    for (index, mark) in marks.enumerated() {
        color.setStroke(); color.setFill()
        switch mark.kind {
        case .pin:
            let circle = NSBezierPath(ovalIn: NSRect(x: mark.x - 13, y: mark.y - 13, width: 26, height: 26))
            circle.fill()
            let label = "\(letter)\(index + 1)"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: mark.x - size.width / 2, y: mark.y - size.height / 2), withAttributes: attrs)
        case .rectangle:
            let rect = NSRect(x: min(mark.x, mark.endX), y: min(mark.y, mark.endY),
                              width: abs(mark.endX - mark.x), height: abs(mark.endY - mark.y))
            let path = NSBezierPath(rect: rect); path.lineWidth = 3; path.stroke()
            drawBadge(letter: letter, number: index + 1, at: NSPoint(x: rect.minX, y: rect.maxY))
        case .arrow:
            let path = NSBezierPath(); path.lineWidth = 3
            path.move(to: NSPoint(x: mark.x, y: mark.y)); path.line(to: NSPoint(x: mark.endX, y: mark.endY)); path.stroke()
            let angle = atan2(mark.endY - mark.y, mark.endX - mark.x)
            let head = NSBezierPath(); head.lineWidth = 3
            for delta in [-0.55, 0.55] {
                head.move(to: NSPoint(x: mark.endX - 14 * cos(angle + delta), y: mark.endY - 14 * sin(angle + delta)))
                head.line(to: NSPoint(x: mark.endX, y: mark.endY))
            }
            head.stroke()
            drawBadge(letter: letter, number: index + 1, at: NSPoint(x: mark.x, y: mark.y))
        }
    }
}

private func drawBadge(letter: String, number: Int, at point: NSPoint) {
    let circle = NSBezierPath(ovalIn: NSRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22))
    NSColor.systemBlue.setFill(); circle.fill()
    let label = "\(letter)\(number)"
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 9), .foregroundColor: NSColor.white]
    let size = label.size(withAttributes: attrs)
    label.draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), withAttributes: attrs)
}

private func render(crop: CGImage, logicalSize: NSSize, marks: [Mark], letter: String) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: crop.width, pixelsHigh: crop.height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = logicalSize
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSImage(cgImage: crop, size: logicalSize).draw(in: NSRect(origin: .zero, size: logicalSize))
    drawMarks(marks, letter: letter)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

private final class OverlayView: NSView {
    enum Mode { case select, pin, rectangle, arrow }
    let image: CGImage
    let displayImage: NSImage
    let letter: String
    var mode: Mode = .select
    var selection: NSRect?
    var marks: [Mark] = []
    private var redoMarks: [Mark] = []
    private var selectedIndex: Int?
    var onFinish: ((NSRect, [Mark]) -> Void)?
    var onCancel: (() -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?
    private var notePopup: NotePopup?
    private var toolbar: NSStackView!

    init(frame: NSRect, image: CGImage, letter: String) {
        self.image = image
        self.displayImage = NSImage(cgImage: image, size: frame.size)
        self.letter = letter
        super.init(frame: frame)
        wantsLayer = true
        makeToolbar()
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:image:letter:)") }
    override var acceptsFirstResponder: Bool { true }

    private func makeToolbar() {
        toolbar = NSStackView()
        toolbar.orientation = .horizontal; toolbar.spacing = 8
        toolbar.alignment = .centerY
        let entries: [(String, Selector)] = [
            ("Точка 1", #selector(selectPin)), ("Рамка 2", #selector(selectRectangle)),
            ("Стрелка 3", #selector(selectArrow)), ("Готово ↩", #selector(finish)),
            ("Отмена Esc", #selector(cancel))
        ]
        for (title, action) in entries {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            toolbar.addArrangedSubview(button)
        }
        toolbar.isHidden = true
        addSubview(toolbar)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: centerXAnchor),
            toolbar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24)
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        displayImage.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.55).setFill(); bounds.fill()
        if let selection {
            displayImage.draw(in: selection, from: selection, operation: .copy, fraction: 1)
            NSColor.systemBlue.setStroke()
            let border = NSBezierPath(rect: selection); border.lineWidth = 2; border.stroke()
            drawMarks(marks, letter: letter)
            if let selectedIndex, marks.indices.contains(selectedIndex) {
                let badge = badgePoint(for: marks[selectedIndex])
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: badge.x - 17, y: badge.y - 17, width: 34, height: 34))
                ring.lineWidth = 2; ring.stroke()
            }
        } else if let start, let current {
            let rect = rectBetween(start, current)
            displayImage.draw(in: rect, from: rect, operation: .copy, fraction: 1)
            NSColor.systemBlue.setStroke(); NSBezierPath(rect: rect).stroke()
        }
        if mode != .select, let start, let current {
            NSColor.systemRed.setStroke()
            let path = mode == .rectangle ? NSBezierPath(rect: rectBetween(start, current)) : NSBezierPath()
            if mode == .arrow { path.move(to: start); path.line(to: current) }
            path.lineWidth = 2; path.stroke()
        }
        if selection == nil {
            let title = "Выдели область. Esc отменяет"
            title.draw(at: NSPoint(x: bounds.midX - 115, y: 35), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.white
            ])
        }
    }

    private func rectBetween(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    private func point(_ event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }
    private func badgePoint(for mark: Mark) -> NSPoint {
        if mark.kind == .rectangle {
            return NSPoint(x: min(mark.x, mark.endX), y: max(mark.y, mark.endY))
        }
        return NSPoint(x: mark.x, y: mark.y)
    }

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        if mode == .select { start = p; current = p; needsDisplay = true; return }
        guard selection?.contains(p) == true else { return }
        notePopup?.save()
        if let existing = marks.indices.reversed().first(where: { index in
            let badge = badgePoint(for: marks[index])
            return hypot(badge.x - p.x, badge.y - p.y) < 17
        }) {
            selectedIndex = existing
            editNote(index: existing, near: p)
            needsDisplay = true
            return
        }
        if mode == .pin {
            marks.append(Mark(kind: .pin, x: p.x, y: p.y, endX: p.x, endY: p.y, note: ""))
            redoMarks.removeAll(); selectedIndex = marks.count - 1
            editNote(index: marks.count - 1, near: p)
        } else { start = p; current = p }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard start != nil else { return }
        current = point(event); needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        let end = point(event)
        defer { self.start = nil; self.current = nil; needsDisplay = true }
        if mode == .select {
            let rect = rectBetween(start, end)
            guard rect.width >= 30, rect.height >= 30 else { return }
            selection = rect; mode = .pin; toolbar.isHidden = false
            return
        }
        guard let selection, rectBetween(start, end).width + rectBetween(start, end).height > 12 else { return }
        let clippedEnd = NSPoint(x: min(max(end.x, selection.minX), selection.maxX),
                                 y: min(max(end.y, selection.minY), selection.maxY))
        let kind: MarkKind = mode == .rectangle ? .rectangle : .arrow
        marks.append(Mark(kind: kind, x: start.x, y: start.y, endX: clippedEnd.x, endY: clippedEnd.y, note: ""))
        redoMarks.removeAll(); selectedIndex = marks.count - 1
        editNote(index: marks.count - 1, near: clippedEnd)
    }

    private func editNote(index: Int, near point: NSPoint) {
        guard let parent = window else { return }
        notePopup = NotePopup(parent: parent, letter: letter, number: index + 1,
                              near: point, initial: marks[index].note,
                              onSave: { [weak self] text in
            guard let self else { return }
            if self.marks.indices.contains(index) { self.marks[index].note = text }
            self.notePopup = nil
            parent.makeKeyAndOrderFront(nil)
            parent.makeFirstResponder(self)
            self.needsDisplay = true
        }, onDelete: { [weak self] in
            guard let self else { return }
            if self.marks.indices.contains(index) { self.marks.remove(at: index) }
            self.redoMarks.removeAll(); self.selectedIndex = nil; self.notePopup = nil
            parent.makeKeyAndOrderFront(nil)
            parent.makeFirstResponder(self)
            self.needsDisplay = true
        })
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 6, event.modifierFlags.contains(.command) { // ⌘Z / ⇧⌘Z
            notePopup?.save()
            if event.modifierFlags.contains(.shift) {
                if let mark = redoMarks.popLast() { marks.append(mark); selectedIndex = marks.count - 1 }
            } else if let mark = marks.popLast() {
                redoMarks.append(mark); selectedIndex = nil
            }
            needsDisplay = true
            return
        }
        switch event.keyCode {
        case 53: cancel() // Escape
        case 36:
            if mode == .select {
                selection = bounds
                mode = .pin
                toolbar.isHidden = false
                needsDisplay = true
            } else if selection != nil { finish() } // Return
        case 18: selectPin() // 1
        case 19: selectRectangle() // 2
        case 20: selectArrow() // 3
        case 51:
            notePopup?.save()
            if let selectedIndex, marks.indices.contains(selectedIndex) { marks.remove(at: selectedIndex) }
            else if !marks.isEmpty { marks.removeLast() }
            selectedIndex = nil; redoMarks.removeAll(); needsDisplay = true
        default: super.keyDown(with: event)
        }
    }
    @objc private func selectPin() { notePopup?.save(); mode = .pin }
    @objc private func selectRectangle() { notePopup?.save(); mode = .rectangle }
    @objc private func selectArrow() { notePopup?.save(); mode = .arrow }
    @objc private func finish() { notePopup?.save(); if let selection { onFinish?(selection, marks) } }
    @objc private func cancel() { notePopup?.close(); onCancel?() }
}

private final class KeyableOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class NotePopup: NSObject {
    let window: KeyableOverlayPanel
    let field: NSTextField
    private let onSave: (String) -> Void
    private let onDelete: () -> Void

    init(parent: NSWindow, letter: String, number: Int, near point: NSPoint,
         initial: String, onSave: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.onSave = onSave
        self.onDelete = onDelete
        let width: CGFloat = 440
        let height: CGFloat = 105
        let x = min(max(parent.frame.minX + point.x + 16, parent.frame.minX + 12), parent.frame.maxX - width - 12)
        let y = min(max(parent.frame.minY + point.y + 16, parent.frame.minY + 65), parent.frame.maxY - height - 12)
        window = KeyableOverlayPanel(contentRect: NSRect(x: x, y: y, width: width, height: height),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(letter)\(number): комментарий"
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        field = NSTextField(frame: NSRect(x: 16, y: 43, width: width - 32, height: 30))
        field.placeholderString = "Что здесь изменить?"
        field.stringValue = initial
        field.font = .systemFont(ofSize: 16)
        super.init()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.addSubview(field)
        let saveButton = NSButton(title: "Сохранить ↩", target: self, action: #selector(saveAction))
        saveButton.frame = NSRect(x: width - 156, y: 8, width: 140, height: 28)
        content.addSubview(saveButton)
        let deleteButton = NSButton(title: "Удалить метку", target: self, action: #selector(deleteAction))
        deleteButton.frame = NSRect(x: 16, y: 8, width: 125, height: 28)
        content.addSubview(deleteButton)
        window.contentView = content
        field.target = self; field.action = #selector(saveAction)
        parent.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window.makeKey()
            self.window.makeFirstResponder(self.field)
            self.field.selectText(nil)
        }
    }

    @objc private func saveAction() { save() }
    @objc private func deleteAction() {
        close()
        onDelete()
    }
    func save() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        onSave(text)
    }
    func close() {
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }
}

private final class OverlayController {
    let window: NSPanel
    let view: OverlayView
    init(screen: NSScreen, image: CGImage, letter: String,
         onFinish: @escaping (NSRect, [Mark]) -> Void, onCancel: @escaping () -> Void) {
        window = KeyableOverlayPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        window.level = .screenSaver
        window.isOpaque = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false
        view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image, letter: letter)
        view.onFinish = onFinish; view.onCancel = onCancel
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(view)
    }
    func close() { window.orderOut(nil) }
}

// One mark at both menu-bar and application-icon sizes: a frame in a queue.
private func queueIcon(size: CGFloat, template: Bool = false) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.scale(by: size / 100); transform.concat()
        if !template {
            let background = NSBezierPath(roundedRect: NSRect(x: 3, y: 3, width: 94, height: 94), xRadius: 22, yRadius: 22)
            NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.73, blue: 0.77, alpha: 1),
                       ending: NSColor(calibratedRed: 0.08, green: 0.38, blue: 0.75, alpha: 1))!.draw(in: background, angle: -60)
        }
        (template ? NSColor.black : NSColor.white).setStroke()
        let back = NSBezierPath()
        back.move(to: NSPoint(x: 34, y: 79)); back.line(to: NSPoint(x: 77, y: 79))
        back.curve(to: NSPoint(x: 82, y: 74), controlPoint1: NSPoint(x: 81, y: 79), controlPoint2: NSPoint(x: 82, y: 78))
        back.line(to: NSPoint(x: 82, y: 34)); back.lineWidth = 5; back.lineCapStyle = .round; back.stroke()
        let front = NSBezierPath(roundedRect: NSRect(x: 19, y: 22, width: 51, height: 45), xRadius: 7, yRadius: 7)
        front.lineWidth = 5; front.stroke()
        let focus = NSBezierPath()
        focus.move(to: NSPoint(x: 31, y: 42)); focus.line(to: NSPoint(x: 31, y: 54)); focus.line(to: NSPoint(x: 43, y: 54))
        focus.move(to: NSPoint(x: 58, y: 47)); focus.line(to: NSPoint(x: 58, y: 35)); focus.line(to: NSPoint(x: 46, y: 35))
        focus.lineWidth = 4; focus.lineCapStyle = .round; focus.lineJoinStyle = .round; focus.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
    image.isTemplate = template
    return image
}

private enum Preferences {
    static let confirmationKey = "confirmBeforeClearing"
    static var confirmBeforeClearing: Bool {
        get { UserDefaults.standard.object(forKey: confirmationKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: confirmationKey) }
    }
}

private final class SettingsPanel: NSObject {
    private let window: NSPanel
    private let confirmation: NSButton

    override init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 115),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        confirmation = NSButton(checkboxWithTitle: "Спрашивать перед очисткой очереди", target: nil, action: nil)
        super.init()
        window.title = "Настройки ShotQueue"
        window.isReleasedWhenClosed = false
        confirmation.target = self; confirmation.action = #selector(changeConfirmation)
        confirmation.frame = NSRect(x: 20, y: 65, width: 315, height: 24)
        let hint = NSTextField(wrappingLabelWithString: "При очистке снимки и комментарии остаются в локальном архиве.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 22, y: 18, width: 304, height: 36)
        window.contentView?.addSubview(confirmation); window.contentView?.addSubview(hint)
        window.center()
    }
    func show() {
        confirmation.state = Preferences.confirmBeforeClearing ? .on : .off
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func changeConfirmation() { Preferences.confirmBeforeClearing = confirmation.state == .on }
}

private final class QueuePanel {
    let window: NSPanel
    let label: NSTextField
    let captureButton: NSButton
    let copyButton: NSButton
    private let clearButton: NSButton
    init(target: AnyObject, capture: Selector, copy: Selector, clear: Selector, settings: Selector) {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 248, height: 48),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = true; window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("CompactQueuePanel")
        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 248, height: 48))
        content.material = .hudWindow; content.blendingMode = .behindWindow; content.state = .active
        content.wantsLayer = true; content.layer?.cornerRadius = 14; content.layer?.masksToBounds = true
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        label = NSTextField(labelWithString: "0")
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.alignment = .center
        label.frame = NSRect(x: 10, y: 15, width: 32, height: 18)
        label.setAccessibilityLabel("Снимков в очереди")
        func button(_ symbol: String, _ title: String, _ action: Selector, _ x: CGFloat) -> NSButton {
            let control = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: target, action: action)
            control.bezelStyle = .inline; control.isBordered = false
            control.frame = NSRect(x: x, y: 8, width: 36, height: 32)
            control.toolTip = title; control.setAccessibilityLabel(title)
            return control
        }
        captureButton = button("camera.viewfinder", "Новый снимок", capture, 50)
        copyButton = button("square.and.arrow.up.on.square", "Вставить серию", copy, 98)
        clearButton = button("trash", "Очистить очередь", clear, 146)
        let settingsButton = button("gearshape", "Настройки", settings, 202)
        for control in [label, captureButton, copyButton, clearButton, settingsButton] { content.addSubview(control) }
        window.contentView = content
        if !window.setFrameUsingName("CompactQueuePanel"), let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 268, y: screen.visibleFrame.maxY - 76))
        }
    }
    func show(count: Int) {
        label.stringValue = "\(count)"
        label.setAccessibilityValue("\(count)")
        copyButton.isEnabled = count > 0
        clearButton.isEnabled = count > 0
        window.orderFrontRegardless()
    }
    func hide() { window.orderOut(nil) }
    func setShortcuts(capture: String, paste: String) {
        captureButton.toolTip = "Новый снимок · \(capture)"
        copyButton.toolTip = "Вставить серию · \(paste)"
    }
}

private func hotkeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return noErr }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    if status == noErr {
        let app = Unmanaged<ShotQueueApp>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async { if id.id == 1 { app.capture() } else if id.id == 2 { app.pasteSeries() } }
    }
    return noErr
}

@main private final class ShotQueueApp: NSObject, NSApplicationDelegate {
    static func main() {
        let application = NSApplication.shared
        if let index = CommandLine.arguments.firstIndex(of: "--export-icon"), CommandLine.arguments.count > index + 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for size in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    let pixels = size * scale
                    let image = queueIcon(size: CGFloat(pixels))
                    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
                    let suffix = scale == 2 ? "@2x" : ""
                    try! rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
                }
            }
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            guard selfTestRender(), selfTestArchive() else {
                fputs("Ошибка проверки рендера или архива\n", stderr); exit(1)
            }
            print("Рендер и архив: проверены")
            return
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "life.azat.shotqueue")
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            fputs("ShotQueue уже запущен\n", stderr)
            return
        }
        let delegate = ShotQueueApp()
        application.delegate = delegate
        application.run()
    }

    private static func selfTestRender() -> Bool {
        guard let source = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        source.setFillColor(NSColor.systemRed.cgColor)
        source.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        guard let image = source.makeImage(),
              let png = render(crop: image, logicalSize: NSSize(width: 100, height: 50), marks: [], letter: "A"),
              let rep = NSBitmapImageRep(data: png),
              rep.pixelsWide == 200, rep.pixelsHigh == 100,
              let top = rep.colorAt(x: 100, y: 8)?.usingColorSpace(.deviceRGB),
              let bottom = rep.colorAt(x: 100, y: 92)?.usingColorSpace(.deviceRGB) else { return false }
        return top.redComponent > 0.7 && bottom.redComponent > 0.7
    }

    private static func selfTestArchive() -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShotQueue-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShotStore(root: root)
        guard let source = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        source.setFillColor(NSColor.systemBlue.cgColor)
        source.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        guard let image = source.makeImage() else { return false }
        let mark = Mark(kind: .pin, x: 25, y: 25, endX: 25, endY: 25, note: "проверка")
        do {
            try store.append(image: image, selection: NSRect(x: 0, y: 0, width: 100, height: 50),
                             marks: [mark], screenSize: NSSize(width: 100, height: 50))
            guard store.shots.count == 1, store.markdown().contains("A1: проверка") else { return false }
            try store.clear()
            let archives = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Archive"),
                                                                         includingPropertiesForKeys: nil)
            guard store.shots.isEmpty, archives.count == 1,
                  FileManager.default.fileExists(atPath: archives[0].appendingPathComponent("A.png").path),
                  FileManager.default.fileExists(atPath: archives[0].appendingPathComponent("session.md").path) else {
                return false
            }
            return true
        } catch { return false }
    }

    private let store = ShotStore()
    private var statusItem: NSStatusItem!
    private var captureMenuItem: NSMenuItem!
    private var pasteMenuItem: NSMenuItem!
    private var overlay: OverlayController?
    private var queuePanel: QueuePanel!
    private var settingsPanel: SettingsPanel?
    private var captureKey: EventHotKeyRef?
    private var pasteKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var lastExternalApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var pasting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = queueIcon(size: 18, template: true)
        statusItem.button?.toolTip = "ShotQueue"
        let menu = NSMenu()
        captureMenuItem = NSMenuItem(title: "Новый снимок  ⌥⌘S", action: #selector(captureAction), keyEquivalent: "")
        menu.addItem(captureMenuItem)
        menu.addItem(NSMenuItem(title: "Показать очередь", action: #selector(showQueue), keyEquivalent: ""))
        pasteMenuItem = NSMenuItem(title: "Вставить серию  ⌥⌘V", action: #selector(pasteAction), keyEquivalent: "")
        menu.addItem(pasteMenuItem)
        menu.addItem(NSMenuItem(title: "Очистить очередь", action: #selector(clearAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Настройки…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        queuePanel = QueuePanel(target: self, capture: #selector(captureAction), copy: #selector(pasteAction), clear: #selector(clearAction), settings: #selector(showSettings))
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.lastExternalApp = app
        }
        registerHotkeys()
        queuePanel.show(count: store.shots.count)
    }

    private func registerHotkeys() {
        let spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var mutable = spec
        InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, 1, &mutable,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
        var captureShortcut = "⌥⌘S"
        let captureStatus = RegisterEventHotKey(1, UInt32(cmdKey | optionKey),
            EventHotKeyID(signature: 0x53515145, id: 1), GetApplicationEventTarget(), 0, &captureKey)
        if captureStatus != noErr {
            let fallback = RegisterEventHotKey(1, UInt32(cmdKey | optionKey | shiftKey),
                EventHotKeyID(signature: 0x53515145, id: 1), GetApplicationEventTarget(), 0, &captureKey)
            captureShortcut = fallback == noErr ? "⇧⌥⌘S" : "через кнопку"
        }
        var pasteShortcut = "⌥⌘V"
        let pasteStatus = RegisterEventHotKey(9, UInt32(cmdKey | optionKey),
            EventHotKeyID(signature: 0x53515145, id: 2), GetApplicationEventTarget(), 0, &pasteKey)
        if pasteStatus != noErr {
            let fallback = RegisterEventHotKey(9, UInt32(cmdKey | optionKey | shiftKey),
                EventHotKeyID(signature: 0x53515145, id: 2), GetApplicationEventTarget(), 0, &pasteKey)
            pasteShortcut = fallback == noErr ? "⇧⌥⌘V" : "через кнопку"
        }
        captureMenuItem.title = "Новый снимок  \(captureShortcut)"
        pasteMenuItem.title = "Вставить серию  \(pasteShortcut)"
        queuePanel.setShortcuts(capture: captureShortcut, paste: pasteShortcut)
    }

    @objc private func captureAction() { capture() }
    @objc private func pasteAction() { pasteSeries() }
    @objc private func showQueue() { queuePanel.show(count: store.shots.count) }
    @objc private func showSettings() {
        if settingsPanel == nil { settingsPanel = SettingsPanel() }
        settingsPanel?.show()
    }
    @objc private func clearAction() {
        guard !store.shots.isEmpty, !pasting, overlay == nil else { return }
        if Preferences.confirmBeforeClearing {
            let alert = NSAlert(); alert.messageText = "Очистить очередь из \(store.shots.count) снимков?"
            alert.informativeText = "Предыдущая серия останется в локальном архиве ShotQueue."
            alert.addButton(withTitle: "Очистить"); alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do { try store.clear(); queuePanel.show(count: 0) } catch { showError(error) }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func capture() {
        guard overlay == nil else { return }
        guard let letter = store.nextLetter else { showError(ShotError.queueFull); return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            let alert = NSAlert()
            alert.messageText = "Разреши ShotQueue запись экрана"
            alert.informativeText = "macOS попросит доступ к записи экрана. После разрешения закрой и снова открой ShotQueue."
            alert.runModal()
            return
        }
        queuePanel.hide()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try? await Task.sleep(nanoseconds: 200_000_000) // дать панели исчезнуть до снимка
                let image = try await SCScreenshotManager.captureImage(in: screen.frame)
                self.overlay = OverlayController(screen: screen, image: image, letter: letter,
                    onFinish: { [weak self] selection, marks in
                        guard let self else { return }
                        self.overlay?.close(); self.overlay = nil
                        do { try self.store.append(image: image, selection: selection, marks: marks, screenSize: screen.frame.size) }
                        catch { self.showError(error) }
                        self.queuePanel.show(count: self.store.shots.count)
                    }, onCancel: { [weak self] in
                        self?.overlay?.close(); self?.overlay = nil
                        if let self { self.queuePanel.show(count: self.store.shots.count) }
                    })
            } catch {
                self.showError(error); self.queuePanel.show(count: self.store.shots.count)
            }
        }
    }

    func pasteSeries() {
        guard !store.shots.isEmpty, !pasting else { return }
        guard AXIsProcessTrusted() else {
            let alert = NSAlert()
            alert.messageText = "Разреши ShotQueue Универсальный доступ"
            alert.informativeText = "Он нужен, чтобы ⌥⌘V вставил снимки и текст в открытое поле Codex. ShotQueue сам сообщение не отправляет."
            alert.runModal()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let target = (front?.bundleIdentifier == Bundle.main.bundleIdentifier ? lastExternalApp : front) ?? lastExternalApp
        guard let target, target.bundleIdentifier == "com.microsoft.VSCode" || target.bundleIdentifier == "com.openai.codex" else {
            showError(PasteError.noTarget); return
        }
        pasting = true
        queuePanel.hide()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pasting = false; self.queuePanel.show(count: self.store.shots.count) }
            do {
                _ = target.activate(options: [])
                try await Task.sleep(nanoseconds: 250_000_000)
                for shot in self.store.shots {
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                        throw PasteError.targetChanged
                    }
                    guard let data = self.store.imageData(for: shot) else { throw PasteError.missingImage }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setData(data, forType: .png)
                    guard self.postCommandV() else { throw PasteError.eventFailed }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                    throw PasteError.targetChanged
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.store.markdown(), forType: .string)
                guard self.postCommandV() else { throw PasteError.eventFailed }
            } catch { self.showError(error) }
        }
    }

    private func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "ShotQueue: \(error.localizedDescription)"
        alert.informativeText = "Если это первый захват, разреши ShotQueue запись экрана в настройках macOS и перезапусти приложение."
        alert.runModal()
    }
}
