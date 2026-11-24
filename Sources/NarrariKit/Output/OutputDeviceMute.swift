import CoreAudio

public struct OutputDeviceMute: DeviceMuteSwitch {
    public init() {}

    public func defaultOutputUID() -> String? {
        AudioDevices.defaultOutput().flatMap(AudioDevices.uid(of:))
    }

    public func hasMute(_ uid: String) -> Bool {
        AudioDevices.device(uid: uid).map { !Self.muteElements(of: $0).isEmpty } ?? false
    }

    public func isMuted(_ uid: String) -> Bool {
        guard let device = AudioDevices.device(uid: uid) else { return false }
        let elements = Self.muteElements(of: device)
        return !elements.isEmpty && elements.allSatisfy { element in
            var address = Self.muteAddress(element)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
        }
    }

    // A device that is gone has nothing left to unmute.
    public func setMuted(_ isMuted: Bool, _ uid: String) -> Bool {
        guard let device = AudioDevices.device(uid: uid) else { return !isMuted }
        let elements = Self.muteElements(of: device)
        guard isMuted else { return Self.set(false, on: device, elements) }
        var muted: [AudioObjectPropertyElement] = []
        for element in elements {
            guard Self.set(true, on: device, [element]) else { break }
            muted.append(element)
        }
        guard !elements.isEmpty, muted.count == elements.count else {
            if !muted.isEmpty, !Self.set(false, on: device, muted) { Log.failure("output-unmute-rollback") }
            return false
        }
        return true
    }

    private static func muteElements(of device: AudioObjectID) -> [AudioObjectPropertyElement] {
        if isMuteSettable(device, kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        let channels = (1...max(outputChannelCount(of: device), 1)).map { AudioObjectPropertyElement($0) }
        return channels.allSatisfy { isMuteSettable(device, $0) } ? channels : []
    }

    private static func isMuteSettable(_ device: AudioObjectID, _ element: AudioObjectPropertyElement) -> Bool {
        var address = muteAddress(element)
        var isSettable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address) else { return false }
        return AudioObjectIsPropertySettable(device, &address, &isSettable) == noErr && isSettable.boolValue
    }

    private static func set(
        _ isMuted: Bool, on device: AudioObjectID, _ elements: [AudioObjectPropertyElement]
    ) -> Bool {
        guard !elements.isEmpty else { return false }
        return elements.allSatisfy { element in
            var address = muteAddress(element)
            var value: UInt32 = isMuted ? 1 : 0
            return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
        }
    }

    private static func outputChannelCount(of device: AudioObjectID) -> Int {
        var address = AudioDevices.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func muteAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioDevices.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, element: element)
    }
}
