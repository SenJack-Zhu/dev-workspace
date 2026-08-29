#import "Live2DMacOSTexture.h"

#import "Live2DWrapper.h"

#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>

#define GL_GLEXT_PROTOTYPES 1
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace {

static const NSTimeInterval kFrameInterval = 1.0 / 30.0;

// Cubism's OpenGL shader manager is process-global. Flutter can keep the chat
// stage alive while pushing the Live2D settings preview, so every renderer
// must belong to the same OpenGL share group or the second context will try to
// use shader object names created by the first context and render transparent.
static NSOpenGLContext *Live2DShareContext(NSOpenGLPixelFormat *format) {
    static NSOpenGLContext *context = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        context = [[NSOpenGLContext alloc] initWithFormat:format shareContext:nil];
    });
    return context;
}

static void LogOpenGLError(NSString *operation) {
    const GLenum error = glGetError();
    if (error != GL_NO_ERROR) {
        NSLog(@"[Live2D] %@ failed with OpenGL error 0x%x", operation, error);
    }
}

}  // namespace

/// Owns all objects that must only be accessed from the platform thread.
@interface Live2DOffscreenRenderer : NSObject

- (nullable instancetype)initWithWidth:(int)width height:(int)height;
- (BOOL)resizeWithWidth:(int)width height:(int)height;
- (nullable CVPixelBufferRef)renderFrame CF_RETURNS_RETAINED;
- (BOOL)loadModelWithDir:(NSString *)modelDir fileName:(NSString *)fileName;
- (void)unloadModel;
- (void)startMotionGroup:(NSString *)group index:(int)index priority:(int)priority;
- (void)setExpressionAtIndex:(int)index;
- (void)setParameterWithId:(NSString *)parameterId value:(float)value;
- (void)setMotionSpeed:(float)speed;
- (void)touchBeganAtX:(float)x y:(float)y;
- (void)touchMovedAtX:(float)x y:(float)y;
- (void)touchEndedAtX:(float)x y:(float)y;
- (void)dispose;

@end

@implementation Live2DOffscreenRenderer {
    NSOpenGLContext *_context;
    Live2DWrapper *_wrapper;
    GLuint _framebuffer;
    GLuint _colorTexture;
    int _width;
    int _height;
    CVPixelBufferPoolRef _pixelBufferPool;
    std::vector<uint8_t> _readbackBuffer;
    BOOL _shouldLogFrameStats;
    BOOL _disposed;
}

- (nullable instancetype)initWithWidth:(int)width height:(int)height {
    self = [super init];
    if (!self) return nil;

    NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFAOpenGLProfile,
        NSOpenGLProfileVersionLegacy,
        NSOpenGLPFAColorSize,
        24,
        NSOpenGLPFAAlphaSize,
        8,
        NSOpenGLPFAAccelerated,
        0,
    };
    NSOpenGLPixelFormat *format =
        [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    if (!format) {
        NSLog(@"[Live2D] Unable to create an offscreen OpenGL pixel format");
        return nil;
    }
    _context = [[NSOpenGLContext alloc]
        initWithFormat:format
          shareContext:Live2DShareContext(format)];
    if (!_context) {
        NSLog(@"[Live2D] Unable to create an offscreen OpenGL context");
        return nil;
    }

    [_context makeCurrentContext];
    _wrapper = [[Live2DWrapper alloc] init];
    [_wrapper onSurfaceCreated];
    if (![self resizeWithWidth:width height:height]) {
        [self dispose];
        return nil;
    }
    return self;
}

- (BOOL)resizeWithWidth:(int)width height:(int)height {
    if (_disposed) return NO;
    width = std::max(1, width);
    height = std::max(1, height);
    if (width == _width && height == _height && _framebuffer != 0) return YES;

    [_context makeCurrentContext];
    [self destroyFramebuffer];

    glGenTextures(1, &_colorTexture);
    glBindTexture(GL_TEXTURE_2D, _colorTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(
        GL_TEXTURE_2D,
        0,
        GL_RGBA8,
        width,
        height,
        0,
        GL_BGRA,
        GL_UNSIGNED_INT_8_8_8_8_REV,
        nullptr);

    glGenFramebuffersEXT(1, &_framebuffer);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, _framebuffer);
    glFramebufferTexture2DEXT(
        GL_FRAMEBUFFER_EXT,
        GL_COLOR_ATTACHMENT0_EXT,
        GL_TEXTURE_2D,
        _colorTexture,
        0);
    const GLenum status = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
    if (status != GL_FRAMEBUFFER_COMPLETE_EXT) {
        NSLog(@"[Live2D] Offscreen framebuffer is incomplete: 0x%x", status);
        [self destroyFramebuffer];
        return NO;
    }

    _width = width;
    _height = height;
    [self recreatePixelBufferPool];
    [_wrapper onSurfaceChangedWidth:width height:height];
    glBindTexture(GL_TEXTURE_2D, 0);
    LogOpenGLError(@"resize offscreen framebuffer");
    return _pixelBufferPool != nil;
}

- (nullable CVPixelBufferRef)renderFrame {
    if (_disposed || !_pixelBufferPool || _framebuffer == 0) return nil;

    [_context makeCurrentContext];
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, _framebuffer);
    [_wrapper onDrawFrame];
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, _framebuffer);
    glReadBuffer(GL_COLOR_ATTACHMENT0_EXT);

    CVPixelBufferRef pixelBuffer = nil;
    const CVReturn createResult =
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pixelBufferPool, &pixelBuffer);
    if (createResult != kCVReturnSuccess || !pixelBuffer) {
        NSLog(@"[Live2D] Unable to acquire a CVPixelBuffer: %d", createResult);
        return nil;
    }

    const size_t sourceBytesPerRow = static_cast<size_t>(_width) * 4;
    const size_t pixelBytes = sourceBytesPerRow * static_cast<size_t>(_height);
    constexpr size_t kReadbackGuardBytes = 4096;
    _readbackBuffer.resize(pixelBytes + 2 * kReadbackGuardBytes);
    std::fill(_readbackBuffer.begin(), _readbackBuffer.end(), 0xA5);
    uint8_t *readbackPixels = _readbackBuffer.data() + kReadbackGuardBytes;

    // Cubism only uses vertex/index buffers, but explicitly reset all pack
    // state before handing a CPU pointer to the OpenGL driver.
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glPixelStorei(GL_PACK_ROW_LENGTH, 0);
    glPixelStorei(GL_PACK_SKIP_ROWS, 0);
    glPixelStorei(GL_PACK_SKIP_PIXELS, 0);
    while (glGetError() != GL_NO_ERROR) {}
    glReadPixels(
        0,
        0,
        _width,
        _height,
        GL_BGRA,
        GL_UNSIGNED_BYTE,
        readbackPixels);
    const GLenum readError = glGetError();
    if (readError != GL_NO_ERROR) {
        NSLog(@"[Live2D] glReadPixels failed: 0x%x (%dx%d)", readError, _width, _height);
        CVPixelBufferRelease(pixelBuffer);
        return nil;
    }
    const auto guardByteIsIntact = [](uint8_t byte) { return byte == 0xA5; };
    const BOOL prefixIntact = std::all_of(
        _readbackBuffer.begin(),
        _readbackBuffer.begin() + static_cast<ptrdiff_t>(kReadbackGuardBytes),
        guardByteIsIntact);
    const BOOL suffixIntact = std::all_of(
        _readbackBuffer.begin() +
            static_cast<ptrdiff_t>(kReadbackGuardBytes + pixelBytes),
        _readbackBuffer.end(),
        guardByteIsIntact);
    if (!prefixIntact || !suffixIntact) {
        NSLog(@"[Live2D] glReadPixels crossed its %zu-byte destination (%@%@)",
              pixelBytes,
              prefixIntact ? @"" : @"prefix ",
              suffixIntact ? @"" : @"suffix");
        CVPixelBufferRelease(pixelBuffer);
        return nil;
    }
    if (_shouldLogFrameStats) {
        uint8_t maximumAlpha = 0;
        uint8_t maximumColor = 0;
        size_t nonTransparentPixels = 0;
        for (size_t offset = 0; offset < pixelBytes; offset += 4) {
            maximumColor = std::max(maximumColor, readbackPixels[offset]);
            maximumColor = std::max(maximumColor, readbackPixels[offset + 1]);
            maximumColor = std::max(maximumColor, readbackPixels[offset + 2]);
            maximumAlpha = std::max(maximumAlpha, readbackPixels[offset + 3]);
            if (readbackPixels[offset + 3] != 0) nonTransparentPixels++;
        }
        NSLog(@"[Live2D] Readback frame %dx%d: maxColor=%u maxAlpha=%u nonTransparent=%zu",
              _width, _height, maximumColor, maximumAlpha, nonTransparentPixels);
        _shouldLogFrameStats = NO;
    }

    const CVReturn lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    if (lockResult != kCVReturnSuccess) {
        NSLog(@"[Live2D] Unable to lock CVPixelBuffer: %d", lockResult);
        CVPixelBufferRelease(pixelBuffer);
        return nil;
    }

    uint8_t *base = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(pixelBuffer));
    const size_t destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    const size_t dataSize = CVPixelBufferGetDataSize(pixelBuffer);
    const size_t requiredSize =
        destinationBytesPerRow * static_cast<size_t>(_height);
    if (!base || destinationBytesPerRow < sourceBytesPerRow || dataSize < requiredSize) {
        NSLog(@"[Live2D] Invalid CVPixelBuffer layout: base=%p row=%zu data=%zu required=%zu",
              base, destinationBytesPerRow, dataSize, requiredSize);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        return nil;
    }

    // OpenGL returns the bottom row first; Flutter pixel buffers are top-down.
    for (int y = 0; y < _height; y++) {
        const uint8_t *source =
            readbackPixels +
            static_cast<size_t>(_height - 1 - y) * sourceBytesPerRow;
        uint8_t *destination =
            base + static_cast<size_t>(y) * destinationBytesPerRow;
        memcpy(destination, source, sourceBytesPerRow);
        if (destinationBytesPerRow > sourceBytesPerRow) {
            memset(
                destination + sourceBytesPerRow,
                0,
                destinationBytesPerRow - sourceBytesPerRow);
        }
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

- (BOOL)loadModelWithDir:(NSString *)modelDir fileName:(NSString *)fileName {
    if (_disposed) return NO;
    [_context makeCurrentContext];
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, _framebuffer);
    const BOOL loaded = [_wrapper loadModelWithDir:modelDir fileName:fileName];
    _shouldLogFrameStats = loaded;
    NSLog(@"[Live2D] Model %@: %@", loaded ? @"loaded" : @"failed", fileName);
    return loaded;
}

- (void)unloadModel {
    if (_disposed) return;
    [_context makeCurrentContext];
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, _framebuffer);
    [_wrapper unloadModel];
}

- (void)startMotionGroup:(NSString *)group index:(int)index priority:(int)priority {
    if (_disposed) return;
    [_context makeCurrentContext];
    [_wrapper startMotionGroup:group index:index priority:priority];
}

- (void)setExpressionAtIndex:(int)index {
    if (_disposed) return;
    [_context makeCurrentContext];
    [_wrapper setExpressionAtIndex:index];
}

- (void)setParameterWithId:(NSString *)parameterId value:(float)value {
    if (_disposed) return;
    [_context makeCurrentContext];
    [_wrapper setParameterWithId:parameterId value:value];
}

- (void)setMotionSpeed:(float)speed {
    if (!_disposed) [_wrapper setMotionSpeed:speed];
}

- (void)touchBeganAtX:(float)x y:(float)y {
    if (!_disposed) [_wrapper touchBeganAtX:x y:y];
}

- (void)touchMovedAtX:(float)x y:(float)y {
    if (!_disposed) [_wrapper touchMovedAtX:x y:y];
}

- (void)touchEndedAtX:(float)x y:(float)y {
    if (!_disposed) [_wrapper touchEndedAtX:x y:y];
}

- (void)recreatePixelBufferPool {
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = nil;
    }
    NSDictionary *poolAttributes = @{
        (NSString *)kCVPixelBufferPoolMinimumBufferCountKey : @3,
    };
    NSDictionary *pixelAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey : @(_width),
        (NSString *)kCVPixelBufferHeightKey : @(_height),
        (NSString *)kCVPixelBufferBytesPerRowAlignmentKey : @(_width * 4),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (NSString *)kCVPixelBufferOpenGLCompatibilityKey : @YES,
        (NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    const CVReturn result = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        (__bridge CFDictionaryRef)poolAttributes,
        (__bridge CFDictionaryRef)pixelAttributes,
        &_pixelBufferPool);
    if (result != kCVReturnSuccess) {
        NSLog(@"[Live2D] Unable to create CVPixelBufferPool: %d", result);
        _pixelBufferPool = nil;
    }
}

- (void)destroyFramebuffer {
    if (_framebuffer != 0) {
        glDeleteFramebuffersEXT(1, &_framebuffer);
        _framebuffer = 0;
    }
    if (_colorTexture != 0) {
        glDeleteTextures(1, &_colorTexture);
        _colorTexture = 0;
    }
}

- (void)dispose {
    if (_disposed) return;
    _disposed = YES;
    [_context makeCurrentContext];
    [_wrapper dispose];
    _wrapper = nil;
    [self destroyFramebuffer];
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = nil;
    }
    [_context clearDrawable];
    _context = nil;
    [NSOpenGLContext clearCurrentContext];
}

- (void)dealloc {
    [self dispose];
}

@end

@implementation Live2DMacOSTexture {
    id<FlutterTextureRegistry> _registry;
    Live2DOffscreenRenderer *_renderer;
    NSTimer *_renderTimer;
    NSLock *_pixelBufferLock;
    CVPixelBufferRef _latestPixelBuffer;
    BOOL _renderingPaused;
    BOOL _disposed;
}

- (nullable instancetype)initWithRegistry:(id<FlutterTextureRegistry>)registry
                                    width:(int)width
                                   height:(int)height {
    self = [super init];
    if (!self) return nil;
    _registry = registry;
    _pixelBufferLock = [[NSLock alloc] init];
    _renderer = [[Live2DOffscreenRenderer alloc] initWithWidth:width height:height];
    if (!_renderer) return nil;
    return self;
}

- (void)startWithTextureId:(int64_t)textureId {
    if (_disposed || _renderTimer) return;
    _textureId = textureId;
    __weak Live2DMacOSTexture *weakSelf = self;
    _renderTimer = [NSTimer timerWithTimeInterval:kFrameInterval
                                         repeats:YES
                                           block:^(NSTimer *timer) {
        Live2DMacOSTexture *strongSelf = weakSelf;
        if (strongSelf) [strongSelf renderNow];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_renderTimer forMode:NSRunLoopCommonModes];
    [self renderNow];
}

- (void)renderNow {
    if (_disposed || _renderingPaused || _textureId == 0) return;
    CVPixelBufferRef frame = [_renderer renderFrame];
    if (!frame) return;

    [_pixelBufferLock lock];
    CVPixelBufferRef oldFrame = _latestPixelBuffer;
    _latestPixelBuffer = frame;
    [_pixelBufferLock unlock];
    if (oldFrame) CVPixelBufferRelease(oldFrame);
    [_registry textureFrameAvailable:_textureId];
}

- (CVPixelBufferRef)copyPixelBuffer {
    [_pixelBufferLock lock];
    CVPixelBufferRef frame =
        _latestPixelBuffer ? CVPixelBufferRetain(_latestPixelBuffer) : nil;
    [_pixelBufferLock unlock];
    return frame;
}

- (void)onTextureUnregistered:(NSObject<FlutterTexture> *)texture {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopAndReleaseRenderer];
    });
}

- (BOOL)resizeWithWidth:(int)width height:(int)height {
    if (_disposed) return NO;
    const BOOL resized = [_renderer resizeWithWidth:width height:height];
    if (resized) [self renderNow];
    return resized;
}

- (BOOL)loadModelWithDir:(NSString *)modelDir fileName:(NSString *)fileName {
    if (_disposed) return NO;
    const BOOL loaded = [_renderer loadModelWithDir:modelDir fileName:fileName];
    if (loaded) [self renderNow];
    return loaded;
}

- (void)unloadModel {
    [_renderer unloadModel];
    [self renderNow];
}

- (void)setRenderingPaused:(BOOL)paused {
    _renderingPaused = paused;
    if (!paused) [self renderNow];
}

- (void)startMotionGroup:(NSString *)group index:(int)index priority:(int)priority {
    [_renderer startMotionGroup:group index:index priority:priority];
}

- (void)setExpressionAtIndex:(int)index {
    [_renderer setExpressionAtIndex:index];
}

- (void)setParameterWithId:(NSString *)parameterId value:(float)value {
    [_renderer setParameterWithId:parameterId value:value];
}

- (void)setMotionSpeed:(float)speed {
    [_renderer setMotionSpeed:speed];
}

- (void)touchBeganAtX:(float)x y:(float)y {
    [_renderer touchBeganAtX:x y:y];
}

- (void)touchMovedAtX:(float)x y:(float)y {
    [_renderer touchMovedAtX:x y:y];
}

- (void)touchEndedAtX:(float)x y:(float)y {
    [_renderer touchEndedAtX:x y:y];
}

- (void)stopAndReleaseRenderer {
    [_renderTimer invalidate];
    _renderTimer = nil;
    [_renderer dispose];
    _renderer = nil;

    [_pixelBufferLock lock];
    CVPixelBufferRef frame = _latestPixelBuffer;
    _latestPixelBuffer = nil;
    [_pixelBufferLock unlock];
    if (frame) CVPixelBufferRelease(frame);
}

- (void)dispose {
    if (_disposed) return;
    _disposed = YES;
    const int64_t textureId = _textureId;
    _textureId = 0;
    [self stopAndReleaseRenderer];
    if (textureId != 0) [_registry unregisterTexture:textureId];
}

- (void)dealloc {
    [self stopAndReleaseRenderer];
}

@end
