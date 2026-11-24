import CoreAudio

enum AudioDevices {
    static func defaultOutput() -> AudioObjectID? { systemDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    static func defaultInput() -> AudioObjectID? { systemDevice(kAudioHardwarePropertyDefaultInputDevice) }

    private static func systemDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = address(selector)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func inputDevices() -> [AudioObjectID] {
        objects(in: AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices)).filter(hasInput)
    }

    static func inputStreams(of device: AudioObjectID) -> [AudioStreamID] {
        objects(in: device, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput))
    }

    static func objects(in object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    static func virtualFormat(of stream: AudioStreamID) -> AudioStreamBasicDescription? {
        var address = address(kAudioStreamPropertyVirtualFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format) == noErr ? format : nil
    }

    static func nominalSampleRate(of device: AudioObjectID) -> Double? {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr && rate > 0 ? rate : nil
    }

    static func isAlive(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    static func name(of device: AudioObjectID) -> String? { string(kAudioObjectPropertyName, of: device) }

    static func uid(of device: AudioObjectID) -> String? { string(kAudioDevicePropertyDeviceUID, of: device) }

    static func string(_ selector: AudioObjectPropertySelector, of device: AudioObjectID) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { value in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, value)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func transport(of device: AudioObjectID) -> UInt32 {
        var address = address(kAudioDevicePropertyTransportType)
        var transport = kAudioDeviceTransportTypeUnknown
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr ? transport : kAudioDeviceTransportTypeUnknown
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    static func device(uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device
            )
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}
