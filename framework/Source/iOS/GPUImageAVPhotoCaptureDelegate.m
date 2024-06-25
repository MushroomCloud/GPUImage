//
//  GPUImageAVPhotoCaptureDelegate.m
//  GPUImage
//
//  Created by Rayman Rosevear on 2023/10/16.
//  Copyright © 2023 Brad Larson. All rights reserved.
//

#import "GPUImageAVPhotoCaptureDelegate.h"

NS_ASSUME_NONNULL_BEGIN

@interface GPUImageAVPhotoCaptureDelegate ()

@property (nonatomic, readonly) void (^callback)(AVCapturePhoto * _Nullable photo, NSError * _Nullable error);

@end

NS_ASSUME_NONNULL_END

@implementation GPUImageAVPhotoCaptureDelegate

- (instancetype)initWithCallback:(void (^)(AVCapturePhoto *, NSError *))callback
{
    NSParameterAssert(callback);
    if (self = [super init])
    {
        _callback = [callback copy];
    }
    return self;
}

- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error
{
    self.callback(photo, error);
}

@end
