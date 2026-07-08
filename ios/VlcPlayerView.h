#import <React/RCTViewComponentView.h>
#import <UIKit/UIKit.h>

/**
 * Fabric component view for `VlcPlayerView`, backed by MobileVLCKit 3.7.3.
 *
 * The playback architecture mirrors the official VLC-iOS app's
 * VLCPlaybackService: a VLCMediaListPlayer created with a plain UIView
 * drawable up front (video decoding fails if the drawable arrives late),
 * repeat handled natively via VLCRepeatMode, and all player access going
 * through MobileVLCKit's published API only.
 */
@interface VlcPlayerView : RCTViewComponentView
@end
