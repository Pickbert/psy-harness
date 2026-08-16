import Foundation
import CoreGraphics

enum PetMotion {
    struct Step: Equatable {
        let x: CGFloat
        let reachedTarget: Bool
        let isFacingRight: Bool
    }

    static func step(currentX: CGFloat, targetX: CGFloat, speed: CGFloat, deltaTime: TimeInterval) -> Step {
        let distance = targetX - currentX
        let isFacingRight = distance >= 0
        let maximumTravel = max(0, speed * CGFloat(max(0, deltaTime)))

        guard abs(distance) > maximumTravel, maximumTravel > 0 else {
            return Step(x: targetX, reachedTarget: true, isFacingRight: isFacingRight)
        }

        return Step(
            x: currentX + (isFacingRight ? maximumTravel : -maximumTravel),
            reachedTarget: false,
            isFacingRight: isFacingRight
        )
    }

    static func clampedOrigin(_ origin: CGPoint, windowSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - windowSize.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - windowSize.height)

        return CGPoint(
            x: min(max(origin.x, visibleFrame.minX), maximumX),
            y: min(max(origin.y, visibleFrame.minY), maximumY)
        )
    }
}
