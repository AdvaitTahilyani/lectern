import AVFoundation

/// Builds Float32 formats and constant-valued buffers for converter tests.
enum AVAudioFormatFactory {
    static func make(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        if channels > 2 {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
        }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
    }

    static func buffer(_ format: AVAudioFormat, frames: Int, value: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<frames { buffer.floatChannelData![channel][frame] = value }
        }
        return buffer
    }
}
