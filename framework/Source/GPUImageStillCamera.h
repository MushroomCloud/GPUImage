#import "GPUImageVideoCamera.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const kGPUImageStillCameraErrorDomain;

extern void stillImageDataReleaseCallback(void *releaseRefCon, const void *baseAddress);
OSStatus GPUImageCreateSampleBuffer(CVPixelBufferRef pixelBuffer, CMTime timestamp, CMSampleBufferRef _Nonnull * _Nullable sampleBuffer);
extern void GPUImageCreateResizedSampleBuffer(CVPixelBufferRef cameraFrame, CGSize finalSize, CMSampleBufferRef _Nonnull * _Nullable sampleBuffer);

typedef NS_ENUM(NSUInteger, GPUImageStillCameraError)
{
    GPUImageStillCameraErrorCaptureDidNotProducePixelBuffer,
    GPUImageStillCameraErrorCouldNotAllocateSampleBuffer
};

@protocol GPUImageStillCameraCaptureDelegate;

@interface GPUImageStillCamera : GPUImageVideoCamera

@property (nonatomic, readonly) AVCapturePhotoOutput *photoOutput;

@property (nonatomic, weak, nullable) id<GPUImageStillCameraCaptureDelegate> captureDelegate;

/** The JPEG compression quality to use when capturing a photo as a JPEG.
 */
@property CGFloat jpegCompressionQuality;

// Photography controls
- (NSDictionary<NSString *, id> *)defaultCaptureFormatSettings;

- (void)capturePhotoAsSampleBufferWithCompletionHandler:(void (^)(AVCapturePhoto * _Nullable photo, NSError * _Nullable error))block;
- (void)capturePhotoAsImageProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain
                         withCompletionHandler:(void (^)(UIImage * _Nullable processedImage, NSError * _Nullable error))block;
- (void)capturePhotoAsImageProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain
                               withOrientation:(UIImageOrientation)orientation withCompletionHandler:(void (^)(UIImage * _Nullable processedImage, NSError * _Nullable error))block;
- (void)capturePhotoAsJPEGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain
                        withCompletionHandler:(void (^)(NSData * _Nullable processedJPEG, NSError * _Nullable error))block;
- (void)capturePhotoAsJPEGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain
                              withOrientation:(UIImageOrientation)orientation 
                        withCompletionHandler:(void (^)(NSData * _Nullable processedJPEG, NSError * _Nullable error))block;
- (void)capturePhotoAsPNGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain
                       withCompletionHandler:(void (^)(NSData * _Nullable processedPNG, NSError * _Nullable error))block;
- (void)capturePhotoAsPNGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain
                             withOrientation:(UIImageOrientation)orientation
                       withCompletionHandler:(void (^)(NSData * _Nullable processedPNG, NSError * _Nullable error))block;

// Use this method to capture a photo without converting the output. the readyHandler block will be called when the image is on the GPU and ready to be processed.
// Be sure to call the unlockFrameRendering block in the ready handler somewhere.
- (void)capturePhotoProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain 
                       withReadyHandler:(void (^)(AVCapturePhoto * _Nullable photo, dispatch_block_t unlockFrameRendering, NSError * _Nullable error))block;

@end

@protocol GPUImageStillCameraCaptureDelegate <NSObject>

/// This is called when capturing a photo. The returned settings will be used to capture the photo. This delegate
/// method can be used to modify the settings if desired. If returning a different settings instance, care should be
/// taken to ensure the the capture produces a photo with a compatible pixel buffer format. The
/// `defaultCaptureFormatSettings` can be used to ensure this.
- (AVCapturePhotoSettings *)camera:(GPUImageStillCamera *)camera
      willCapturePhotoWithSettings:(AVCapturePhotoSettings *)settings;

@end

NS_ASSUME_NONNULL_END
