// An equalizer for AVPlayer.
//
// AVPlayer has no equalizer and cannot be routed through one. What it will do is hand
// over the samples of each item as they are played — an MTAudioProcessingTap on the
// item's audio mix — and let them be changed on the way past. So the filters are run
// here, on those samples: a cascade of biquads, the same shapes a browser's Web Audio
// filters have, so a curve sounds the same on a phone as on a laptop.
//
// Two rules this is written around.
//
//  * Somebody who never switches the equalizer on must be playing music exactly as
//    they always did. No tap is attached to anything until the first time it is
//    switched on; from then on every item gets one, and a tap that is switched off
//    passes the samples through untouched.
//
//  * The callback that does the work runs on the audio thread. It takes no lock it
//    could wait on, allocates nothing, and calls nothing that might: the settings are
//    copied across with a try-lock, and if the try fails it carries on with the ones
//    it has and looks again next time.
//
// It works on files played over HTTP and from disk, which is everything this app
// plays. It would not work on HLS — those have no audio track to hang a mix on — and
// then nothing is attached and the song simply plays.
#import "./include/just_audio/WetowlEq.h"
#import <MediaToolbox/MediaToolbox.h>
#import <os/lock.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define WO_MAX_BANDS 16
#define WO_MAX_CHANNELS 8

typedef struct {
    int type;          // 0 peaking, 1 low shelf, 2 high shelf
    double hz;
    double gainDb;
    double q;
} WOBand;

// What was asked for. Written on the main thread under the lock; read on the audio
// thread under a try-lock. `gVersion` says whether there is anything new to read.
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static WOBand gBands[WO_MAX_BANDS];
static int gBandCount = 0;
static int gEnabled = 0;
static double gPreampDb = 0.0;
static atomic_int gVersion = 0;

// Main thread only.
static BOOL gEverOn = NO;
static NSHashTable<AVPlayerItem *> *gItems = nil;

typedef struct {
    double sampleRate;
    int channels;
    int interleaved;
    int supported;

    int version;
    int enabled;
    int bandCount;
    float preamp;
    double b0[WO_MAX_BANDS], b1[WO_MAX_BANDS], b2[WO_MAX_BANDS];
    double a1[WO_MAX_BANDS], a2[WO_MAX_BANDS];
    double z1[WO_MAX_CHANNELS][WO_MAX_BANDS], z2[WO_MAX_CHANNELS][WO_MAX_BANDS];
} WOTap;

// The Audio EQ Cookbook's filters (Robert Bristow-Johnson), normalised by a0.
static void woCoefficients(WOTap *t, int i, const WOBand *band) {
    double fs = t->sampleRate > 0 ? t->sampleRate : 44100.0;
    double hz = band->hz;
    // Nothing sensible can be done at or above half the sample rate: pass through.
    if (hz <= 0 || hz >= fs * 0.49 || fabs(band->gainDb) < 0.01) {
        t->b0[i] = 1; t->b1[i] = 0; t->b2[i] = 0; t->a1[i] = 0; t->a2[i] = 0;
        return;
    }
    double A = pow(10.0, band->gainDb / 40.0);
    double w0 = 2.0 * M_PI * hz / fs;
    double cs = cos(w0), sn = sin(w0);
    double q = band->q > 0.05 ? band->q : 0.707;
    double b0, b1, b2, a0, a1, a2;
    if (band->type == 0) {
        double alpha = sn / (2.0 * q);
        b0 = 1 + alpha * A;  b1 = -2 * cs;  b2 = 1 - alpha * A;
        a0 = 1 + alpha / A;  a1 = -2 * cs;  a2 = 1 - alpha / A;
    } else {
        // A shelf with a slope of one: as steep as it goes without overshooting.
        double alpha = sn / 2.0 * sqrt(2.0);
        double rootA = 2.0 * sqrt(A) * alpha;
        if (band->type == 1) {
            b0 = A * ((A + 1) - (A - 1) * cs + rootA);
            b1 = 2 * A * ((A - 1) - (A + 1) * cs);
            b2 = A * ((A + 1) - (A - 1) * cs - rootA);
            a0 = (A + 1) + (A - 1) * cs + rootA;
            a1 = -2 * ((A - 1) + (A + 1) * cs);
            a2 = (A + 1) + (A - 1) * cs - rootA;
        } else {
            b0 = A * ((A + 1) + (A - 1) * cs + rootA);
            b1 = -2 * A * ((A - 1) + (A + 1) * cs);
            b2 = A * ((A + 1) + (A - 1) * cs - rootA);
            a0 = (A + 1) - (A - 1) * cs + rootA;
            a1 = 2 * ((A - 1) - (A + 1) * cs);
            a2 = (A + 1) - (A - 1) * cs - rootA;
        }
    }
    t->b0[i] = b0 / a0; t->b1[i] = b1 / a0; t->b2[i] = b2 / a0;
    t->a1[i] = a1 / a0; t->a2[i] = a2 / a0;
}

// Take up what was asked for, if it can be had without waiting.
static void woCatchUp(WOTap *t) {
    int now = atomic_load(&gVersion);
    if (now == t->version) return;
    if (!os_unfair_lock_trylock(&gLock)) return;      // busy: next time
    int wasEnabled = t->enabled;
    t->enabled = gEnabled;
    t->bandCount = gBandCount > WO_MAX_BANDS ? WO_MAX_BANDS : gBandCount;
    t->preamp = (float)pow(10.0, gPreampDb / 20.0);
    for (int i = 0; i < t->bandCount; i++) woCoefficients(t, i, &gBands[i]);
    t->version = now;
    os_unfair_lock_unlock(&gLock);
    // Coming on from off: whatever the filters remembered is from another moment.
    if (t->enabled && !wasEnabled) {
        memset(t->z1, 0, sizeof(t->z1));
        memset(t->z2, 0, sizeof(t->z2));
    }
}

static inline void woRun(WOTap *t, int channel, float *samples, int frames, int stride) {
    const float preamp = t->preamp;
    for (int n = 0; n < frames; n++) {
        double x = (double)samples[n * stride] * preamp;
        for (int i = 0; i < t->bandCount; i++) {
            // Transposed direct form II: two numbers of memory a band.
            double y = t->b0[i] * x + t->z1[channel][i];
            t->z1[channel][i] = t->b1[i] * x - t->a1[i] * y + t->z2[channel][i];
            t->z2[channel][i] = t->b2[i] * x - t->a2[i] * y;
            x = y;
        }
        samples[n * stride] = (float)x;
    }
}

static void woInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    WOTap *t = calloc(1, sizeof(WOTap));
    if (t) t->version = -1;
    *tapStorageOut = t;
}

static void woFinalize(MTAudioProcessingTapRef tap) {
    void *t = MTAudioProcessingTapGetStorage(tap);
    if (t) free(t);
}

static void woPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames,
                      const AudioStreamBasicDescription *format) {
    WOTap *t = MTAudioProcessingTapGetStorage(tap);
    if (!t) return;
    t->sampleRate = format->mSampleRate;
    t->channels = (int)format->mChannelsPerFrame;
    t->interleaved = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 0 : 1;
    int isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) && format->mBitsPerChannel == 32;
    // Anything other than 32-bit float is passed through as it came. It has always
    // been float here; this is for the day it is not.
    t->supported = isFloat && t->channels >= 1 && t->channels <= WO_MAX_CHANNELS;
    t->version = -1;
    memset(t->z1, 0, sizeof(t->z1));
    memset(t->z2, 0, sizeof(t->z2));
}

static void woUnprepare(MTAudioProcessingTapRef tap) {}

static void woProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
                      MTAudioProcessingTapFlags flags, AudioBufferList *bufferListInOut,
                      CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                         flagsOut, NULL, numberFramesOut);
    if (status != noErr) return;
    WOTap *t = MTAudioProcessingTapGetStorage(tap);
    if (!t || !t->supported) return;
    woCatchUp(t);
    if (!t->enabled || t->bandCount <= 0) return;

    int frames = (int)*numberFramesOut;
    if (t->interleaved) {
        if (bufferListInOut->mNumberBuffers < 1) return;
        AudioBuffer *buffer = &bufferListInOut->mBuffers[0];
        if (!buffer->mData) return;
        int have = (int)(buffer->mDataByteSize / (sizeof(float) * (size_t)t->channels));
        if (frames > have) frames = have;
        for (int c = 0; c < t->channels; c++) {
            woRun(t, c, ((float *)buffer->mData) + c, frames, t->channels);
        }
    } else {
        int buffers = (int)bufferListInOut->mNumberBuffers;
        for (int c = 0; c < buffers && c < WO_MAX_CHANNELS; c++) {
            AudioBuffer *buffer = &bufferListInOut->mBuffers[c];
            if (!buffer->mData) continue;
            int have = (int)(buffer->mDataByteSize / sizeof(float));
            woRun(t, c, (float *)buffer->mData, frames > have ? have : frames, 1);
        }
    }
}

@implementation WetowlEq

+ (void)registerWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger {
    FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:@"wetowl/eq"
                                                                binaryMessenger:messenger];
    [channel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
        if ([@"available" isEqualToString:call.method]) {
            result(@YES);
        } else if ([@"apply" isEqualToString:call.method]) {
            [WetowlEq apply:(NSDictionary *)call.arguments];
            result(nil);
        } else {
            result(FlutterMethodNotImplemented);
        }
    }];
}

+ (void)apply:(NSDictionary *)arguments {
    if (![arguments isKindOfClass:[NSDictionary class]]) return;
    BOOL enabled = [arguments[@"enabled"] respondsToSelector:@selector(boolValue)]
        ? [arguments[@"enabled"] boolValue] : NO;
    double preamp = [arguments[@"preamp"] respondsToSelector:@selector(doubleValue)]
        ? [arguments[@"preamp"] doubleValue] : 0.0;
    NSArray *bands = [arguments[@"bands"] isKindOfClass:[NSArray class]] ? arguments[@"bands"] : @[];

    os_unfair_lock_lock(&gLock);
    gEnabled = enabled ? 1 : 0;
    gPreampDb = fmax(-24.0, fmin(24.0, preamp));
    gBandCount = 0;
    for (id entry in bands) {
        if (gBandCount >= WO_MAX_BANDS) break;
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *band = (NSDictionary *)entry;
        NSString *type = [band[@"type"] isKindOfClass:[NSString class]] ? band[@"type"] : @"peaking";
        WOBand *to = &gBands[gBandCount++];
        to->type = [type isEqualToString:@"lowshelf"] ? 1 : [type isEqualToString:@"highshelf"] ? 2 : 0;
        to->hz = [band[@"hz"] respondsToSelector:@selector(doubleValue)] ? [band[@"hz"] doubleValue] : 0;
        to->gainDb = [band[@"gain"] respondsToSelector:@selector(doubleValue)]
            ? fmax(-24.0, fmin(24.0, [band[@"gain"] doubleValue])) : 0;
        to->q = [band[@"q"] respondsToSelector:@selector(doubleValue)] ? [band[@"q"] doubleValue] : 1.41;
    }
    os_unfair_lock_unlock(&gLock);
    atomic_fetch_add(&gVersion, 1);

    // The first time it is switched on: what is already playing, and what is queued
    // behind it, were made before anything was being attached.
    if (enabled && !gEverOn) {
        gEverOn = YES;
        for (AVPlayerItem *item in [gItems allObjects]) [WetowlEq tap:item];
    }
}

+ (void)attachTo:(AVPlayerItem *)item {
    if (!item) return;
    if (!gItems) gItems = [NSHashTable weakObjectsHashTable];
    [gItems addObject:item];
    if (gEverOn) [WetowlEq tap:item];
}

+ (void)tap:(AVPlayerItem *)item {
    AVAsset *asset = item.asset;
    if (!asset || item.audioMix != nil) return;
    __weak AVPlayerItem *weakItem = item;
    // The tracks of something coming over the network are not known yet, and asking
    // for them outright would hold the main thread until they were.
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
        NSError *error = nil;
        if ([asset statusOfValueForKey:@"tracks" error:&error] != AVKeyValueStatusLoaded) return;
        NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        if (tracks.count == 0) return;

        MTAudioProcessingTapCallbacks callbacks;
        callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
        callbacks.clientInfo = NULL;
        callbacks.init = woInit;
        callbacks.finalize = woFinalize;
        callbacks.prepare = woPrepare;
        callbacks.unprepare = woUnprepare;
        callbacks.process = woProcess;

        MTAudioProcessingTapRef tap = NULL;
        OSStatus status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                     kMTAudioProcessingTapCreationFlag_PostEffects, &tap);
        if (status != noErr || tap == NULL) return;

        AVMutableAudioMixInputParameters *parameters =
            [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:tracks.firstObject];
        parameters.audioTapProcessor = tap;
        CFRelease(tap);                       // the parameters keep it now
        AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
        mix.inputParameters = @[parameters];

        dispatch_async(dispatch_get_main_queue(), ^{
            AVPlayerItem *stillThere = weakItem;
            if (stillThere && stillThere.audioMix == nil) stillThere.audioMix = mix;
        });
    }];
}

@end
