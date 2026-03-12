#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RuntimeMethodDumper : NSObject

/// Dump all methods on CABackdropLayer to console (NSLog)
+ (void)dumpMethodsForCABackdropLayer;

/// Get list of all method signatures for CABackdropLayer
/// @return Array of method signature strings (e.g., "- setScale:", "+ layer")
+ (NSArray<NSString *> *)methodListForCABackdropLayer;

@end

NS_ASSUME_NONNULL_END
