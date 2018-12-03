#import "GPUImageTwoPassTextureSamplingFilter.h"

@implementation GPUImageTwoPassTextureSamplingFilter

@synthesize verticalTexelSpacing = _verticalTexelSpacing;
@synthesize horizontalTexelSpacing = _horizontalTexelSpacing;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithFirstStageVertexShaderFromString:(NSString *)firstStageVertexShaderString firstStageFragmentShaderFromString:(NSString *)firstStageFragmentShaderString secondStageVertexShaderFromString:(NSString *)secondStageVertexShaderString secondStageFragmentShaderFromString:(NSString *)secondStageFragmentShaderString
{
    if (!(self = [super initWithFirstStageVertexShaderFromString:firstStageVertexShaderString firstStageFragmentShaderFromString:firstStageFragmentShaderString secondStageVertexShaderFromString:secondStageVertexShaderString secondStageFragmentShaderFromString:secondStageFragmentShaderString]))
    {
		return nil;
    }
    
    typeof(self) __strong strongself = self;
    runSynchronouslyOnVideoProcessingQueue(^{
        [GPUImageContext useImageProcessingContext];

        strongself->verticalPassTexelWidthOffsetUniform = [strongself->filterProgram uniformIndex:@"texelWidthOffset"];
        strongself->verticalPassTexelHeightOffsetUniform = [strongself->filterProgram uniformIndex:@"texelHeightOffset"];
        
        strongself->horizontalPassTexelWidthOffsetUniform = [strongself->secondFilterProgram uniformIndex:@"texelWidthOffset"];
        strongself->horizontalPassTexelHeightOffsetUniform = [strongself->secondFilterProgram uniformIndex:@"texelHeightOffset"];
    });
    
    self.verticalTexelSpacing = 1.0;
    self.horizontalTexelSpacing = 1.0;
    
    return self;
}

- (void)setUniformsForProgramAtIndex:(NSUInteger)programIndex;
{
    [super setUniformsForProgramAtIndex:programIndex];
    
    if (programIndex == 0)
    {
        glUniform1f(verticalPassTexelWidthOffsetUniform, verticalPassTexelWidthOffset);
        glUniform1f(verticalPassTexelHeightOffsetUniform, verticalPassTexelHeightOffset);
    }
    else
    {
        glUniform1f(horizontalPassTexelWidthOffsetUniform, horizontalPassTexelWidthOffset);
        glUniform1f(horizontalPassTexelHeightOffsetUniform, horizontalPassTexelHeightOffset);
    }
}

- (void)setupFilterForSize:(CGSize)filterFrameSize;
{
    typeof(self) __strong strongself = self;
    runSynchronouslyOnVideoProcessingQueue(^{
        // The first pass through the framebuffer may rotate the inbound image, so need to account for that by changing up the kernel ordering for that pass
        if (GPUImageRotationSwapsWidthAndHeight(strongself->inputRotation))
        {
            strongself->verticalPassTexelWidthOffset = strongself->_verticalTexelSpacing / filterFrameSize.height;
            strongself->verticalPassTexelHeightOffset = 0.0;
        }
        else
        {
            strongself->verticalPassTexelWidthOffset = 0.0;
            strongself->verticalPassTexelHeightOffset = strongself->_verticalTexelSpacing / filterFrameSize.height;
        }
        
        strongself->horizontalPassTexelWidthOffset = strongself->_horizontalTexelSpacing / filterFrameSize.width;
        strongself->horizontalPassTexelHeightOffset = 0.0;
    });
}

#pragma mark -
#pragma mark Accessors

- (void)setVerticalTexelSpacing:(CGFloat)newValue;
{
    _verticalTexelSpacing = newValue;
    [self setupFilterForSize:[self sizeOfFBO]];
}

- (void)setHorizontalTexelSpacing:(CGFloat)newValue;
{
    _horizontalTexelSpacing = newValue;
    [self setupFilterForSize:[self sizeOfFBO]];
}

@end
