#import <React/RCTViewComponentView.h>
#import <UIKit/UIKit.h>

#ifndef VlcPlayerViewNativeComponent_h
#define VlcPlayerViewNativeComponent_h

NS_ASSUME_NONNULL_BEGIN

/// Fabric component view that bridges VLCKit's @c VLCMediaPlayer to React
/// Native. Props are applied through @c updateProps:oldProps: and runtime
/// commands (@c play, @c pause, @c seek, @c snapshot, @c reload) are
/// dispatched through @c handleCommand:args:.
@interface VlcPlayerView : RCTViewComponentView
@end

NS_ASSUME_NONNULL_END

#endif /* VlcPlayerViewNativeComponent_h */
