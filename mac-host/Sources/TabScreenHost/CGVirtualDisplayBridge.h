#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface CGVirtualDisplayBridge : NSObject

@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) uint32_t width;
@property (nonatomic, readonly) uint32_t height;
@property (nonatomic, readonly) double refreshRate;

+ (nullable instancetype)createWithName:(NSString *)name
                                  width:(uint32_t)width
                                 height:(uint32_t)height
                            refreshRate:(double)refreshRate
                                  hiDPI:(BOOL)hiDPI;

- (void)destroy;

@end

NS_ASSUME_NONNULL_END
