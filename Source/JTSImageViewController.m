//
//  JTSImageViewController.m
//
//
//  Created by Jared Sinclair on 3/28/14.
//  Copyright (c) 2014 Nice Boy LLC. All rights reserved.
//

#import "JTSImageViewController.h"
#import "JTSSimpleImageDownloader.h"
#import "UIView+EYEAdditions.h"
#import "BDDROneFingerZoomGestureRecognizer.h"


CGFloat const JTSImageViewController_TransitionAnimationDuration = 0.2f;
CGFloat const JTSImageViewController_BounceAnimationDuration = 0.2;
CGFloat const JTSImageViewController_BounceUpScale = 1.1;
CGFloat const JTSImageViewController_BounceDownScale = 0.95;
CGFloat const JTSImageViewController_OneFingerZoomVelocity = 4.0;

@interface JTSImageViewController ()
<
UIScrollViewDelegate,
UITextViewDelegate,
UIViewControllerTransitioningDelegate,
UIGestureRecognizerDelegate
>

@property (strong, nonatomic, readwrite) JTSImageInfo *imageInfo;
@property (strong, nonatomic, readwrite) UIImage *image;

@property (assign, nonatomic) BOOL isAnimatingAPresentationOrDismissal;
@property (assign, nonatomic) BOOL isDismissing;
@property (assign, nonatomic) BOOL isTransitioningFromInitialModalToInteractiveState;
@property (assign, nonatomic) BOOL viewHasAppeared;
@property (assign, nonatomic) BOOL isRotating;
@property (assign, nonatomic) BOOL isPresented;
@property (assign, nonatomic) BOOL rotationTransformIsDirty;
@property (assign, nonatomic) BOOL imageIsFlickingAwayForDismissal;
@property (assign, nonatomic) BOOL presentingViewControllerPresentedFromItsUnsupportedOrientation;
@property (assign, nonatomic) BOOL scrollViewIsAnimatingAZoom;
@property (assign, nonatomic) BOOL isManuallyResizingTheScrollViewFrame;
@property (assign, nonatomic) BOOL imageDownloadFailed;

@property (assign, nonatomic) CGRect startingReferenceFrameForThumbnail;
@property (assign, nonatomic) CGRect startingReferenceFrameForThumbnailInPresentingViewControllersOriginalOrientation;
@property (assign, nonatomic) CGAffineTransform currentSnapshotRotationTransform;

@property (assign, nonatomic) UIInterfaceOrientation startingInterfaceOrientation;
@property (assign, nonatomic) UIInterfaceOrientation lastUsedOrientation;

@property (strong, nonatomic) UIView *snapshotView;
@property (strong, nonatomic) UIImageView *imageView;
@property (strong, nonatomic) UIScrollView *scrollView;

@property (strong, nonatomic) UITapGestureRecognizer *singleTapperPhoto;
@property (strong, nonatomic) UITapGestureRecognizer *doubleTapperPhoto;
@property (strong, nonatomic) BDDROneFingerZoomGestureRecognizer *oneFingerZoomRecognizer;

@property (strong, nonatomic) NSURLSessionDataTask *imageDownloadDataTask;
@property (strong, nonatomic) NSTimer *downloadProgressTimer;

@property (assign, nonatomic) CGSize fullResolutionPhotoSize;
@property (assign, nonatomic) CGSize regularResolutionPhotoSize;

@property (assign, nonatomic) BOOL didScroll;
@property (assign, nonatomic) BOOL runningBouncing;
@property (assign, nonatomic) BOOL animateForDoubleTap;

@property (assign, nonatomic) CGPoint initialTapPoint;

@end

#define USE_DEBUG_SLOW_ANIMATIONS 0


@implementation JTSImageViewController

#pragma mark - Public

- (instancetype)initWithImageInfo:(JTSImageInfo *)imageInfo
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _imageInfo = imageInfo;
        _currentSnapshotRotationTransform = CGAffineTransformIdentity;
		_regularResolutionPhotoSize = imageInfo.referenceView.frame.size;
		[self setupImageAndDownloadIfNecessary:imageInfo];
    }
	
    return self;
}


- (instancetype)initWithImageInfo:(JTSImageInfo *)imageInfo initialTapPoint:(CGPoint)initialTapPoint
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _imageInfo = imageInfo;
        _currentSnapshotRotationTransform = CGAffineTransformIdentity;
		_regularResolutionPhotoSize = imageInfo.referenceView.frame.size;
		_initialTapPoint = initialTapPoint;
		[self setupImageAndDownloadIfNecessary:imageInfo];
    }
	
    return self;
}


- (void)showFromViewController:(UIViewController *)viewController
{
	[self _showImageViewerByExpandingFromOriginalPositionFromViewController:viewController];
	
}


- (void)dismiss:(BOOL)animated
{
	if (self.isPresented == NO) {
		return;
	}
	
	[self setIsPresented:NO];
	
	
	if (self.imageIsFlickingAwayForDismissal) {
		[self _dismissByCleaningUpAfterImageWasFlickedOffscreen];
	}
	else {
		BOOL startingRectForThumbnailIsNonZero = (CGRectEqualToRect(CGRectZero, self.startingReferenceFrameForThumbnail) == NO);
		BOOL useCollapsingThumbnailStyle = (startingRectForThumbnailIsNonZero && self.image != nil);
		if (useCollapsingThumbnailStyle) {
			[self _dismissByCollapsingImageBackToOriginalPosition];
		}
	}
}


#pragma mark - NSObject

- (void)dealloc
{
    [_imageDownloadDataTask cancel];
}


#pragma mark - UIViewController

- (NSUInteger)supportedInterfaceOrientations
{
    return ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskAllButUpsideDown;
}


- (BOOL)shouldAutorotate
{
    return (self.isAnimatingAPresentationOrDismissal == NO);
}


- (BOOL)prefersStatusBarHidden
{
	return YES;
}


- (UIStatusBarAnimation)preferredStatusBarUpdateAnimation
{
    return UIStatusBarAnimationFade;
}


- (UIModalTransitionStyle)modalTransitionStyle
{
    return UIModalTransitionStyleCrossDissolve;
}


- (void)viewDidLoad
{
    [super viewDidLoad];
    [self.view setBackgroundColor:[UIColor clearColor]];
    [self.view setAutoresizingMask:UIViewAutoresizingFlexibleHeight|UIViewAutoresizingFlexibleWidth];
    
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.delegate = self;
    self.scrollView.zoomScale = 1.0f;
    self.scrollView.maximumZoomScale = 8.0;
	self.scrollView.minimumZoomScale = 1.0;
    self.scrollView.scrollEnabled = YES;
	self.scrollView.showsHorizontalScrollIndicator = NO;
	self.scrollView.showsVerticalScrollIndicator = NO;
	self.scrollView.bounces = YES;
    [self.view addSubview:self.scrollView];
    
    self.imageView = [[UIImageView alloc] initWithFrame:self.view.bounds];
    self.imageView.contentMode = UIViewContentModeScaleAspectFill;
    self.imageView.isAccessibilityElement = NO;
    self.imageView.clipsToBounds = YES;
    
    // We'll add the image view to either the scroll view
    // or the parent view, based on the transition style
    // used in the "show" method.
    // After that transition completes, the image view will be
    // added to the scroll view.
    
    [self setupImageModeGestureRecognizers];
    
    
    if (self.image) {
        [self updateInterfaceWithImage:self.image];
    }
}


- (void)viewDidLayoutSubviews
{
	[self updateLayoutsForOrientation:self.lastUsedOrientation];
}


- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (self.lastUsedOrientation != self.interfaceOrientation) {
        [self setLastUsedOrientation:self.interfaceOrientation];
		[self.oneFingerZoomRecognizer setPhotoOrientation:self.lastUsedOrientation];
        [self setRotationTransformIsDirty:YES];
        [self updateLayoutsForOrientation:self.interfaceOrientation];
    }
}


- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self setViewHasAppeared:YES];
}


- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    [self setLastUsedOrientation:toInterfaceOrientation];
	[self.oneFingerZoomRecognizer setPhotoOrientation:self.lastUsedOrientation];
    [self setRotationTransformIsDirty:YES];
    [self setIsRotating:YES];
	
	[self _enableGestureRecognizers:!self.isRotating];
	[self.scrollView setZoomScale:1.0 animated:YES];
}


- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation
{
	[self setIsRotating:NO];
	[self _enableGestureRecognizers:!self.isRotating];
}


- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
	[self updateLayoutsForOrientation:self.interfaceOrientation];
}


- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
	// willRotateToInterfaceOrientation
	UIInterfaceOrientation orientation = [self orientationForTransform:[coordinator targetTransform]];
	[self setLastUsedOrientation:orientation];
	[self.oneFingerZoomRecognizer setPhotoOrientation:self.lastUsedOrientation];
	[self setRotationTransformIsDirty:YES];
	[self setIsRotating:YES];
	[self _enableGestureRecognizers:!self.isRotating];
	[self.scrollView setZoomScale:1.0 animated:YES];
	
	[coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
		// willAnimateRotationToInterfaceOrientation
		[self updateLayoutsForOrientation:orientation];

		
	} completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
		// didRotateFromInterfaceOrientation
		[self setIsRotating:NO];
		[self _enableGestureRecognizers:!self.isRotating];
	}];
}

//For some reason iOS8 returns very accurate transformed values, we need only the whole part to compare
- (CGAffineTransform)_getRoundedAffineTransformForRotationAngle:(NSInteger)angle
{
	CGAffineTransform tmpTransform = CGAffineTransformMakeRotation(DEGREES_TO_RADIANS(angle));
	tmpTransform.a = floor(tmpTransform.a);
	tmpTransform.b = floor(tmpTransform.b);
	tmpTransform.c = floor(tmpTransform.c);
	tmpTransform.d = floor(tmpTransform.d);
	tmpTransform.tx = floor(tmpTransform.tx);
	tmpTransform.ty = floor(tmpTransform.ty);
	return tmpTransform;
}


- (UIInterfaceOrientation)orientationForTransform:(CGAffineTransform) transform
{
	if (CGAffineTransformEqualToTransform (transform, [self _getRoundedAffineTransformForRotationAngle:90])) {
		if (UIInterfaceOrientationIsPortrait(self.lastUsedOrientation)) {
			return UIInterfaceOrientationLandscapeLeft;
		} else {
			return UIInterfaceOrientationPortrait;
		}
	} else if (CGAffineTransformEqualToTransform (transform, [self _getRoundedAffineTransformForRotationAngle:-90])) {
		if (UIInterfaceOrientationIsPortrait(self.lastUsedOrientation)) {
			return UIInterfaceOrientationLandscapeRight;
		} else {
			return UIInterfaceOrientationPortrait;
		}
	} else if (CGAffineTransformEqualToTransform ( transform, [self _getRoundedAffineTransformForRotationAngle:180])) {
		if (UIInterfaceOrientationIsPortrait(self.lastUsedOrientation)) {
			return UIInterfaceOrientationPortraitUpsideDown;
		} else {
			return UIInterfaceOrientationPortrait;
		}
	} else if (CGAffineTransformEqualToTransform ( transform, [self _getRoundedAffineTransformForRotationAngle:0])) {
		if (UIInterfaceOrientationIsPortrait(self.lastUsedOrientation)) {
			return UIInterfaceOrientationPortrait;
		} else {
			return self.lastUsedOrientation;
		}
	} else {
		return UIInterfaceOrientationPortrait;
	}
}


#pragma mark - Setup

- (void)setupImageAndDownloadIfNecessary:(JTSImageInfo *)imageInfo
{
    if (imageInfo.image) {
		self.fullResolutionPhotoSize = imageInfo.image.size;
        [self setImage:imageInfo.image];
    }
    else {
        
        [self setImage:imageInfo.placeholderImage];
		
        __weak JTSImageViewController *weakSelf = self;
        NSURLSessionDataTask *task = [JTSSimpleImageDownloader downloadImageForURL:imageInfo.imageURL canonicalURL:imageInfo.canonicalImageURL completion:^(UIImage *image) {
            if (image) {
                if (weakSelf.isViewLoaded) {
					weakSelf.fullResolutionPhotoSize = image.size;
                    [weakSelf updateInterfaceWithImage:image];
                } else {
					weakSelf.fullResolutionPhotoSize = image.size;
                    [weakSelf setImage:image];
                }
            } else if (weakSelf.image == nil) {
                [weakSelf setImageDownloadFailed:YES];
                if (weakSelf.isPresented && weakSelf.isAnimatingAPresentationOrDismissal == NO) {
                    [weakSelf dismiss:YES];
                }
            }
        }];
        
        [self setImageDownloadDataTask:task];
	}
}


- (void)setupImageModeGestureRecognizers
{
    
    UITapGestureRecognizer *doubleTapper = nil;
    doubleTapper = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_handleDoubleTap:)];
    doubleTapper.numberOfTapsRequired = 2;
    doubleTapper.delegate = self;
    self.doubleTapperPhoto = doubleTapper;
    
    UITapGestureRecognizer *singleTapper = nil;
    singleTapper = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_handleSingleTap:)];
    [singleTapper requireGestureRecognizerToFail:doubleTapper];
    singleTapper.delegate = self;
    self.singleTapperPhoto = singleTapper;
	
	BDDROneFingerZoomGestureRecognizer *oneFingerZoomRecognizer = [[BDDROneFingerZoomGestureRecognizer alloc] initWithTarget:self action:@selector(_handleOneFingerZoom:)];
	oneFingerZoomRecognizer.delegate = self;
	oneFingerZoomRecognizer.scaleFactor = JTSImageViewController_OneFingerZoomVelocity;
	self.oneFingerZoomRecognizer = oneFingerZoomRecognizer;
	
    [self.scrollView addGestureRecognizer:self.oneFingerZoomRecognizer];
    [self.scrollView addGestureRecognizer:self.singleTapperPhoto];
    [self.scrollView addGestureRecognizer:self.doubleTapperPhoto];
}


#pragma mark - Presentation

- (void)_showImageViewerByExpandingFromOriginalPositionFromViewController:(UIViewController *)viewController
{
    [self setIsAnimatingAPresentationOrDismissal:YES];
    [self.view setUserInteractionEnabled:NO];
    
    
    [self setStartingInterfaceOrientation:viewController.interfaceOrientation];
    [self setLastUsedOrientation:viewController.interfaceOrientation];
	[self.oneFingerZoomRecognizer setPhotoOrientation:self.lastUsedOrientation];
	
    CGRect referenceFrameInWindow = [self.imageInfo.referenceView convertRect:self.imageInfo.referenceRect toView:nil];
    self.startingReferenceFrameForThumbnailInPresentingViewControllersOriginalOrientation = [self.view convertRect:referenceFrameInWindow fromView:nil];

	self.snapshotView = [self snapshotFromParentmostViewController:viewController];
	[self.view insertSubview:self.snapshotView atIndex:0];
	
    [viewController presentViewController:self animated:NO completion:^{
		[self.view addSubview:self.imageView];

        if (self.interfaceOrientation != self.startingInterfaceOrientation) {
            [self setPresentingViewControllerPresentedFromItsUnsupportedOrientation:YES];
        }
        
        CGRect referenceFrameInMyView = [self.view convertRect:referenceFrameInWindow fromView:nil];		
        [self setStartingReferenceFrameForThumbnail:referenceFrameInMyView];
        [self.imageView setFrame:referenceFrameInMyView];
        [self updateScrollViewAndImageViewForCurrentMetrics];
        
        BOOL mustRotateDuringTransition = (self.interfaceOrientation != self.startingInterfaceOrientation);
        if (mustRotateDuringTransition) {
            CGRect newStartingRect = [self.snapshotView convertRect:self.startingReferenceFrameForThumbnail toView:self.view];
            [self.imageView setFrame:newStartingRect];
            [self updateScrollViewAndImageViewForCurrentMetrics];
            self.imageView.transform = self.snapshotView.transform;
            [self.imageView eyeCenterInView:self.view];
		}
		
        
        CGFloat duration = JTSImageViewController_BounceAnimationDuration;
        if (USE_DEBUG_SLOW_ANIMATIONS == 1) {
            duration *= 4;
        }
        
        __weak JTSImageViewController *weakSelf = self;
        
        // Have to dispatch ahead two runloops,
        // or else the image view changes above won't be
        // committed prior to the animations below.
        //
        // Dispatching only one runloop ahead doesn't fix
        // the issue on certain devices.
        //
        // This issue also seems to be triggered by only
        // certain kinds of interactions with certain views,
        // especially when a UIButton is the reference
        // for the JTSImageInfo.
        //
        dispatch_async(dispatch_get_main_queue(), ^{
			dispatch_async(dispatch_get_main_queue(), ^{
				
				[UIView
				 animateWithDuration:duration
				 delay:0
				 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
				 animations:^{
					 weakSelf.snapshotView.alpha = 0.0;
					 [weakSelf setIsTransitioningFromInitialModalToInteractiveState:YES];
					 [weakSelf setNeedsStatusBarAppearanceUpdate];
					 
					 if (mustRotateDuringTransition) {
						 [weakSelf.imageView setTransform:CGAffineTransformIdentity];
					 }
					 
					 
					 if (UIInterfaceOrientationIsPortrait(self.lastUsedOrientation)) {
						 CGFloat multiplier =  self.scrollView.frame.size.height/self.image.size.height;
						 [self.imageView setFrame: CGRectMake(0, 0, self.image.size.width * multiplier, self.scrollView.frame.size.height)];
								
						 CGFloat coordsMultiplier = self.imageInfo.referenceView.frame.size.width/self.initialTapPoint.x;
						 CGFloat xOffset = -self.imageView.frame.size.width/coordsMultiplier;

							 if (ABS(xOffset - CGRectGetWidth(self.view.frame)/2) > self.imageView.frame.size.width) {
							 [weakSelf.imageView eyeMoveToX:-self.imageView.frame.size.width + self.view.frame.size.width];
						 } else if (xOffset > - CGRectGetWidth(self.view.frame)/2) {
							 [weakSelf.imageView eyeMoveToX:0];
						 }
						 else {
							 [weakSelf.imageView eyeMoveToX: xOffset + CGRectGetWidth(self.view.frame)/2];
						 }
					 } else {
						 CGFloat multiplier =  self.view.frame.size.width/self.image.size.width;
						 [self.imageView setFrame: CGRectMake(0, 0, self.scrollView.frame.size.width, self.image.size.height * multiplier)];
						 [weakSelf.imageView eyeCenterInView:weakSelf.view];
						 [self.imageView setFrame: CGRectMake(0, 0, self.view.frame.size.width, self.image.size.height * multiplier)];
					 }
					 
					[self _upScaleView];
					 
				 } completion:^(BOOL finished) {
					 
					 [weakSelf setIsManuallyResizingTheScrollViewFrame:YES];
					 [weakSelf.scrollView setFrame:weakSelf.view.bounds];
					 [weakSelf setIsManuallyResizingTheScrollViewFrame:NO];
					 [weakSelf.scrollView addSubview:weakSelf.imageView];
					 
					 [weakSelf setIsTransitioningFromInitialModalToInteractiveState:NO];
					 [weakSelf setIsAnimatingAPresentationOrDismissal:NO];
					 [weakSelf setIsPresented:YES];
					 
					 [weakSelf updateScrollViewAndImageViewForCurrentMetrics];
					 
					 if (weakSelf.imageDownloadFailed) {
						 [weakSelf dismiss:YES];
					 } else {
						 [weakSelf.view setUserInteractionEnabled:YES];
					 }
					 
					 
					 [UIView animateWithDuration:JTSImageViewController_BounceAnimationDuration animations:^{
						 [self _resetScaleView];
					 }];
					 
					 //force to rotate all windows since photoview doesn't support landscape mode
					 [UIViewController attemptRotationToDeviceOrientation];
					 
				 }];
			});
        });
    }];
}


#pragma mark - Animations

- (void)_enableGestureRecognizers:(BOOL)enable
{
	self.singleTapperPhoto.enabled = enable;
	self.doubleTapperPhoto.enabled = enable;
	self.oneFingerZoomRecognizer.enabled = enable;
	for (UIGestureRecognizer *gestureRecognizer in self.scrollView.gestureRecognizers) {
		gestureRecognizer.enabled = enable;
	}
}


- (void)_upScaleView
{
	[[[UIApplication sharedApplication] delegate]window].transform = CGAffineTransformScale(CGAffineTransformIdentity, JTSImageViewController_BounceUpScale, JTSImageViewController_BounceUpScale);
}


- (void)_downScaleView
{
	[[[UIApplication sharedApplication] delegate]window].transform = CGAffineTransformScale(CGAffineTransformIdentity, JTSImageViewController_BounceDownScale, JTSImageViewController_BounceDownScale);
}


- (void)_resetScaleView
{
	[[[UIApplication sharedApplication] delegate]window].transform = CGAffineTransformScale(CGAffineTransformIdentity, 1.0, 1.0);
}


#pragma mark - Dismissal

- (void)_dismissByCollapsingImageBackToOriginalPosition
{
    
    [self.view setUserInteractionEnabled:NO];
    [self setIsAnimatingAPresentationOrDismissal:YES];
    [self setIsDismissing:YES];
    
    CGRect imageFrame = [self.view convertRect:self.imageView.frame fromView:self.scrollView];
    self.imageView.autoresizingMask = UIViewAutoresizingNone;
    [self.imageView setTransform:CGAffineTransformIdentity];
    [self.imageView.layer setTransform:CATransform3DIdentity];
    [self.imageView removeFromSuperview];
    [self.imageView setFrame:imageFrame];
    [self.view addSubview:self.imageView];
    [self.scrollView removeFromSuperview];
    [self setScrollView:nil];
    
    __weak JTSImageViewController *weakSelf = self;
    
    // Have to dispatch after or else the image view changes above won't be
    // committed prior to the animations below. A single dispatch_async(dispatch_get_main_queue()
    // wouldn't work under certain scrolling conditions, so it has to be an ugly
    // two runloops ahead.
    dispatch_async(dispatch_get_main_queue(), ^{
		dispatch_async(dispatch_get_main_queue(), ^{
			
			CGFloat duration = JTSImageViewController_TransitionAnimationDuration;
			if (USE_DEBUG_SLOW_ANIMATIONS == 1) {
				duration *= 4;
			}
			
			BOOL mustRotateDuringTransition = (weakSelf.interfaceOrientation != weakSelf.startingInterfaceOrientation);
			
			if (mustRotateDuringTransition) {
				if (weakSelf.interfaceOrientation == UIInterfaceOrientationLandscapeLeft) {
					weakSelf.currentSnapshotRotationTransform = CGAffineTransformMakeRotation(DEGREES_TO_RADIANS(90));
				} else if (weakSelf.interfaceOrientation == UIInterfaceOrientationLandscapeRight) {
					weakSelf.currentSnapshotRotationTransform = CGAffineTransformMakeRotation(DEGREES_TO_RADIANS(-90));
				}
			}
			weakSelf.snapshotView.transform = weakSelf.currentSnapshotRotationTransform;
			
			[UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut animations:^{
				weakSelf.snapshotView.alpha = 1.0;
				
				CGRect newEndingRect;
				CGPoint centerInRect;
				if (mustRotateDuringTransition) {
					CGRect rectToConvert = weakSelf.startingReferenceFrameForThumbnailInPresentingViewControllersOriginalOrientation;
					CGRect rectForCentering = [weakSelf.snapshotView convertRect:rectToConvert toView:weakSelf.view];
					centerInRect = CGPointMake(rectForCentering.origin.x+rectForCentering.size.width/2.0f,
											   rectForCentering.origin.y+rectForCentering.size.height/2.0f);
					newEndingRect = weakSelf.startingReferenceFrameForThumbnailInPresentingViewControllersOriginalOrientation;
					[weakSelf.imageView setFrame:newEndingRect];
					weakSelf.imageView.transform = weakSelf.currentSnapshotRotationTransform;
					[weakSelf.imageView setCenter:centerInRect];
				} else {
					if (weakSelf.presentingViewControllerPresentedFromItsUnsupportedOrientation) {
						[weakSelf.imageView setFrame:weakSelf.startingReferenceFrameForThumbnailInPresentingViewControllersOriginalOrientation];
					} else {
						[weakSelf.imageView setFrame:weakSelf.startingReferenceFrameForThumbnail];
					}
					
					// Rotation not needed, so fade the status bar back in. Looks nicer.
					[weakSelf setNeedsStatusBarAppearanceUpdate];
				}
			} completion:^(BOOL finished) {
				// Needed if dismissing from a different orientation then the one we started with
				[weakSelf setNeedsStatusBarAppearanceUpdate];
				
				[weakSelf.presentingViewController dismissViewControllerAnimated:NO completion:^{
					[weakSelf.dismissalDelegate imageViewerDidDismiss:weakSelf];
				}];
			}];
		});
	});
}


- (void)_dismissByCleaningUpAfterImageWasFlickedOffscreen
{
    
    [self.view setUserInteractionEnabled:NO];
    [self setIsAnimatingAPresentationOrDismissal:YES];
    [self setIsDismissing:YES];
    
    __weak JTSImageViewController *weakSelf = self;
    
    CGFloat duration = JTSImageViewController_TransitionAnimationDuration;
    if (USE_DEBUG_SLOW_ANIMATIONS == 1) {
        duration *= 4;
	}
	
	[UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut animations:^{
		weakSelf.snapshotView.transform = weakSelf.currentSnapshotRotationTransform;
		[weakSelf.scrollView setAlpha:0];
		[weakSelf setNeedsStatusBarAppearanceUpdate];
		
	} completion:^(BOOL finished) {
		
		[weakSelf.presentingViewController dismissViewControllerAnimated:NO completion:^{
			[weakSelf.dismissalDelegate imageViewerDidDismiss:weakSelf];
		}];
	}];
}


#pragma mark - Snapshots

- (UIView *)snapshotFromParentmostViewController:(UIViewController *)viewController
{
	UIViewController *presentingViewController = viewController.view.window.rootViewController;
	while (presentingViewController.presentedViewController) presentingViewController = presentingViewController.presentedViewController;
	UIView *snapshot = [presentingViewController.view snapshotViewAfterScreenUpdates:NO];
	[snapshot setClipsToBounds:NO];
	return snapshot;
}


#pragma mark - Interface Updates

- (void)updateInterfaceWithImage:(UIImage *)image
{
    if (image) {
        [self setImage:image];
        [self.imageView setImage:image];
    }
}


- (void)updateLayoutsForOrientation:(UIInterfaceOrientation)orientation
{
	[self updateScrollViewAndImageViewForCurrentMetrics];
    
    CGAffineTransform transform = CGAffineTransformIdentity;
    
    if (self.startingInterfaceOrientation == UIInterfaceOrientationPortrait) {
        switch (self.lastUsedOrientation) {
            case UIInterfaceOrientationLandscapeLeft:
                transform = CGAffineTransformMakeRotation(M_PI/2.0f);
                break;
            case UIInterfaceOrientationLandscapeRight:
                transform = CGAffineTransformMakeRotation(-M_PI/2.0f);
                break;
            case UIInterfaceOrientationPortrait:
                transform = CGAffineTransformIdentity;
                break;
            case UIInterfaceOrientationPortraitUpsideDown:
                transform = CGAffineTransformMakeRotation(M_PI);
                break;
            default:
                break;
        }
    }
    else if (self.startingInterfaceOrientation == UIInterfaceOrientationPortraitUpsideDown) {
        switch (self.lastUsedOrientation) {
            case UIInterfaceOrientationLandscapeLeft:
                transform = CGAffineTransformMakeRotation(-M_PI/2.0f);
                break;
            case UIInterfaceOrientationLandscapeRight:
                transform = CGAffineTransformMakeRotation(M_PI/2.0f);
                break;
            case UIInterfaceOrientationPortrait:
                transform = CGAffineTransformMakeRotation(M_PI);
                break;
            case UIInterfaceOrientationPortraitUpsideDown:
                transform = CGAffineTransformIdentity;
                break;
            default:
                break;
        }
    }
    else if (self.startingInterfaceOrientation == UIInterfaceOrientationLandscapeLeft) {
        switch (self.lastUsedOrientation) {
            case UIInterfaceOrientationLandscapeLeft:
                transform = CGAffineTransformIdentity;
                break;
            case UIInterfaceOrientationLandscapeRight:
                transform = CGAffineTransformMakeRotation(M_PI);
                break;
            case UIInterfaceOrientationPortrait:
                transform = CGAffineTransformMakeRotation(-M_PI/2.0f);
                break;
            case UIInterfaceOrientationPortraitUpsideDown:
                transform = CGAffineTransformMakeRotation(M_PI/2.0f);
                break;
            default:
                break;
        }
    }
    else if (self.startingInterfaceOrientation == UIInterfaceOrientationLandscapeRight) {
        switch (self.lastUsedOrientation) {
            case UIInterfaceOrientationLandscapeLeft:
                transform = CGAffineTransformMakeRotation(M_PI);
                break;
            case UIInterfaceOrientationLandscapeRight:
                transform = CGAffineTransformIdentity;
                break;
            case UIInterfaceOrientationPortrait:
                transform = CGAffineTransformMakeRotation(M_PI/2.0f);
                break;
            case UIInterfaceOrientationPortraitUpsideDown:
                transform = CGAffineTransformMakeRotation(-M_PI/2.0f);
                break;
            default:
                break;
        }
    }
    
    self.snapshotView.center = CGPointMake(self.view.bounds.size.width/2.0f, self.view.bounds.size.height/2.0f);
    
    if (self.rotationTransformIsDirty) {
        [self setRotationTransformIsDirty:NO];
        self.currentSnapshotRotationTransform = transform;
        if (self.isPresented) {
			self.scrollView.frame = self.view.bounds;
        } else {
            self.snapshotView.transform = transform;
        }
    }
}


- (void)updateScrollViewAndImageViewForCurrentMetrics
{
	if (self.scrollView.zoomScale > 1.0) {
		return;
	}
	
    if (self.isAnimatingAPresentationOrDismissal == NO) {
        [self setIsManuallyResizingTheScrollViewFrame:YES];
        self.scrollView.frame = self.view.bounds;
        [self setIsManuallyResizingTheScrollViewFrame:NO];
    }
		
    if (self.isAnimatingAPresentationOrDismissal == NO) {

		if (UIInterfaceOrientationIsPortrait(self.lastUsedOrientation)) {
			CGFloat multiplier =  self.scrollView.frame.size.height/self.image.size.height;
            [self.imageView setFrame: CGRectMake(0, 0, self.image.size.width * multiplier, self.scrollView.frame.size.height)];
			
		} else {
			CGFloat multiplier =  self.scrollView.frame.size.width/self.image.size.width;
            [self.imageView setFrame: CGRectMake(0, 0, self.scrollView.frame.size.width, self.image.size.height * multiplier)];
		}
		
		if (UIInterfaceOrientationIsPortrait(self.lastUsedOrientation)) {
			self.scrollView.minimumZoomScale = self.scrollView.frame.size.width/self.imageView.frame.size.width;
		} else {
			self.scrollView.minimumZoomScale = self.scrollView.frame.size.height/self.imageView.frame.size.height;
		}
        self.scrollView.contentSize = self.imageView.frame.size;
		
		// prevent to reset the offset when replacing the photo for the higher resolution one
		if (!self.didScroll) {
			CGFloat r = self.imageInfo.referenceView.frame.size.width/self.initialTapPoint.x;
			
			CGFloat x = self.imageView.frame.size.width/r;
			self.scrollView.contentOffset = CGPointMake(x - CGRectGetWidth(self.view.frame)/2, 0);
		}
	}
}


#pragma mark - UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
	self.didScroll = YES;
}


- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView
{
    return self.imageView;
}


- (void)scrollViewDidZoom:(UIScrollView *)scrollView
{
    
    if (self.imageIsFlickingAwayForDismissal) {
        return;
    }
	
	if (scrollView.zoomScale >= scrollView.maximumZoomScale) {
		scrollView.zoomScale = scrollView.maximumZoomScale;
	}
	
	UIView *subView = [scrollView.subviews objectAtIndex:0];
	
    CGFloat offsetX = MAX((scrollView.bounds.size.width - scrollView.contentSize.width) * 0.5, 0.0);
    CGFloat offsetY = MAX((scrollView.bounds.size.height - scrollView.contentSize.height) * 0.5, 0.0);
	
    subView.center = CGPointMake(scrollView.contentSize.width * 0.5 + offsetX,
                                 scrollView.contentSize.height * 0.5 + offsetY);
}


- (void)scrollViewDidEndZooming:(UIScrollView *)scrollView withView:(UIView *)view atScale:(CGFloat)scale
{
    if (self.imageIsFlickingAwayForDismissal || scale == 1.0) {
        return;
    }
    
	if (scrollView.zoomScale > 1.0) {
		[scrollView setZoomScale:1.0 animated:YES];
		[self updateScrollViewAndImageViewForCurrentMetrics];
	}
}


#pragma mark - Gesture Recognizer Actions

- (void)_handleDoubleTap:(UITapGestureRecognizer *)sender
{
    
    if (self.scrollViewIsAnimatingAZoom) {
        return;
    }
	
    CGPoint rawLocation = [sender locationInView:sender.view];
    CGPoint point = [self.imageView convertPoint:rawLocation fromView:sender.view];
    CGRect targetZoomRect = CGRectZero;
	CGFloat zoomWidth = 0.0;
	CGFloat zoomHeight = 0.0;
	
    if (self.scrollView.zoomScale == 1.0f) {
		zoomWidth = self.scrollView.frame.size.width / self.scrollView.minimumZoomScale;
		zoomHeight = self.scrollView.frame.size.height / self.scrollView.minimumZoomScale;
    } else {
		zoomWidth = self.scrollView.frame.size.width;
		zoomHeight = self.scrollView.frame.size.height;
    }
	
	targetZoomRect = CGRectMake(point.x - (zoomWidth/2.0f), point.y - (zoomHeight/2.0f), zoomWidth, zoomHeight);
	[self.view setUserInteractionEnabled:NO];
	[self setScrollViewIsAnimatingAZoom:YES];
	[self.scrollView zoomToRect:targetZoomRect animated:YES];
	
	if (self.scrollView.zoomScale == 1.0f) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW,0), dispatch_get_main_queue(), ^{
			[UIView animateWithDuration:0.35 delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
				if (UIInterfaceOrientationIsPortrait(self.lastUsedOrientation)) {
					[self.imageView eyeCenterVerticallyInView:self.scrollView];
				} else {
					[self.imageView eyeCenterHorizontallyInView:self.scrollView];
				}
			} completion:^(BOOL finished) {
				//add bouncing
				[UIView animateWithDuration:JTSImageViewController_BounceAnimationDuration animations:^{
					[self _upScaleView];
				} completion:^(BOOL aFinished) {
					[UIView animateWithDuration:JTSImageViewController_BounceAnimationDuration animations:^{
						[self _resetScaleView];
					}];
				}];
			}];
		});
		
		__weak JTSImageViewController *weakSelf = self;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.35 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			[weakSelf.view setUserInteractionEnabled:YES];
			[weakSelf setScrollViewIsAnimatingAZoom:NO];
		});
	} else {
		__weak JTSImageViewController *weakSelf = self;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.35 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			[weakSelf.view setUserInteractionEnabled:YES];
			[weakSelf setScrollViewIsAnimatingAZoom:NO];
		});
		
		self.animateForDoubleTap = YES;
	}
}


- (void)_handleSingleTap:(id)sender
{
    if (self.scrollViewIsAnimatingAZoom || self.oneFingerZoomRecognizer.state == UIGestureRecognizerStateChanged) {
        return;
    }
	
    [self dismiss:YES];
}


- (void)_handleOneFingerZoom:(BDDROneFingerZoomGestureRecognizer *)oneFingerZoomGestureRecognizer
{
	switch (oneFingerZoomGestureRecognizer.state) {
		case UIGestureRecognizerStateBegan:
			oneFingerZoomGestureRecognizer.scale = self.scrollView.zoomScale;
			
			if (self.scrollView.bouncesZoom) {
				self.scrollView.minimumZoomScale /= 2.0f;
				self.scrollView.maximumZoomScale *= 2.0f;
			}
			break;
			
		case UIGestureRecognizerStateChanged:
			self.scrollView.zoomScale = oneFingerZoomGestureRecognizer.scale;
			break;
			
		case UIGestureRecognizerStateEnded:
			
		case UIGestureRecognizerStateCancelled:
			if (self.scrollView.bouncesZoom) {
				self.scrollView.minimumZoomScale *= 2.0f;
				self.scrollView.maximumZoomScale /= 2.0f;
				
				if (self.scrollView.zoomScale < self.scrollView.minimumZoomScale) {
					[self.scrollView setZoomScale:self.scrollView.minimumZoomScale animated:YES];
					self.animateForDoubleTap = YES;
				}
				else if (self.scrollView.zoomScale > 1.0)
					[self.scrollView setZoomScale:1.0 animated:YES];
			}
			break;
		default:
			break;
	}
}


#pragma mark - Gesture Recognizer Delegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
	//necessary to track oneFingerZoom and single taps. The logic to discard the gestures are on their own selectors.
	return YES;
}


- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch
{
    BOOL shouldReceiveTouch = YES;
	
	if ([self.interactionsDelegate respondsToSelector:@selector(imageViewerShouldTemporarilyIgnoreTouches:)]) {
        shouldReceiveTouch = ![self.interactionsDelegate imageViewerShouldTemporarilyIgnoreTouches:self];
    }
    return shouldReceiveTouch;
}

@end



