#import <UIKit/UIKit.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@interface PortalViewWrapper : NSObject

/// Check if _UIPortalView is available on this device/OS
+ (BOOL)isAvailable;

/// Create a portal view that mirrors the source view's content
/// @param sourceView The view to mirror (e.g., scroll view)
/// @param frame The frame for the portal view
/// @return A UIView that mirrors sourceView's content, or nil if unavailable
+ (nullable UIView *)createPortalViewWithSourceView:(UIView *)sourceView
                                              frame:(CGRect)frame;

/// Update the source view of an existing portal view
+ (void)setSourceView:(UIView *)sourceView onPortalView:(UIView *)portalView;

/// Get MTLTexture from portal view's IOSurface (zero-copy GPU texture)
/// @param portalView The portal view created with createPortalViewWithSourceView:
/// @param device The Metal device to create the texture on
/// @return MTLTexture backed by the same IOSurface as the portal view, or nil
+ (nullable id<MTLTexture>)textureFromPortalView:(UIView *)portalView
                                          device:(id<MTLDevice>)device;

/// Check if the given object is an IOSurface
+ (BOOL)isIOSurface:(nullable id)object;

@end

NS_ASSUME_NONNULL_END
