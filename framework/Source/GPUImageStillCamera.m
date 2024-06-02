// 2448x3264 pixel image = 31,961,088 bytes for uncompressed RGBA

#import "GPUImageStillCamera.h"
#import "GPUImageAVPhotoCaptureDelegate.h"

NSString * const kGPUImageStillCameraErrorDomain = @"GPUImageStillCameraErrorDomain";

void stillImageDataReleaseCallback(void *releaseRefCon, const void *baseAddress)
{
    free((void *)baseAddress);
}

OSStatus GPUImageCreateSampleBuffer(CVPixelBufferRef pixelBuffer, CMTime timestamp, CMSampleBufferRef *sampleBufferOut)
{
    CMVideoFormatDescriptionRef videoFormat = NULL;
    OSStatus result = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        &videoFormat
    );
    if (result != noErr) { return result; }

    CMTime frameTime = CMTimeMake(1, 30);
    CMSampleTimingInfo timing = {frameTime, timestamp, kCMTimeInvalid};

    result = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault, // allocator
        pixelBuffer, // imageBuffer
        YES, // dataReady
        NULL, // makeDataReadyCallback
        NULL, // makeDataReadyRefcon
        videoFormat, // formatDescription
        &timing, // sampleTiming
        sampleBufferOut // sampleBufferOut
    );
    CFRelease(videoFormat);

    return result;
}

void GPUImageCreateResizedSampleBuffer(CVPixelBufferRef cameraFrame, CGSize finalSize, CMSampleBufferRef *sampleBuffer)
{
    // CVPixelBufferCreateWithPlanarBytes for YUV input
    
    CGSize originalSize = CGSizeMake(CVPixelBufferGetWidth(cameraFrame), CVPixelBufferGetHeight(cameraFrame));

    CVPixelBufferLockBaseAddress(cameraFrame, 0);
    GLubyte *sourceImageBytes =  CVPixelBufferGetBaseAddress(cameraFrame);
    CGDataProviderRef dataProvider = CGDataProviderCreateWithData(NULL, sourceImageBytes, CVPixelBufferGetBytesPerRow(cameraFrame) * originalSize.height, NULL);
    CGColorSpaceRef genericRGBColorspace = CGColorSpaceCreateDeviceRGB();
    CGImageRef cgImageFromBytes = CGImageCreate((int)originalSize.width, (int)originalSize.height, 8, 32, CVPixelBufferGetBytesPerRow(cameraFrame), genericRGBColorspace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst, dataProvider, NULL, NO, kCGRenderingIntentDefault);
    
    GLubyte *imageData = (GLubyte *) calloc(1, (int)finalSize.width * (int)finalSize.height * 4);
    
    CGContextRef imageContext = CGBitmapContextCreate(imageData, (int)finalSize.width, (int)finalSize.height, 8, (int)finalSize.width * 4, genericRGBColorspace,  kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGContextDrawImage(imageContext, CGRectMake(0.0, 0.0, finalSize.width, finalSize.height), cgImageFromBytes);
    CGImageRelease(cgImageFromBytes);
    CGContextRelease(imageContext);
    CGColorSpaceRelease(genericRGBColorspace);
    CGDataProviderRelease(dataProvider);
    
    CVPixelBufferRef pixel_buffer = NULL;
    CVPixelBufferCreateWithBytes(kCFAllocatorDefault, finalSize.width, finalSize.height, kCVPixelFormatType_32BGRA, imageData, finalSize.width * 4, stillImageDataReleaseCallback, NULL, NULL, &pixel_buffer);
    CMVideoFormatDescriptionRef videoInfo = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixel_buffer, &videoInfo);
    
    CMTime frameTime = CMTimeMake(1, 30);
    CMSampleTimingInfo timing = {frameTime, frameTime, kCMTimeInvalid};
    
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixel_buffer, YES, NULL, NULL, videoInfo, &timing, sampleBuffer);
    CVPixelBufferUnlockBaseAddress(cameraFrame, 0);
    CFRelease(videoInfo);
    CVPixelBufferRelease(pixel_buffer);
}

@interface GPUImageStillCamera ()

// Methods calling this are responsible for calling dispatch_semaphore_signal(frameRenderingSemaphore) somewhere inside the block
- (void)capturePhotoProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain
                  withImageOnGPUHandler:(void (^)(AVCapturePhoto *photo, NSError *error))block;

- (GPUImageRotationMode)requiredRotationModeForPhoto:(AVCapturePhoto *)photo;

@end

@implementation GPUImageStillCamera {
    BOOL requiresFrontCameraTextureCacheCorruptionWorkaround;
}

@synthesize jpegCompressionQuality = _jpegCompressionQuality;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithSessionPreset:(NSString *)sessionPreset inputCamera:(AVCaptureDevice *)inputCamera
{
    if (!(self = [super initWithSessionPreset:sessionPreset inputCamera:inputCamera]))
    {
		return nil;
    }
    
    /* Detect iOS version < 6 which require a texture cache corruption workaround */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    requiresFrontCameraTextureCacheCorruptionWorkaround = [[[UIDevice currentDevice] systemVersion] compare:@"6.0" options:NSNumericSearch] == NSOrderedAscending;
#pragma clang diagnostic pop
    
    [self.captureSession beginConfiguration];
    
    _photoOutput = [[AVCapturePhotoOutput alloc] init];
    // Enable this now to prevent delays changing this later. If high resolution images are not needed, that option can
    // be disabled using the AVCapturePhotoSettings instance by the captureDelegate.
    _photoOutput.highResolutionCaptureEnabled = YES;
    [self.captureSession addOutput:_photoOutput];

    // Having a still photo input set to BGRA and video to YUV doesn't work well, so since I don't have YUV resizing for iPhone 4 yet, kick back to BGRA for that device
    if (!(captureAsYUV && [GPUImageContext deviceSupportsRedTextures]))
    {
        captureAsYUV = NO;
        [videoOutput setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    }
    
    [self.captureSession commitConfiguration];
    self.jpegCompressionQuality = 0.8;
    
    return self;
}

- (id)init
{
    // default to the back camera if possible
    NSArray<AVCaptureDeviceType> *deviceTypes = [GPUImageStillCamera defaultCaptureDeviceTypes];
    AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypes
                                                                                                        mediaType:AVMediaTypeVideo
                                                                                                         position:AVCaptureDevicePositionBack];

    AVCaptureDevicePosition cameraPosition = AVCaptureDevicePositionBack;
    NSArray<AVCaptureDevice *> *devices = discovery.devices;
    AVCaptureDevice *inputCamera = devices.firstObject;
    for (AVCaptureDevice *device in devices)
    {
        if ([device position] == cameraPosition)
        {
            inputCamera = device;
        }
    }
    
    if (!(self = [self initWithSessionPreset:AVCaptureSessionPresetPhoto inputCamera:inputCamera]))
    {
		return nil;
    }
    return self;
}

- (void)removeInputsAndOutputs;
{
    [self.captureSession removeOutput:_photoOutput];
    [super removeInputsAndOutputs];
}

#pragma mark -
#pragma mark Photography controls

- (NSDictionary<NSString *, id> *)defaultCaptureFormatSettings
{
    BOOL captureAsYUV = self->captureAsYUV;
    if (captureAsYUV)
    {
        BOOL supportsFullYUVRange = NO;
        NSArray *supportedPixelFormats = _photoOutput.availablePhotoPixelFormatTypes;
        for (NSNumber *currentPixelFormat in supportedPixelFormats)
        {
            if ([currentPixelFormat intValue] == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            {
                supportsFullYUVRange = YES;
            }
        }

        if (supportsFullYUVRange)
        {
            return @{
                (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            };
        }
        else
        {
            return @{
                (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            };
        }
    }
    else
    {
        return @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
        };
    }
}

- (void)capturePhotoAsSampleBufferWithCompletionHandler:(void (^)(AVCapturePhoto *photo, NSError *error))block
{
    NSLog(@"If you want to use the method capturePhotoAsSampleBufferWithCompletionHandler:, you must comment out the line in GPUImageStillCamera.m in the method initWithSessionPreset:cameraPosition: which sets the CVPixelBufferPixelFormatTypeKey, as well as uncomment the rest of the method capturePhotoAsSampleBufferWithCompletionHandler:. However, if you do this you cannot use any of the photo capture methods to take a photo if you also supply a filter.");
    
    /*dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_FOREVER);
    
    [photoOutput captureStillImageAsynchronouslyFromConnection:[[photoOutput connections] objectAtIndex:0] completionHandler:^(AVCapturePhoto *photo, NSError *error) {
        block(imageSampleBuffer, error);
    }];
     
     dispatch_semaphore_signal(frameRenderingSemaphore);

     */
    
    return;
}

- (void)capturePhotoAsImageProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withCompletionHandler:(void (^)(UIImage *processedImage, NSError *error))block;
{
    typeof(self) __strong strongself = self;
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(AVCapturePhoto *photo, NSError *error) {
        UIImage *filteredPhoto = nil;

        if(!error){
            filteredPhoto = [finalFilterInChain imageFromCurrentFramebuffer];
        }
        dispatch_semaphore_signal(strongself->frameRenderingSemaphore);

        block(filteredPhoto, error);
    }];
}

- (void)capturePhotoAsImageProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withOrientation:(UIImageOrientation)orientation withCompletionHandler:(void (^)(UIImage *processedImage, NSError *error))block {
    typeof(self) __strong strongself = self;
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(AVCapturePhoto *photo, NSError *error) {
        UIImage *filteredPhoto = nil;
        
        if(!error) {
            filteredPhoto = [finalFilterInChain imageFromCurrentFramebufferWithOrientation:orientation];
        }
        dispatch_semaphore_signal(strongself->frameRenderingSemaphore);
        
        block(filteredPhoto, error);
    }];
}

- (void)capturePhotoAsJPEGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withCompletionHandler:(void (^)(NSData *processedJPEG, NSError *error))block;
{
//    reportAvailableMemoryForGPUImage(@"Before Capture");

    typeof(self) __strong strongself = self;
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(AVCapturePhoto *photo, NSError *error) {
        NSData *dataForJPEGFile = nil;

        if(!error){
            @autoreleasepool {
                UIImage *filteredPhoto = [finalFilterInChain imageFromCurrentFramebuffer];
                dispatch_semaphore_signal(strongself->frameRenderingSemaphore);
//                reportAvailableMemoryForGPUImage(@"After UIImage generation");

                dataForJPEGFile = UIImageJPEGRepresentation(filteredPhoto,self.jpegCompressionQuality);
//                reportAvailableMemoryForGPUImage(@"After JPEG generation");
            }

//            reportAvailableMemoryForGPUImage(@"After autorelease pool");
        }else{
            dispatch_semaphore_signal(strongself->frameRenderingSemaphore);
        }

        block(dataForJPEGFile, error);
    }];
}

- (void)capturePhotoAsJPEGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withOrientation:(UIImageOrientation)orientation withCompletionHandler:(void (^)(NSData *processedImage, NSError *error))block {
    typeof(self) __strong strongself = self;
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(AVCapturePhoto *photo, NSError *error) {
        NSData *dataForJPEGFile = nil;
        
        if(!error) {
            @autoreleasepool {
                UIImage *filteredPhoto = [finalFilterInChain imageFromCurrentFramebufferWithOrientation:orientation];
                dispatch_semaphore_signal(strongself->frameRenderingSemaphore);
                
                dataForJPEGFile = UIImageJPEGRepresentation(filteredPhoto, self.jpegCompressionQuality);
            }
        } else {
            dispatch_semaphore_signal(strongself->frameRenderingSemaphore);
        }
        
        block(dataForJPEGFile, error);
    }];
}

- (void)capturePhotoAsPNGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withCompletionHandler:(void (^)(NSData *processedPNG, NSError *error))block;
{
    typeof(self) __strong strongself = self;
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(AVCapturePhoto *photo, NSError *error) {
        NSData *dataForPNGFile = nil;

        if(!error){
            @autoreleasepool {
                UIImage *filteredPhoto = [finalFilterInChain imageFromCurrentFramebuffer];
                dispatch_semaphore_signal(strongself->frameRenderingSemaphore);
                dataForPNGFile = UIImagePNGRepresentation(filteredPhoto);
            }
        }else{
            dispatch_semaphore_signal(strongself->frameRenderingSemaphore);
        }
        
        block(dataForPNGFile, error);
    }];
    
    return;
}

- (void)capturePhotoAsPNGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withOrientation:(UIImageOrientation)orientation withCompletionHandler:(void (^)(NSData *processedPNG, NSError *error))block;
{
    typeof(self) __strong strongself = self;
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(AVCapturePhoto *photo, NSError *error) {
        NSData *dataForPNGFile = nil;
        
        if(!error){
            @autoreleasepool {
                UIImage *filteredPhoto = [finalFilterInChain imageFromCurrentFramebufferWithOrientation:orientation];
                dispatch_semaphore_signal(strongself->frameRenderingSemaphore);
                dataForPNGFile = UIImagePNGRepresentation(filteredPhoto);
            }
        }else{
            dispatch_semaphore_signal(strongself->frameRenderingSemaphore);
        }
        
        block(dataForPNGFile, error);
    }];
    
    return;
}

- (void)capturePhotoProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain
                       withReadyHandler:(void (^)(AVCapturePhoto * _Nullable photo, dispatch_block_t unlockFrameRendering, NSError * _Nullable error))block
{
    typeof(self) __strong strongself = self;
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(AVCapturePhoto *photo, NSError *error) {
        dispatch_block_t unlockFrameRendering = ^{
            dispatch_semaphore_signal(strongself->frameRenderingSemaphore);
        };
        block(photo, unlockFrameRendering, error);
    }];
}

#pragma mark - Private Methods

- (void)capturePhotoProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain
                  withImageOnGPUHandler:(void (^)(AVCapturePhoto *photo, NSError *error))block
{
    dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_FOREVER);

    NSDictionary<NSString *, id> *outputFormat = [self defaultCaptureFormatSettings];

    AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettingsWithFormat:outputFormat];
    id<GPUImageStillCameraCaptureDelegate> captureDelegate = self.captureDelegate;
    if (captureDelegate != nil)
    {
        settings = [captureDelegate camera:self willCapturePhotoWithSettings:settings];
    }

    typeof(self) __strong strongself = self;
    // The delegate must retain itself until the capture is complete
    __block id retainedDelegate = nil;
    GPUImageAVPhotoCaptureDelegate *delegate = [[GPUImageAVPhotoCaptureDelegate alloc] initWithCallback:
    ^(AVCapturePhoto *photo, NSError *error)
    {
        // The delegate can be released now
        retainedDelegate = nil;
        if (error != nil)
        {
            block(nil, error);
            return;
        }

        // For now, resize photos to fix within the max texture size of the GPU
        CVImageBufferRef cameraFrame = photo.pixelBuffer;
        if (cameraFrame == nil)
        {
            NSString *message = NSLocalizedString(@"The photo capture did not produce a pixel buffer.", @"Error message generated when capturing a photo");
            NSError *error = [NSError errorWithDomain:kGPUImageStillCameraErrorDomain
                                                 code:GPUImageStillCameraErrorCaptureDidNotProducePixelBuffer
                                             userInfo:@{NSLocalizedDescriptionKey: message}];
            block(nil, error);
            return;
        }

        // The orientation of the captured image doesn't always match the orientation of the sample buffers returned by
        // the live stream. Specifically, continuity cameras, and the landscape cameras on the `iPad16,{3,4,5,6}` have
        // started doing this for some reason. To get around it, we need to check for the actual orientation in the
        // photo metadata and make sure that the rotation mode is updated to reflect that
        GPUImageRotationMode originalRotation = strongself.rotationMode;
        GPUImageRotationMode fixedRotation = [strongself requiredRotationModeForPhoto:photo];
        BOOL shouldFixTransform = originalRotation != fixedRotation;;
        void(^updateToFixedOrientation)(void) = ^(void)
        {
            if (shouldFixTransform)
            {
                [strongself setRotationMode:fixedRotation];
            }
        };
        void(^revertToOriginalOrientation)(void) = ^(void)
        {
            if (shouldFixTransform)
            {
                [strongself setRotationMode:originalRotation];
            }
        };

        CGSize sizeOfPhoto = CGSizeMake(CVPixelBufferGetWidth(cameraFrame), CVPixelBufferGetHeight(cameraFrame));
        CGSize scaledImageSizeToFitOnGPU = [GPUImageContext sizeThatFitsWithinATextureForSize:sizeOfPhoto];
        if (!CGSizeEqualToSize(sizeOfPhoto, scaledImageSizeToFitOnGPU))
        {
            CMSampleBufferRef sampleBuffer = NULL;

            if (CVPixelBufferGetPlaneCount(cameraFrame) > 0)
            {
                NSAssert(NO, @"Error: no downsampling for YUV input in the framework yet");
            }
            else
            {
                GPUImageCreateResizedSampleBuffer(cameraFrame, scaledImageSizeToFitOnGPU, &sampleBuffer);
            }

            dispatch_semaphore_signal(strongself->frameRenderingSemaphore);
            // Make sure to only do this while holding the frame rendering semaphore
            updateToFixedOrientation();
            [finalFilterInChain useNextFrameForImageCapture];
            [strongself captureOutput:strongself->_photoOutput
          didOutputSampleBuffer:sampleBuffer
                 fromConnection:[[strongself->_photoOutput connections] objectAtIndex:0]];
            revertToOriginalOrientation();
            dispatch_semaphore_wait(strongself->frameRenderingSemaphore, DISPATCH_TIME_FOREVER);
            
            if (sampleBuffer != NULL)
            {
                CFRelease(sampleBuffer);
            }
        }
        else
        {
            // This is a workaround for the corrupt images that are sometimes returned when taking a photo with the front camera and using the iOS 5.0 texture caches
            AVCaptureDevicePosition currentCameraPosition = [[strongself->videoInput device] position];
            if ((currentCameraPosition != AVCaptureDevicePositionFront) ||
                (![GPUImageContext supportsFastTextureUpload]) ||
                !strongself->requiresFrontCameraTextureCacheCorruptionWorkaround)
            {
                CMSampleBufferRef imageSampleBuffer = NULL;
                OSStatus result = GPUImageCreateSampleBuffer(cameraFrame, photo.timestamp, &imageSampleBuffer);
                if (result != noErr)
                {
                    if (imageSampleBuffer != NULL)
                    {
                        CFRelease(imageSampleBuffer);
                    }

                    NSString *messageFormat = NSLocalizedString(@"Could not allocate a sample buffer during capture (OSStatus %i).", @"Error message generated when capturing a photo");
                    NSString *message = [NSString localizedStringWithFormat:messageFormat, result];
                    NSError *error = [NSError errorWithDomain:kGPUImageStillCameraErrorDomain
                                                         code:GPUImageStillCameraErrorCouldNotAllocateSampleBuffer
                                                     userInfo:@{NSLocalizedDescriptionKey: message}];
                    block(nil, error);
                    return;
                }

                dispatch_semaphore_signal(strongself->frameRenderingSemaphore);
                // Make sure to only do this while holding the frame rendering semaphore
                updateToFixedOrientation();
                [finalFilterInChain useNextFrameForImageCapture];
                [strongself captureOutput:strongself->_photoOutput
              didOutputSampleBuffer:imageSampleBuffer
                     fromConnection:[[strongself->_photoOutput connections] objectAtIndex:0]];
                revertToOriginalOrientation();
                dispatch_semaphore_wait(strongself->frameRenderingSemaphore, DISPATCH_TIME_FOREVER);

                if (imageSampleBuffer != NULL)
                {
                    CFRelease(imageSampleBuffer);
                }
            }
        }

        block(photo, nil);
    }];
    retainedDelegate = delegate;

    AVCaptureConnection *videoConnection = [_photoOutput connectionWithMediaType:AVMediaTypeVideo];
    AVCaptureVideoOrientation videoOrientation =
        [self videoOrientationForPhotoOutputWithVideoConnection:videoConnection];
    [videoConnection setVideoOrientation:videoOrientation];
    [_photoOutput capturePhotoWithSettings:settings delegate:delegate];
}

- (AVCaptureVideoOrientation)videoOrientationForPhotoOutputWithVideoConnection:(AVCaptureConnection *)videoConnection
{
    AVCaptureDevice *device = videoInput.device;
    if (@available(iOS 16.0, *))
    {
        if ([device isContinuityCamera])
        {
            // Continuity camera always returns photos in this the correct orientation. In order to have the EXIF image
            // orientation set correctly, we need to return landscape right for these cameras
            return AVCaptureVideoOrientationLandscapeRight;
        }
    }
    // TODO: determine correct orientation for devices with deviceType == AVCaptureDeviceTypeExternal
    switch (self.outputImageOrientation)
    {
        case UIInterfaceOrientationPortrait:
        {
            return AVCaptureVideoOrientationPortrait;
        }
        case UIInterfaceOrientationPortraitUpsideDown:
        {
            return AVCaptureVideoOrientationPortraitUpsideDown;
        }
        case UIInterfaceOrientationLandscapeLeft:
        {
            return AVCaptureVideoOrientationLandscapeLeft;
        }
        case UIInterfaceOrientationLandscapeRight:
        {
            return AVCaptureVideoOrientationLandscapeRight;
        }
        default:
        {
            return videoConnection.videoOrientation;
        }
    }
}

- (GPUImageRotationMode)requiredRotationModeForPhoto:(AVCapturePhoto *)photo
{
    NSNumber *orientationNumber = photo.metadata[(id)kCGImagePropertyOrientation];
    if ([orientationNumber isKindOfClass:[NSNumber class]])
    {
        BOOL isFrontCamera = videoInput.device.position == AVCaptureDevicePositionFront;
        BOOL isBackCamera = videoInput.device.position == AVCaptureDevicePositionBack;
        CGImagePropertyOrientation orientation = [orientationNumber intValue];

        // This matches the switch statement in -[GPUImageVideoCamera updateOrientationSendToTargets]
        switch (orientation)
        {
            case kCGImagePropertyOrientationUp: return kGPUImageNoRotation;
            case kCGImagePropertyOrientationUpMirrored: return kGPUImageFlipHorizonal;

            case kCGImagePropertyOrientationDown: return kGPUImageRotate180;
            case kCGImagePropertyOrientationDownMirrored: return kGPUImageFlipVertical;

            case kCGImagePropertyOrientationLeft: return kGPUImageRotateLeft;
            case kCGImagePropertyOrientationLeftMirrored: return kGPUImageRotateRightFlipHorizontal;

            case kCGImagePropertyOrientationRight: return kGPUImageRotateRight;
            case kCGImagePropertyOrientationRightMirrored: return kGPUImageRotateRightFlipVertical;
        }
    }

    return self.rotationMode;
}

@end
