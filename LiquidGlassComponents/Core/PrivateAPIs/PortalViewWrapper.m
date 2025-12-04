#import "PortalViewWrapper.h"
#import <objc/runtime.h>
#import <objc/message.h>
@import IOSurface;

@implementation PortalViewWrapper

// Helper to build obfuscated class name at runtime
+ (NSString *)portalViewClassName {
    return [@[@"_UI", @"Portal", @"View"] componentsJoinedByString:@""];
}

+ (BOOL)isAvailable {
    return NSClassFromString([self portalViewClassName]) != nil;
}

+ (nullable UIView *)createPortalViewWithSourceView:(UIView *)sourceView
                                              frame:(CGRect)frame {
    Class portalClass = NSClassFromString([self portalViewClassName]);
    if (!portalClass) {
        NSLog(@"[PortalViewWrapper] _UIPortalView not available");
        return nil;
    }

    UIView *portalView = [[portalClass alloc] initWithFrame:frame];
    if (!portalView) {
        NSLog(@"[PortalViewWrapper] Failed to create portal view");
        return nil;
    }

    // Set the source view
    @try {
        [portalView setValue:sourceView forKey:@"sourceView"];
    } @catch (NSException *exception) {
        NSLog(@"[PortalViewWrapper] Failed to set sourceView: %@", exception);
        return nil;
    }

    // Make the portal view not render on screen (we only want to read its IOSurface)
    portalView.hidden = YES;

    return portalView;
}

+ (void)setSourceView:(UIView *)sourceView onPortalView:(UIView *)portalView {
    @try {
        [portalView setValue:sourceView forKey:@"sourceView"];
    } @catch (NSException *exception) {
        NSLog(@"[PortalViewWrapper] Failed to set sourceView: %@", exception);
    }
}

+ (BOOL)isIOSurface:(nullable id)object {
    if (!object) return NO;

    // Check if it's a CFType with IOSurface type ID
    CFTypeRef cf = (__bridge CFTypeRef)object;
    CFTypeID typeID = CFGetTypeID(cf);
    CFTypeID ioSurfaceTypeID = IOSurfaceGetTypeID();

    return typeID == ioSurfaceTypeID;
}

+ (nullable id<MTLTexture>)textureFromPortalView:(UIView *)portalView
                                          device:(id<MTLDevice>)device {
    if (!portalView || !device) {
        return nil;
    }

    CALayer *layer = portalView.layer;
    IOSurfaceRef surface = NULL;

    // Try to get IOSurface from layer.contents
    @try {
        id contents = [layer valueForKey:@"contents"];
        if (!contents) {
            // Log only occasionally to avoid spam (use static counter)
            static int nilCount = 0;
            if (++nilCount % 60 == 1) {
                NSLog(@"[PortalViewWrapper] layer.contents is nil (count: %d)", nilCount);
            }
            return nil;
        }

        if ([self isIOSurface:contents]) {
            surface = (__bridge IOSurfaceRef)contents;
        } else {
            // Log the actual type we got instead
            static int wrongTypeCount = 0;
            if (++wrongTypeCount % 60 == 1) {
                NSLog(@"[PortalViewWrapper] layer.contents is not IOSurface, type: %@ (count: %d)",
                      NSStringFromClass([contents class]), wrongTypeCount);
            }
            return nil;
        }
    } @catch (NSException *exception) {
        NSLog(@"[PortalViewWrapper] Failed to get layer.contents: %@", exception);
        return nil;
    }

    if (!surface) {
        // IOSurface might not be ready yet (needs at least one render pass)
        return nil;
    }

    // Get surface dimensions
    size_t width = IOSurfaceGetWidth(surface);
    size_t height = IOSurfaceGetHeight(surface);

    if (width == 0 || height == 0) {
        NSLog(@"[PortalViewWrapper] IOSurface has zero dimensions");
        return nil;
    }

    // Create Metal texture descriptor
    MTLTextureDescriptor *desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:width
        height:height
        mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;

    // Create texture from IOSurface (zero-copy!)
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc
                                                    iosurface:surface
                                                        plane:0];

    if (texture) {
        NSLog(@"[PortalViewWrapper] Created texture %zux%zu from IOSurface", width, height);
    } else {
        NSLog(@"[PortalViewWrapper] Failed to create texture from IOSurface");
    }

    return texture;
}

@end
