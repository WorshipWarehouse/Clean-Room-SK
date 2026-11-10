import CoreAudio
import Foundation

/// Asks the system whether there is an output device at all.
///
/// `AVAudioEngine` will happily let you reach into `outputNode` on a Mac with no
/// output device and then raise an Objective-C exception, which Swift cannot
/// catch and which takes the process down. Asking CoreAudio first turns that into
/// an ordinary error the app can show in its status line.
///
/// Only the default output device matters here: the graph is connected to
/// `outputNode`, which follows the system default, so a machine with some other
/// device selected is the same case as one with none.
enum DefaultOutputDevice {
    static func exists() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )

        return status == noErr && device != AudioObjectID(kAudioObjectUnknown)
    }
}
