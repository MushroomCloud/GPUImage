#import "GPUImageRawDataInput.h"

@interface GPUImageRawDataInput()
- (void)uploadBytes:(GLubyte *)bytesToUpload;
@end

@implementation GPUImageRawDataInput

@synthesize pixelFormat = _pixelFormat;
@synthesize pixelType = _pixelType;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithBytes:(GLubyte *)bytesToUpload size:(CGSize)imageSize;
{
    if (!(self = [self initWithBytes:bytesToUpload size:imageSize pixelFormat:GPUPixelFormatBGRA type:GPUPixelTypeUByte]))
    {
		return nil;
    }
	
	return self;
}

- (id)initWithBytes:(GLubyte *)bytesToUpload size:(CGSize)imageSize pixelFormat:(GPUPixelFormat)pixelFormat;
{
    if (!(self = [self initWithBytes:bytesToUpload size:imageSize pixelFormat:pixelFormat type:GPUPixelTypeUByte]))
    {
		return nil;
    }
	
	return self;
}

- (id)initWithBytes:(GLubyte *)bytesToUpload size:(CGSize)imageSize pixelFormat:(GPUPixelFormat)pixelFormat type:(GPUPixelType)pixelType;
{
    if (!(self = [super init]))
    {
		return nil;
    }
    
	dataUpdateSemaphore = dispatch_semaphore_create(1);

    uploadedImageSize = imageSize;
	self.pixelFormat = pixelFormat;
	self.pixelType = pixelType;
        
    [self uploadBytes:bytesToUpload];
    
    return self;
}

// ARC forbids explicit message send of 'release'; since iOS 6 even for dispatch_release() calls: stripping it out in that case is required.
- (void)dealloc;
{
#if !OS_OBJECT_USE_OBJC
    if (dataUpdateSemaphore != NULL)
    {
        dispatch_release(dataUpdateSemaphore);
    }
#endif
}

#pragma mark -
#pragma mark Image rendering

- (void)uploadBytes:(GLubyte *)bytesToUpload;
{
    [GPUImageContext useImageProcessingContext];

    // TODO: This probably isn't right, and will need to be corrected
    outputFramebuffer = [[GPUImageContext sharedFramebufferCache] fetchFramebufferForSize:uploadedImageSize textureOptions:self.outputTextureOptions onlyTexture:YES];
    
    glBindTexture(GL_TEXTURE_2D, [outputFramebuffer texture]);
    glTexImage2D(GL_TEXTURE_2D, 0, _pixelFormat, (int)uploadedImageSize.width, (int)uploadedImageSize.height, 0, (GLint)_pixelFormat, (GLenum)_pixelType, bytesToUpload);
}

- (void)updateDataFromBytes:(GLubyte *)bytesToUpload size:(CGSize)imageSize;
{
    uploadedImageSize = imageSize;

    [self uploadBytes:bytesToUpload];
}

- (void)processData;
{
	if (dispatch_semaphore_wait(dataUpdateSemaphore, DISPATCH_TIME_NOW) != 0)
    {
        return;
    }
	
    typeof(self) __strong strongself = self;
	runAsynchronouslyOnVideoProcessingQueue(^
    {
		CGSize pixelSizeOfImage = [strongself outputImageSize];
    
		for (id<GPUImageInput> currentTarget in strongself->targets)
		{
			NSInteger indexOfObject = [strongself->targets indexOfObject:currentTarget];
			NSInteger textureIndexOfTarget = [[strongself->targetTextureIndices objectAtIndex:indexOfObject] integerValue];
        
			[currentTarget setInputSize:pixelSizeOfImage atIndex:textureIndexOfTarget];
            [currentTarget setInputFramebuffer:strongself->outputFramebuffer atIndex:textureIndexOfTarget];
			[currentTarget newFrameReadyAtTime:kCMTimeInvalid atIndex:textureIndexOfTarget];
		}
	
		dispatch_semaphore_signal(strongself->dataUpdateSemaphore);
	});
}

- (void)processDataForTimestamp:(CMTime)frameTime;
{
	if (dispatch_semaphore_wait(dataUpdateSemaphore, DISPATCH_TIME_NOW) != 0)
    {
        return;
    }
	
    typeof(self) __strong strongself = self;
	runAsynchronouslyOnVideoProcessingQueue(^{
        
		CGSize pixelSizeOfImage = [self outputImageSize];
        
		for (id<GPUImageInput> currentTarget in strongself->targets)
		{
			NSInteger indexOfObject = [strongself->targets indexOfObject:currentTarget];
			NSInteger textureIndexOfTarget = [[strongself->targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            
			[currentTarget setInputSize:pixelSizeOfImage atIndex:textureIndexOfTarget];
			[currentTarget newFrameReadyAtTime:frameTime atIndex:textureIndexOfTarget];
		}
        
		dispatch_semaphore_signal(strongself->dataUpdateSemaphore);
	});
}

- (CGSize)outputImageSize;
{
    return uploadedImageSize;
}

@end
