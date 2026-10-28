#import "CGVirtualDisplayBridge.h"

// Private CoreGraphics interfaces
@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) unsigned int maxPixelsWide;
@property (nonatomic, assign) unsigned int maxPixelsHigh;
@property (nonatomic, assign) unsigned int vendorID;
@property (nonatomic, assign) unsigned int productID;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, copy) NSArray *modes;
@property (nonatomic, assign) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (void)dealloc;
@end

@interface CGVirtualDisplayBridge ()
@property (nonatomic, strong) id displayInstance;
@property (nonatomic, readwrite) CGDirectDisplayID displayID;
@property (nonatomic, readwrite) uint32_t width;
@property (nonatomic, readwrite) uint32_t height;
@property (nonatomic, readwrite) double refreshRate;
@end

@implementation CGVirtualDisplayBridge

+ (nullable instancetype)createWithName:(NSString *)name
                                  width:(uint32_t)width
                                 height:(uint32_t)height
                            refreshRate:(double)refreshRate
                                  hiDPI:(BOOL)hiDPI {
    Class descClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class dispClass = NSClassFromString(@"CGVirtualDisplay");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settClass = NSClassFromString(@"CGVirtualDisplaySettings");

    if (!descClass || !dispClass || !modeClass || !settClass) {
        NSLog(@"[TabScreen] CGVirtualDisplay private classes not found on this macOS build");
        return nil;
    }

    CGVirtualDisplayDescriptor *desc = [[descClass alloc] init];
    desc.name = name;
    desc.maxPixelsWide = width;
    desc.maxPixelsHigh = height;
    desc.vendorID = 0x5461; // 'Ta'
    desc.productID = 0x6253; // 'bS'
    desc.queue = dispatch_get_main_queue();

    CGVirtualDisplay *display = [[dispClass alloc] initWithDescriptor:desc];
    if (!display) {
        NSLog(@"[TabScreen] Failed to initialize CGVirtualDisplay");
        return nil;
    }

    CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:width height:height refreshRate:refreshRate];
    CGVirtualDisplaySettings *settings = [[settClass alloc] init];
    settings.modes = @[mode];
    settings.hiDPI = hiDPI ? 1 : 0;

    if (![display applySettings:settings]) {
        NSLog(@"[TabScreen] Failed to apply settings to CGVirtualDisplay");
        return nil;
    }

    CGVirtualDisplayBridge *bridge = [[CGVirtualDisplayBridge alloc] init];
    bridge.displayInstance = display;
    bridge.displayID = display.displayID;
    bridge.width = width;
    bridge.height = height;
    bridge.refreshRate = refreshRate;

    NSLog(@"[TabScreen] Created Virtual Display ID: %u (%ux%u @ %.0fHz, hiDPI: %d)",
          bridge.displayID, width, height, refreshRate, hiDPI);

    return bridge;
}

- (void)destroy {
    if (self.displayInstance) {
        NSLog(@"[TabScreen] Destroying Virtual Display ID: %u", self.displayID);
        self.displayInstance = nil;
        self.displayID = 0;
    }
}

- (void)dealloc {
    [self destroy];
}

@end
