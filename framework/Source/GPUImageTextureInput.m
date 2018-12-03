#import "GPUImageTextureInput.h"

@implementation GPUImageTextureInput

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithTexture:(GLuint)newInputTexture size:(CGSize)newTextureSize;
{
    if (!(self = [super init]))
    {
        return nil;
    }

    runSynchronouslyOnVideoProcessingQueue(^{
        [GPUImageContext useImageProcessingContext];
    });
    
    textureSize = newTextureSize;

    typeof(self) __strong strongself = self;
    runSynchronouslyOnVideoProcessingQueue(^{
        strongself->outputFramebuffer = [[GPUImageFramebuffer alloc] initWithSize:newTextureSize overriddenTexture:newInputTexture];
    });
    
    return self;
}

#pragma mark -
#pragma mark Image rendering

- (void)processTextureWithFrameTime:(CMTime)frameTime;
{
    typeof(self) __strong strongself = self;
    runAsynchronouslyOnVideoProcessingQueue(^{
        for (id<GPUImageInput> currentTarget in strongself->targets)
        {
            NSInteger indexOfObject = [strongself->targets indexOfObject:currentTarget];
            NSInteger targetTextureIndex = [[strongself->targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            
            [currentTarget setInputSize:strongself->textureSize atIndex:targetTextureIndex];
            [currentTarget setInputFramebuffer:strongself->outputFramebuffer atIndex:targetTextureIndex];
            [currentTarget newFrameReadyAtTime:frameTime atIndex:targetTextureIndex];
        }
    });
}

@end
