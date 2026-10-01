import CoreAudio
import Dispatch
import Foundation

let queue = DispatchQueue(label: "mic-in-use")
let system = AudioObjectID(kAudioObjectSystemObject)
let defaultInputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
let runningAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

func property(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
    var address = address
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    guard status == noErr else {
        fputs("CoreAudio property read failed: \(status)\n", stderr)
        return nil
    }
    return value
}

func printState(_ device: AudioObjectID) {
    guard let running = property(device, runningAddress) else { return }
    print("\(ISO8601DateFormatter().string(from: Date())) state=\(running == 0 ? "idle" : "in-use")")
    fflush(stdout)
}

var device = AudioObjectID(kAudioObjectUnknown)
let runningListener: AudioObjectPropertyListenerBlock = { _, _ in
    printState(device)
}
let defaultInputListener: AudioObjectPropertyListenerBlock = { _, _ in
    let next = property(system, defaultInputAddress) ?? kAudioObjectUnknown
    guard next != device else { return }
    if device != kAudioObjectUnknown {
        var address = runningAddress
        let status = AudioObjectRemovePropertyListenerBlock(device, &address, queue, runningListener)
        if status != noErr { fputs("CoreAudio listener removal failed: \(status)\n", stderr) }
    }
    device = next
    if device != kAudioObjectUnknown {
        var address = runningAddress
        let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, runningListener)
        if status != noErr { fputs("CoreAudio listener registration failed: \(status)\n", stderr) }
        printState(device)
    } else {
        print("\(ISO8601DateFormatter().string(from: Date())) state=idle")
        fflush(stdout)
    }
}

var address = defaultInputAddress
let status = AudioObjectAddPropertyListenerBlock(system, &address, queue, defaultInputListener)
guard status == noErr else {
    fputs("CoreAudio default input listener registration failed: \(status)\n", stderr)
    exit(1)
}
defaultInputListener(0, UnsafePointer(&address))
dispatchMain()
