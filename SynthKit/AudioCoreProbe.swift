import Foundation

public enum AudioCoreProbe {
    public static func probe(_ value: Int32) -> Int32 { synth_audio_core_probe(value) }
}
