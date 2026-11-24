// t_movie's clip, made here so the test needs no file and no tool: an MP4 with H.264 video (uniform frames given as NV12 in video range, a key
// frame at least every key_every frames, no frame reordering) and AAC audio (a sine at half scale, 48 kHz stereo, as long as the video),
// written by AVAssetWriter. Returns 1 when the file was written.
#import <AVFoundation/AVFoundation.h>
#include <math.h>
#include <unistd.h>

int t_movie_clip(const char *file, int w, int h, int fps, int nframes, int key_every, void (*ycbcr)(int frame, uint8_t out[3]), int tone_hz) {
    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:@(file)];
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        NSError *err = nil;
        AVAssetWriter *wr = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeMPEG4 error:&err];
        if (!wr) { fprintf(stderr, "t_movie_clip: no writer: %s\n", err.localizedDescription.UTF8String); return 0; }
        AVAssetWriterInput *vi = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
            AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @(w), AVVideoHeightKey: @(h),
            AVVideoCompressionPropertiesKey: @{AVVideoMaxKeyFrameIntervalKey: @(key_every), AVVideoAllowFrameReorderingKey: @NO, AVVideoAverageBitRateKey: @1000000}}];
        AVAssetWriterInputPixelBufferAdaptor *ad = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:vi
            sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                                          (id)kCVPixelBufferWidthKey: @(w), (id)kCVPixelBufferHeightKey: @(h)}];
        AVAssetWriterInput *ai = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:@{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @48000, AVNumberOfChannelsKey: @2, AVEncoderBitRateKey: @128000}];
        if (![wr canAddInput:vi] || ![wr canAddInput:ai]) { fprintf(stderr, "t_movie_clip: the writer takes no H.264 / AAC input\n"); return 0; }
        [wr addInput:vi]; [wr addInput:ai];
        if (![wr startWriting]) { fprintf(stderr, "t_movie_clip: startWriting: %s\n", wr.error.localizedDescription.UTF8String); return 0; }
        [wr startSessionAtSourceTime:kCMTimeZero];
        AudioStreamBasicDescription asbd = {.mSampleRate = 48000, .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, .mBytesPerPacket = 4, .mFramesPerPacket = 1,
            .mBytesPerFrame = 4, .mChannelsPerFrame = 2, .mBitsPerChannel = 16};
        CMAudioFormatDescriptionRef afd = NULL;
        if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &afd) != noErr) return 0;
        int per = 48000 / fps, v = 0, a = 0, idle = 0; BOOL ok = YES;   // per: audio frames beside one video frame
        NSDictionary *pba = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        while (ok && (v < nframes || a < nframes) && idle < 10000) {   // whichever input the writer wants next (it interleaves the two)
            if (v < nframes && vi.readyForMoreMediaData) {
                CVPixelBufferRef pb = NULL; uint8_t c[3]; ycbcr(v, c);
                if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)w, (size_t)h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)pba, &pb) != kCVReturnSuccess) { ok = NO; break; }
                CVPixelBufferLockBaseAddress(pb, 0);
                uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
                size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), us = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
                for (int r = 0; r < h; r++) memset(y + (size_t)r * ys, c[0], (size_t)w);
                for (int r = 0; r < h / 2; r++) for (int x = 0; x < w / 2; x++) { uv[(size_t)r * us + 2 * x] = c[1]; uv[(size_t)r * us + 2 * x + 1] = c[2]; }
                CVPixelBufferUnlockBaseAddress(pb, 0);
                ok = [ad appendPixelBuffer:pb withPresentationTime:CMTimeMake(v, fps)];
                CVPixelBufferRelease(pb); v++; idle = 0;
            } else if (a < nframes && ai.readyForMoreMediaData) {
                size_t bytes = (size_t)per * 4; int16_t *pcm = malloc(bytes);
                for (int i = 0; i < per; i++) { int16_t s = (int16_t)lrint(16384.0 * sin(2 * M_PI * tone_hz * (double)((int64_t)a * per + i) / 48000.0)); pcm[2 * i] = pcm[2 * i + 1] = s; }
                CMBlockBufferRef bb = NULL; CMSampleBufferRef sb = NULL;
                if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, bytes, kCFAllocatorDefault, NULL, 0, bytes, kCMBlockBufferAssureMemoryNowFlag, &bb) != kCMBlockBufferNoErr ||
                    CMBlockBufferReplaceDataBytes(pcm, bb, 0, bytes) != kCMBlockBufferNoErr ||
                    CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, bb, afd, per, CMTimeMake((int64_t)a * per, 48000), NULL, &sb) != noErr) ok = NO;
                else ok = [ai appendSampleBuffer:sb];
                if (sb) CFRelease(sb);
                if (bb) CFRelease(bb);
                free(pcm); a++; idle = 0;
            } else { usleep(1000); idle++; }
        }
        [vi markAsFinished]; [ai markAsFinished];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [wr finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
        long late = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * (int64_t)NSEC_PER_SEC));
        CFRelease(afd);
        if (late || wr.status != AVAssetWriterStatusCompleted || !ok || v != nframes || a != nframes) {
            fprintf(stderr, "t_movie_clip: not written (status %ld, %d of %d frames, %d audio parts, %s)\n", (long)wr.status, v, nframes, a,
                    wr.error ? wr.error.localizedDescription.UTF8String : "no error given");
            return 0;
        }
        return 1;
    }
}
