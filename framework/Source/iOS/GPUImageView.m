#import "GPUImageView.h"
#import <OpenGLES/EAGLDrawable.h>
#import <QuartzCore/QuartzCore.h>
#import "GPUImageContext.h"
#import "GPUImageFilter.h"
#import <AVFoundation/AVFoundation.h>

#pragma mark -
#pragma mark Private methods and instance variables

@interface GPUImageView ()
{
    GPUImageFramebuffer *inputFramebufferForDisplay;
    GLuint displayRenderbuffer, displayFramebuffer;
    
    GLProgram *displayProgram;
    GLint displayPositionAttribute, displayTextureCoordinateAttribute;
    GLint displayInputTextureUniform;

    CGSize inputImageSize;
    GLfloat imageVertices[8];
    GLfloat backgroundColorRed, backgroundColorGreen, backgroundColorBlue, backgroundColorAlpha;

    CGSize boundsSizeAtFrameBufferEpoch;
}

/**
 This is updated on view creation, and in -layoutSubviews. It allows the bounds property to be accessed off the main thread, without causing a deadlock
 */
@property (nonatomic, assign) CGRect cachedBounds;
@property (nonatomic, readonly) id cachedBoundsLock;

@property (assign, nonatomic) NSUInteger aspectRatio;

// Initialization and teardown
- (void)commonInit;

// Managing the display FBOs
- (void)createDisplayFramebuffer;
- (void)destroyDisplayFramebuffer;

// Handling fill mode
- (void)recalculateViewGeometry;

@end

@implementation GPUImageView

@synthesize aspectRatio;
@synthesize sizeInPixels = _sizeInPixels;
@synthesize fillMode = _fillMode;
@synthesize enabled;

#pragma mark -
#pragma mark Initialization and teardown

+ (Class)layerClass
{
	return [CAEAGLLayer class];
}

- (id)initWithFrame:(CGRect)frame
{
    if (!(self = [super initWithFrame:frame]))
    {
		return nil;
    }
    
    [self commonInit];
    
    return self;
}

-(id)initWithCoder:(NSCoder *)coder
{
	if (!(self = [super initWithCoder:coder]))
    {
        return nil;
	}

    [self commonInit];

	return self;
}

- (void)commonInit
{
    _cachedBoundsLock = [NSObject new];
    _cachedBounds = self.bounds;
    
    // Set scaling to account for Retina display
    if ([self respondsToSelector:@selector(setContentScaleFactor:)])
    {
        self.contentScaleFactor = [[UIScreen mainScreen] scale];
    }

    inputRotation = kGPUImageNoRotation;
    self.opaque = YES;
    self.hidden = NO;
    CAEAGLLayer *eaglLayer = (CAEAGLLayer *)self.layer;
    eaglLayer.opaque = YES;
    eaglLayer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:NO], kEAGLDrawablePropertyRetainedBacking, kEAGLColorFormatRGBA8, kEAGLDrawablePropertyColorFormat, nil];

    self.enabled = YES;
    
    typeof(self) __strong strongself = self;
    runSynchronouslyOnVideoProcessingQueue(^{
        [GPUImageContext useImageProcessingContext];
        
        strongself->displayProgram = [[GPUImageContext sharedImageProcessingContext] programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImagePassthroughFragmentShaderString];
        if (!strongself->displayProgram.initialized)
        {
            [strongself->displayProgram addAttribute:@"position"];
            [strongself->displayProgram addAttribute:@"inputTextureCoordinate"];
            
            if (![strongself->displayProgram link])
            {
                NSString *progLog = [strongself->displayProgram programLog];
                NSLog(@"Program link log: %@", progLog);
                NSString *fragLog = [strongself->displayProgram fragmentShaderLog];
                NSLog(@"Fragment shader compile log: %@", fragLog);
                NSString *vertLog = [strongself->displayProgram vertexShaderLog];
                NSLog(@"Vertex shader compile log: %@", vertLog);
                strongself->displayProgram = nil;
                NSAssert(NO, @"Filter shader link failed");
            }
        }
        
        strongself->displayPositionAttribute = [strongself->displayProgram attributeIndex:@"position"];
        strongself->displayTextureCoordinateAttribute = [strongself->displayProgram attributeIndex:@"inputTextureCoordinate"];
        strongself->displayInputTextureUniform = [strongself->displayProgram uniformIndex:@"inputImageTexture"]; // This does assume a name of "inputTexture" for the fragment shader

        [GPUImageContext setActiveShaderProgram:strongself->displayProgram];
        glEnableVertexAttribArray(strongself->displayPositionAttribute);
        glEnableVertexAttribArray(strongself->displayTextureCoordinateAttribute);
        
        [self setBackgroundColorRed:0.0 green:0.0 blue:0.0 alpha:1.0];
        strongself->_fillMode = kGPUImageFillModePreserveAspectRatio;
        [self createDisplayFramebuffer];
    });
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    @synchronized (self.cachedBoundsLock)
    {
        self.cachedBounds = self.bounds;
    }
    
    // The frame buffer needs to be trashed and re-created when the view size changes.
    if (!CGSizeEqualToSize(self.bounds.size, boundsSizeAtFrameBufferEpoch) &&
        !CGSizeEqualToSize(self.bounds.size, CGSizeZero))
    {
        runSynchronouslyOnVideoProcessingQueue(^
        {
            [self destroyDisplayFramebuffer];
            [self createDisplayFramebuffer];
        });
    }
    else if (!CGSizeEqualToSize(self.bounds.size, CGSizeZero))
    {
        [self recalculateViewGeometry];
    }
}

- (void)dealloc
{
    runSynchronouslyOnVideoProcessingQueue(^{
        [self destroyDisplayFramebuffer];
    });
}

#pragma mark -
#pragma mark Managing the display FBOs

- (void)createDisplayFramebuffer
{
    [GPUImageContext useImageProcessingContext];
    
    glGenFramebuffers(1, &displayFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, displayFramebuffer);
	
    glGenRenderbuffers(1, &displayRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, displayRenderbuffer);
	
    [[[GPUImageContext sharedImageProcessingContext] context] renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer*)self.layer];
	
    GLint backingWidth, backingHeight;

    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &backingWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &backingHeight);
    
    if ( (backingWidth == 0) || (backingHeight == 0) )
    {
        [self destroyDisplayFramebuffer];
        return;
    }
    
    _sizeInPixels.width = (CGFloat)backingWidth;
    _sizeInPixels.height = (CGFloat)backingHeight;

//    NSLog(@"Backing width: %d, height: %d", backingWidth, backingHeight);

    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, displayRenderbuffer);
	
    __unused GLuint framebufferCreationStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    NSAssert(framebufferCreationStatus == GL_FRAMEBUFFER_COMPLETE, @"Failure with display framebuffer generation for display of size: %f, %f", self.bounds.size.width, self.bounds.size.height);
    boundsSizeAtFrameBufferEpoch = self.bounds.size;

    [self recalculateViewGeometry];
}

- (void)destroyDisplayFramebuffer
{
    [GPUImageContext useImageProcessingContext];

    if (displayFramebuffer)
	{
		glDeleteFramebuffers(1, &displayFramebuffer);
		displayFramebuffer = 0;
	}
	
	if (displayRenderbuffer)
	{
		glDeleteRenderbuffers(1, &displayRenderbuffer);
		displayRenderbuffer = 0;
	}
}

- (void)setDisplayFramebuffer
{
    if (!displayFramebuffer)
    {
        [self createDisplayFramebuffer];
    }
    
    glBindFramebuffer(GL_FRAMEBUFFER, displayFramebuffer);
    
    glViewport(0, 0, (GLint)_sizeInPixels.width, (GLint)_sizeInPixels.height);
}

- (void)presentFramebuffer
{
    glBindRenderbuffer(GL_RENDERBUFFER, displayRenderbuffer);
    [[GPUImageContext sharedImageProcessingContext] presentBufferForDisplay];
}

#pragma mark -
#pragma mark Handling fill mode

- (void)recalculateViewGeometry
{
    CGRect bounds = CGRectZero;
    @synchronized (self.cachedBoundsLock)
    {
        // This method can be called off the main thread, but the bounds
        // can't be accessed off the main thread. If we dispatch to the
        // main thread now, it could cause a deadlock, so just use the
        // cached bounds. If/when the bounds change again, the
        // -layoutSubviews method will be called, which will update the
        // cached bounds, and call this method again
        bounds = self.cachedBounds;
    }
    
    typeof(self) __strong strongself = self;
    runSynchronouslyOnVideoProcessingQueue(^
    {
        CGFloat heightScaling, widthScaling;
        CGSize currentViewSize = bounds.size;
        
        CGRect insetRect = AVMakeRectWithAspectRatioInsideRect(strongself->inputImageSize, bounds);
        
        switch(strongself->_fillMode)
        {
            case kGPUImageFillModeStretch:
            {
                widthScaling = 1.0;
                heightScaling = 1.0;
            }; break;
            case kGPUImageFillModePreserveAspectRatio:
            {
                widthScaling = insetRect.size.width / currentViewSize.width;
                heightScaling = insetRect.size.height / currentViewSize.height;
            }; break;
            case kGPUImageFillModePreserveAspectRatioAndFill:
            {
                //            CGFloat widthHolder = insetRect.size.width / currentViewSize.width;
                widthScaling = currentViewSize.height / insetRect.size.height;
                heightScaling = currentViewSize.width / insetRect.size.width;
            }; break;
        }
        
        strongself->imageVertices[0] = -widthScaling;
        strongself->imageVertices[1] = -heightScaling;
        strongself->imageVertices[2] = widthScaling;
        strongself->imageVertices[3] = -heightScaling;
        strongself->imageVertices[4] = -widthScaling;
        strongself->imageVertices[5] = heightScaling;
        strongself->imageVertices[6] = widthScaling;
        strongself->imageVertices[7] = heightScaling;
    });
}

- (void)setBackgroundColorRed:(GLfloat)redComponent green:(GLfloat)greenComponent blue:(GLfloat)blueComponent alpha:(GLfloat)alphaComponent
{
    backgroundColorRed = redComponent;
    backgroundColorGreen = greenComponent;
    backgroundColorBlue = blueComponent;
    backgroundColorAlpha = alphaComponent;
}

+ (const GLfloat *)textureCoordinatesForRotation:(GPUImageRotationMode)rotationMode
{
    static const GLfloat noRotationTextureCoordinates[] = {
        0.0f, 1.0f,
        1.0f, 1.0f,
        0.0f, 0.0f,
        1.0f, 0.0f,
    };

    static const GLfloat rotateRightTextureCoordinates[] = {
        1.0f, 1.0f,
        1.0f, 0.0f,
        0.0f, 1.0f,
        0.0f, 0.0f,
    };

    static const GLfloat rotateLeftTextureCoordinates[] = {
        0.0f, 0.0f,
        0.0f, 1.0f,
        1.0f, 0.0f,
        1.0f, 1.0f,
    };
    
    static const GLfloat verticalFlipTextureCoordinates[] = {
        0.0f, 0.0f,
        1.0f, 0.0f,
        0.0f, 1.0f,
        1.0f, 1.0f,
    };
    
    static const GLfloat horizontalFlipTextureCoordinates[] = {
        1.0f, 1.0f,
        0.0f, 1.0f,
        1.0f, 0.0f,
        0.0f, 0.0f,
    };
    
    static const GLfloat rotateRightVerticalFlipTextureCoordinates[] = {
        1.0f, 0.0f,
        1.0f, 1.0f,
        0.0f, 0.0f,
        0.0f, 1.0f,
    };
    
    static const GLfloat rotateRightHorizontalFlipTextureCoordinates[] = {
        0.0f, 1.0f,
        0.0f, 0.0f,
        1.0f, 1.0f,
        1.0f, 0.0f,
    };

    static const GLfloat rotate180TextureCoordinates[] = {
        1.0f, 0.0f,
        0.0f, 0.0f,
        1.0f, 1.0f,
        0.0f, 1.0f,
    };
    
    switch(rotationMode)
    {
        case kGPUImageNoRotation: return noRotationTextureCoordinates;
        case kGPUImageRotateLeft: return rotateLeftTextureCoordinates;
        case kGPUImageRotateRight: return rotateRightTextureCoordinates;
        case kGPUImageFlipVertical: return verticalFlipTextureCoordinates;
        case kGPUImageFlipHorizonal: return horizontalFlipTextureCoordinates;
        case kGPUImageRotateRightFlipVertical: return rotateRightVerticalFlipTextureCoordinates;
        case kGPUImageRotateRightFlipHorizontal: return rotateRightHorizontalFlipTextureCoordinates;
        case kGPUImageRotate180: return rotate180TextureCoordinates;
    }
}

#pragma mark -
#pragma mark GPUInput protocol

- (void)newFrameReadyAtTime:(CMTime)frameTime atIndex:(NSInteger)textureIndex
{
    typeof(self) __strong strongself = self;
    runSynchronouslyOnVideoProcessingQueue(^{
        [GPUImageContext setActiveShaderProgram:strongself->displayProgram];
        [self setDisplayFramebuffer];
        
        glClearColor(strongself->backgroundColorRed, strongself->backgroundColorGreen, strongself->backgroundColorBlue, strongself->backgroundColorAlpha);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        
        glActiveTexture(GL_TEXTURE4);
        glBindTexture(GL_TEXTURE_2D, [strongself->inputFramebufferForDisplay texture]);
        glUniform1i(strongself->displayInputTextureUniform, 4);
        
        glVertexAttribPointer(strongself->displayPositionAttribute, 2, GL_FLOAT, 0, 0, strongself->imageVertices);
        glVertexAttribPointer(strongself->displayTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, [GPUImageView textureCoordinatesForRotation:strongself->inputRotation]);
        
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        
        [strongself presentFramebuffer];
        [strongself->inputFramebufferForDisplay unlock];
        strongself->inputFramebufferForDisplay = nil;
    });
}

- (NSInteger)nextAvailableTextureIndex
{
    return 0;
}

- (void)setInputFramebuffer:(GPUImageFramebuffer *)newInputFramebuffer atIndex:(NSInteger)textureIndex
{
    inputFramebufferForDisplay = newInputFramebuffer;
    [inputFramebufferForDisplay lock];
}

- (void)setInputRotation:(GPUImageRotationMode)newInputRotation atIndex:(NSInteger)textureIndex
{
    inputRotation = newInputRotation;
}

- (void)setInputSize:(CGSize)newSize atIndex:(NSInteger)textureIndex
{
    typeof(self) __strong strongself = self;
    runSynchronouslyOnVideoProcessingQueue(^{
        CGSize rotatedSize = newSize;
        
        if (GPUImageRotationSwapsWidthAndHeight(strongself->inputRotation))
        {
            rotatedSize.width = newSize.height;
            rotatedSize.height = newSize.width;
        }
        
        if (!CGSizeEqualToSize(strongself->inputImageSize, rotatedSize))
        {
            strongself->inputImageSize = rotatedSize;
            [self recalculateViewGeometry];
        }
    });
}

- (CGSize)maximumOutputSize
{
    if ([self respondsToSelector:@selector(setContentScaleFactor:)])
    {
        CGSize pointSize = self.bounds.size;
        return CGSizeMake(self.contentScaleFactor * pointSize.width, self.contentScaleFactor * pointSize.height);
    }
    else
    {
        return self.bounds.size;
    }
}

- (void)endProcessing
{
}

- (BOOL)shouldIgnoreUpdatesToThisTarget
{
    return NO;
}

- (BOOL)wantsMonochromeInput
{
    return NO;
}

- (void)setCurrentlyReceivingMonochromeInput:(BOOL)newValue
{
    
}

#pragma mark -
#pragma mark Accessors

- (CGSize)sizeInPixels
{
    if (CGSizeEqualToSize(_sizeInPixels, CGSizeZero))
    {
        return [self maximumOutputSize];
    }
    else
    {
        return _sizeInPixels;
    }
}

- (void)setFillMode:(GPUImageFillModeType)newValue
{
    _fillMode = newValue;
    [self recalculateViewGeometry];
}

@end
