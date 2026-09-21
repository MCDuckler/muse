// WetOwl's equalizer for the Darwin player. Not part of upstream just_audio: see
// third_party/just_audio/WETOWL.md for what was added and why.
#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

@interface WetowlEq : NSObject

/// The channel the app sets the curve over ("wetowl/eq").
+ (void)registerWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger;

/// Called for every player item as it is made. Does nothing at all until the
/// equalizer has been switched on at least once.
+ (void)attachTo:(AVPlayerItem *)item;

@end
