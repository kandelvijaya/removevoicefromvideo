import Foundation
import AudioToolbox

private func checked(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw Failure("AUSoundIsolation \(operation) failed: OSStatus \(status)") }
}

private final class Feed {
    let channels: Int
    let samples: UnsafeMutablePointer<Float>
    var position = 0
    init(channels: Int) {
        self.channels = channels
        samples = .allocate(capacity: blockFrames * channels)
        samples.initialize(repeating: 0, count: blockFrames * channels)
    }
    deinit { samples.deallocate() }
}

/// Each instance owns a distinct vois unit; the pipeline connects instances in memory.
final class Isolation: BlockRenderer {
    let channels: Int
    private(set) var latencyFrames = 0
    private var unit: AudioUnit?
    private var initialized = false
    private let feed: Feed
    private let buffers: UnsafeMutableAudioBufferListPointer
    private var time: Double = 0

    init(channels: Int) throws {
        guard channels == 1 || channels == 2 else { throw Failure("only mono and stereo audio are supported") }
        self.channels = channels
        feed = Feed(channels: channels)
        buffers = AudioBufferList.allocate(maximumBuffers: channels)
        for c in 0..<channels {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
            pointer.initialize(repeating: 0, count: blockFrames)
            buffers[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(blockFrames * 4), mData: pointer)
        }
        do { try configure() } catch { cleanup(); throw error }
    }
    private func configure() throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
            componentSubType: 0x766F6973, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw Failure("Apple AUSoundIsolation (vois) is unavailable")
        }
        try checked(AudioComponentInstanceNew(component, &unit), "instantiate")
        guard let unit = unit else { throw Failure("AUSoundIsolation returned no instance") }

        // Query advertised channel combinations. No mono fallback or stereo downmix.
        var size: UInt32 = 0
        var writable = DarwinBoolean(false)
        try checked(AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_SupportedNumChannels,
                    kAudioUnitScope_Global, 0, &size, &writable), "query channel capability")
        guard size > 0, size % UInt32(MemoryLayout<AUChannelInfo>.size) == 0 else {
            throw Failure("invalid AUSoundIsolation channel capability")
        }
        var combinations = [AUChannelInfo](repeating: AUChannelInfo(), count: Int(size) / MemoryLayout<AUChannelInfo>.size)
        try combinations.withUnsafeMutableBytes { bytes in
            try checked(AudioUnitGetProperty(unit, kAudioUnitProperty_SupportedNumChannels,
                kAudioUnitScope_Global, 0, bytes.baseAddress!, &size), "read channel capability")
        }
        let ch = Int32(channels)
        guard combinations.contains(where: {
            ($0.inChannels == ch || $0.inChannels < 0) && ($0.outChannels == ch || $0.outChannels < 0)
        }) else { throw Failure("AUSoundIsolation does not advertise \(channels)-channel support") }

        var format = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
            try checked(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0, &format,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set \(channels)-channel format")
            var actual = AudioStreamBasicDescription()
            var bytes = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try checked(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0, &actual, &bytes), "read format")
            guard actual.mSampleRate == format.mSampleRate, actual.mChannelsPerFrame == format.mChannelsPerFrame,
                  actual.mFormatID == format.mFormatID, actual.mFormatFlags == format.mFormatFlags,
                  actual.mBytesPerFrame == 4, actual.mBitsPerChannel == 32 else {
                throw Failure("AUSoundIsolation changed the requested PCM format")
            }
        }
        for (parameter, value) in [(AudioUnitParameterID(0), Float(-100)), (AudioUnitParameterID(1), Float(0))] {
            var info = AudioUnitParameterInfo()
            var bytes = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
            try checked(AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global,
                                             parameter, &info, &bytes), "query parameter \(parameter)")
            guard info.minValue <= value, value <= info.maxValue else {
                throw Failure("AUSoundIsolation parameter \(parameter) range \(info.minValue)...\(info.maxValue) excludes \(value)")
            }
            try checked(AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Global, 0, value, 0), "set parameter \(parameter)")
            var actual: Float = 0
            try checked(AudioUnitGetParameter(unit, parameter, kAudioUnitScope_Global, 0, &actual), "read parameter \(parameter)")
            guard actual == value else { throw Failure("AUSoundIsolation did not accept parameter \(parameter)=\(value)") }
        }
        var maximum: UInt32 = UInt32(blockFrames)
        try checked(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global,
            0, &maximum, UInt32(MemoryLayout<UInt32>.size)), "set render slice")
        var callback = AURenderCallbackStruct(inputProc: { ref, _, _, _, count, data in
            let feed = Unmanaged<Feed>.fromOpaque(ref).takeUnretainedValue()
            guard let data = data, Int(count) + feed.position <= blockFrames else { return kAudio_ParamError }
            let list = UnsafeMutableAudioBufferListPointer(data)
            guard list.count == feed.channels else { return kAudio_ParamError }
            for c in 0..<feed.channels {
                guard list[c].mNumberChannels == 1, list[c].mDataByteSize >= count * 4,
                      let pointer = list[c].mData?.assumingMemoryBound(to: Float.self) else { return kAudio_ParamError }
                for frame in 0..<Int(count) { pointer[frame] = feed.samples[(feed.position + frame) * feed.channels + c] }
                list[c].mDataByteSize = count * 4
            }
            feed.position += Int(count)
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(feed).toOpaque())
        try checked(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
            0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set callback")
        try checked(AudioUnitInitialize(unit), "initialize")
        initialized = true
        var actualMaximum: UInt32 = 0
        var maximumBytes = UInt32(MemoryLayout<UInt32>.size)
        try checked(AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global,
            0, &actualMaximum, &maximumBytes), "read render slice")
        guard actualMaximum == UInt32(blockFrames) else { throw Failure("AUSoundIsolation changed the 4096-frame slice") }
        for (parameter, expected) in [(AudioUnitParameterID(0), Float(-100)), (AudioUnitParameterID(1), Float(0))] {
            var value: Float = 0
            try checked(AudioUnitGetParameter(unit, parameter, kAudioUnitScope_Global, 0, &value), "read initialized parameter")
            guard value == expected else { throw Failure("AUSoundIsolation reset parameter \(parameter) during initialization") }
        }
        var latency: Double = 0
        var bytes = UInt32(MemoryLayout<Double>.size)
        try checked(AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0,
                                         &latency, &bytes), "read latency")
        guard latency.isFinite, latency >= 0, latency <= 10 else { throw Failure("invalid isolation latency: \(latency)") }
        latencyFrames = Int((latency * Double(sampleRate)).rounded())
        log("AUSoundIsolation: \(channels) channels, HQ conversation, wet/dry -100, latency \(latencyFrames) frames")
    }
    func render(_ padded: Data) throws -> Data {
        guard padded.count == blockFrames * channels * 4, let unit = unit else { throw Failure("invalid isolation input") }
        _ = padded.withUnsafeBytes { bytes in memcpy(feed.samples, bytes.baseAddress!, padded.count) }
        feed.position = 0
        for c in 0..<channels { buffers[c].mDataByteSize = UInt32(blockFrames * 4) }
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = time
        timestamp.mFlags = .sampleTimeValid
        var flags = AudioUnitRenderActionFlags()
        try checked(AudioUnitRender(unit, &flags, &timestamp, 0, UInt32(blockFrames), buffers.unsafeMutablePointer), "render at frame \(Int(time))")
        time += Double(blockFrames)
        guard feed.position == blockFrames else { throw Failure("AUSoundIsolation consumed \(feed.position) frames, expected 4096") }
        var samples = [Float](repeating: 0, count: blockFrames * channels)
        for c in 0..<channels {
            guard let pointer = buffers[c].mData?.assumingMemoryBound(to: Float.self),
                  buffers[c].mDataByteSize == blockFrames * 4 else { throw Failure("invalid isolation output buffer") }
            for frame in 0..<blockFrames {
                let value = pointer[frame]
                guard value.isFinite else { throw Failure("AUSoundIsolation returned a non-finite sample") }
                samples[frame * channels + c] = value
            }
        }
        return samples.withUnsafeBytes { Data($0) }
    }
    private func cleanup() {
        if let unit = unit {
            if initialized {
                let status = AudioUnitUninitialize(unit)
                if status != noErr { log("AUSoundIsolation uninitialize failed: \(status)") }
            }
            let status = AudioComponentInstanceDispose(unit)
            if status != noErr { log("AUSoundIsolation dispose failed: \(status)") }
            self.unit = nil
        }
    }
    deinit {
        cleanup()
        for c in 0..<channels { buffers[c].mData?.assumingMemoryBound(to: Float.self).deallocate() }
        UnsafeMutableRawPointer(buffers.unsafeMutablePointer).deallocate()
    }
}
