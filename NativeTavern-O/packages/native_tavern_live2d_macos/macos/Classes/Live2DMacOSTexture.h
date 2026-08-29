#pragma once

#import <FlutterMacOS/FlutterMacOS.h>

NS_ASSUME_NONNULL_BEGIN

/// A Flutter texture backed by an offscreen Cubism OpenGL renderer.
@interface Live2DMacOSTexture : NSObject <FlutterTexture>

@property(nonatomic, readonly) int64_t textureId;

- (nullable instancetype)initWithRegistry:(id<FlutterTextureRegistry>)registry
                                    width:(int)width
                                   height:(int)height
    NS_SWIFT_NAME(init(registry:width:height:));

/// Starts frame delivery after the texture has been registered with Flutter.
- (void)startWithTextureId:(int64_t)textureId
    NS_SWIFT_NAME(start(textureId:));

- (BOOL)resizeWithWidth:(int)width height:(int)height
    NS_SWIFT_NAME(resize(width:height:));
- (BOOL)loadModelWithDir:(NSString *)modelDir fileName:(NSString *)fileName
    NS_SWIFT_NAME(loadModel(modelDir:fileName:));
- (void)unloadModel;
- (void)setRenderingPaused:(BOOL)paused
    NS_SWIFT_NAME(setRenderingPaused(_:));

- (void)startMotionGroup:(NSString *)group index:(int)index priority:(int)priority
    NS_SWIFT_NAME(startMotion(group:index:priority:));
- (void)setExpressionAtIndex:(int)index
    NS_SWIFT_NAME(setExpression(index:));
- (void)setParameterWithId:(NSString *)parameterId value:(float)value
    NS_SWIFT_NAME(setParameter(parameterId:value:));
- (void)setMotionSpeed:(float)speed
    NS_SWIFT_NAME(setMotionSpeed(_:));

- (void)touchBeganAtX:(float)x y:(float)y
    NS_SWIFT_NAME(touchBegan(x:y:));
- (void)touchMovedAtX:(float)x y:(float)y
    NS_SWIFT_NAME(touchMoved(x:y:));
- (void)touchEndedAtX:(float)x y:(float)y
    NS_SWIFT_NAME(touchEnded(x:y:));

/// Stops rendering, unregisters the texture, and releases all GL resources.
- (void)dispose;

@end

NS_ASSUME_NONNULL_END
