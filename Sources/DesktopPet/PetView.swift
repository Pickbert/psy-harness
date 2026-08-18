import AppKit

enum PetMood {
    case idle
    case walking
    case sleeping
    case waiting
}

struct PetFrames {
    let idle: NSImage
    let blink: NSImage
    let walking: [NSImage]
    let lifted: [NSImage]
    let waiting: NSImage
    let waitingBlink: NSImage
    let waitingEar: NSImage
    let waitingTail: NSImage
}

enum PetAnimation {
    static func liftedFrameIndex(elapsed: TimeInterval, frameCount: Int) -> Int {
        guard frameCount > 1 else { return 0 }
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: 1.2)
        return phase >= 0.42 && phase < 0.60 ? 1 : 0
    }
}

private enum WaitingMotion {
    case ear
    case tail
}

final class PetView: NSView {
    var onDragStarted: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onTripleClick: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onInteraction: (() -> Void)?

    var mood: PetMood = .idle {
        didSet {
            if mood == .waiting, oldValue != .waiting {
                waitingMotion = nil
                nextWaitingMotionAt = animationTime + Double.random(in: 1.2...2.8)
            } else if mood != .waiting {
                waitingMotion = nil
            }
        }
    }
    var isFacingRight = true

    private let frames: PetFrames
    private var animationTime: TimeInterval = 0
    private var nextBlinkAt: TimeInterval = 2.4
    private var blinkStartedAt: TimeInterval?
    private var isDoubleBlink = false
    private var waitingMotion: WaitingMotion?
    private var waitingMotionStartedAt: TimeInterval = 0
    private var waitingMotionEndsAt: TimeInterval = 0
    private var nextWaitingMotionAt: TimeInterval = 2
    private var affectionStartedAt: TimeInterval = -10
    private var affectionEndsAt: TimeInterval = -10
    private var mouseDownLocation: CGPoint?
    private var windowOriginAtMouseDown: CGPoint?
    private var didDrag = false
    private var isBeingDragged = false
    private var dragAnimationStartedAt: TimeInterval = 0
    private var message: String?
    private var messageExpiresAt: TimeInterval = 0
    private var hearts: [HeartParticle] = []

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    init(frame frameRect: NSRect, frames: PetFrames) {
        self.frames = frames
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func update(deltaTime: TimeInterval) {
        animationTime += deltaTime
        updateBlink()
        updateWaitingMotion()
        hearts = hearts.compactMap { particle in
            var next = particle
            next.age += deltaTime
            return next.age < next.lifetime ? next : nil
        }

        if animationTime >= messageExpiresAt {
            message = nil
        }
        needsDisplay = true
    }

    func showAffection() {
        let messages = ["汪！", "摸摸～", "今天也要开心呀", "我在这里！", "要一起散步吗？"]
        message = messages.randomElement() ?? "汪！"
        messageExpiresAt = animationTime + 2.2
        affectionStartedAt = animationTime
        affectionEndsAt = animationTime + 1.05

        for index in 0..<3 {
            hearts.append(
                HeartParticle(
                    age: -Double(index) * 0.12,
                    lifetime: 1.45,
                    horizontalOffset: CGFloat.random(in: -28...28),
                    size: CGFloat.random(in: 14...22)
                )
            )
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onInteraction?()
        mouseDownLocation = NSEvent.mouseLocation
        windowOriginAtMouseDown = window.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            let window,
            let mouseDownLocation,
            let windowOriginAtMouseDown
        else { return }

        let currentLocation = NSEvent.mouseLocation
        let deltaX = currentLocation.x - mouseDownLocation.x
        let deltaY = currentLocation.y - mouseDownLocation.y
        if !didDrag, hypot(deltaX, deltaY) > 3 {
            didDrag = true
            isBeingDragged = true
            dragAnimationStartedAt = animationTime
            blinkStartedAt = nil
            onDragStarted?()
        }
        window.setFrameOrigin(
            CGPoint(x: windowOriginAtMouseDown.x + deltaX, y: windowOriginAtMouseDown.y + deltaY)
        )
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            isBeingDragged = false
            needsDisplay = true
            onDragEnded?()
        } else if event.clickCount >= 3 {
            onTripleClick?()
        } else if event.clickCount == 1 {
            showAffection()
        }
        mouseDownLocation = nil
        windowOriginAtMouseDown = nil
        didDrag = false
    }

    override func rightMouseDown(with event: NSEvent) {
        onInteraction?()
        onContextMenu?(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill()

        drawDog()
        drawHearts()
        drawMessage()
    }

    private func drawDog() {
        guard let context = NSGraphicsContext.current else { return }

        let messageAllowance: CGFloat = message == nil ? 8 : 28
        let sidePadding = bounds.width * 0.04
        let dogRect = CGRect(
            x: sidePadding,
            y: 2,
            width: bounds.width - sidePadding * 2,
            height: bounds.height - messageAllowance
        )

        var bob: CGFloat
        let breathingScale: CGFloat
        var tilt: CGFloat

        if isBeingDragged {
            let elapsed = animationTime - dragAnimationStartedAt
            bob = 4 + CGFloat(sin(elapsed * 8) * 1.2)
            breathingScale = 1
            tilt = CGFloat(sin(elapsed * 7) * 0.018)
        } else {
            switch mood {
            case .walking:
                bob = abs(sin(animationTime * 9)) * 5
                breathingScale = 1
                tilt = sin(animationTime * 9) * 0.025
            case .sleeping:
                bob = 0
                breathingScale = 0.97 + CGFloat((sin(animationTime * 2.2) + 1) * 0.012)
                tilt = -0.035
            case .waiting:
                bob = CGFloat(sin(animationTime * 2.0) * 0.55)
                breathingScale = 0.992 + CGFloat((sin(animationTime * 2.0) + 1) * 0.006)
                tilt = CGFloat(sin(animationTime * 0.9) * 0.004)
            case .idle:
                bob = CGFloat(sin(animationTime * 2.8) * 1.5)
                breathingScale = 0.99 + CGFloat((sin(animationTime * 2.8) + 1) * 0.008)
                tilt = CGFloat(sin(animationTime * 1.3) * 0.008)
            }
        }

        if !isBeingDragged, animationTime < affectionEndsAt {
            let progress = CGFloat((animationTime - affectionStartedAt) / (affectionEndsAt - affectionStartedAt))
            bob += abs(sin(progress * .pi * 2)) * 7 * (1 - progress * 0.35)
            tilt += sin(progress * .pi * 4) * 0.045 * (1 - progress)
        }

        context.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: dogRect.midX, yBy: dogRect.midY + bob)
        transform.rotate(byRadians: tilt)
        transform.scaleX(by: isFacingRight ? 1 : -1, yBy: breathingScale)
        transform.translateX(by: -dogRect.midX, yBy: -dogRect.midY)
        transform.concat()
        activeFrame().draw(in: dogRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        context.restoreGraphicsState()

        if mood == .sleeping, !isBeingDragged {
            drawSleepMarks()
        }
    }

    private func updateBlink() {
        guard mood == .idle || mood == .waiting else {
            blinkStartedAt = nil
            return
        }

        if let blinkStartedAt {
            let duration = isDoubleBlink ? 0.31 : 0.13
            if animationTime - blinkStartedAt >= duration {
                self.blinkStartedAt = nil
                nextBlinkAt = animationTime + Double.random(in: 2.4...5.8)
            }
        } else if animationTime >= nextBlinkAt {
            blinkStartedAt = animationTime
            isDoubleBlink = Int.random(in: 0..<4) == 0
        }
    }

    private func updateWaitingMotion() {
        guard mood == .waiting else { return }
        if waitingMotion != nil, animationTime >= waitingMotionEndsAt {
            waitingMotion = nil
            nextWaitingMotionAt = animationTime + Double.random(in: 1.8...4.5)
        } else if waitingMotion == nil, animationTime >= nextWaitingMotionAt {
            waitingMotion = Bool.random() ? .ear : .tail
            waitingMotionStartedAt = animationTime
            waitingMotionEndsAt = animationTime + (waitingMotion == .ear ? 0.38 : 0.72)
        }
    }

    private func activeFrame() -> NSImage {
        if isBeingDragged, !frames.lifted.isEmpty {
            let index = PetAnimation.liftedFrameIndex(
                elapsed: animationTime - dragAnimationStartedAt,
                frameCount: frames.lifted.count
            )
            return frames.lifted[index]
        }
        switch mood {
        case .walking:
            guard !frames.walking.isEmpty else { return frames.idle }
            let frameIndex = Int(animationTime * 8.5) % frames.walking.count
            return frames.walking[frameIndex]
        case .sleeping:
            return frames.blink
        case .waiting:
            if let blinkStartedAt {
                let elapsed = animationTime - blinkStartedAt
                if elapsed <= 0.13 || (isDoubleBlink && elapsed >= 0.19 && elapsed <= 0.31) {
                    return frames.waitingBlink
                }
            }
            if let waitingMotion {
                let elapsed = animationTime - waitingMotionStartedAt
                switch waitingMotion {
                case .ear:
                    return (elapsed < 0.14 || elapsed >= 0.24) ? frames.waitingEar : frames.waiting
                case .tail:
                    return Int(elapsed / 0.12).isMultiple(of: 2) ? frames.waitingTail : frames.waiting
                }
            }
            return frames.waiting
        case .idle:
            guard let blinkStartedAt else { return frames.idle }
            let elapsed = animationTime - blinkStartedAt
            if elapsed <= 0.13 || (isDoubleBlink && elapsed >= 0.19 && elapsed <= 0.31) {
                return frames.blink
            }
            return frames.idle
        }
    }

    private func drawHearts() {
        for particle in hearts where particle.age >= 0 {
            let progress = CGFloat(particle.age / particle.lifetime)
            let center = CGPoint(
                x: bounds.midX + particle.horizontalOffset + sin(progress * 8) * 6,
                y: bounds.height * 0.68 + progress * bounds.height * 0.3
            )
            drawHeart(
                center: center,
                size: particle.size * (1 - progress * 0.25),
                alpha: max(0, 1 - progress)
            )
        }
    }

    private func drawHeart(center: CGPoint, size: CGFloat, alpha: CGFloat) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: center.x, y: center.y - size * 0.42))
        path.curve(
            to: CGPoint(x: center.x - size * 0.5, y: center.y + size * 0.1),
            controlPoint1: CGPoint(x: center.x - size * 0.15, y: center.y - size * 0.25),
            controlPoint2: CGPoint(x: center.x - size * 0.62, y: center.y - size * 0.08)
        )
        path.curve(
            to: CGPoint(x: center.x, y: center.y + size * 0.48),
            controlPoint1: CGPoint(x: center.x - size * 0.5, y: center.y + size * 0.38),
            controlPoint2: CGPoint(x: center.x - size * 0.18, y: center.y + size * 0.5)
        )
        path.curve(
            to: CGPoint(x: center.x + size * 0.5, y: center.y + size * 0.1),
            controlPoint1: CGPoint(x: center.x + size * 0.18, y: center.y + size * 0.5),
            controlPoint2: CGPoint(x: center.x + size * 0.5, y: center.y + size * 0.38)
        )
        path.curve(
            to: CGPoint(x: center.x, y: center.y - size * 0.42),
            controlPoint1: CGPoint(x: center.x + size * 0.62, y: center.y - size * 0.08),
            controlPoint2: CGPoint(x: center.x + size * 0.15, y: center.y - size * 0.25)
        )
        path.close()
        NSColor.systemPink.withAlphaComponent(alpha).setFill()
        path.fill()
    }

    private func drawMessage() {
        guard let message else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(12, bounds.width * 0.07), weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = (message as NSString).size(withAttributes: attributes)
        let bubbleRect = CGRect(
            x: max(4, bounds.midX - textSize.width / 2 - 11),
            y: bounds.height - textSize.height - 13,
            width: min(bounds.width - 8, textSize.width + 22),
            height: textSize.height + 10
        )

        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 11, yRadius: 11)
        bubble.fill()
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        bubble.lineWidth = 1
        bubble.stroke()

        let textRect = CGRect(
            x: bubbleRect.midX - textSize.width / 2,
            y: bubbleRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        (message as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func drawSleepMarks() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: bounds.width * 0.12, weight: .bold),
            .foregroundColor: NSColor.systemIndigo.withAlphaComponent(0.82)
        ]
        ("Z" as NSString).draw(
            at: CGPoint(x: bounds.width * 0.76, y: bounds.height * 0.71),
            withAttributes: attributes
        )
    }
}

private struct HeartParticle {
    var age: TimeInterval
    let lifetime: TimeInterval
    let horizontalOffset: CGFloat
    let size: CGFloat
}
