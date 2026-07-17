#!/usr/bin/env swift

import Foundation

/// Deterministic scalar model of the experimental controller in Scroll.m.
/// It exercises sparse TB800-style change reports independently of USB polling rate.

struct InputEvent {
    let time: Double
    let distance: Double
}

struct Scenario {
    let name: String
    let events: [InputEvent]
}

struct Result {
    let accepted: Double
    let position: Double
    let maximumPosition: Double
    let minimumFrameDelta: Double
    let motionGapsBeforeLastInput: Int
    let firstOutputMs: Double
    let settleAfterLastInputMs: Double
}

func clip(_ value: Double, _ low: Double, _ high: Double) -> Double {
    min(high, max(low, value))
}

func advanceSpring(position: inout Double, velocity: inout Double, target: Double, omega: Double, dt: Double) {
    let error = position - target
    let velocityPlusOmegaError = velocity + omega * error
    let decay = exp(-omega * dt)
    let newError = (error + velocityPlusOmegaError * dt) * decay
    velocity = (velocity - omega * velocityPlusOmegaError * dt) * decay
    position = target + newError
}

func simulate(_ scenario: Scenario, refreshRate: Double) -> Result {
    let dt = 1.0 / refreshRate
    let releaseDelay = 56.66 / 1000.0
    let activeOmega = 90.0
    let releaseOmega = 26.0

    var position = 0.0
    var lastPosition = 0.0
    var target = 0.0
    var velocity = 0.0
    var pending = 0.0
    var feedSpeed = 0.0
    var feedHorizon = 0.0
    var recentInputInterval = 0.0
    var effectiveReleaseDelay = releaseDelay
    var lastInputTime = -Double.infinity
    var eventIndex = 0
    var accepted = 0.0
    var maximumPosition = 0.0
    var minimumFrameDelta = Double.infinity
    var firstOutputTime: Double?
    var motionGapsBeforeLastInput = 0
    var startedMoving = false
    var settledTime = 0.0
    let lastInput = scenario.events.last!.time

    for frame in 1...Int(refreshRate * 2.0) {
        let now = Double(frame) * dt

        while eventIndex < scenario.events.count && scenario.events[eventIndex].time <= now + 1e-12 {
            let event = scenario.events[eventIndex]
            if lastInputTime.isFinite {
                let interval = event.time - lastInputTime
                if interval > 0 && interval <= 0.5 {
                    if recentInputInterval <= 0 || interval < recentInputInterval {
                        recentInputInterval = interval
                    } else {
                        let alpha = 1.0 - exp(-interval / 0.060)
                        recentInputInterval += alpha * (interval - recentInputInterval)
                    }
                }
            }

            pending += event.distance
            accepted += event.distance
            lastInputTime = event.time
            effectiveReleaseDelay = max(releaseDelay, min(0.140, recentInputInterval * 1.5))

            let minimumFeedHorizon = max(0.012, dt * 2.0)
            let cadenceFeedHorizon = recentInputInterval > 0
                ? recentInputInterval * 1.25
                : max(releaseDelay, 0.050)
            feedHorizon = clip(cadenceFeedHorizon, minimumFeedHorizon, 0.140)
            feedSpeed = pending / feedHorizon
            eventIndex += 1
        }

        if pending > 1e-6 {
            let fed = min(pending, feedSpeed * dt)
            target += fed
            pending -= fed
            if pending < 1e-6 {
                pending = 0
                feedSpeed = 0
            }
        }

        let inputIsActive = now - lastInputTime <= effectiveReleaseDelay
        var omega = inputIsActive ? activeOmega : releaseOmega
        if !inputIsActive {
            let remaining = target - position
            if remaining > 0.001 && velocity > 0 {
                omega = min(160.0, max(omega, 1.05 * velocity / remaining))
            }
        }

        advanceSpring(position: &position, velocity: &velocity, target: target, omega: omega, dt: dt)

        let isSettled = !inputIsActive && pending < 0.001 && target - position < 0.20 && abs(velocity) < 4.0
        if isSettled {
            position = target
            velocity = 0
        }

        let frameDelta = position - lastPosition
        lastPosition = position
        maximumPosition = max(maximumPosition, position)
        minimumFrameDelta = min(minimumFrameDelta, frameDelta)

        if frameDelta > 0.01 {
            startedMoving = true
            if firstOutputTime == nil { firstOutputTime = now }
        } else if startedMoving && now <= lastInput + 1e-12 {
            motionGapsBeforeLastInput += 1
        }

        if isSettled && eventIndex == scenario.events.count {
            settledTime = now
            break
        }
    }

    return Result(
        accepted: accepted,
        position: position,
        maximumPosition: maximumPosition,
        minimumFrameDelta: minimumFrameDelta,
        motionGapsBeforeLastInput: motionGapsBeforeLastInput,
        firstOutputMs: (firstOutputTime ?? .infinity) * 1000.0,
        settleAfterLastInputMs: (settledTime - lastInput) * 1000.0
    )
}

let scenarios = [
    Scenario(name: "isolated-small", events: [InputEvent(time: 0, distance: 25)]),
    Scenario(name: "sparse-95ms", events: stride(from: 0.0, through: 0.475, by: 0.095).map { InputEvent(time: $0, distance: 289) }),
    Scenario(name: "steady-50ms", events: stride(from: 0.0, through: 0.400, by: 0.050).map { InputEvent(time: $0, distance: 289) }),
    Scenario(name: "fast-20ms", events: stride(from: 0.0, through: 0.400, by: 0.020).map { InputEvent(time: $0, distance: 289) }),
    Scenario(name: "accelerating", events: [
        InputEvent(time: 0.000, distance: 25),
        InputEvent(time: 0.095, distance: 100),
        InputEvent(time: 0.175, distance: 180),
        InputEvent(time: 0.235, distance: 240),
        InputEvent(time: 0.275, distance: 289),
        InputEvent(time: 0.300, distance: 289),
        InputEvent(time: 0.320, distance: 289),
    ]),
]

var failed = false
for refreshRate in [60.0, 120.0, 144.0] {
    for scenario in scenarios {
        let result = simulate(scenario, refreshRate: refreshRate)
        let exact = abs(result.position - result.accepted) < 1e-6
        let monotonic = result.minimumFrameDelta >= -1e-9
        let noOvershoot = result.maximumPosition <= result.accepted + 1e-6
        let noActiveGaps = scenario.name == "isolated-small" || result.motionGapsBeforeLastInput == 0
        let settlesPromptly = result.settleAfterLastInputMs > 0 && result.settleAfterLastInputMs < 500
        let passed = exact && monotonic && noOvershoot && noActiveGaps && settlesPromptly
        failed = failed || !passed

        print(String(
            format: "%3.0fHz %-15s %@ first=%5.1fms settle=%5.1fms gaps=%d final=%.1f/%.1f",
            refreshRate,
            (scenario.name as NSString).utf8String!,
            passed ? "PASS" : "FAIL",
            result.firstOutputMs,
            result.settleAfterLastInputMs,
            result.motionGapsBeforeLastInput,
            result.position,
            result.accepted
        ))
    }
}

if failed { exit(1) }
