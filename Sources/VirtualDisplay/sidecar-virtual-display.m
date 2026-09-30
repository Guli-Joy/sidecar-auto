// sidecar-virtual-display
//
// Small, deliberately dependency-free virtual-display owner for Sidecar Auto.
//
// macOS does not expose a supported public API for creating a display.  The
// two implementations below are therefore runtime probes, rather than a
// static link against Apple's private frameworks:
//
//   * macOS 26 and later: SkyLight's SLVirtualDisplay* classes.
//   * Other releases exposing the runtime classes: CGVirtualDisplay Objective-C
//     classes, then the legacy VirtualDisplay.framework C symbols.
//
// The process must stay alive.  Releasing the private display object removes
// the display from WindowServer, so `ensure` is a foreground service command
// suitable for a LaunchAgent (or it can be started with --background).
//
// This file uses only the runtime signatures observed in the open-source FBD
// project and in the macOS runtime.  It is intentionally kept separate from
// the SidecarCore client: creating a fallback screen must never start a
// Sidecar session or claim the user's iPad.

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <signal.h>
#import <spawn.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>

extern char **environ;

static NSString * const kDefaultDisplayName = @"SidecarHeadlessFallback";
static NSString * const kDefaultStateRelativePath = @".config/sidecar-auto/virtual-display.state";

typedef NS_ENUM(NSInteger, DisplayBackend) {
    DisplayBackendNone = 0,
    DisplayBackendSL,
    DisplayBackendCGObjC,
    DisplayBackendCG,
};

typedef struct {
    float x;
    float y;
} VirtualPoint;

typedef struct {
    uint32_t width;
    uint32_t height;
} VirtualSize;

typedef struct {
    VirtualPoint red;
    VirtualPoint green;
    VirtualPoint blue;
    VirtualPoint white;
} VirtualChromaticities;

typedef struct {
    uint32_t displayID;
    CFStringRef name;
    uint32_t serialNum;
    uint32_t productID;
    uint32_t vendorID;
    uint32_t maxPixelsWide;
    uint32_t maxPixelsHigh;
    CGSize sizeInMillimeters;
    CGPoint redPrimary;
    CGPoint greenPrimary;
    CGPoint bluePrimary;
    CGPoint whitePoint;
} LegacyVirtualDisplayDescriptor;

typedef struct {
    uint32_t hiDPI;
    uint32_t width;
    uint32_t height;
    double refreshRate;
} LegacyVirtualDisplaySettings;

typedef void *(*LegacyCreateFn)(const LegacyVirtualDisplayDescriptor *descriptor);
typedef void (*LegacyDestroyFn)(void *display);
typedef void *(*LegacyCreateModeFn)(void *display, uint32_t width, uint32_t height, double refreshRate);
typedef void (*LegacySetModeFn)(void *display, void *mode);
typedef void (*LegacyApplySettingsFn)(void *display, const LegacyVirtualDisplaySettings *settings);
typedef void (*LegacyReleaseModeFn)(void *display, void *mode);

typedef struct {
    LegacyCreateFn create;
    LegacyDestroyFn destroy;
    LegacyCreateModeFn createMode;
    LegacySetModeFn setMode;
    LegacyApplySettingsFn applySettings;
    LegacyReleaseModeFn releaseMode;
} LegacySymbols;

static volatile sig_atomic_t gShouldStop = 0;
static int gLockFD = -1;
static NSString *gStatePath = nil;
static NSString *gDisplayName = nil;
static DisplayBackend gBackend = DisplayBackendNone;
static uint32_t gDisplayID = 0;
static uint32_t gDisplayWidth = 1920;
static uint32_t gDisplayHeight = 1080;
static double gDisplayRefreshRate = 60.0;
static id gSLDisplay = nil;
static id gCGDisplay = nil;
static void *gLegacyDisplay = NULL;
static void *gLegacyFramework = NULL;
static LegacySymbols gLegacySymbols = {0};
static void *gSkyLightFramework = NULL;

static void signalHandler(int signalNumber) {
    (void)signalNumber;
    gShouldStop = 1;
}

static void installSignalHandlers(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = signalHandler;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGHUP, &action, NULL);
}

static NSString *homePath(NSString *relativePath) {
    NSString *home = NSHomeDirectory();
    if (home.length == 0) return relativePath;
    return [home stringByAppendingPathComponent:relativePath];
}

static NSString *environmentOrDefault(const char *name, NSString *fallback) {
    const char *value = getenv(name);
    if (value == NULL || value[0] == '\0') return fallback;
    return [NSString stringWithUTF8String:value] ?: fallback;
}

static BOOL writeTextAtomically(NSString *text, NSString *path, NSError **error) {
    NSString *directory = [path stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:error]) {
        return NO;
    }
    return [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error];
}

static void loadConfiguration(void) {
    // The built-in provider intentionally exposes one fixed profile.  The
    // advanced dimensions and display naming belong to BetterDisplay.
    gDisplayName = kDefaultDisplayName;
    gDisplayWidth = 1920;
    gDisplayHeight = 1080;
    gDisplayRefreshRate = 60.0;
    gStatePath = environmentOrDefault("SIDECAR_VIRTUAL_DISPLAY_STATE", homePath(kDefaultStateRelativePath));
}

static NSString *backendName(DisplayBackend backend) {
    switch (backend) {
        case DisplayBackendSL: return @"sl";
        case DisplayBackendCGObjC: return @"cg-objc";
        case DisplayBackendCG: return @"cg";
        default: return @"none";
    }
}

static BOOL pidIsAlive(pid_t pid) {
    if (pid <= 0) return NO;
    if (kill(pid, 0) == 0) return YES;
    return errno == EPERM;
}

static NSDictionary<NSString *, NSString *> *readState(void) {
    NSString *text = [NSString stringWithContentsOfFile:gStatePath encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0) return @{};
    NSMutableDictionary<NSString *, NSString *> *state = [NSMutableDictionary dictionary];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSRange equals = [line rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *key = [line substringToIndex:equals.location];
        NSString *value = [line substringFromIndex:equals.location + 1];
        if (key.length > 0) state[key] = value;
    }
    return state;
}

static BOOL writeState(NSError **error) {
    NSString *text = [NSString stringWithFormat:
        @"pid=%d\nbackend=%@\nname=%@\ndisplay_id=%u\nwidth=%u\nheight=%u\nrefresh_rate=%.3f\nonline=1\n",
        getpid(), backendName(gBackend), gDisplayName, gDisplayID,
        gDisplayWidth, gDisplayHeight, gDisplayRefreshRate];
    return writeTextAtomically(text, gStatePath, error);
}

static void removeState(void) {
    [[NSFileManager defaultManager] removeItemAtPath:gStatePath error:nil];
}

static void printState(BOOL includeProcess) {
    NSDictionary<NSString *, NSString *> *state = readState();
    NSString *pidString = state[@"pid"] ?: @"0";
    pid_t pid = (pid_t)strtol(pidString.UTF8String, NULL, 10);
    BOOL running = pidIsAlive(pid);
    if (!running && state.count > 0) {
        printf("installed=1 running=0 online=0 backend=%s name=%s pid=%s display_id=%s\n",
               [state[@"backend"] ?: @"none" UTF8String],
               [state[@"name"] ?: gDisplayName UTF8String],
               [pidString UTF8String],
               [state[@"display_id"] ?: @"0" UTF8String]);
        return;
    }
    if (state.count == 0) {
        printf("installed=0 running=0 online=0 backend=none name=%s pid=0 display_id=0\n",
               gDisplayName.UTF8String);
        return;
    }
    printf("installed=1 running=%d online=%s backend=%s name=%s pid=%s display_id=%s",
           running ? 1 : 0,
           [state[@"online"] ?: @"0" UTF8String],
           [state[@"backend"] ?: @"none" UTF8String],
           [state[@"name"] ?: gDisplayName UTF8String],
           [pidString UTF8String],
           [state[@"display_id"] ?: @"0" UTF8String]);
    if (includeProcess) printf(" owner_pid=%d", getpid());
    printf("\n");
}

static BOOL acquireLock(void) {
    NSString *lockPath = [gStatePath stringByAppendingString:@".lock"];
    NSString *directory = [lockPath stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:nil]) {
        fprintf(stderr, "cannot create state directory: %s\n", directory.UTF8String);
        return NO;
    }
    gLockFD = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (gLockFD < 0) {
        fprintf(stderr, "cannot open lock %s: %s\n", lockPath.UTF8String, strerror(errno));
        return NO;
    }
    if (flock(gLockFD, LOCK_EX | LOCK_NB) != 0) {
        close(gLockFD);
        gLockFD = -1;
        return NO;
    }
    return YES;
}

static void releaseLock(void) {
    if (gLockFD >= 0) {
        flock(gLockFD, LOCK_UN);
        close(gLockFD);
        gLockFD = -1;
    }
}

static NSArray<NSNumber *> *activeDisplayIDs(void) {
    uint32_t count = 0;
    if (CGGetActiveDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) return @[];
    NSMutableData *data = [NSMutableData dataWithLength:sizeof(CGDirectDisplayID) * count];
    CGDirectDisplayID *ids = data.mutableBytes;
    if (CGGetActiveDisplayList(count, ids, &count) != kCGErrorSuccess) return @[];
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t index = 0; index < count; index++) [result addObject:@(ids[index])];
    return result;
}

static uint32_t newlyOnlineDisplayID(NSArray<NSNumber *> *before, uint32_t preferred) {
    NSSet<NSNumber *> *old = [NSSet setWithArray:before];
    for (NSUInteger attempt = 0; attempt < 30; attempt++) {
        for (NSNumber *number in activeDisplayIDs()) {
            if (![old containsObject:number]) return number.unsignedIntValue;
        }
        if (preferred != 0 && CGDisplayIsOnline(preferred)) return preferred;
        usleep(100000);
    }
    return preferred;
}

static BOOL createSLDisplay(NSError **error) {
    // SkyLight is a private framework.  Loading it dynamically avoids a
    // hard link and lets the helper degrade on older macOS versions.
    if (gSkyLightFramework == NULL) {
        gSkyLightFramework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
    }
    Class configClass = NSClassFromString(@"SLVirtualDisplayConfiguration");
    Class modeClass = NSClassFromString(@"SLVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"SLVirtualDisplaySettings");
    Class displayClass = NSClassFromString(@"SLVirtualDisplay");
    if (!configClass || !modeClass || !settingsClass || !displayClass) return NO;

    typedef id (*ConfigFn)(id, SEL, id, uint64_t, uint64_t, uint64_t,
                           VirtualPoint, VirtualSize, VirtualChromaticities, NSError **);
    typedef id (*ModeFn)(id, SEL, VirtualSize, VirtualSize, float, NSError **);
    typedef id (*SettingsFn)(id, SEL, id, id, id, uint64_t, NSError **);
    typedef id (*DisplayFn)(id, SEL, id, NSError **);
    typedef uint32_t (*DisplayIDFn)(id, SEL);
    typedef BOOL (*ApplyFn)(id, SEL, id, NSError **);

    VirtualPoint mm = { 200.0f, 112.0f };
    VirtualSize maxPixels = { gDisplayWidth, gDisplayHeight };
    VirtualChromaticities chromaticities = {
        { 0.680f, 0.320f }, { 0.265f, 0.690f },
        { 0.150f, 0.060f }, { 0.3127f, 0.3290f }
    };
    id config = ((ConfigFn)objc_msgSend)([configClass alloc],
        sel_registerName("initWithName:vendorID:productID:serialNumber:sizeInMillimeters:maximumSizeInPixels:chromaticities:error:"),
        // 0xF0F0 is the vendor used by the open-source BetterDummy reference
        // and is also recognized by Sidecar Auto's display probe.
        gDisplayName, (uint64_t)0xF0F0, (uint64_t)0x0001,
        (uint64_t)1, mm, maxPixels, chromaticities, error);
    if (!config) return NO;

    id display = ((DisplayFn)objc_msgSend)([displayClass alloc],
        sel_registerName("initWithConfiguration:error:"), config, error);
    if (!display) return NO;

    VirtualSize pixels = { gDisplayWidth, gDisplayHeight };
    id mode = ((ModeFn)objc_msgSend)([modeClass alloc],
        sel_registerName("initWithSizeInPixels:sizeInPoints:refreshRate:error:"),
        pixels, pixels, (float)gDisplayRefreshRate, error);
    if (!mode) return NO;

    id settings = ((SettingsFn)objc_msgSend)([settingsClass alloc],
        sel_registerName("initWithNativeMode:preferredMode:optionalModes:rotations:error:"),
        mode, mode, @[], (uint64_t)0, error);
    if (!settings) return NO;

    if (!((ApplyFn)objc_msgSend)(display, sel_registerName("applySettings:error:"), settings, error)) {
        return NO;
    }

    gSLDisplay = display;
    gDisplayID = ((DisplayIDFn)objc_msgSend)(display, sel_registerName("displayID"));
    gBackend = DisplayBackendSL;
    return gDisplayID != 0;
}

static BOOL createCGObjCDisplay(NSError **error) {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptorClass || !modeClass || !settingsClass || !displayClass) return NO;

    typedef id (*AllocInitFn)(id, SEL);
    typedef void (*SetObjectFn)(id, SEL, id);
    typedef void (*SetUIntFn)(id, SEL, uint32_t);
    typedef void (*SetSizeFn)(id, SEL, CGSize);
    typedef void (*SetPointFn)(id, SEL, CGPoint);
    typedef id (*ModeFn)(id, SEL, uint32_t, uint32_t, double);
    typedef id (*DisplayFn)(id, SEL, id);
    typedef BOOL (*ApplyFn)(id, SEL, id);
    typedef uint32_t (*DisplayIDFn)(id, SEL);

    id descriptor = ((AllocInitFn)objc_msgSend)([descriptorClass alloc], sel_registerName("init"));
    if (!descriptor) return NO;
    SEL setQueue = sel_registerName("setQueue:");
    if (![descriptor respondsToSelector:setQueue]) setQueue = sel_registerName("setDispatchQueue:");
    if (![descriptor respondsToSelector:setQueue]) return NO;
    ((SetObjectFn)objc_msgSend)(descriptor, setQueue, dispatch_get_main_queue());
    ((SetObjectFn)objc_msgSend)(descriptor, sel_registerName("setName:"), gDisplayName);
    // Match the virtual vendor fingerprint recognized by display-state.  The
    // human-readable name is user-configurable and cannot be the classifier.
    ((SetUIntFn)objc_msgSend)(descriptor, sel_registerName("setVendorID:"), 0xF0F0);
    ((SetUIntFn)objc_msgSend)(descriptor, sel_registerName("setProductID:"), 0x0001);
    SEL serialSelector = sel_registerName("setSerialNumber:");
    if (![descriptor respondsToSelector:serialSelector]) serialSelector = sel_registerName("setSerialNum:");
    if (![descriptor respondsToSelector:serialSelector]) return NO;
    ((SetUIntFn)objc_msgSend)(descriptor, serialSelector, 1);
    ((SetUIntFn)objc_msgSend)(descriptor, sel_registerName("setMaxPixelsWide:"), gDisplayWidth);
    ((SetUIntFn)objc_msgSend)(descriptor, sel_registerName("setMaxPixelsHigh:"), gDisplayHeight);
    ((SetSizeFn)objc_msgSend)(descriptor, sel_registerName("setSizeInMillimeters:"), CGSizeMake(200.0, 112.0));
    SEL red = sel_registerName("setRedPrimary:");
    SEL green = sel_registerName("setGreenPrimary:");
    SEL blue = sel_registerName("setBluePrimary:");
    SEL white = sel_registerName("setWhitePoint:");
    if ([descriptor respondsToSelector:red]) ((SetPointFn)objc_msgSend)(descriptor, red, CGPointMake(0.680, 0.320));
    if ([descriptor respondsToSelector:green]) ((SetPointFn)objc_msgSend)(descriptor, green, CGPointMake(0.265, 0.690));
    if ([descriptor respondsToSelector:blue]) ((SetPointFn)objc_msgSend)(descriptor, blue, CGPointMake(0.150, 0.060));
    if ([descriptor respondsToSelector:white]) ((SetPointFn)objc_msgSend)(descriptor, white, CGPointMake(0.3127, 0.3290));

    NSArray<NSNumber *> *before = activeDisplayIDs();
    id display = ((DisplayFn)objc_msgSend)([displayClass alloc],
        sel_registerName("initWithDescriptor:"), descriptor);
    if (!display) return NO;

    id mode = ((ModeFn)objc_msgSend)([modeClass alloc],
        sel_registerName("initWithWidth:height:refreshRate:"),
        gDisplayWidth, gDisplayHeight, gDisplayRefreshRate);
    if (!mode) return NO;

    id settings = ((AllocInitFn)objc_msgSend)([settingsClass alloc], sel_registerName("init"));
    if (!settings) return NO;
    ((SetUIntFn)objc_msgSend)(settings, sel_registerName("setHiDPI:"), 0);
    ((SetObjectFn)objc_msgSend)(settings, sel_registerName("setModes:"), @[mode]);
    if (!((ApplyFn)objc_msgSend)(display, sel_registerName("applySettings:"), settings)) {
        if (error) *error = [NSError errorWithDomain:@"SidecarVirtualDisplay" code:20
                                             userInfo:@{NSLocalizedDescriptionKey: @"CGVirtualDisplay applySettings 失败"}];
        return NO;
    }

    gCGDisplay = display;
    gDisplayID = ((DisplayIDFn)objc_msgSend)(display, sel_registerName("displayID"));
    if (gDisplayID == 0) gDisplayID = newlyOnlineDisplayID(before, 0);
    gBackend = DisplayBackendCGObjC;
    return gDisplayID != 0;
}

static BOOL resolveLegacySymbols(void) {
    if (gLegacyFramework != NULL) return gLegacySymbols.create != NULL;
    gLegacyFramework = dlopen("/System/Library/PrivateFrameworks/VirtualDisplay.framework/VirtualDisplay", RTLD_LAZY | RTLD_LOCAL);
    if (!gLegacyFramework) return NO;
#define LOAD_LEGACY(field, symbol, type) gLegacySymbols.field = (type)dlsym(gLegacyFramework, symbol)
    LOAD_LEGACY(create, "CGVirtualDisplayCreateWithDescriptor", LegacyCreateFn);
    LOAD_LEGACY(destroy, "CGVirtualDisplayDestroy", LegacyDestroyFn);
    LOAD_LEGACY(createMode, "CGVirtualDisplayCreateMode", LegacyCreateModeFn);
    LOAD_LEGACY(setMode, "CGVirtualDisplaySetDisplayMode", LegacySetModeFn);
    LOAD_LEGACY(applySettings, "CGVirtualDisplayApplySettings", LegacyApplySettingsFn);
    gLegacySymbols.releaseMode = (LegacyReleaseModeFn)dlsym(gLegacyFramework, "CGVirtualDisplayReleaseMode");
#undef LOAD_LEGACY
    return gLegacySymbols.create && gLegacySymbols.destroy && gLegacySymbols.createMode &&
           gLegacySymbols.setMode && gLegacySymbols.applySettings;
}

static BOOL createLegacyDisplay(NSError **error) {
    if (!resolveLegacySymbols()) return NO;
    NSArray<NSNumber *> *before = activeDisplayIDs();
    NSString *name = [gDisplayName copy];
    LegacyVirtualDisplayDescriptor descriptor;
    memset(&descriptor, 0, sizeof(descriptor));
    descriptor.displayID = 0xF000 + (uint32_t)(getpid() & 0xFF);
    descriptor.name = (__bridge CFStringRef)name;
    descriptor.serialNum = 1;
    descriptor.productID = 1;
    descriptor.vendorID = 0x5343;
    descriptor.maxPixelsWide = gDisplayWidth;
    descriptor.maxPixelsHigh = gDisplayHeight;
    descriptor.sizeInMillimeters = CGSizeMake(200.0, 112.0);
    descriptor.redPrimary = CGPointMake(0.680, 0.320);
    descriptor.greenPrimary = CGPointMake(0.265, 0.690);
    descriptor.bluePrimary = CGPointMake(0.150, 0.060);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
    void *display = gLegacySymbols.create(&descriptor);
    if (!display) {
        if (error) *error = [NSError errorWithDomain:@"SidecarVirtualDisplay" code:10
                                             userInfo:@{NSLocalizedDescriptionKey: @"CGVirtualDisplay 创建失败"}];
        return NO;
    }
    void *mode = gLegacySymbols.createMode(display, gDisplayWidth, gDisplayHeight, gDisplayRefreshRate);
    if (!mode) {
        gLegacySymbols.destroy(display);
        if (error) *error = [NSError errorWithDomain:@"SidecarVirtualDisplay" code:11
                                             userInfo:@{NSLocalizedDescriptionKey: @"CGVirtualDisplay 模式创建失败"}];
        return NO;
    }
    gLegacySymbols.setMode(display, mode);
    LegacyVirtualDisplaySettings settings = {
        .hiDPI = 0,
        .width = gDisplayWidth,
        .height = gDisplayHeight,
        .refreshRate = gDisplayRefreshRate,
    };
    gLegacySymbols.applySettings(display, &settings);
    if (gLegacySymbols.releaseMode) gLegacySymbols.releaseMode(display, mode);
    gLegacyDisplay = display;
    gDisplayID = newlyOnlineDisplayID(before, descriptor.displayID);
    gBackend = DisplayBackendCG;
    return YES;
}

static BOOL createDisplay(NSError **error) {
    NSString *requested = environmentOrDefault("SIDECAR_VIRTUAL_DISPLAY_BACKEND", nil);
    BOOL onlySL = [requested.lowercaseString isEqualToString:@"sl"];
    BOOL onlyCG = [requested.lowercaseString isEqualToString:@"cg"];
    if (onlySL) return createSLDisplay(error);
    if (onlyCG) return createCGObjCDisplay(error);
    if (createSLDisplay(error)) return YES;
    if (createCGObjCDisplay(error)) return YES;
    if (createLegacyDisplay(error)) return YES;
    if (error && *error == nil) {
        *error = [NSError errorWithDomain:@"SidecarVirtualDisplay" code:12
                                  userInfo:@{NSLocalizedDescriptionKey:
                                             @"当前 macOS 没有可用的虚拟显示后端（需要 macOS 26+ SLVirtualDisplay 或 macOS 13–15 VirtualDisplay.framework）"}];
    }
    return NO;
}

static void destroyDisplay(void) {
    if (gSLDisplay != nil) {
        typedef void (*DestroyFn)(id, SEL);
        ((DestroyFn)objc_msgSend)(gSLDisplay, sel_registerName("destroy"));
        gSLDisplay = nil;
    }
    // CGVirtualDisplay's synthetic screen is tied to object lifetime.
    gCGDisplay = nil;
    if (gLegacyDisplay != NULL && gLegacySymbols.destroy != NULL) {
        gLegacySymbols.destroy(gLegacyDisplay);
        gLegacyDisplay = NULL;
    }
    gDisplayID = 0;
    gBackend = DisplayBackendNone;
}

static void waitForDisplayToSettle(void) {
    // WindowServer applies a new virtual display asynchronously.  Pump the
    // run loop briefly so the display and its modes can become online before
    // the state file is published.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while ([deadline timeIntervalSinceNow] > 0.0 && !gShouldStop) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        if (gDisplayID != 0 && CGDisplayIsOnline(gDisplayID)) break;
    }
}

static int serve(void) {
    loadConfiguration();
    if (!acquireLock()) {
        NSDictionary<NSString *, NSString *> *state = readState();
        pid_t owner = (pid_t)strtol([state[@"pid"] ?: @"0" UTF8String], NULL, 10);
        if (pidIsAlive(owner)) {
            printf("already_running=1 pid=%d backend=%s display_id=%s\n",
                   owner, [state[@"backend"] ?: @"none" UTF8String],
                   [state[@"display_id"] ?: @"0" UTF8String]);
            return 0;
        }
        // A stale lock can only be left by an abnormal filesystem teardown;
        // flock is released by the kernel when the owner dies.  Report the
        // condition rather than deleting another process's lock file.
        fprintf(stderr, "another virtual-display helper owns the lock\n");
        return 3;
    }

    installSignalHandlers();
    NSError *error = nil;
    if (!createDisplay(&error)) {
        fprintf(stderr, "virtual display creation failed: %s\n", error.localizedDescription.UTF8String);
        releaseLock();
        return 4;
    }
    waitForDisplayToSettle();
    if (gDisplayID == 0) {
        destroyDisplay();
        releaseLock();
        return 5;
    }
    if (!writeState(&error)) {
        fprintf(stderr, "cannot publish virtual-display state: %s\n", error.localizedDescription.UTF8String);
        destroyDisplay();
        releaseLock();
        return 6;
    }
    printf("ready=1 backend=%s name=%s display_id=%u pid=%d online=%d\n",
           backendName(gBackend).UTF8String, gDisplayName.UTF8String,
           gDisplayID, getpid(), CGDisplayIsOnline(gDisplayID) ? 1 : 0);
    fflush(stdout);

    NSDate *nextRecoveryAttempt = [NSDate date];
    while (!gShouldStop) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        // A virtual display can be terminated by WindowServer during sleep or
        // a display reconfiguration. Recreate it in the same owner process so
        // an explicit shortcut does not report failure merely because
        // WindowServer recycled the display ID during sleep/wake.
        if (gDisplayID != 0 && !CGDisplayIsOnline(gDisplayID) &&
            [nextRecoveryAttempt timeIntervalSinceNow] <= 0.0) {
            nextRecoveryAttempt = [NSDate dateWithTimeIntervalSinceNow:2.0];
            destroyDisplay();
            NSError *recoveryError = nil;
            if (createDisplay(&recoveryError)) {
                waitForDisplayToSettle();
                if (gDisplayID == 0 || !CGDisplayIsOnline(gDisplayID)) {
                    destroyDisplay();
                }
            }
            if (gDisplayID != 0 && CGDisplayIsOnline(gDisplayID)) {
                (void)writeState(NULL);
            } else {
                NSString *text = [NSString stringWithFormat:
                    @"pid=%d\nbackend=none\nname=%@\ndisplay_id=0\nwidth=%u\nheight=%u\nrefresh_rate=%.3f\nonline=0\n",
                    getpid(), gDisplayName, gDisplayWidth, gDisplayHeight,
                    gDisplayRefreshRate];
                (void)writeTextAtomically(text, gStatePath, NULL);
            }
        }
    }
    destroyDisplay();
    removeState();
    releaseLock();
    return 0;
}

static int spawnBackground(const char *program) {
    pid_t pid = 0;
    char *const arguments[] = { (char *)program, (char *)"--serve", NULL };
    // Do not let the resident child inherit a command-substitution pipe.  A
    // caller such as `helper ensure --background` must return immediately;
    // keeping stdout open in the child would make the shell wait until the
    // helper is destroyed.
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    int status = posix_spawn(&pid, program, &actions, NULL, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (status != 0) {
        fprintf(stderr, "cannot start background helper: %s\n", strerror(status));
        return 7;
    }
    printf("spawned_pid=%d\n", pid);
    return 0;
}

static int destroyCommand(void) {
    loadConfiguration();
    NSDictionary<NSString *, NSString *> *state = readState();
    pid_t pid = (pid_t)strtol([state[@"pid"] ?: @"0" UTF8String], NULL, 10);
    if (!pidIsAlive(pid)) {
        removeState();
        printf("destroyed=1 running=0\n");
        return 0;
    }
    if (kill(pid, SIGTERM) != 0 && errno != ESRCH) {
        fprintf(stderr, "cannot stop helper pid %d: %s\n", pid, strerror(errno));
        return 8;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while ([deadline timeIntervalSinceNow] > 0.0 && pidIsAlive(pid)) usleep(100000);
    if (pidIsAlive(pid)) {
        fprintf(stderr, "helper pid %d did not stop before timeout\n", pid);
        return 9;
    }
    removeState();
    printf("destroyed=1 running=0\n");
    return 0;
}

static int setMainCommand(uint32_t requestedDisplayID) {
    loadConfiguration();
    NSDictionary<NSString *, NSString *> *state = readState();
    uint32_t displayID = (uint32_t)strtoul([state[@"display_id"] ?: @"0" UTF8String], NULL, 10);
    pid_t owner = (pid_t)strtol([state[@"pid"] ?: @"0" UTF8String], NULL, 10);
    if (displayID == 0 || !pidIsAlive(owner)) {
        fprintf(stderr, "virtual display helper is not running\n");
        return 10;
    }

    // CoreGraphics has no public “set main display” function.  Moving a
    // display to (0,0) is the arrangement operation used by System Settings,
    // Crisp and FBD.  When a Sidecar display ID is supplied, put that display
    // at the origin and park our fallback immediately to its right in the
    // same transaction.  Without an argument, put the fallback at the origin
    // for the pre-Sidecar headless state.
    uint32_t targetID = requestedDisplayID;
    if (targetID != 0) {
        if (targetID == displayID || !CGDisplayIsOnline(targetID)) {
            fprintf(stderr, "Sidecar display %u is not online or equals the fallback\n", targetID);
            return 10;
        }
    }
    CGDisplayConfigRef configuration = NULL;
    CGError begin = CGBeginDisplayConfiguration(&configuration);
    if (begin != kCGErrorSuccess || configuration == NULL) {
        fprintf(stderr, "cannot begin display configuration (code=%d)\n", begin);
        return 11;
    }
    CGError configure = CGConfigureDisplayOrigin(configuration,
                                                 targetID == 0 ? displayID : targetID,
                                                 0, 0);
    if (configure == kCGErrorSuccess && targetID != 0) {
        CGRect targetBounds = CGDisplayBounds(targetID);
        int32_t parkingX = (int32_t)ceil(CGRectGetWidth(targetBounds)) + 64;
        configure = CGConfigureDisplayOrigin(configuration, displayID, parkingX, 0);
    }
    CGError complete = configure == kCGErrorSuccess
        ? CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession)
        : configure;
    if (complete != kCGErrorSuccess) {
        fprintf(stderr, "cannot place virtual display at origin (code=%d)\n", complete);
        return 12;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    uint32_t mainID = targetID == 0 ? displayID : targetID;
    while ([deadline timeIntervalSinceNow] > 0.0 && !CGDisplayIsMain(mainID)) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    printf("main_requested=1 target_display_id=%u fallback_display_id=%u main=%d\n",
           mainID, displayID, CGDisplayIsMain(mainID) ? 1 : 0);
    return CGDisplayIsMain(mainID) ? 0 : 13;
}

static void usage(const char *program) {
    fprintf(stderr,
            "usage: %s ensure [--background] | status | destroy | set-main [SIDECAR_DISPLAY_ID]\n"
            "  ensure       create the one fallback display and keep this process alive\n"
            "  --background start an internal --serve child and return immediately\n"
            "  status       print machine-readable helper state\n"
            "  destroy      stop the owner and remove the fallback display\n"
            "  set-main     move fallback to (0,0), or put Sidecar there and park fallback\n",
            program);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            usage(argv[0]);
            return 64;
        }
        NSString *command = [NSString stringWithUTF8String:argv[1]] ?: @"";
        if ([command isEqualToString:@"status"]) {
            loadConfiguration();
            printState(NO);
            return 0;
        }
        if ([command isEqualToString:@"destroy"]) return destroyCommand();
        if ([command isEqualToString:@"set-main"]) {
            uint32_t requested = 0;
            if (argc > 2) {
                char *end = NULL;
                unsigned long value = strtoul(argv[2], &end, 10);
                if (end == argv[2] || *end != '\0' || value == 0 || value > UINT32_MAX) {
                    fprintf(stderr, "set-main expects a numeric display ID\n");
                    return 64;
                }
                requested = (uint32_t)value;
            }
            if (argc > 3) {
                fprintf(stderr, "set-main accepts at most one display ID\n");
                return 64;
            }
            return setMainCommand(requested);
        }
        if ([command isEqualToString:@"--serve"]) return serve();
        if ([command isEqualToString:@"ensure"]) {
            for (int index = 2; index < argc; index++) {
                if (strcmp(argv[index], "--background") == 0) return spawnBackground(argv[0]);
                if (strcmp(argv[index], "--help") == 0) {
                    usage(argv[0]);
                    return 0;
                }
                fprintf(stderr, "unknown option: %s\n", argv[index]);
                return 64;
            }
            return serve();
        }
        usage(argv[0]);
        return 64;
    }
}
