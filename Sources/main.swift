// foldctl: sets the pose (hinge angle and orientation) of the iPhone Duo simulator from the command line.
//
// It does what Device Hub's pose controls do. CoreDevice sends a vendor-defined HID event (usage page
// 0xFF61, usage 0x5B) whose payload is a binary IOCFSerialize'd dictionary: for the hinge
// {"source": "hinge-slider-control", "type": "range", "value": <degrees>}, for the orientation
// {"source": "orientation-picker-control", "type": "enum", "value": <orientation name>}. Inside the
// simulator, dtuhidd posts the event and locationd's device state relay applies it. The tool then waits
// until CoreDevice's motion monitors report the new pose.
import CoreDevice
import CoreDeviceUtilities
import Foundation
import IOKit
import Synchronization

@main
struct FoldCtl {
    static let usage = """
        usage: foldctl <device> [--hinge <angle>] [--orientation <orientation>]

          device         a simulator UDID, a simulator name, or "booted" for the only booted simulator
          --hinge        closed (0), half (90), open (180), or any angle from 0 to 180
          --orientation  portrait, landscape-left, landscape-right, faceup or facedown

        Without options it prints the current pose.

        examples:
          foldctl booted
          foldctl booted --hinge closed
          foldctl "iPhone Duo" --hinge half --orientation landscape-left
        """

    /// What the tool is waiting for, which the timeout message names.
    static let stage = Mutex("waiting for CoreDevice")

    static func main() async {
        let (deviceArgument, hinge, orientation) = parseArguments()
        let simulator = resolveSimulator(deviceArgument)

        // CoreDevice can stall while it reaches a simulator's services; give up instead of hanging.
        Task {
            guard (try? await Task.sleep(for: .seconds(60))) != nil else { return }
            fail("timed out after 60 seconds \(stage.withLock { $0 })")
        }

        setStage("finding \(simulator.name) in CoreDevice")
        // DeviceManager.shared hides simulators; devicectl opts into them the same way.
        let manager = DeviceManager(
            serviceConnection: CoreDeviceService.sharedConnection,
            allowedDeviceVisibilityClasses: [.default, .simulators]
        )
        await manager.awaitFullInitialization()
        // Simulators come from a CoreDevice plugin that checks in after the initial device list.
        await manager.waitForPostPluginLoadCheckIn()
        guard let device = manager.devices[simulator.udid] else {
            fail("CoreDevice does not list \(simulator.name) (\(simulator.udid.uuidString)); is it booted?")
        }

        setStage("reading the pose of \(simulator.name)")
        var monitor: PoseMonitor
        do {
            let motionManager = try await device.getImplementation(
                for: CapabilityStaticMember<MonitorMotionCapability>.monitorMotion
            ).motionManager()
            guard motionManager.supportsHingeAngle, motionManager.supportsDeviceMotionState else {
                fail("\(simulator.name) is not foldable")
            }
            monitor = try await PoseMonitor(motionManager: motionManager)
        } catch {
            fail("could not read the pose of \(simulator.name): \(String(reflecting: error))")
        }

        if hinge != nil || orientation != nil {
            let vendorDefined: any HIDVendorDefined
            do {
                vendorDefined = try await device.getImplementation(
                    for: CapabilityStaticMember<VendorDefinedHIDCapability>.hid.vendorDefined
                )
            } catch {
                fail("\(simulator.name) offers no vendor-defined HID: \(String(reflecting: error))")
            }
            // dtuhidd builds the connection's virtual HID services when it connects and drops an event that
            // arrives before them; the barrier waits for those services.
            vendorDefined.sendBarrier()
            do throws(CoreDeviceError) {
                if let hinge {
                    try vendorDefined.send(
                        usagePage: 0xFF61, usage: 0x5B, version: 0,
                        data: event(source: "hinge-slider-control", type: "range", value: NSNumber(value: hinge))
                    )
                }
                if let orientation {
                    try vendorDefined.send(
                        usagePage: 0xFF61, usage: 0x5B, version: 0,
                        data: event(source: "orientation-picker-control", type: "enum", value: orientation.name as NSString)
                    )
                }
            } catch {
                fail("sending the pose failed: \(String(reflecting: error))")
            }

            // The services hold the events until locationd opens them, and they go away with this process, so
            // it stays until the simulator reports the new pose.
            do {
                if let hinge {
                    setStage("waiting for \(simulator.name) to report a hinge angle of \(hinge.formatted())°")
                    try await monitor.waitForAngle(near: hinge)
                }
                if let orientation {
                    setStage("waiting for \(simulator.name) to report \(orientation.name)")
                    try await monitor.waitForOrientation(orientation)
                }
            } catch {
                fail("the pose monitor of \(simulator.name) failed: \(String(reflecting: error))")
            }
        }
        print("\(simulator.name): \(monitor.description)")
    }

    static func setStage(_ description: String) {
        stage.withLock { $0 = description }
    }

    static func parseArguments() -> (device: String, hinge: Double?, orientation: Orientation?) {
        var arguments = CommandLine.arguments.dropFirst()
        if arguments.contains("-h") || arguments.contains("--help") {
            print(usage)
            exit(0)
        }
        guard let device = arguments.popFirst(), !device.hasPrefix("-") else { fail(usage, code: 64) }
        var hinge: Double?
        var orientation: Orientation?
        while let option = arguments.popFirst() {
            guard let value = arguments.popFirst() else { fail("\(option) needs a value\n\n\(usage)", code: 64) }
            switch option {
            case "--hinge":
                hinge = switch value {
                case "closed": 0
                case "half": 90
                case "open": 180
                default: Double(value).flatMap { (0...180).contains($0) ? $0 : nil }
                }
                guard hinge != nil else {
                    fail("invalid hinge angle \"\(value)\": use closed, half, open or a number from 0 to 180", code: 64)
                }
            case "--orientation":
                orientation = Orientation.allCases.first { $0.name == value }
                guard orientation != nil else {
                    let names = Orientation.allCases.map(\.name).joined(separator: ", ")
                    fail("invalid orientation \"\(value)\": use \(names)", code: 64)
                }
            default:
                fail("unknown option \(option)\n\n\(usage)", code: 64)
            }
        }
        return (device, hinge, orientation)
    }

    static func event(source: String, type: String, value: NSObject) -> Data {
        let payload: NSDictionary = ["source": source, "type": type, "value": value]
        guard let data = IOCFSerialize(payload, CFOptionFlags(kIOCFSerializeToBinary)) as Data? else {
            fail("could not serialize \(payload)")
        }
        return data
    }

    struct Simulator {
        let udid: UUID
        let name: String
        let isBooted: Bool
    }

    /// Resolves a UDID, a name or "booted" against `simctl list devices`, preferring booted simulators.
    static func resolveSimulator(_ argument: String) -> Simulator {
        let simulators = listSimulators()
        if let udid = UUID(uuidString: argument) {
            return simulators.first(where: { $0.udid == udid }) ?? Simulator(udid: udid, name: argument, isBooted: true)
        }
        let candidates = argument == "booted"
            ? simulators.filter(\.isBooted)
            : simulators.filter { $0.name == argument }.sorted { $0.isBooted && !$1.isBooted }
        guard let simulator = candidates.first else {
            fail(argument == "booted" ? "no simulator is booted" : "no simulator is named \"\(argument)\"")
        }
        if argument == "booted", candidates.count > 1 {
            let names = candidates.map { "  \($0.name) \($0.udid.uuidString)" }.joined(separator: "\n")
            fail("more than one simulator is booted; name one:\n\(names)")
        }
        guard simulator.isBooted else { fail("\(simulator.name) is not booted") }
        return simulator
    }

    static func listSimulators() -> [Simulator] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            fail("could not run simctl: \(error.localizedDescription)")
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]]
        else {
            fail("could not read the simulator list from simctl")
        }
        return runtimes.values.flatMap { $0 }.compactMap { entry in
            guard let udidString = entry["udid"] as? String,
                  let udid = UUID(uuidString: udidString),
                  let name = entry["name"] as? String
            else { return nil }
            return Simulator(udid: udid, name: name, isBooted: entry["state"] as? String == "Booted")
        }
    }

    static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("foldctl: \(message)\n".utf8))
        exit(code)
    }
}

/// An orientation as locationd's device state relay names it in the event and numbers it in the motion
/// state, which uses UIDeviceOrientation's raw values. The relay has no portrait-upside-down.
enum Orientation: Int, CaseIterable {
    case portrait = 1
    case landscapeLeft = 3
    case landscapeRight = 4
    case faceUp = 5
    case faceDown = 6

    var name: String {
        switch self {
        case .portrait: "portrait"
        case .landscapeLeft: "landscape-left"
        case .landscapeRight: "landscape-right"
        case .faceUp: "faceup"
        case .faceDown: "facedown"
        }
    }
}

/// Follows the hinge angle and motion state streams. Both report the current value first, then every change.
struct PoseMonitor: CustomStringConvertible {
    struct StreamEnded: Error {}

    // The motion state names its properties opaquely; propertyA is the orientation. (propertyB is the posture
    // locationd derives from the hinge angle, and it can lag the angle, so the tool reports the angle instead.)
    static let orientationKey = "propertyA"

    private var angles: AsyncThrowingStream<[DeviceHingeAngleSnapshot], any Error>.Iterator
    private var states: AsyncThrowingStream<[DeviceMotionStateSnapshot], any Error>.Iterator
    private(set) var angle = 0.0
    private(set) var state: [String: Int] = [:]

    init(motionManager: DeviceMotionManager) async throws {
        angles = try await motionManager.monitorHingeAngle(
            config: HingeAngleStreamConfig(
                changeThreshold: Measurement(value: 0.5, unit: .degrees),
                updateInterval: .milliseconds(100)
            )
        ).makeAsyncIterator()
        states = try await motionManager.monitorDeviceMotionState().makeAsyncIterator()
        try await nextAngle()
        try await nextState()
    }

    mutating func waitForAngle(near target: Double) async throws {
        while abs(angle - target) > 0.5 {
            try await nextAngle()
        }
    }

    mutating func waitForOrientation(_ orientation: Orientation) async throws {
        while state[Self.orientationKey] != orientation.rawValue {
            try await nextState()
        }
    }

    var description: String {
        let orientation = switch state[Self.orientationKey] {
        case let code?: Orientation(rawValue: code)?.name ?? "orientation \(code)"
        case nil: "orientation unknown"
        }
        return "hinge \(angle.formatted(.number.precision(.fractionLength(0...1))))°, \(orientation)"
    }

    private mutating func nextAngle() async throws {
        while true {
            guard let snapshots = try await angles.next() else { throw StreamEnded() }
            if let snapshot = snapshots.last(where: \.isAngleValid) {
                angle = snapshot.angle.converted(to: .degrees).value
                return
            }
        }
    }

    private mutating func nextState() async throws {
        guard let snapshots = try await states.next() else { throw StreamEnded() }
        for snapshot in snapshots {
            for (key, value) in snapshot.properties {
                switch value.unwrappedValue() {
                case let integer as Int: state[key] = integer
                case let integer as UInt: state[key] = Int(integer)
                default: break
                }
            }
        }
    }
}
