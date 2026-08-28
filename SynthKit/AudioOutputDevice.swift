import AVFoundation
import CoreAudio
import Foundation

/// One output device the system can play through.
public struct AudioOutputDevice: Equatable, Identifiable, Sendable {
    /// Core Audio's per-boot identifier. Not stable across restarts — persist
    /// `uid` instead.
    public let deviceID: AudioDeviceID
    /// Stable across restarts and reconnections. This is what a preference
    /// should remember.
    public let uid: String
    public let name: String
    public let outputChannelCount: Int
    public let isDefault: Bool

    public var id: String { uid }

    public init(
        deviceID: AudioDeviceID,
        uid: String,
        name: String,
        outputChannelCount: Int,
        isDefault: Bool
    ) {
        self.deviceID = deviceID
        self.uid = uid
        self.name = name
        self.outputChannelCount = outputChannelCount
        self.isDefault = isDefault
    }
}

/// Reads the Core Audio HAL: which output devices exist, and which one the
/// system prefers.
///
/// Every call is a live query. A device list is exactly the kind of state that
/// goes stale the moment a cable moves, so nothing here is cached; the
/// observer below exists to say "ask again", not to hand out a snapshot.
public enum AudioOutputDeviceCatalog {
    /// Every device with at least one output channel, in the HAL's order.
    ///
    /// Returns an empty array on a machine with no audio hardware — a headless
    /// CI runner, for instance — rather than failing. Callers distinguish "no
    /// devices" from "could not ask" through `enumerate()`'s thrown error.
    public static func outputDevices() -> [AudioOutputDevice] {
        (try? enumerate()) ?? []
    }

    public enum CatalogError: Error, CustomStringConvertible {
        case propertyUnavailable(OSStatus)

        public var description: String {
            switch self {
            case .propertyUnavailable(let status):
                return "Core Audio refused a device query with status \(status)."
            }
        }
    }

    /// Live query, with the failure surfaced.
    ///
    /// A refused query is UNKNOWN, not "no devices": silently returning an
    /// empty list would make a broken HAL look exactly like a Mac with the
    /// speakers unplugged.
    public static func enumerate() throws -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr else { throw CatalogError.propertyUnavailable(status) }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        )
        guard status == noErr else { throw CatalogError.propertyUnavailable(status) }

        let defaultID = defaultOutputDeviceID()

        return ids.compactMap { id -> AudioOutputDevice? in
            let channels = outputChannelCount(of: id)
            guard channels > 0 else { return nil }
            return AudioOutputDevice(
                deviceID: id,
                uid: stringProperty(of: id, selector: kAudioDevicePropertyDeviceUID) ?? "device-\(id)",
                name: stringProperty(of: id, selector: kAudioObjectPropertyName) ?? "Output \(id)",
                outputChannelCount: channels,
                isDefault: id == defaultID
            )
        }
    }

    /// The system's current default output, or nil when there is none.
    public static func defaultOutputDevice() -> AudioOutputDevice? {
        let id = defaultOutputDeviceID()
        guard id != kAudioObjectUnknown else { return nil }
        return outputDevices().first { $0.deviceID == id }
    }

    public static func defaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : AudioDeviceID(kAudioObjectUnknown)
    }

    static func outputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, raw) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func stringProperty(of deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String
    }
}

/// Watches the HAL for the two changes that matter: the default output moved,
/// or the set of devices changed.
///
/// Both callbacks arrive on an arbitrary queue, so the observer hops to the
/// main queue before calling back. Nothing here runs on the audio thread.
final class AudioOutputDeviceObserver {
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var isRunning = false

    private let onDefaultDeviceChanged: @Sendable () -> Void
    private let onDeviceListChanged: @Sendable () -> Void

    init(
        onDefaultDeviceChanged: @escaping @Sendable () -> Void,
        onDeviceListChanged: @escaping @Sendable () -> Void
    ) {
        self.onDefaultDeviceChanged = onDefaultDeviceChanged
        self.onDeviceListChanged = onDeviceListChanged
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let handleDefault: AudioObjectPropertyListenerBlock = { [onDefaultDeviceChanged] _, _ in
            DispatchQueue.main.async { onDefaultDeviceChanged() }
        }
        let handleList: AudioObjectPropertyListenerBlock = { [onDeviceListChanged] _, _ in
            DispatchQueue.main.async { onDeviceListChanged() }
        }
        defaultDeviceListener = handleDefault
        deviceListListener = handleList

        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddress, nil, handleDefault
        )

        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, nil, handleList
        )
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let defaultDeviceListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, nil, defaultDeviceListener
            )
        }
        if let deviceListListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, nil, deviceListListener
            )
        }
        defaultDeviceListener = nil
        deviceListListener = nil
    }

    deinit { stop() }
}
