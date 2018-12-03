#import "GPUImageFramebuffer.h"
#import "GPUImageOutput.h"

@interface GPUImageFramebuffer()
{
    GLuint framebuffer;
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
    CVPixelBufferRef renderTarget;
    CVOpenGLESTextureRef renderTexture;
    NSUInteger readLockCount;
#else
#endif
    NSUInteger framebufferReferenceCount;
    BOOL referenceCountingDisabled;
}

- (void)generateFramebuffer;
- (void)generateTexture;
- (void)destroyFramebuffer;

@end

void dataProviderReleaseCallback (void *info, const void *data, size_t size);
void dataProviderUnlockCallback (void *info, const void *data, size_t size);

@implementation GPUImageFramebuffer

@synthesize size = _size;
@synthesize textureOptions = _textureOptions;
@synthesize texture = _texture;
@synthesize missingFramebuffer = _missingFramebuffer;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithSize:(CGSize)framebufferSize textureOptions:(GPUTextureOptions)fboTextureOptions onlyTexture:(BOOL)onlyGenerateTexture;
{
    if (!(self = [super init]))
    {
		return nil;
    }
    
    _textureOptions = fboTextureOptions;
    _size = framebufferSize;
    framebufferReferenceCount = 0;
    referenceCountingDisabled = NO;
    _missingFramebuffer = onlyGenerateTexture;

    if (_missingFramebuffer)
    {
        typeof(self) __strong strongself = self;
        runSynchronouslyOnVideoProcessingQueue(^{
            [GPUImageContext useImageProcessingContext];
            [strongself generateTexture];
            strongself->framebuffer = 0;
        });
    }
    else
    {
        [self generateFramebuffer];
    }
    return self;
}

- (id)initWithSize:(CGSize)framebufferSize overriddenTexture:(GLuint)inputTexture;
{
    if (!(self = [super init]))
    {
		return nil;
    }

    GPUTextureOptions defaultTextureOptions;
    defaultTextureOptions.minFilter = GL_LINEAR;
    defaultTextureOptions.magFilter = GL_LINEAR;
    defaultTextureOptions.wrapS = GL_CLAMP_TO_EDGE;
    defaultTextureOptions.wrapT = GL_CLAMP_TO_EDGE;
    defaultTextureOptions.internalFormat = GL_RGBA;
    defaultTextureOptions.format = GL_BGRA;
    defaultTextureOptions.type = GL_UNSIGNED_BYTE;

    _textureOptions = defaultTextureOptions;
    _size = framebufferSize;
    framebufferReferenceCount = 0;
    referenceCountingDisabled = YES;
    
    _texture = inputTexture;
    
    return self;
}

- (id)initWithSize:(CGSize)framebufferSize;
{
    GPUTextureOptions defaultTextureOptions;
    defaultTextureOptions.minFilter = GL_LINEAR;
    defaultTextureOptions.magFilter = GL_LINEAR;
    defaultTextureOptions.wrapS = GL_CLAMP_TO_EDGE;
    defaultTextureOptions.wrapT = GL_CLAMP_TO_EDGE;
    defaultTextureOptions.internalFormat = GL_RGBA;
    defaultTextureOptions.format = GL_BGRA;
    defaultTextureOptions.type = GL_UNSIGNED_BYTE;

    if (!(self = [self initWithSize:framebufferSize textureOptions:defaultTextureOptions onlyTexture:NO]))
    {
		return nil;
    }

    return self;
}

- (void)dealloc
{
    [self destroyFramebuffer];
}

#pragma mark -
#pragma mark Internal

- (void)generateTexture;
{
    glActiveTexture(GL_TEXTURE1);
    glGenTextures(1, &_texture);
    glBindTexture(GL_TEXTURE_2D, _texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, _textureOptions.minFilter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, _textureOptions.magFilter);
    // This is necessary for non-power-of-two textures
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, _textureOptions.wrapS);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, _textureOptions.wrapT);
    
    // TODO: Handle mipmaps
}

- (void)generateFramebuffer;
{
    typeof(self) __strong strongself = self;
    runSynchronouslyOnVideoProcessingQueue(^{
        [GPUImageContext useImageProcessingContext];
    
        glGenFramebuffers(1, &strongself->framebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, strongself->framebuffer);
        
        // By default, all framebuffers on iOS 5.0+ devices are backed by texture caches, using one shared cache
        if ([GPUImageContext supportsFastTextureUpload])
        {
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
            CVOpenGLESTextureCacheRef coreVideoTextureCache = [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache];
            // Code originally sourced from http://allmybrain.com/2011/12/08/rendering-to-a-texture-with-ios-5-texture-cache-api/
            
            CFDictionaryRef empty; // empty value for attr value.
            CFMutableDictionaryRef attrs;
            empty = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks); // our empty IOSurface properties dictionary
            attrs = CFDictionaryCreateMutable(kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, empty);
            
            CVReturn err = CVPixelBufferCreate(kCFAllocatorDefault, (int)strongself->_size.width, (int)strongself->_size.height, kCVPixelFormatType_32BGRA, attrs, &strongself->renderTarget);
            if (err)
            {
                NSLog(@"FBO size: %f, %f", strongself->_size.width, strongself->_size.height);
                NSAssert(NO, @"Error at CVPixelBufferCreate %d", err);
            }
            
            err = CVOpenGLESTextureCacheCreateTextureFromImage(
                                kCFAllocatorDefault,
                                coreVideoTextureCache,
                                strongself->renderTarget,
                                NULL, // texture attributes
                                GL_TEXTURE_2D,
                                strongself->_textureOptions.internalFormat, // opengl format
                                (int)strongself->_size.width,
                                (int)strongself->_size.height,
                                strongself->_textureOptions.format, // native iOS format
                                strongself->_textureOptions.type,
                                0,
                                &strongself->renderTexture);
            if (err)
            {
                NSAssert(NO, @"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
            }
            
            CFRelease(attrs);
            CFRelease(empty);
            
            glBindTexture(CVOpenGLESTextureGetTarget(strongself->renderTexture), CVOpenGLESTextureGetName(strongself->renderTexture));
            strongself->_texture = CVOpenGLESTextureGetName(strongself->renderTexture);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, strongself->_textureOptions.wrapS);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, strongself->_textureOptions.wrapT);
            
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, CVOpenGLESTextureGetName(strongself->renderTexture), 0);
#endif
        }
        else
        {
            [strongself generateTexture];

            glBindTexture(GL_TEXTURE_2D, strongself->_texture);
            
            glTexImage2D(GL_TEXTURE_2D,
                         0,
                         strongself->_textureOptions.internalFormat,
                         (int)strongself->_size.width,
                         (int)strongself->_size.height,
                         0,
                         strongself->_textureOptions.format,
                         strongself->_textureOptions.type,
                         0);
            glFramebufferTexture2D(GL_FRAMEBUFFER,
                                   GL_COLOR_ATTACHMENT0,
                                   GL_TEXTURE_2D,
                                   strongself->_texture,
                                   0);
        }
        
        #ifndef NS_BLOCK_ASSERTIONS
        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        NSAssert(status == GL_FRAMEBUFFER_COMPLETE, @"Incomplete filter FBO: %d", status);
        #endif
        
        glBindTexture(GL_TEXTURE_2D, 0);
    });
}

- (void)destroyFramebuffer;
{
    typeof(self) __strong strongself = self;
    runSynchronouslyOnVideoProcessingQueue(^{
        [GPUImageContext useImageProcessingContext];
        
        if (strongself->framebuffer)
        {
            glDeleteFramebuffers(1, &strongself->framebuffer);
            strongself->framebuffer = 0;
        }

        
        if ([GPUImageContext supportsFastTextureUpload] &&
            (!strongself->_missingFramebuffer))
        {
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
            if (strongself->renderTarget)
            {
                CFRelease(strongself->renderTarget);
                strongself->renderTarget = NULL;
            }
            
            if (strongself->renderTexture)
            {
                CFRelease(strongself->renderTexture);
                strongself->renderTexture = NULL;
            }
#endif
        }
        else
        {
            glDeleteTextures(1, &strongself->_texture);
        }

    });
}

#pragma mark -
#pragma mark Usage

- (void)activateFramebuffer;
{
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glViewport(0, 0, (int)_size.width, (int)_size.height);
}

#pragma mark -
#pragma mark Reference counting

- (void)lock;
{
    if (referenceCountingDisabled)
    {
        return;
    }
    
    framebufferReferenceCount++;
}

- (void)unlock;
{
    if (referenceCountingDisabled)
    {
        return;
    }

    NSAssert(framebufferReferenceCount > 0, @"Tried to overrelease a framebuffer, did you forget to call -useNextFrameForImageCapture before using -imageFromCurrentFramebuffer?");
    framebufferReferenceCount--;
    if (framebufferReferenceCount < 1)
    {
        [[GPUImageContext sharedFramebufferCache] returnFramebufferToCache:self];
    }
}

- (void)clearAllLocks;
{
    framebufferReferenceCount = 0;
}

- (void)disableReferenceCounting;
{
    referenceCountingDisabled = YES;
}

- (void)enableReferenceCounting;
{
    referenceCountingDisabled = NO;
}

#pragma mark -
#pragma mark Image capture

void dataProviderReleaseCallback (void *info, const void *data, size_t size)
{
    free((void *)data);
}

void dataProviderUnlockCallback (void *info, const void *data, size_t size)
{
    GPUImageFramebuffer *framebuffer = (__bridge_transfer GPUImageFramebuffer*)info;
    
    [framebuffer restoreRenderTarget];
    [framebuffer unlock];
    [[GPUImageContext sharedFramebufferCache] removeFramebufferFromActiveImageCaptureList:framebuffer];
}

- (CGImageRef)newCGImageFromFramebufferContents;
{
    // a CGImage can only be created from a 'normal' color texture
    NSAssert(self.textureOptions.internalFormat == GL_RGBA, @"For conversion to a CGImage the output texture format for this filter must be GL_RGBA.");
    NSAssert(self.textureOptions.type == GL_UNSIGNED_BYTE, @"For conversion to a CGImage the type of the output texture of this filter must be GL_UNSIGNED_BYTE.");
    
    __block CGImageRef cgImageFromBytes;
    
    typeof(self) __strong strongself = self;
    runSynchronouslyOnVideoProcessingQueue(^{
        [GPUImageContext useImageProcessingContext];
        
        NSUInteger totalBytesForImage = (int)strongself->_size.width * (int)strongself->_size.height * 4;
        // It appears that the width of a texture must be padded out to be a multiple of 8 (32 bytes) if reading from it using a texture cache
        
        GLubyte *rawImagePixels;
        
        CGDataProviderRef dataProvider = NULL;
        if ([GPUImageContext supportsFastTextureUpload])
        {
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
            NSUInteger paddedWidthOfImage = CVPixelBufferGetBytesPerRow(strongself->renderTarget) / 4.0;
            NSUInteger paddedBytesForImage = paddedWidthOfImage * (int)strongself->_size.height * 4;
            
            glFinish();
            CFRetain(strongself->renderTarget); // I need to retain the pixel buffer here and release in the data source callback to prevent its bytes from being prematurely deallocated during a photo write operation
            [strongself lockForReading];
            rawImagePixels = (GLubyte *)CVPixelBufferGetBaseAddress(strongself->renderTarget);
            dataProvider = CGDataProviderCreateWithData((__bridge_retained void*)strongself, rawImagePixels, paddedBytesForImage, dataProviderUnlockCallback);
            [[GPUImageContext sharedFramebufferCache] addFramebufferToActiveImageCaptureList:strongself]; // In case the framebuffer is swapped out on the filter, need to have a strong reference to it somewhere for it to hang on while the image is in existence
#else
#endif
        }
        else
        {
            [strongself activateFramebuffer];
            rawImagePixels = (GLubyte *)malloc(totalBytesForImage);
            glReadPixels(0,
                         0,
                         (int)strongself->_size.width,
                         (int)strongself->_size.height,
                         GL_RGBA,
                         GL_UNSIGNED_BYTE,
                         rawImagePixels);
            dataProvider = CGDataProviderCreateWithData(NULL, rawImagePixels, totalBytesForImage, dataProviderReleaseCallback);
            [self unlock]; // Don't need to keep this around anymore
        }
        
        CGColorSpaceRef defaultRGBColorSpace = CGColorSpaceCreateDeviceRGB();
        
        if ([GPUImageContext supportsFastTextureUpload])
        {
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
            cgImageFromBytes = CGImageCreate((int)strongself->_size.width,
                                             (int)strongself->_size.height,
                                             8,
                                             32,
                                             CVPixelBufferGetBytesPerRow(strongself->renderTarget),
                                             defaultRGBColorSpace,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,
                                             dataProvider,
                                             NULL,
                                             NO,
                                             kCGRenderingIntentDefault);
#else
#endif
        }
        else
        {
            cgImageFromBytes = CGImageCreate((int)strongself->_size.width,
                                             (int)strongself->_size.height,
                                             8,
                                             32,
                                             4 * (int)strongself->_size.width,
                                             defaultRGBColorSpace,
                                             kCGBitmapByteOrderDefault | kCGImageAlphaLast,
                                             dataProvider,
                                             NULL,
                                             NO,
                                             kCGRenderingIntentDefault);
        }
        
        // Capture image with current device orientation
        CGDataProviderRelease(dataProvider);
        CGColorSpaceRelease(defaultRGBColorSpace);
        
    });
    
    return cgImageFromBytes;
}

- (void)restoreRenderTarget;
{
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
    [self unlockAfterReading];
    CFRelease(renderTarget);
#else
#endif
}

#pragma mark -
#pragma mark Raw data bytes

- (void)lockForReading
{
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
    if ([GPUImageContext supportsFastTextureUpload])
    {
        if (readLockCount == 0)
        {
            CVPixelBufferLockBaseAddress(renderTarget, 0);
        }
        readLockCount++;
    }
#endif
}

- (void)unlockAfterReading
{
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
    if ([GPUImageContext supportsFastTextureUpload])
    {
        NSAssert(readLockCount > 0, @"Unbalanced call to -[GPUImageFramebuffer unlockAfterReading]");
        readLockCount--;
        if (readLockCount == 0)
        {
            CVPixelBufferUnlockBaseAddress(renderTarget, 0);
        }
    }
#endif
}

- (NSUInteger)bytesPerRow;
{
    if ([GPUImageContext supportsFastTextureUpload])
    {
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
        return CVPixelBufferGetBytesPerRow(renderTarget);
#else
        return _size.width * 4; // TODO: do more with this on the non-texture-cache side
#endif
    }
    else
    {
        return _size.width * 4;
    }
}

- (GLubyte *)byteBuffer;
{
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
    [self lockForReading];
    GLubyte * bufferBytes = CVPixelBufferGetBaseAddress(renderTarget);
    [self unlockAfterReading];
    return bufferBytes;
#else
    return NULL; // TODO: do more with this on the non-texture-cache side
#endif
}

- (CVPixelBufferRef )pixelBuffer;
{
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
    return renderTarget;
#else
    return NULL; // TODO: do more with this on the non-texture-cache side
#endif
}

- (GLuint)texture;
{
//    NSLog(@"Accessing texture: %d from FB: %@", _texture, self);
    return _texture;
}

@end
