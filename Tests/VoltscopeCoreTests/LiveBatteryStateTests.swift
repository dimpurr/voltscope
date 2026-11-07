import XCTest
@testable import VoltscopeCore

/// Charge-state derivation from the three public Power Sources keys, plus the one
/// derived transitional state. Wording is asserted here as well because the panel,
/// the menu bar and VoiceOver all read it.
final class LiveBatteryStateTests: XCTestCase {
    func testFourSteadyStatesComeFromThePublicKeys() {
        XCTAssertEqual(
            BatteryChargeState.resolve(isACPlugged: true, isCharging: true, isCharged: false),
            .charging
        )
        XCTAssertEqual(
            BatteryChargeState.resolve(isACPlugged: true, isCharging: false, isCharged: false),
            .pluggedNotCharging
        )
        XCTAssertEqual(
            BatteryChargeState.resolve(isACPlugged: true, isCharging: false, isCharged: true),
            .charged
        )
        XCTAssertEqual(
            BatteryChargeState.resolve(isACPlugged: false, isCharging: false, isCharged: false),
            .onBattery
        )
    }

    func testTransitionalStateOnlyAppearsInsideTheSettleWindow() {
        XCTAssertEqual(
            BatteryChargeState.resolve(
                isACPlugged: true, isCharging: false, isCharged: false,
                settlingAfterPlugChange: true
            ),
            .startingToCharge
        )
        // Outside the window the same keys are the honest steady state: whatever
        // the reason, the battery is not charging.
        XCTAssertEqual(
            BatteryChargeState.resolve(
                isACPlugged: true, isCharging: false, isCharged: false,
                settlingAfterPlugChange: false
            ),
            .pluggedNotCharging
        )
    }

    func testChargedIsNeverGuessed() {
        // An 80 percent hold reports AC with neither charging nor charged set.
        XCTAssertEqual(
            BatteryChargeState.resolve(
                isACPlugged: true, isCharging: false, isCharged: false,
                settlingAfterPlugChange: true
            ),
            .startingToCharge
        )
        XCTAssertNotEqual(
            BatteryChargeState.resolve(isACPlugged: true, isCharging: false, isCharged: false),
            .charged
        )
    }

    func testBatteryPowerWinsOverTheChargingAndChargedKeys() {
        // Should not happen, but a battery on the road must not be drawn as
        // plugged in just because a stale key says so.
        XCTAssertEqual(
            BatteryChargeState.resolve(isACPlugged: false, isCharging: true, isCharged: true),
            .onBattery
        )
    }

    func testSettlingNeverInventsChargingOrCharged() {
        for isCharged in [true, false] {
            let settling = BatteryChargeState.resolve(
                isACPlugged: true, isCharging: false, isCharged: isCharged,
                settlingAfterPlugChange: true
            )
            XCTAssertNotEqual(settling, .charging)
        }
        let charging = BatteryChargeState.resolve(
            isACPlugged: true, isCharging: true, isCharged: false,
            settlingAfterPlugChange: true
        )
        XCTAssertEqual(charging, .charging)
    }

    func testEveryStateHasDistinctWordingSymbolAndSpokenForm() {
        let states = BatteryChargeState.allCases
        XCTAssertEqual(Set(states.map { $0.displayName }).count, states.count)
        XCTAssertEqual(Set(states.map { $0.spokenName }).count, states.count)
        XCTAssertEqual(Set(states.map { $0.announcementText }).count, states.count)
        for state in states {
            XCTAssertFalse(state.displayName.isEmpty)
            XCTAssertEqual(state.spokenName, state.spokenName.lowercased())
            XCTAssertFalse(state.symbolName.isEmpty)
        }
    }

    func testWordingMatchesTheSpecification() {
        XCTAssertEqual(BatteryChargeState.charging.displayName, "Charging")
        XCTAssertEqual(BatteryChargeState.startingToCharge.displayName, "Plugged In, Starting to Charge…")
        XCTAssertEqual(BatteryChargeState.pluggedNotCharging.displayName, "Plugged In, Not Charging")
        XCTAssertEqual(BatteryChargeState.charged.displayName, "Battery Is Charged")
        XCTAssertEqual(BatteryChargeState.onBattery.displayName, "On Battery")
    }

    func testOnlyThePowerStatesCountAsConnectedToPower() {
        XCTAssertTrue(BatteryChargeState.charging.isConnectedToPower)
        XCTAssertTrue(BatteryChargeState.startingToCharge.isConnectedToPower)
        XCTAssertTrue(BatteryChargeState.pluggedNotCharging.isConnectedToPower)
        XCTAssertTrue(BatteryChargeState.charged.isConnectedToPower)
        XCTAssertFalse(BatteryChargeState.onBattery.isConnectedToPower)
    }

    func testLiveReadingDecidesItsStateAtSampleTime() {
        func reading(isACPlugged: Bool, isCharging: Bool, isCharged: Bool, settling: Bool) -> LiveBatteryReading {
            LiveBatteryReading(
                snapshot: BatterySnapshot(
                    timestamp: 1_700_000_000_000, levelPercent: 66, capacityMAh: nil, designMAh: nil,
                    cycleCount: nil, voltageMV: nil, amperageMA: nil, temperatureC: nil,
                    timeRemainingMin: nil, isCharging: isCharging, isACPlugged: isACPlugged
                ),
                isCharged: isCharged,
                settlingAfterPlugChange: settling
            )
        }
        XCTAssertEqual(reading(isACPlugged: true, isCharging: false, isCharged: false, settling: true).chargeState, .startingToCharge)
        XCTAssertEqual(reading(isACPlugged: true, isCharging: true, isCharged: false, settling: true).chargeState, .charging)
        XCTAssertEqual(reading(isACPlugged: true, isCharging: false, isCharged: true, settling: false).chargeState, .charged)
        XCTAssertEqual(reading(isACPlugged: false, isCharging: false, isCharged: false, settling: true).chargeState, .onBattery)
        XCTAssertEqual(reading(isACPlugged: true, isCharging: false, isCharged: false, settling: true).levelPercent, 66)
    }
}
