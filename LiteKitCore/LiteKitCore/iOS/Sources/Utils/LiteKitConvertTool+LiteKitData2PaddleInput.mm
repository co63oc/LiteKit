/*
 Copyright © 2020 Baidu, Inc. All Rights Reserved.

 Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"),
 to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
 and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/


#import "LiteKitConvertTool+LiteKitData2PaddleInput.h"
#include <opencv2/core/utility.hpp>
#include <opencv2/imgproc.hpp>
#import "LiteKitPaddleConfig.h"
#import <CoreVideo/CoreVideo.h>
#import "LiteKitDataProcess.h"

using namespace cv;
using namespace std;

@implementation LiteKitConvertTool(LiteKitInputMatrix)
#pragma mark - LiteKitInputMatrix converters
+ (LiteKitInputMatrix *)inputMatrixConvertFromImage:(UIImage *)image {
    LiteKitInputMatrix *returnData = [self litekit_createInputMatrixWithImage:image];
    return returnData;
}

+ (LiteKitInputMatrix *)inputMatrixConvertFromImageURL:(NSString *)imageURL {
    UIImage *image = [UIImage imageWithContentsOfFile:imageURL];
    LiteKitInputMatrix *returnData = [self litekit_createInputMatrixWithImage:image];
    
    return returnData;
}

+ (LiteKitInputMatrix *)inputMatrixConvertFromCVPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    UIImage *image = [self litekit_pixelBufferToImage:pixelBuffer];
    LiteKitInputMatrix *returnData = [self litekit_createInputMatrixWithImage:image];
    return returnData;
}

+ (LiteKitInputMatrix *)inputMatrixConvertFromMultiArray:(MLMultiArray *)multiArray {
    UIImage *image = [self litekit_mulArrayToImage:multiArray];
    LiteKitInputMatrix *returnData = [self litekit_createInputMatrixWithImage:image];
    return returnData;
}

+ (LiteKitInputMatrix *)inputMatrixConvertFromLiteKitShapedData:(LiteKitShapedData *)shapedData {
    if ( nil == shapedData || [shapedData.dim count] < 4 ) {
        return nil;
    }
    LiteKitInputMatrix *returnData = [[LiteKitInputMatrix alloc] initWithWith:shapedData.dim[3].intValue
                                                            andHeight:shapedData.dim[2].intValue
                                                           andChannel:shapedData.dim[1].intValue
                                                       andInputPixels:shapedData.data];
    return returnData;
}

#pragma mark - methods
+ (UIImage *)litekit_mulArrayToImage:(MLMultiArray *)aMLArray{
    if (aMLArray.shape.count < 5) {
        return nil;
    }
    
    NSInteger channelAxis = 2;
    NSInteger heightAxis = 3;
    NSInteger widthAxis = 4;
    
    NSInteger height = aMLArray.shape[heightAxis].intValue;
    NSInteger width = aMLArray.shape[widthAxis].intValue;
    
    NSInteger channel = aMLArray.shape[channelAxis].intValue;
    if (channel>3) {
        //max is 4 channels（RGBA）
        channel = 4;
    }
    
    NSInteger cStride = aMLArray.strides[channelAxis].intValue;
    
    NSInteger count = height * width * channel;
    UInt8 *pixels = (UInt8 *)alloca(sizeof(UInt8)*count);
    
    double *ptr = (double *)aMLArray.dataPointer ;
    
    double *channel1 = channel>1 ? ptr+cStride*1 : NULL;
    double *channel2 = channel>2 ? ptr+cStride*2 : NULL;
    double *channel3 = channel>3 ? ptr+cStride*3 : NULL;
    for (int i = 0; i<width * height; i++) {
        pixels[i*channel] = ptr[i];
        if (channel1 != NULL) { pixels[i*channel+1] = channel1[i]; }
        if (channel2 != NULL) { pixels[i*channel+2] = channel2[i]; }
        if (channel3 != NULL) { pixels[i*channel+3] = channel3[i]; }
    }
    
    CVPixelBufferRef pixelBuffer = NULL;
    OSType pixelFormatType;
    if (channel == 1) {
        pixelFormatType = kCVPixelFormatType_OneComponent8;
    } else {
        pixelFormatType = kCVPixelFormatType_32BGRA;
    }
    NSDictionary *options = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
    CVReturn status = CVPixelBufferCreateWithBytes(kCFAllocatorDefault,
                                                   width,
                                                   height,
                                                   pixelFormatType,
                                                   pixels,
                                                   width,
                                                   NULL,
                                                   NULL,
                                                   (__bridge CFDictionaryRef) options,
                                                   &pixelBuffer);
    
    UIImage *image = [self litekit_pixelBufferToImage:pixelBuffer];
    CVBufferRelease(pixelBuffer);
    
    return image;
}

+ (UIImage *)litekit_pixelBufferToImage:(CVPixelBufferRef)pixelBuffer {
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    
    CIContext *temporaryContext = [CIContext contextWithOptions:nil];
    CGImageRef videoImage = [temporaryContext
                             createCGImage:ciImage
                             fromRect:CGRectMake(0, 0, CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))];
    
    UIImage *uiImage = [UIImage imageWithCGImage:videoImage];
    CGImageRelease(videoImage);
    
    return uiImage;
}

+ (LiteKitInputMatrix *)litekit_createInputMatrixWithImage:(UIImage *)image {
    if (!image) {
        return nil;
    }
    // uiimage to mat
    Mat inputImage;
    inputImage = [LiteKitDataProcess litekit_CVMatFromUIImage:image];

    float *image_data = NULL;
    
    int w = inputImage.cols;
    int h = inputImage.rows;
    int c = inputImage.channels();
    
    switch (c) {
        case 4: {
            image_data = (float *)malloc(w * h * sizeof(float) * 4);
            
            // split
            Mat YCbCr;
            cvtColor(inputImage, YCbCr, CV_RGB2YCrCb, 0);
            
            vector<Mat> channels;
            split(YCbCr, channels);
            
            Mat Y = [self litekit_samplingChannel:channels.at(0) samplingRate:255];
            [LiteKitDataProcess litekit_convertCVMatData:Y toFloatData:image_data];
            Mat Cr = [self litekit_samplingChannel:channels.at(1) samplingRate:255];
            [LiteKitDataProcess litekit_convertCVMatData:Cr toFloatData:image_data+(w * h)];
            Mat Cb = [self litekit_samplingChannel:channels.at(2) samplingRate:255];
            [LiteKitDataProcess litekit_convertCVMatData:Cb toFloatData:image_data+(w * h * 2)];

            Mat alpha;
            extractChannel(inputImage, alpha, 3);
            alpha = [self litekit_samplingChannel:alpha samplingRate:255];
            [LiteKitDataProcess litekit_convertCVMatData:alpha toFloatData:image_data+(w * h * 3)];
            
            break;
        }

        case 3: {
            image_data = (float *)malloc(w * h * sizeof(float) * 3);
            
            // split
            Mat YCbCr;
            cvtColor(inputImage, YCbCr, CV_RGB2YCrCb, 0);
            
            vector<Mat> channels;
            split(YCbCr, channels);
 
            Mat Y = [self litekit_samplingChannel:channels.at(0) samplingRate:255];
            [LiteKitDataProcess litekit_convertCVMatData:Y toFloatData:image_data];
            Mat Cr = [self litekit_samplingChannel:channels.at(1) samplingRate:255];
            [LiteKitDataProcess litekit_convertCVMatData:Cr toFloatData:image_data+(w * h * sizeof(float))];
            Mat Cb = [self litekit_samplingChannel:channels.at(2) samplingRate:255];
            [LiteKitDataProcess litekit_convertCVMatData:Cb toFloatData:image_data+(w * h * sizeof(float) * 2)];
            break;
        }

        case 1: {
            image_data = (float *)malloc(w * h * sizeof(float) * 1);
            
            Mat YCbCr;
            cvtColor(inputImage, YCbCr, CV_RGB2YCrCb, 0);
            
            vector<Mat> channels;
            split(YCbCr, channels);
            
            Mat Y = [self litekit_samplingChannel:channels.at(0) samplingRate:255];
            [LiteKitDataProcess litekit_convertCVMatData:Y toFloatData:image_data];
        }
            
        default:
            break;
    }
    
    LiteKitInputMatrix *returnMatrix = [[LiteKitInputMatrix alloc] initWithWith:w
                                                              andHeight:h
                                                             andChannel:c
                                                         andInputPixels:image_data];
    
    return returnMatrix;
}



+ (Mat)litekit_samplingChannel:(Mat)samplingMat samplingRate:(NSInteger)samplingRate {
    Mat pixel;
    samplingMat.convertTo(pixel, CV_32FC1, 1.f / samplingRate);
    return pixel;
}

@end
