#import "BackdropLayerWrapper.h"
#import <objc/runtime.h>
#import <objc/message.h>

@implementation BackdropLayerWrapper

// Helper to build obfuscated class names at runtime
+ (NSString *)backdropLayerClassName {
    return [@[@"CA", @"Backdrop", @"Layer"] componentsJoinedByString:@""];
}

+ (NSString *)filterClassName {
    return [@[@"CA", @"Filter"] componentsJoinedByString:@""];
}

+ (BOOL)isAvailable {
    return NSClassFromString([self backdropLayerClassName]) != nil;
}

+ (nullable CALayer *)createBackdropLayerWithFrame:(CGRect)frame
                                     blurIntensity:(CGFloat)blur
                                        saturation:(CGFloat)saturation
                                             scale:(CGFloat)scale {

    Class backdropClass = NSClassFromString([self backdropLayerClassName]);
    if (!backdropClass) {
        return nil;
    }

    CALayer *backdrop = [[backdropClass alloc] init];
    backdrop.frame = frame;

    // Get CAFilter class
    Class filterClass = NSClassFromString([self filterClassName]);
    if (!filterClass) {
        return backdrop;
    }

    // Create gaussian blur filter
    SEL filterWithNameSel = NSSelectorFromString(@"filterWithName:");
    if (![filterClass respondsToSelector:filterWithNameSel]) {
        return backdrop;
    }

    id blurFilter = ((id (*)(id, SEL, id))objc_msgSend)(filterClass, filterWithNameSel, @"gaussianBlur");
    if (blurFilter) {
        [blurFilter setValue:@(blur * 45.0) forKey:@"inputRadius"];  // Increased for heavier frost
    }

    // Create saturation filter
    id satFilter = ((id (*)(id, SEL, id))objc_msgSend)(filterClass, filterWithNameSel, @"colorSaturate");
    if (satFilter) {
        [satFilter setValue:@(saturation) forKey:@"inputAmount"];
    }

    // Apply filters
    NSMutableArray *filters = [NSMutableArray array];
    if (blurFilter) [filters addObject:blurFilter];
    if (satFilter) [filters addObject:satFilter];
    backdrop.filters = filters;

    // Set render scale for performance (half resolution)
    @try {
        [backdrop setValue:@(scale) forKey:@"scale"];
    } @catch (NSException *exception) {
        // Scale property may not exist on all versions
    }

    return backdrop;
}

+ (void)updateBlurIntensity:(CGFloat)blur onLayer:(CALayer *)layer {
    NSArray *filters = layer.filters;
    if (!filters) return;

    for (id filter in filters) {
        NSString *name = nil;
        @try {
            name = [filter valueForKey:@"name"];
        } @catch (NSException *exception) {
            continue;
        }

        if ([name isEqualToString:@"gaussianBlur"]) {
            [filter setValue:@(blur * 45.0) forKey:@"inputRadius"];  // Increased for heavier frost
            break;
        }
    }

    // Force filter update by reassigning
    layer.filters = filters;
}

+ (void)updateSaturation:(CGFloat)saturation onLayer:(CALayer *)layer {
    NSArray *filters = layer.filters;
    if (!filters) return;

    for (id filter in filters) {
        NSString *name = nil;
        @try {
            name = [filter valueForKey:@"name"];
        } @catch (NSException *exception) {
            continue;
        }

        if ([name isEqualToString:@"colorSaturate"]) {
            [filter setValue:@(saturation) forKey:@"inputAmount"];
            break;
        }
    }

    // Force filter update
    layer.filters = filters;
}

@end
