// Copyright 2015 Google Inc. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import <AssertMacros.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import "CameraExampleViewController.h"

// #include <sys/time.h>
#include <time.h>

#include "tensorflow_utils.h"

// If you have your own model, modify this to the file name, and make sure
// you've added the file to your app resources too.
//static NSString* model_file_name = @"quantized_opt_sqdt";
static NSString* model_file_name = @"opt_small_sqdt";
static NSString* model_file_type = @"pb";
// This controls whether we'll be loading a plain GraphDef proto, or a
// file created by the convert_graphdef_memmapped_format utility that wraps a
// GraphDef and parameter file that can be mapped into memory from file to
// reduce overall memory usage.
const bool model_uses_memory_mapping = false;
// If you have your own model, point this to the labels file.
static NSString* labels_file_name = @"labels";
static NSString* labels_file_type = @"txt";
// These dimensions need to match those the model was trained with.
const int wanted_input_width = 960;
const int wanted_input_height = 288;
const int wanted_input_channels = 3;
const int anchor_per_center = 9;
const int num_det_candidate = wanted_input_height * wanted_input_width / (16 * 16) * anchor_per_center;
const float input_means[3] = {103.939f, 116.779f, 123.68f};
const float input_std = 1.0f;
const std::string input_layer_name = "image_input";
const std::string bbox_output = "bbox/trimming/bbox";
const std::string prob_output = "probability/score";
const std::string class_output = "probability/class_idx";

static const NSString *AVCaptureStillImageIsCapturingStillImageContext =
    @"AVCaptureStillImageIsCapturingStillImageContext";

@interface CameraExampleViewController (InternalMethods)
- (void)setupAVCapture;
- (void)teardownAVCapture;
@end

@implementation CameraExampleViewController

- (void)setupAVCapture {
  NSError *error = nil;

  session = [AVCaptureSession new];
  if ([[UIDevice currentDevice] userInterfaceIdiom] ==
      UIUserInterfaceIdiomPhone)
    [session setSessionPreset:AVCaptureSessionPreset1280x720];
  else
    [session setSessionPreset:AVCaptureSessionPresetPhoto];

  AVCaptureDevice *device =
      [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  AVCaptureDeviceInput *deviceInput =
      [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
  assert(error == nil);

  isUsingFrontFacingCamera = NO;
  if ([session canAddInput:deviceInput]) [session addInput:deviceInput];

  stillImageOutput = [AVCaptureStillImageOutput new];
  [stillImageOutput
      addObserver:self
       forKeyPath:@"capturingStillImage"
          options:NSKeyValueObservingOptionNew
          context:(void *)(AVCaptureStillImageIsCapturingStillImageContext)];
  if ([session canAddOutput:stillImageOutput])
    [session addOutput:stillImageOutput];

  videoDataOutput = [AVCaptureVideoDataOutput new];

  NSDictionary *rgbOutputSettings = [NSDictionary
      dictionaryWithObject:[NSNumber numberWithInt:kCMPixelFormat_32BGRA]
                    forKey:(id)kCVPixelBufferPixelFormatTypeKey];
  [videoDataOutput setVideoSettings:rgbOutputSettings];
  [videoDataOutput setAlwaysDiscardsLateVideoFrames:YES];
  videoDataOutputQueue =
      dispatch_queue_create("VideoDataOutputQueue", DISPATCH_QUEUE_SERIAL);
  [videoDataOutput setSampleBufferDelegate:self queue:videoDataOutputQueue];

  if ([session canAddOutput:videoDataOutput])
    [session addOutput:videoDataOutput];
  [[videoDataOutput connectionWithMediaType:AVMediaTypeVideo] setEnabled:YES];

  previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:session];
  previewLayer.connection.videoOrientation = AVCaptureVideoOrientationLandscapeRight;
  //[previewLayer setBackgroundColor:[[UIColor blackColor] CGColor]];
  [previewLayer setVideoGravity:AVLayerVideoGravityResizeAspect];
  CALayer *rootLayer = [previewView layer];
  //[rootLayer setMasksToBounds:YES];
  [previewLayer setFrame:[rootLayer bounds]];
  [rootLayer addSublayer:previewLayer];
  [session startRunning];

  [session release];
  if (error) {
    UIAlertView *alertView = [[UIAlertView alloc]
            initWithTitle:[NSString stringWithFormat:@"Failed with error %d",
                                                     (int)[error code]]
                  message:[error localizedDescription]
                 delegate:nil
        cancelButtonTitle:@"Dismiss"
        otherButtonTitles:nil];
    [alertView show];
    [alertView release];
    [self teardownAVCapture];
  }
}

- (void)teardownAVCapture {
  [videoDataOutput release];
  if (videoDataOutputQueue) dispatch_release(videoDataOutputQueue);
  [stillImageOutput removeObserver:self forKeyPath:@"isCapturingStillImage"];
  [stillImageOutput release];
  [previewLayer removeFromSuperlayer];
  [previewLayer release];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
  if (context == AVCaptureStillImageIsCapturingStillImageContext) {
    BOOL isCapturingStillImage =
        [[change objectForKey:NSKeyValueChangeNewKey] boolValue];

    if (isCapturingStillImage) {
      // do flash bulb like animation
      flashView = [[UIView alloc] initWithFrame:[previewView frame]];
      [flashView setBackgroundColor:[UIColor whiteColor]];
      [flashView setAlpha:0.f];
      [[[self view] window] addSubview:flashView];

      [UIView animateWithDuration:.4f
                       animations:^{
                         [flashView setAlpha:1.f];
                       }];
    } else {
      [UIView animateWithDuration:.4f
          animations:^{
            [flashView setAlpha:0.f];
          }
          completion:^(BOOL finished) {
            [flashView removeFromSuperview];
            [flashView release];
            flashView = nil;
          }];
    }
  }
}

//- (AVCaptureVideoOrientation)avOrientationForDeviceOrientation:
//    (UIDeviceOrientation)deviceOrientation {
//  AVCaptureVideoOrientation result =
//      (AVCaptureVideoOrientation)(deviceOrientation);
//  if (deviceOrientation == UIDeviceOrientationLandscapeLeft)
//    result = AVCaptureVideoOrientationLandscapeRight;
//  else if (deviceOrientation == UIDeviceOrientationLandscapeRight)
//    result = AVCaptureVideoOrientationLandscapeLeft;
//  //NSLog(@"orientation, %ld,%ld",(long)deviceOrientation,(long)result);
//  return result;
//}

- (IBAction)takePicture:(id)sender {
  if ([session isRunning]) {
    [session stopRunning];
    [sender setTitle:@"Continue" forState:UIControlStateNormal];

    flashView = [[UIView alloc] initWithFrame:[previewView frame]];
    [flashView setBackgroundColor:[UIColor whiteColor]];
    [flashView setAlpha:0.f];
    [[[self view] window] addSubview:flashView];

    [UIView animateWithDuration:.2f
        animations:^{
          [flashView setAlpha:1.f];
        }
        completion:^(BOOL finished) {
          [UIView animateWithDuration:.2f
              animations:^{
                [flashView setAlpha:0.f];
              }
              completion:^(BOOL finished) {
                [flashView removeFromSuperview];
                [flashView release];
                flashView = nil;
              }];
        }];

  } else {
    [session startRunning];
    [sender setTitle:@"Freeze Frame" forState:UIControlStateNormal];
  }
}

+ (CGRect)videoPreviewBoxForGravity:(NSString *)gravity
                          frameSize:(CGSize)frameSize
                       apertureSize:(CGSize)apertureSize {
  CGFloat apertureRatio = apertureSize.height / apertureSize.width;
  CGFloat viewRatio = frameSize.width / frameSize.height;

  CGSize size = CGSizeZero;
  if ([gravity isEqualToString:AVLayerVideoGravityResizeAspectFill]) {
    if (viewRatio > apertureRatio) {
      size.width = frameSize.width;
      size.height =
          apertureSize.width * (frameSize.width / apertureSize.height);
    } else {
      size.width =
          apertureSize.height * (frameSize.height / apertureSize.width);
      size.height = frameSize.height;
    }
  } else if ([gravity isEqualToString:AVLayerVideoGravityResizeAspect]) {
    if (viewRatio > apertureRatio) {
      size.width =
          apertureSize.height * (frameSize.height / apertureSize.width);
      size.height = frameSize.height;
    } else {
      size.width = frameSize.width;
      size.height =
          apertureSize.width * (frameSize.width / apertureSize.height);
    }
  } else if ([gravity isEqualToString:AVLayerVideoGravityResize]) {
    size.width = frameSize.width;
    size.height = frameSize.height;
  }

  CGRect videoBox;
  videoBox.size = size;
  if (size.width < frameSize.width)
    videoBox.origin.x = (frameSize.width - size.width) / 2;
  else
    videoBox.origin.x = (size.width - frameSize.width) / 2;

  if (size.height < frameSize.height)
    videoBox.origin.y = (frameSize.height - size.height) / 2;
  else
    videoBox.origin.y = (size.height - frameSize.height) / 2;

  return videoBox;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
  [connection setVideoOrientation:AVCaptureVideoOrientationLandscapeRight];
  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  [self runCNNOnFrame:pixelBuffer];
}

- (void)dealloc {
  [self teardownAVCapture];
  [square release];
  [super dealloc];
}

// use front/back camera
- (IBAction)switchCameras:(id)sender {
  AVCaptureDevicePosition desiredPosition;
  if (isUsingFrontFacingCamera)
    desiredPosition = AVCaptureDevicePositionBack;
  else
    desiredPosition = AVCaptureDevicePositionFront;

  for (AVCaptureDevice *d in
       [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
    if ([d position] == desiredPosition) {
      [[previewLayer session] beginConfiguration];
      AVCaptureDeviceInput *input =
          [AVCaptureDeviceInput deviceInputWithDevice:d error:nil];
      for (AVCaptureInput *oldInput in [[previewLayer session] inputs]) {
        [[previewLayer session] removeInput:oldInput];
      }
      [[previewLayer session] addInput:input];
      [[previewLayer session] commitConfiguration];
      break;
    }
  }
  isUsingFrontFacingCamera = !isUsingFrontFacingCamera;
}

- (void)didReceiveMemoryWarning {
  [super didReceiveMemoryWarning];
}

- (void)viewDidUnload {
  [super viewDidUnload];
  [oldPredictionValues release];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
}


//- (BOOL)shouldAutorotateToInterfaceOrientation:
//    (UIInterfaceOrientation)interfaceOrientation {
//    return (interfaceOrientation == UIInterfaceOrientationLandscapeLeft);
////  return (interfaceOrientation == UIInterfaceOrientationPortrait);
//}

- (BOOL)prefersStatusBarHidden {
  return YES;
}

// ===================================================
- (void)runCNNOnFrame:(CVPixelBufferRef)pixelBuffer {
  assert(pixelBuffer != NULL);

  OSType sourcePixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);

  int doReverseChannels;
  if (kCVPixelFormatType_32ARGB == sourcePixelFormat) {
    doReverseChannels = 1;
  } else if (kCVPixelFormatType_32BGRA == sourcePixelFormat) {
    doReverseChannels = 0;
  } else {
    assert(false);  // Unknown source format
  }


  const int sourceRowBytes = (int)CVPixelBufferGetBytesPerRow(pixelBuffer);
  const int image_width = (int)CVPixelBufferGetWidth(pixelBuffer);
  const int fullHeight = (int)CVPixelBufferGetHeight(pixelBuffer);
  const int image_channels = 4;
  CVPixelBufferLockBaseAddress(pixelBuffer, 0);
  unsigned char *sourceBaseAddr =
      (unsigned char *)(CVPixelBufferGetBaseAddress(pixelBuffer));
  int image_height;
  unsigned char *sourceStartAddr;
  if (fullHeight <= image_width) {
    image_height = fullHeight;
    sourceStartAddr = sourceBaseAddr;
  } else {
    image_height = image_width;
    const int marginY = ((fullHeight - image_width) / 2);
    sourceStartAddr = (sourceBaseAddr + (marginY * sourceRowBytes));
  }
  //NSLog(@"load image %dx%d",fullHeight,image_width);

  //change hard code here
  float scale_w = 480.0f/wanted_input_width;
  float scale_h = 320.0f/wanted_input_height;
  NSLog(@"image_width: %d, image_height: %d, fullHeight: %d, wanted_input_width: %d, wanted_input_height: %d, scale_w: %f, scale_h: %f", image_width, image_height, fullHeight, wanted_input_width, wanted_input_height, scale_w, scale_h);

    
  assert(image_channels >= wanted_input_channels);
  tensorflow::Tensor image_tensor(
      tensorflow::DT_FLOAT,
      tensorflow::TensorShape(
          {1, wanted_input_height, wanted_input_width, wanted_input_channels}));
  auto image_tensor_mapped = image_tensor.tensor<float, 4>();
  tensorflow::uint8 *in = sourceStartAddr;
  float *out = image_tensor_mapped.data();
  for (int y = 0; y < wanted_input_height; ++y) {
    float *out_row = out + (y * wanted_input_width * wanted_input_channels);
    for (int x = 0; x < wanted_input_width; ++x) {
      const int in_x = (x * image_width) / wanted_input_width;
      const int in_y = (y * image_height) / wanted_input_height;
      tensorflow::uint8 *in_pixel =
          in + (in_y * image_width * image_channels) + (in_x * image_channels);
      float *out_pixel = out_row + (x * wanted_input_channels);
      for (int c = 0; c < wanted_input_channels; ++c) {
        out_pixel[c] = (in_pixel[c] - input_means[c]) / input_std;
      }
    }
  }
  //timer
  // struct timeval t1, t2;
  //end section of timer
  if (tf_session.get()) {
    std::vector<tensorflow::Tensor> outputs;
    //NSLog(@"start run");
    //timer
    // gettimeofday(&t1, NULL); //from #include <sys/time.h>
    clock_t start = clock(), diff;
    tensorflow::Status run_status = tf_session->Run(
        {{input_layer_name, image_tensor}},
         {bbox_output, prob_output, class_output}, {}, &outputs);
    //NSLog(@"stop run");
      //timer
    //gettimeofday(&t2, NULL);
    diff = clock() - start;
    int msec = diff * 1000 / CLOCKS_PER_SEC;
    NSLog(@"run time for model: %d", msec);
    //double elapsedTime;

    // compute and print the elapsed time in millisec
    // elapsedTime = (t2.tv_usec - t1.tv_usec) / 1000000.0 + (t2.tv_sec - t1.tv_sec);  // sec to ms
    //elapsedTime = (t2.tv_usec - t1.tv_usec) / 1000000.0;
    //NSLog(@"run time for model: %f", elapsedTime);
    if (!run_status.ok()) {
      LOG(ERROR) << "Running model failed:" << run_status;
    } else {
      tensorflow::Tensor *boxes = &outputs[0];
      tensorflow::Tensor *probs = &outputs[1];
      tensorflow::Tensor *cls = &outputs[2];
      auto probs_vec = probs->shaped<float, 1>({num_det_candidate});
      auto cls_vec = cls->shaped<int64_t, 1>({num_det_candidate});
      auto boxes_matrix = boxes->shaped<float, 2>({num_det_candidate, 4});

      NSMutableArray *probs_filtered = [NSMutableArray array];
      NSMutableArray *labels_filtered = [NSMutableArray array];
      NSMutableArray *boxes_filtered = [NSMutableArray array];

      for (int index=0;index<probs_vec.size();index++){
        const float probsValue = probs_vec(index);
        if(probsValue>0.45f){
          [probs_filtered addObject:[NSNumber numberWithFloat:probsValue]];
          std::string label=labels[(tensorflow::StringPiece::size_type)cls_vec(index)];
          [labels_filtered addObject:[NSString stringWithUTF8String:label.c_str()]];
          [boxes_filtered addObject:[NSArray arrayWithObjects:
                                     [NSNumber numberWithFloat:boxes_matrix(index,0)],
                                     [NSNumber numberWithFloat:boxes_matrix(index,1)],
                                     [NSNumber numberWithFloat:boxes_matrix(index,2)],
                                     [NSNumber numberWithFloat:boxes_matrix(index,3)], nil
                                     ]];
        }
      }
      dispatch_async(dispatch_get_main_queue(), ^(void){
        [self setPredictionWithLabels:labels_filtered
                                  probs:probs_filtered
                                  boxes:boxes_filtered
                                  scale_w:scale_w
                                  scale_h:scale_h
        ];
      });
      // NSLog(@"labels %@ %@",labels_filtered,boxes_filtered);

    }
  }
}


- (void)viewDidLoad {
  [super viewDidLoad];
  square = [[UIImage imageNamed:@"squarePNG"] retain];
  synth = [[AVSpeechSynthesizer alloc] init];
  labelLayers = [[NSMutableArray alloc] init];
  oldPredictionValues = [[NSMutableDictionary alloc] init];
  NSLog(@"Load Model");
  tensorflow::Status load_status;
  if (model_uses_memory_mapping) {
    load_status = LoadMemoryMappedModel(
        model_file_name, model_file_type, &tf_session, &tf_memmapped_env);
  } else {
    load_status = LoadModel(model_file_name, model_file_type, &tf_session);
  }
  if (!load_status.ok()) {
    LOG(FATAL) << "Couldn't load model: " << load_status;
  }

  tensorflow::Status labels_status =
      LoadLabels(labels_file_name, labels_file_type, &labels);
  if (!labels_status.ok()) {
    LOG(FATAL) << "Couldn't load labels: " << labels_status;
  }
  [self setupAVCapture];
}

-(void)setPredictionWithLabels:(NSArray *)labels_filtered
                   probs:(NSArray *)probs_filtered
                   boxes:(NSArray *)boxes_filtered
                   scale_w:(float)scale_w
                   scale_h:(float)scale_h{

    [self removeAllLabelLayers];
    CGRect mainScreenBounds = [[UIScreen mainScreen] bounds];

    for (int i=0;i<[labels_filtered count];i++){
      NSString *label=(NSString *)labels_filtered[i];
      [self addLabelLayerWithText:[NSString stringWithFormat:@"%@ %.2f",label,[probs_filtered[i] floatValue]]
       //change hard code here
                          originX:[boxes_filtered[i][0] floatValue]*scale_w+mainScreenBounds.origin.x
                          originY:[boxes_filtered[i][1] floatValue]*scale_h-30
                            width:[boxes_filtered[i][2] floatValue]*scale_w
                           height:[boxes_filtered[i][3] floatValue]*scale_h
                        alignment:kCAAlignmentLeft];
    }
}

- (void)removeAllLabelLayers {
  for (CATextLayer *layer in labelLayers) {
    [layer removeFromSuperlayer];
  }
  [labelLayers removeAllObjects];
}

- (void)addLabelLayerWithText:(NSString *)text
                      originX:(float)originX
                      originY:(float)originY
                        width:(float)width
                       height:(float)height
                    alignment:(NSString *)alignment {

  CGRect mainScreenBounds = [[UIScreen mainScreen] bounds];
  NSLog(@"full screen bounds x = %.f,y = %.f, width = %.f, height = %.f",mainScreenBounds.origin.x,mainScreenBounds.origin.y,mainScreenBounds.size.width,mainScreenBounds.size.height);

  NSString *const font = @"Menlo-Regular";
  const float fontSize = 5.0f;

  const float marginSizeX = 5.0f;
  const float marginSizeY = 2.0f;

  const float realOriginX = originX - (width/2);
  const float realOriginY = originY - (height/2);

  const CGRect backgroundBounds = CGRectMake(
    ceilf(realOriginX),
    ceilf(realOriginY),
    ceilf(width),
    ceilf(height)
  );
  //NSLog(@"box x:%f box y:%f box width:%f box height:%f",realOriginX,realOriginY,width,height);

  const CGRect textBounds =
      CGRectMake((realOriginX + marginSizeX), (realOriginY + marginSizeY),
                 (width - (marginSizeX * 2)), (height - (marginSizeY * 2)));

  CATextLayer *background = [CATextLayer layer];
  [background setBackgroundColor:[UIColor blackColor].CGColor];
  [background setOpacity:0.3f];
  [background setFrame:backgroundBounds];
  background.cornerRadius = 5.0f;

  [[self.view layer] addSublayer:background];
  [labelLayers addObject:background];

  CATextLayer *layer = [CATextLayer layer];
  [layer setForegroundColor:[UIColor whiteColor].CGColor];
  [layer setFrame:textBounds];
  [layer setAlignmentMode:alignment];
  [layer setWrapped:YES];
  [layer setFont:font];
  [layer setFontSize:fontSize];
  layer.contentsScale = [[UIScreen mainScreen] scale];
  [layer setString:text];

  [[self.view layer] addSublayer:layer];
  [labelLayers addObject:layer];
}

@end
