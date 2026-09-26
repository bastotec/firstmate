// VoiceAudio: the HUD's microphone and speaker in one macOS voice-processing
// unit (AUVoiceProcessingIO, the echo canceller FaceTime uses), so the system
// cancels Ziggy's own voice out of the microphone. With its voice gone from
// the mic, anything the mic still hears while Ziggy talks is the captain, and
// can interrupt.
//
// The echo canceller only knows about audio played through this same unit,
// which is why reply playback lives here too.
//
//   stdout  16 kHz mono s16le microphone audio, echo-cancelled, continuous
//   stdin   frames: [1 byte type][u32 LE length][body]
//             1 = reply audio, 24 kHz mono s16le, queued after what is playing
//             2 = flush: drop everything queued (the captain interrupted)
//   stderr  a "ready" line once running, then errors only
//
//   VoiceAudio [--no-aec]      --no-aec: same pipes, plain I/O (no processing)

import AudioToolbox
@preconcurrency import AVFoundation
import Foundation

let rate = 48000.0
let aec = !CommandLine.arguments.contains("--no-aec")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("VoiceAudio: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr { fail("\(what) failed: \(status)") }
}

// ------------------------------------------------------------------ the unit

var desc = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: aec ? kAudioUnitSubType_VoiceProcessingIO : kAudioUnitSubType_HALOutput,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0, componentFlagsMask: 0)
guard let component = AudioComponentFindNext(nil, &desc) else { fail("no audio unit") }
var maybeUnit: AudioUnit?
check(AudioComponentInstanceNew(component, &maybeUnit), "AudioComponentInstanceNew")
let unit = maybeUnit!

var one: UInt32 = 1
check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                           &one, UInt32(MemoryLayout<UInt32>.size)), "enable input")
check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                           &one, UInt32(MemoryLayout<UInt32>.size)), "enable output")
if !aec {
    // The plain HAL unit needs the default input device named explicitly.
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                     &size, &device), "default input device")
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                               &device, size), "set input device")
}

// Both client sides at 48 kHz mono float; conversions happen off the audio thread.
var clientFormat = AudioStreamBasicDescription(
    mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
    mBitsPerChannel: 32, mReserved: 0)
let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                           &clientFormat, asbdSize), "mic format")
check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                           &clientFormat, asbdSize), "speaker format")

if aec, #available(macOS 14.0, *) {
    // Voice processing ducks every other app's audio by default; keep the
    // captain's music and calls at their own volume.
    var ducking = AUVoiceIOOtherAudioDuckingConfiguration(
        mEnableAdvancedDucking: false, mDuckingLevel: .min)
    _ = AudioUnitSetProperty(unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
                             kAudioUnitScope_Global, 0, &ducking,
                             UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))
}

// ------------------------------------------------------------------ playback

// Reply samples at 48 kHz waiting to play. The render callback takes from the
// front; the stdin thread appends; a flush empties it.
var playLock = os_unfair_lock()
var playQueue = [Float]()
var playHead = 0
var playedFrames = 0
// Debug (VOICEAUDIO_TAP=<file>): everything rendered to the speaker, as raw
// 48 kHz float32, plus a count of underruns - callbacks that ran out of reply
// audio mid-stream - so playback glitches can be measured instead of guessed.
let tapPath = ProcessInfo.processInfo.environment["VOICEAUDIO_TAP"]
var tapped = [Float]()
var underruns = 0

// Jitter buffer: after running dry, playback waits until PREROLL frames are
// queued (or the first queued audio has waited PREROLL_WAIT frames, for a
// short last chunk) instead of starting on the first 21 ms chunk. Where it
// starts or runs dry it ramps over FADE frames, so a late chunk makes a short
// soft gap instead of a click.
let PREROLL = Int(rate * 0.12)
let PREROLL_WAIT = Int(rate * 0.25)
let FADE = Int(rate * 0.005)
var playing = false
var waitedFrames = 0
let underrunLog = ProcessInfo.processInfo.environment["VOICEAUDIO_LOG"]

let renderCallback: AURenderCallback = { _, _, _, _, frames, ioData in
    guard let abl = UnsafeMutableAudioBufferListPointer(ioData) else { return noErr }
    let out = abl[0].mData!.assumingMemoryBound(to: Float.self)
    let n = Int(frames)
    os_unfair_lock_lock(&playLock)
    let available = playQueue.count - playHead
    var starting = false
    if !playing && available > 0 {
        waitedFrames += n
        if available >= PREROLL || waitedFrames >= PREROLL_WAIT {
            playing = true
            starting = true
            waitedFrames = 0
        }
    }
    let take = playing ? min(n, available) : 0
    if take > 0 {
        playQueue.withUnsafeBufferPointer { src in
            out.update(from: src.baseAddress! + playHead, count: take)
        }
        playHead += take
        playedFrames += take
        if playHead > 48000 * 10 {
            playQueue.removeFirst(playHead)
            playHead = 0
        }
    }
    // Ran dry: this callback used up everything queued (including when it
    // ended exactly on the callback boundary), so fade its tail now.
    let ranDry = playing && take == available
    if ranDry {
        playing = false
        if take > 0 { underruns += 1 }
        if let path = underrunLog, take > 0 {
            let line = "\(Date().timeIntervalSince1970) dry\n"
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
            else { FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8)) }
        }
    }
    os_unfair_lock_unlock(&playLock)
    if starting {
        for i in 0 ..< min(FADE, take) { out[i] *= Float(i) / Float(FADE) }
    }
    if ranDry && take > 0 {
        let f = min(FADE, take)
        for i in 0 ..< f { out[take - f + i] *= Float(f - i) / Float(f) }
    }
    if take < n { (out + take).update(repeating: 0, count: n - take) }
    if tapPath != nil && (take > 0 || !tapped.isEmpty) {
        tapped.append(contentsOf: UnsafeBufferPointer(start: out, count: n))
    }
    return noErr
}
var render = AURenderCallbackStruct(inputProc: renderCallback, inputProcRefCon: nil)
check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                           &render, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "render callback")

// ------------------------------------------------------------------ microphone

let micQueue = DispatchQueue(label: "mic")
let micIn = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
let micOut = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
let micConverter = AVAudioConverter(from: micIn, to: micOut)!
let stdoutHandle = FileHandle.standardOutput

func emitMic(_ samples: [Float]) {
    let buf = AVAudioPCMBuffer(pcmFormat: micIn, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let converted = AVAudioPCMBuffer(pcmFormat: micOut,
                                     frameCapacity: AVAudioFrameCount(samples.count / 3 + 64))!
    var fed = false
    var error: NSError?
    _ = micConverter.convert(to: converted, error: &error) { _, status in
        if fed { status.pointee = .noDataNow; return nil }
        fed = true
        status.pointee = .haveData
        return buf
    }
    if converted.frameLength > 0 {
        stdoutHandle.write(Data(bytes: converted.int16ChannelData![0], count: Int(converted.frameLength) * 2))
    }
}

var micScratch = [Float](repeating: 0, count: 8192)
let inputCallback: AURenderCallback = { _, flags, timestamp, _, frames, _ in
    let n = Int(frames)
    if n > micScratch.count { micScratch = [Float](repeating: 0, count: n) }
    return micScratch.withUnsafeMutableBufferPointer { scratch -> OSStatus in
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: scratch.baseAddress))
        let status = AudioUnitRender(unit, flags, timestamp, 1, frames, &list)
        if status == noErr {
            let copy = Array(scratch[0 ..< n])
            micQueue.async { emitMic(copy) }
        }
        return status
    }
}
var input = AURenderCallbackStruct(inputProc: inputCallback, inputProcRefCon: nil)
check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                           &input, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input callback")

check(AudioUnitInitialize(unit), "AudioUnitInitialize")
check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
FileHandle.standardError.write("VoiceAudio ready aec=\(aec)\n".data(using: .utf8)!)

// ------------------------------------------------------------------ stdin

let replyIn = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
let replyConverter = AVAudioConverter(from: replyIn, to: micIn)!
let stdinHandle = FileHandle.standardInput

func readExactly(_ n: Int) -> Data? {
    var data = Data()
    while data.count < n {
        let chunk = stdinHandle.readData(ofLength: n - data.count)
        if chunk.isEmpty { return nil }
        data.append(chunk)
    }
    return data
}

func queueReply(_ body: Data) {
    let frames = body.count / 2
    guard frames > 0 else { return }
    let buf = AVAudioPCMBuffer(pcmFormat: replyIn, frameCapacity: AVAudioFrameCount(frames))!
    buf.frameLength = AVAudioFrameCount(frames)
    body.withUnsafeBytes { raw in
        buf.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: frames)
    }
    let converted = AVAudioPCMBuffer(pcmFormat: micIn, frameCapacity: AVAudioFrameCount(frames * 2 + 64))!
    var fed = false
    var error: NSError?
    _ = replyConverter.convert(to: converted, error: &error) { _, status in
        if fed { status.pointee = .noDataNow; return nil }
        fed = true
        status.pointee = .haveData
        return buf
    }
    let n = Int(converted.frameLength)
    guard n > 0 else { return }
    let samples = Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: n))
    os_unfair_lock_lock(&playLock)
    playQueue.append(contentsOf: samples)
    os_unfair_lock_unlock(&playLock)
}

Thread.detachNewThread {
    while let head = readExactly(5) {
        let kind = head[head.startIndex]
        let length = head.subdata(in: head.startIndex + 1 ..< head.startIndex + 5)
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let size = Int(UInt32(littleEndian: length))
        guard let body = size > 0 ? readExactly(size) : Data() else { break }
        switch kind {
        case 1:
            queueReply(body)
        case 2:
            os_unfair_lock_lock(&playLock)
            playQueue.removeAll(keepingCapacity: true)
            playHead = 0
            os_unfair_lock_unlock(&playLock)
            replyConverter.reset()
        default:
            break
        }
    }
    // Stdin closed: the bridge is gone.
    if ProcessInfo.processInfo.environment["VOICEAUDIO_DEBUG"] != nil {
        FileHandle.standardError.write("played \(Double(playedFrames) / rate)s underruns \(underruns)\n".data(using: .utf8)!)
    }
    if let path = tapPath {
        let data = tapped.withUnsafeBufferPointer { Data(buffer: $0) }
        FileManager.default.createFile(atPath: path, contents: data)
    }
    AudioOutputUnitStop(unit)
    exit(0)
}

dispatchMain()
