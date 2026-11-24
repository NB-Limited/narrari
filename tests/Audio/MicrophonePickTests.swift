import CoreAudio
import NarrariKit
import Testing

struct MicrophonePickTests {
    private let headset: AudioObjectID = 1
    private let builtIn: AudioObjectID = 2
    private let usb: AudioObjectID = 3

    private func pick(
        chosen: AudioObjectID? = nil, systemDefault: AudioObjectID? = 1, headsetTransport: UInt32 = kAudioDeviceTransportTypeBluetooth,
        hasBuiltIn: Bool = true, prefersBuiltIn: Bool = true
    ) -> MicrophonePick? {
        var inputs = [(device: headset, transport: headsetTransport), (device: usb, transport: kAudioDeviceTransportTypeUSB)]
        if hasBuiltIn { inputs.append((device: builtIn, transport: kAudioDeviceTransportTypeBuiltIn)) }
        return MicrophonePick.resolve(chosen: chosen, systemDefault: systemDefault, inputs: inputs, prefersBuiltIn: prefersBuiltIn)
    }

    @Test(arguments: [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE])
    func bluetooth_default_records_from_the_built_in_microphone(_ transport: UInt32) {
        #expect(pick(headsetTransport: transport) == .builtInOverBluetooth(builtIn))
    }

    @Test func bluetooth_default_is_used_when_the_setting_is_off() {
        #expect(pick(prefersBuiltIn: false) == .systemDefault(headset))
    }

    @Test func chosen_microphone_wins_even_when_it_is_bluetooth() {
        #expect(pick(chosen: headset) == .chosen(headset))
    }

    @Test func bluetooth_default_is_used_when_there_is_no_built_in_microphone() {
        #expect(pick(hasBuiltIn: false) == .systemDefault(headset))
    }

    @Test func default_that_is_not_bluetooth_is_used_as_it_is() {
        #expect(pick(systemDefault: usb) == .systemDefault(usb))
    }
}
