import AVFoundation
import VideoToolbox
import QuartzCore

struct VideoFrame {
    let image: CVPixelBuffer
    let sequence: Int
    let publishedAt: CFTimeInterval
    let sourceTime: Double?
}

/// A one-frame mailbox: slow rendering drops decoded frames, never queues video latency.
final class VideoSurface: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var sequence = 0
    private var frameCount = 0
    private var byteCount = 0
    private var size = CGSize(width: 9, height: 19.5)
    private var started = Date()
    private var publishedAt = CACurrentMediaTime()
    private var sourceTime: Double?

    func publish(_ image: CVPixelBuffer, sourceTime: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        latest = image
        sequence += 1
        frameCount += 1
        publishedAt = CACurrentMediaTime()
        self.sourceTime = sourceTime
        size = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
    }
    func addBytes(_ count: Int) { lock.lock(); byteCount += count; lock.unlock() }
    func frame(after previous: Int) -> (CVPixelBuffer, Int)? {
        snapshot(after: previous).map { ($0.image, $0.sequence) }
    }
    func snapshot(after previous: Int) -> VideoFrame? {
        lock.lock(); defer { lock.unlock() }
        guard sequence != previous, let latest else { return nil }
        return VideoFrame(image: latest, sequence: sequence, publishedAt: publishedAt, sourceTime: sourceTime)
    }
    func metrics() -> (CGSize, Int, Double, Double) {
        lock.lock(); defer { lock.unlock() }
        let duration = max(Date().timeIntervalSince(started), 0.1)
        return (size, frameCount, Double(frameCount) / duration, Double(byteCount) * 8 / duration / 1_000_000)
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        latest = nil; sequence += 1; frameCount = 0; byteCount = 0; started = Date()
        sourceTime = nil
        size = CGSize(width: 9, height: 19.5)
    }
}

/// Owned exclusively by the Android stream queue. VideoToolbox handles H.264 decoding.
final class H264Decoder {
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private let surface: VideoSurface
    private var sps: Data?
    private var pps: Data?

    init(surface: VideoSurface) { self.surface = surface }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    func consume(_ packet: Data, pts: UInt64, config: Bool) throws {
        let units = H264AnnexB.units(packet)
        if config {
            for unit in units {
                switch (unit.first ?? 0) & 0x1f {
                case 7: sps = unit
                case 8: pps = unit
                default: break
                }
            }
            guard let sps, let pps else { return }
            if let session { VTDecompressionSessionInvalidate(session); self.session = nil }
            let status = sps.withUnsafeBytes { s in
                pps.withUnsafeBytes { p in
                    let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                    let sizes = [sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                        parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                }
            }
            guard status == noErr, let format else { throw TaurossError.message("Unable to read the H.264 configuration (\(status)).") }
            let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                              kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            let result = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: nil,
                decompressionSessionOut: &session)
            guard result == noErr else { throw TaurossError.message("Unable to initialize the video decoder (\(result)).") }
            return
        }
        guard let format, let session else { return }
        var avcc = Data()
        for unit in units { avcc.appendBE(UInt32(unit.count)); avcc.append(unit) }
        guard !avcc.isEmpty else { return }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw TaurossError.message("Unable to create a video buffer.") }
        status = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        guard status == noErr else { throw TaurossError.message("Unable to copy the video buffer.") }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(pts), timescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = avcc.count
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw TaurossError.message("Unable to create a video sample.") }
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [surface] status, _, image, _, _ in
            if status == noErr, let image { surface.publish(image, sourceTime: Double(pts) / 1_000_000) }
        }
        guard status == noErr else { throw TaurossError.message("H.264 decoding failed (\(status)).") }
    }
}
