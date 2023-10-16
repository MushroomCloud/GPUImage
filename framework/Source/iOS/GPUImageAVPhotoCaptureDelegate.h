//
//  GPUImageAVPhotoCaptureDelegate.h
//  GPUImage
//
//  Created by Rayman Rosevear on 2023/10/16.
//  Copyright © 2023 Brad Larson. All rights reserved.
//

#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPUImageAVPhotoCaptureDelegate : NSObject <AVCapturePhotoCaptureDelegate>

- (instancetype)initWithCallback:(void (^)(AVCapturePhoto * _Nullable photo, NSError * _Nullable error))callback;

@end

NS_ASSUME_NONNULL_END
