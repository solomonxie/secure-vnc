import SecureVNCKit
import UIKit

/// Draws the remote framebuffer and turns touches and keys into RFB input.
final class RemoteScreenView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    var trackpadMode = true { didSet { layoutContent() } }
    var onKeyboardHidden: (() -> Void)?

    private var client: RFBClient?
    private let imageLayer = CALayer()
    private let cursorLayer = CALayer()
    private var displayLink: CADisplayLink?
    private let dirty = DirtyFlag()

    private var fbSize = CGSize(width: 1, height: 1)
    private var zoom: CGFloat = 1
    private var offset = CGPoint.zero
    private var pointer = CGPoint.zero
    private var buttons: UInt8 = 0
    private var cursorHotspot = CGPoint.zero
    private var cursorSize = CGSize(width: 16, height: 16)
    private var hasCursorShape = false
    private var scrollRemainder: CGFloat = 0
    private var lastDragPoint = CGPoint.zero
    private var sticky: Set<UInt32> = []
    private lazy var keyBar = KeyBar { [weak self] in self?.barKey($0) }

    // MARK: Lifecycle

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        layer.addSublayer(imageLayer)
        cursorLayer.magnificationFilter = .nearest
        layer.addSublayer(cursorLayer)
        installGestures()
    }

    required init?(coder: NSCoder) { fatalError() }

    func attach(_ client: RFBClient) {
        self.client = client
        let fb = client.framebuffer
        fbSize = CGSize(width: max(fb.width, 1), height: max(fb.height, 1))
        pointer = CGPoint(x: fbSize.width / 2, y: fbSize.height / 2)
        let dirty = dirty
        client.onUpdate = { dirty.set() }
        client.onResize = { _, _ in dirty.set(resized: true) }
        client.onCursor = { [weak self] shape in
            DispatchQueue.main.async { self?.setCursor(shape) }
        }
        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        dirty.set(resized: true)
    }

    func detach() {
        displayLink?.invalidate()
        displayLink = nil
        client?.onUpdate = nil
        client?.onCursor = nil
        client?.onResize = nil
    }

    fileprivate func tick() {
        guard let client, let (changed, resized) = dirty.take(), changed else { return }
        if resized {
            fbSize = CGSize(width: max(client.framebuffer.width, 1), height: max(client.framebuffer.height, 1))
            pointer.x = min(pointer.x, fbSize.width - 1)
            pointer.y = min(pointer.y, fbSize.height - 1)
            layoutContent()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = client.framebuffer.makeImage()
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutContent()
    }

    // MARK: Geometry

    private var scale: CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / fbSize.width, bounds.height / fbSize.height) * zoom
    }

    private func clampOffset() {
        let w = fbSize.width * scale, h = fbSize.height * scale
        offset.x = w <= bounds.width ? (bounds.width - w) / 2 : min(0, max(bounds.width - w, offset.x))
        offset.y = h <= bounds.height ? (bounds.height - h) / 2 : min(0, max(bounds.height - h, offset.y))
    }

    private func layoutContent() {
        clampOffset()
        let s = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = CGRect(x: offset.x, y: offset.y, width: fbSize.width * s, height: fbSize.height * s)
        let showCursor = trackpadMode || hasCursorShape
        cursorLayer.isHidden = !showCursor
        if hasCursorShape {
            cursorLayer.frame = CGRect(x: offset.x + (pointer.x - cursorHotspot.x) * s,
                                       y: offset.y + (pointer.y - cursorHotspot.y) * s,
                                       width: cursorSize.width * s, height: cursorSize.height * s)
        } else {
            let d: CGFloat = 14
            cursorLayer.frame = CGRect(x: offset.x + pointer.x * s - d / 2, y: offset.y + pointer.y * s - d / 2, width: d, height: d)
            cursorLayer.cornerRadius = d / 2
            cursorLayer.borderWidth = 2
            cursorLayer.borderColor = UIColor.white.cgColor
            cursorLayer.backgroundColor = UIColor.black.withAlphaComponent(0.4).cgColor
        }
        CATransaction.commit()
    }

    private func setCursor(_ shape: CursorShape) {
        hasCursorShape = shape.image != nil
        cursorLayer.contents = shape.image
        cursorLayer.borderWidth = 0
        cursorLayer.cornerRadius = 0
        cursorLayer.backgroundColor = nil
        cursorHotspot = shape.hotspot
        cursorSize = shape.size
        layoutContent()
    }

    private func fbPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max((p.x - offset.x) / scale, 0), fbSize.width - 1),
                y: min(max((p.y - offset.y) / scale, 0), fbSize.height - 1))
    }

    /// Keeps the pointer on screen when zoomed in.
    private func follow() {
        let s = scale, margin: CGFloat = 40
        let vx = offset.x + pointer.x * s, vy = offset.y + pointer.y * s
        if vx < margin { offset.x += margin - vx } else if vx > bounds.width - margin { offset.x -= vx - (bounds.width - margin) }
        if vy < margin { offset.y += margin - vy } else if vy > bounds.height - margin { offset.y -= vy - (bounds.height - margin) }
    }

    // MARK: Pointer output

    private func sendPointer() {
        client?.pointer(x: Int(pointer.x), y: Int(pointer.y), buttons: buttons)
        layoutContent()
    }

    private func click(_ button: MouseButton) {
        buttons |= button.rawValue
        sendPointer()
        buttons &= ~button.rawValue
        sendPointer()
    }

    // MARK: Gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap))
        let twoTap = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap))
        twoTap.numberOfTouchesRequired = 2
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan))
        pan.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch))
        let press = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress))
        press.minimumPressDuration = 0.35
        for g in [tap, twoTap, pan, scroll, pinch, press] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
            || (other is UIPinchGestureRecognizer && g is UIPanGestureRecognizer)
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        if !trackpadMode { pointer = fbPoint(g.location(in: self)) }
        click(.left)
    }

    @objc private func onTwoFingerTap(_ g: UITapGestureRecognizer) {
        if !trackpadMode { pointer = fbPoint(g.location(in: self)) }
        click(.right)
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if trackpadMode {
            let speed = 1 + min(g.velocity(in: self).magnitude / 1500, 1.5)
            let s = scale
            pointer.x = min(max(pointer.x + t.x * speed / s, 0), fbSize.width - 1)
            pointer.y = min(max(pointer.y + t.y * speed / s, 0), fbSize.height - 1)
            follow()
            sendPointer()
        } else {
            offset.x += t.x
            offset.y += t.y
            layoutContent()
        }
    }

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        if g.state == .began {
            scrollRemainder = 0
            if !trackpadMode { pointer = fbPoint(g.location(in: self)); sendPointer() }
        }
        scrollRemainder += g.translation(in: self).y
        g.setTranslation(.zero, in: self)
        let step: CGFloat = 14
        while abs(scrollRemainder) >= step {
            click(scrollRemainder > 0 ? .scrollUp : .scrollDown)
            scrollRemainder -= scrollRemainder > 0 ? step : -step
        }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        let loc = g.location(in: self)
        let before = CGPoint(x: (loc.x - offset.x) / scale, y: (loc.y - offset.y) / scale)
        zoom = min(max(zoom * g.scale, 1), 5)
        g.scale = 1
        offset = CGPoint(x: loc.x - before.x * scale, y: loc.y - before.y * scale)
        layoutContent()
    }

    @objc private func onLongPress(_ g: UILongPressGestureRecognizer) {
        let loc = g.location(in: self)
        if !trackpadMode {
            if g.state == .began {
                pointer = fbPoint(loc)
                click(.right)
            }
            return
        }
        switch g.state {
        case .began:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            lastDragPoint = loc
            buttons |= MouseButton.left.rawValue
            sendPointer()
        case .changed:
            let s = scale
            pointer.x = min(max(pointer.x + (loc.x - lastDragPoint.x) / s, 0), fbSize.width - 1)
            pointer.y = min(max(pointer.y + (loc.y - lastDragPoint.y) / s, 0), fbSize.height - 1)
            lastDragPoint = loc
            follow()
            sendPointer()
        default:
            buttons &= ~MouseButton.left.rawValue
            sendPointer()
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { keyBar }

    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        onKeyboardHidden?()
        return r
    }

    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    func insertText(_ text: String) {
        for scalar in text.unicodeScalars { type(KeySym.of(scalar)) }
    }

    func deleteBackward() { type(KeySym.backspace) }

    private func barKey(_ key: KeyBar.Key) {
        switch key {
        case .modifier(let sym):
            if sticky.contains(sym) { sticky.remove(sym) } else { sticky.insert(sym) }
            keyBar.highlight(sticky)
        case .key(let sym):
            type(sym)
        }
    }

    /// Presses a key with any sticky modifiers held, then releases them.
    private func type(_ sym: UInt32) {
        guard let client else { return }
        let mods = Array(sticky)
        for m in mods { client.key(m, down: true) }
        client.key(sym, down: true)
        client.key(sym, down: false)
        for m in mods.reversed() { client.key(m, down: false) }
        if !sticky.isEmpty {
            sticky.removeAll()
            keyBar.highlight(sticky)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let key = press.key, let sym = Self.keysym(key) { client?.key(sym, down: true) } else { unhandled.insert(press) }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        releasePresses(presses, event) { super.pressesEnded($0, with: $1) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        releasePresses(presses, event) { super.pressesCancelled($0, with: $1) }
    }

    private func releasePresses(_ presses: Set<UIPress>, _ event: UIPressesEvent?,
                                fallback: (Set<UIPress>, UIPressesEvent?) -> Void) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let key = press.key, let sym = Self.keysym(key) { client?.key(sym, down: false) } else { unhandled.insert(press) }
        }
        if !unhandled.isEmpty { fallback(unhandled, event) }
    }

    static func keysym(_ key: UIKey) -> UInt32? {
        switch key.keyCode {
        case .keyboardReturnOrEnter, .keypadEnter: return KeySym.enter
        case .keyboardTab: return KeySym.tab
        case .keyboardDeleteOrBackspace: return KeySym.backspace
        case .keyboardDeleteForward: return KeySym.delete
        case .keyboardEscape: return KeySym.escape
        case .keyboardLeftArrow: return KeySym.left
        case .keyboardRightArrow: return KeySym.right
        case .keyboardUpArrow: return KeySym.up
        case .keyboardDownArrow: return KeySym.down
        case .keyboardHome: return KeySym.home
        case .keyboardEnd: return KeySym.end
        case .keyboardPageUp: return KeySym.pageUp
        case .keyboardPageDown: return KeySym.pageDown
        case .keyboardLeftShift, .keyboardRightShift: return KeySym.shift
        case .keyboardLeftControl, .keyboardRightControl: return KeySym.control
        case .keyboardLeftAlt, .keyboardRightAlt: return KeySym.option
        case .keyboardLeftGUI, .keyboardRightGUI: return KeySym.command
        case .keyboardF1: return KeySym.f(1)
        case .keyboardF2: return KeySym.f(2)
        case .keyboardF3: return KeySym.f(3)
        case .keyboardF4: return KeySym.f(4)
        case .keyboardF5: return KeySym.f(5)
        case .keyboardF6: return KeySym.f(6)
        case .keyboardF7: return KeySym.f(7)
        case .keyboardF8: return KeySym.f(8)
        case .keyboardF9: return KeySym.f(9)
        case .keyboardF10: return KeySym.f(10)
        case .keyboardF11: return KeySym.f(11)
        case .keyboardF12: return KeySym.f(12)
        default:
            guard let scalar = key.charactersIgnoringModifiers.unicodeScalars.first else { return nil }
            return KeySym.of(scalar)
        }
    }
}

/// Set from the RFB reading task, drained by the display link on the main thread.
private final class DirtyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    private var resized = false

    func set(resized r: Bool = false) {
        lock.withLock {
            changed = true
            resized = resized || r
        }
    }

    func take() -> (Bool, Bool)? {
        lock.withLock {
            defer { changed = false; resized = false }
            return (changed, resized)
        }
    }
}

/// Breaks the CADisplayLink → view retain cycle.
private final class DisplayLinkTarget {
    weak var view: RemoteScreenView?
    init(_ view: RemoteScreenView) { self.view = view }
    @objc func tick() { view?.tick() }
}

private extension CGPoint {
    var magnitude: CGFloat { (x * x + y * y).squareRoot() }
}

final class KeyBar: UIInputView {
    enum Key { case key(UInt32), modifier(UInt32) }

    private let onKey: (Key) -> Void
    private var modifierButtons: [UInt32: UIButton] = [:]

    init(onKey: @escaping (Key) -> Void) {
        self.onKey = onKey
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let items: [(String, Key)] = [
            ("esc", .key(KeySym.escape)), ("tab", .key(KeySym.tab)),
            ("⌃", .modifier(KeySym.control)), ("⌥", .modifier(KeySym.option)), ("⌘", .modifier(KeySym.command)),
            ("←", .key(KeySym.left)), ("↑", .key(KeySym.up)), ("↓", .key(KeySym.down)), ("→", .key(KeySym.right)),
        ]
        let stack = UIStackView()
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (title, key) in items {
            var config = UIButton.Configuration.gray()
            config.title = title
            config.cornerStyle = .medium
            config.contentInsets = .zero
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.onKey(key) })
            button.accessibilityLabel = Self.spokenName(title)
            if case .modifier(let sym) = key { modifierButtons[sym] = button }
            stack.addArrangedSubview(button)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            heightAnchor.constraint(equalToConstant: 46),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func highlight(_ active: Set<UInt32>) {
        for (sym, button) in modifierButtons {
            button.configuration?.baseBackgroundColor = active.contains(sym) ? tintColor : nil
            button.configuration?.baseForegroundColor = active.contains(sym) ? .white : nil
        }
    }

    private static func spokenName(_ title: String) -> String {
        ["⌃": "Control", "⌥": "Option", "⌘": "Command", "←": "Left", "↑": "Up", "↓": "Down", "→": "Right"][title] ?? title
    }
}
