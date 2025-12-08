import UIKit

/// Physics-based spring animator for smooth blob movement
final class SpringAnimator {

    // MARK: - State

    /// Current animated position
    private(set) var current: CGPoint = .zero

    /// Current velocity
    private(set) var velocity: CGPoint = .zero

    /// Target position
    var target: CGPoint = .zero

    // MARK: - Spring Parameters

    /// Mass affects momentum (higher = more inertia)
    var mass: CGFloat = 1.0

    /// Stiffness affects snap speed (higher = faster return to target)
    var stiffness: CGFloat = 300.0

    /// Damping affects oscillation (higher = less bounce)
    var damping: CGFloat = 20.0

    // MARK: - Internal

    private var lastTime: CFTimeInterval = 0

    /// Whether the spring has settled (velocity and displacement below threshold)
    var isSettled: Bool {
        let displacement = hypot(current.x - target.x, current.y - target.y)
        let speed = hypot(velocity.x, velocity.y)
        return displacement < 0.5 && speed < 0.5
    }

    /// Velocity normalized to -1...1 range for shader slime effect
    var normalizedVelocity: CGPoint {
        let maxSpeed: CGFloat = 500  // points/second normalization factor (lowered for more sensitivity)
        let normalized = CGPoint(
            x: max(-1, min(1, velocity.x / maxSpeed)),
            y: max(-1, min(1, velocity.y / maxSpeed))
        )
        // Debug log
        if abs(velocity.x) > 1 || abs(velocity.y) > 1 {
            print("[SpringAnimator] raw velocity: \(velocity), normalized: \(normalized)")
        }
        return normalized
    }

    // MARK: - Initialization

    init(mass: CGFloat = 1.0, stiffness: CGFloat = 300.0, damping: CGFloat = 20.0) {
        self.mass = mass
        self.stiffness = stiffness
        self.damping = damping
    }

    // MARK: - Animation

    /// Step the spring simulation forward by one frame
    /// Call this on every frame (CADisplayLink callback)
    func step() {
        let now = CACurrentMediaTime()

        // Calculate delta time, capped to avoid explosion after long pauses
        let dt: CGFloat
        if lastTime == 0 {
            dt = 1.0 / 120.0
        } else {
            dt = min(CGFloat(now - lastTime), 1.0 / 30.0)
        }
        lastTime = now

        // Spring force: F = -kx - cv
        // Where k = stiffness, c = damping, x = displacement, v = velocity

        let displacement = CGPoint(
            x: current.x - target.x,
            y: current.y - target.y
        )

        let springForce = CGPoint(
            x: -stiffness * displacement.x,
            y: -stiffness * displacement.y
        )

        let dampingForce = CGPoint(
            x: -damping * velocity.x,
            y: -damping * velocity.y
        )

        let acceleration = CGPoint(
            x: (springForce.x + dampingForce.x) / mass,
            y: (springForce.y + dampingForce.y) / mass
        )

        // Semi-implicit Euler integration (more stable than basic Euler)
        velocity.x += acceleration.x * dt
        velocity.y += acceleration.y * dt
        current.x += velocity.x * dt
        current.y += velocity.y * dt
    }

    /// Set position immediately or animate to it
    /// - Parameters:
    ///   - position: Target position
    ///   - animated: If false, jumps immediately without animation
    func setPosition(_ position: CGPoint, animated: Bool) {
        target = position

        if !animated {
            current = position
            velocity = .zero
            lastTime = 0
        }
    }

    /// Add impulse velocity (e.g., from gesture release)
    func addVelocity(_ v: CGPoint) {
        velocity.x += v.x
        velocity.y += v.y
    }

    /// Reset animator state
    func reset() {
        current = .zero
        velocity = .zero
        target = .zero
        lastTime = 0
    }

    /// Configure from LiquidGlassConfiguration
    func configure(with config: LiquidGlassConfiguration) {
        self.mass = config.springMass
        self.stiffness = config.springStiffness
        self.damping = config.springDamping
    }
}

// MARK: - Radius Animator

/// Animator for blob radius changes (simpler linear interpolation)
final class RadiusAnimator {

    private(set) var current: CGFloat = 0
    var target: CGFloat = 0

    /// Speed of radius change in points per second
    var speed: CGFloat = 400.0

    var isSettled: Bool {
        abs(current - target) < 0.5
    }

    func step() {
        let diff = target - current
        if abs(diff) < 0.5 {
            current = target
            return
        }

        let step = (speed / 120.0) * (diff > 0 ? 1 : -1)
        if abs(step) > abs(diff) {
            current = target
        } else {
            current += step
        }
    }

    func setValue(_ value: CGFloat, animated: Bool) {
        target = value
        if !animated {
            current = value
        }
    }
}

// MARK: - Scale Animator

/// Spring-based animator for blob scale effects (hover/press)
final class ScaleAnimator {

    // MARK: - State

    /// Current animated scale
    private(set) var current: CGFloat = 1.0

    /// Target scale
    var target: CGFloat = 1.0

    /// Current velocity
    private var velocity: CGFloat = 0.0

    /// Last update time
    private var lastTime: CFTimeInterval = 0

    // MARK: - Spring Parameters

    /// Stiffness affects snap speed (higher = faster return to target)
    var stiffness: CGFloat = 2000.0

    /// Damping affects oscillation (higher = less bounce, ~89 = critical for stiffness 2000)
    var damping: CGFloat = 80.0

    /// Whether the spring has settled
    var isSettled: Bool {
        abs(current - target) < 0.001 && abs(velocity) < 0.001
    }

    // MARK: - Animation

    /// Step the spring simulation forward by one frame
    func step() {
        let now = CACurrentMediaTime()

        let dt: CGFloat
        if lastTime == 0 {
            dt = 1.0 / 120.0
        } else {
            dt = min(CGFloat(now - lastTime), 1.0 / 30.0)
        }
        lastTime = now

        let displacement = current - target
        let springForce = -stiffness * displacement
        let dampingForce = -damping * velocity
        let acceleration = springForce + dampingForce

        velocity += acceleration * dt
        current += velocity * dt
    }

    /// Set scale immediately or animate to it
    func setScale(_ scale: CGFloat, animated: Bool) {
        target = scale
        if !animated {
            current = scale
            velocity = 0
            lastTime = 0
        }
    }

    /// Reset to default scale
    func reset() {
        current = 1.0
        target = 1.0
        velocity = 0
        lastTime = 0
    }
}
