#import <FBSDKCoreKit/FBSDKCoreKit.h>
#import <FBSDKLoginKit/FBSDKLoginKit.h>
#import <ORKeyboardReactingApplication/ORKeyboardReactingApplication.h>
#import <iRate/iRate.h>
#import <AFOAuth1Client/AFOAuth1Client.h>
#import <UICKeyChainStore/UICKeyChainStore.h>
#import <Adjust/Adjust.h>

#import "ARAppWatchCommunicator.h"

#import <ARAnalytics/ARAnalytics.h>
#import "ARAnalyticsConstants.h"

#import "ARAppDelegate.h"
#import "ARAppDelegate+Analytics.h"
#import "ARAppDelegate+Emission.h"
#import "ARAppNotificationsDelegate.h"
#import "ARAppConstants.h"
#import "ARFonts.h"
#import "ARUserManager.h"
#import "AROptions.h"
#import "ARSwitchBoard.h"
#import "ARTopMenuViewController.h"

#import "UIViewController+InnermostTopViewController.h"
#import "ARSimpleShowFeedViewController.h"
#import "ARAdminSettingsViewController.h"
#import "ARQuicksilverViewController.h"
#import "ARRouter.h"
#import "ARNetworkConstants.h"
#import "ArtsyAPI+Private.h"
#import "ArtsyAPI+SiteFunctions.h"
#import "ARFileUtils.h"
#import "ARSpotlight.h"
#import "ARWebViewCacheHost.h"
#import "ARAppStatus.h"
#import "Artsy-Swift.h"
#import "ARSystemTime.h"
#import "ARDispatchManager.h"
#import "ARLogger.h"
#import "FeaturedLink.h"
#import "OrderedSet.h"
#import "ArtsyAPI+OrderedSets.h"

#import "UIDevice-Hardware.h"

#import <Keys/ArtsyKeys.h>
#import "AREndOfLineInternalMobileWebViewController.h"
#import "ARDefaults+SiteFeatures.h"

#import <DHCShakeNotifier/UIWindow+DHCShakeRecognizer.h>
#import <VCRURLConnection/VCR.h>
#import <ObjectiveSugar/ObjectiveSugar.h>

// demo
#import "ARDemoSplashViewController.h"


@interface ARAppDelegate ()
@property (strong, nonatomic, readwrite) NSString *referralURLRepresentation;
@property (strong, nonatomic, readwrite) NSString *landingURLRepresentation;
@property (strong, nonatomic, readwrite) NSDictionary *initialLaunchOptions;
@property (strong, nonatomic, readwrite) ARHockeyFeedbackDelegate *feedbackDelegate;

@end


@implementation ARAppDelegate

static ARAppDelegate *_sharedInstance = nil;

+ (void)load
{
    _sharedInstance = [[self alloc] init];
    [JSDecoupledAppDelegate sharedAppDelegate].appStateDelegate = _sharedInstance;

    // TODO Until we drop iOS 8 support, we can’t really conform to the `JSApplicationURLResourceOpeningDelegate`
    // protocol, as it means we would have to implement `application:openURL:options:` which seems tricky if we still
    // have to implement `application:openURL:sourceApplication:annotation:` as well.
    [JSDecoupledAppDelegate sharedAppDelegate].URLResourceOpeningDelegate = (id)_sharedInstance;
}

+ (ARAppDelegate *)sharedInstance
{
    return _sharedInstance;
}

/// These are the pre-requisites for doing any background networking with Eigen.

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    if (ARIsRunningInDemoMode) {
        [ARUserManager clearUserData];
    }

    [ARDefaults setup];
    [ARRouter setup];

    self.initialLaunchOptions = launchOptions;
    return YES;
}

/// This is called when we are going to present a user interface, which
/// is both on traditional app launch, and every time we are backgrounded and back.

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // In case everything's already set up
    if (self.window) {
        return;
    }

    // Temp Fix for: https://github.com/artsy/eigen/issues/602
    [self forceCacheCustomFonts];

    // This cannot be moved after the view setup code, as it
    // relies on swizzling alloc on new objects, thus should be
    // one of the first things that happen.
    [self setupAnalytics];

    self.window = [[ARWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.viewController = [ARTopMenuViewController sharedController];
    self.window.rootViewController = self.viewController;
    [self.window makeKeyAndVisible];

    [self setupAdminTools];

    [self setupRatingTool];
    [self countNumberOfRuns];

    [application setMinimumBackgroundFetchInterval:UIApplicationBackgroundFetchIntervalMinimum];

    _landingURLRepresentation = self.landingURLRepresentation ?: @"https://artsy.net";

    [[ARLogger sharedLogger] startLogging];
    [FBSDKSettings setAppID:[ArtsyKeys new].artsyFacebookAppID];

    if ([AROptions boolForOption:AROptionsEnableReactArtist]) {
        [self setupEmission];
    }

    // This has to be checked *before* creating the first Xapp token.
    BOOL showOnboarding = ![[ARUserManager sharedManager] hasExistingAccount];

    if (ARIsRunningInDemoMode) {
        [self.viewController presentViewController:[[ARDemoSplashViewController alloc] init] animated:NO completion:nil];
        [self performSelector:@selector(finishDemoSplash) withObject:nil afterDelay:1];

    } else if (showOnboarding) {
        [self fetchSiteFeatures];

        // Do not show the splash/onboarding when a user comes in through a user activity, as it breaks the expectation
        // of the user to see the activity. This is probably just an edge-case, most people will probably launch the app
        // after installing it.
        if (self.initialLaunchOptions[UIApplicationLaunchOptionsUserActivityDictionaryKey] == nil) {
            [self showTrialOnboarding];
        }
    }

    [ArtsyAPI getXappTokenWithCompletion:^(NSString *xappToken, NSDate *expirationDate) {
        // Sync clock with server
        [ARSystemTime sync];

        // Register for push notifications as early as possible, but not on top of the onboarding view, in which case it
        // will be called from the -finishOnboardingAnimated: callback.
        //
        // In case the user has not signed-in yet, this will register as an anonymous device on the Artsy API. Later on,
        // when the user does sign-in, this will be ran again and the device will be associated with the user account.
        if (!showOnboarding) {
            [self.remoteNotificationsDelegate registerForDeviceNotifications];
            if ([User currentUser]) {
                [ARSpotlight indexAllUsersFavorites];
            };
        }

        NSDictionary *remoteNotification = self.initialLaunchOptions[UIApplicationLaunchOptionsRemoteNotificationKey];
        if (remoteNotification) {
            // The app was not running, so considering it to be in the UIApplicationStateInactive state.
            [self.remoteNotificationsDelegate applicationDidReceiveRemoteNotification:remoteNotification
                                                                   inApplicationState:UIApplicationStateInactive];
        }
    }];

    [ARWebViewCacheHost startup];
    [self registerNewSessionOpened];
    [self checkForiOS8Deprecation];
}

- (void)registerNewSessionOpened
{
    [ARTrialController extendTrial];
    [ARAnalytics startTimingEvent:ARAnalyticsTimePerSession];

    if ([User currentUser]) {
        [ArtsyAPI getXappTokenWithCompletion:^(NSString *xappToken, NSDate *expirationDate) {
            [self.remoteNotificationsDelegate fetchNotificationCounts];
        }];
    }
}

/// This happens every time we come _back_ to the app from the background

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    [self registerNewSessionOpened];
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    [ARAnalytics finishTimingEvent:ARAnalyticsTimePerSession];
}

- (ARAppNotificationsDelegate *)remoteNotificationsDelegate;
{
    return [[JSDecoupledAppDelegate sharedAppDelegate] remoteNotificationsDelegate];
}

- (void)showTrialOnboarding;
{
    [self showTrialOnboardingWithState:ARInitialOnboardingStateSlideShow andContext:ARTrialContextNotTrial];
}

- (void)finishDemoSplash
{
    [self.viewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)forceCacheCustomFonts
{
    __unused UIFont *font = [UIFont serifBoldItalicFontWithSize:12];
    font = [UIFont serifBoldFontWithSize:12];
    font = [UIFont serifSemiBoldFontWithSize:12];
    font = [UIFont serifFontWithSize:12];
    font = [UIFont serifItalicFontWithSize:12];
    font = [UIFont sansSerifFontWithSize:12];
    font = [UIFont smallCapsSerifFontWithSize:12];
}

- (void)finishOnboardingAnimated:(BOOL)animated didCancel:(BOOL)cancelledSignIn;
{
    [[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationFade];

    ARTopMenuViewController *topVC = ARTopMenuViewController.sharedController;
    if (topVC.presentedViewController) {
        topVC.presentedViewController.transitioningDelegate = topVC;
        [topVC.presentedViewController dismissViewControllerAnimated:animated completion:^{
            [ARTrialController performCompletionNewUser:[ARUserManager didCreateAccountThisSession]];
        }];
    }

    if (!cancelledSignIn) {
        ar_dispatch_main_queue(^{
            [self.remoteNotificationsDelegate registerForDeviceNotifications];
            if ([User currentUser]) {
                [self.remoteNotificationsDelegate fetchNotificationCounts];
                [ARSpotlight indexAllUsersFavorites];
            }
        });
    }
}

- (void)showTrialOnboardingWithState:(enum ARInitialOnboardingState)state andContext:(enum ARTrialContext)context
{
    AROnboardingViewController *onboardVC = [[AROnboardingViewController alloc] initWithState:state];
    onboardVC.trialContext = context;
    onboardVC.modalPresentationStyle = UIModalPresentationOverFullScreen;
    UIViewController *controller = self.viewController;
    // Loop till we find the topmost VC
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }
    [controller presentViewController:onboardVC animated:NO completion:nil];
}

- (void)setupAdminTools
{
    if (!ARAppStatus.isBetaDevOrAdmin) {
        return;
    }

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(rageShakeNotificationRecieved) name:DHCSHakeNotificationName object:nil];
    // TODO Make React Native’s DevMenu module play nice with others that also override -[UIWindow motionEnded:withEvent:]
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(rageShakeNotificationRecieved) name:@"RCTShowDevMenuNotification" object:nil];

    if ([AROptions boolForOption:AROptionsUseVCR]) {
        NSURL *url = [NSURL fileURLWithPath:[ARFileUtils cachesPathWithFolder:@"vcr" filename:@"eigen.json"]];
        [VCR loadCassetteWithContentsOfURL:url];
        [VCR start];
    }

    [ORKeyboardReactingApplication registerForCallbackOnKeyDown:ORTildeKey:^{
        [self rageShakeNotificationRecieved];
    }];

    [ORKeyboardReactingApplication registerForCallbackOnKeyDown:ORSpaceKey:^{
        [self showQuicksilver];
    }];

    [ORKeyboardReactingApplication registerForCallbackOnKeyDown:ORDeleteKey:^{
        [ARTopMenuViewController.sharedController.rootNavigationController popViewControllerAnimated:YES];
    }];

    self.feedbackDelegate = [[ARHockeyFeedbackDelegate alloc] init];
    [self.feedbackDelegate listenForScreenshots];
}

- (void)setupRatingTool
{
    [iRate sharedInstance].promptForNewVersionIfUserRated = NO;
    [iRate sharedInstance].verboseLogging = NO;
}

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
  sourceApplication:(NSString *)sourceApplication
         annotation:(id)annotation
{
    _referralURLRepresentation = sourceApplication;
    _landingURLRepresentation = [url absoluteString];

    [self lookAtURLForAnalytics:url];


    // Twitter SSO
    if ([[url absoluteString] hasPrefix:ARTwitterCallbackPath]) {
        NSNotification *notification = nil;
        notification = [NSNotification notificationWithName:kAFApplicationLaunchedWithURLNotification
                                                     object:nil
                                                   userInfo:@{kAFApplicationLaunchOptionsURLKey : url}];

        [[NSNotificationCenter defaultCenter] postNotification:notification];
        return YES;
    }

    // Facebook
    NSString *fbScheme = [@"fb" stringByAppendingString:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"FacebookAppID"]];

    if ([[url scheme] isEqualToString:fbScheme]) {
        // Call FBAppCall's handleOpenURL:sourceApplication to handle Facebook app responses
        FBSDKApplicationDelegate *fbAppDelegate = [FBSDKApplicationDelegate sharedInstance];
        return [fbAppDelegate application:application openURL:url sourceApplication:sourceApplication annotation:annotation];
    }

    if ([url isFileURL]) {
        // AirDrop receipt
        NSData *fileData = [NSData dataWithContentsOfURL:url];
        NSDictionary *data = [NSJSONSerialization JSONObjectWithData:fileData options:0 error:nil];
        NSString *urlString = [data valueForKey:@"url"];

        if (urlString) {
            _landingURLRepresentation = urlString;

            UIViewController *viewController = [ARSwitchBoard.sharedInstance loadURL:[NSURL URLWithString:urlString]];
            if (viewController) {
                [[ARTopMenuViewController sharedController] pushViewController:viewController];
            }
            return YES;

        } else {
            return NO;
        }
    }

    UIViewController *viewController = [ARSwitchBoard.sharedInstance loadURL:url];
    if (viewController) {
        [[ARTopMenuViewController sharedController] pushViewController:viewController];
    }

    return YES;
}

- (void)rageShakeNotificationRecieved
{
    UINavigationController *navigationController = ARTopMenuViewController.sharedController.rootNavigationController;

    if (![navigationController.topViewController isKindOfClass:ARAdminSettingsViewController.class]) {
        if (![UIDevice isPad]) {
            // For some reason the supported orientation isn’t respected when this is pushed on top
            // of a landscape VIR view.
            //
            // Since this is a debug/admin only issue, it’s safe to use private API here.
            [[UIDevice currentDevice] setValue:@(UIInterfaceOrientationPortrait) forKey:@"orientation"];
        }
        ARAdminSettingsViewController *adminSettings = [[ARAdminSettingsViewController alloc] initWithStyle:UITableViewStyleGrouped];
        [navigationController pushViewController:adminSettings animated:YES];
    }
}

- (void)showQuicksilver
{
    UINavigationController *navigationController = ARTopMenuViewController.sharedController.rootNavigationController;

    // As this is hooked up to return everywhere, it shouldn't be able to
    // call itself when it's just finished showing
    NSInteger count = navigationController.viewControllers.count;

    if (count > 1) {
        id oldVC = navigationController.viewControllers[count - 2];
        if ([oldVC isKindOfClass:[ARQuicksilverViewController class]]) {
            return;
        }
    }

    ARQuicksilverViewController *adminSettings = [[ARQuicksilverViewController alloc] init];
    [navigationController pushViewController:adminSettings animated:YES];
}
- (void)fetchSiteFeatures
{
    [ArtsyAPI getXappTokenWithCompletion:^(NSString *xappToken, NSDate *expirationDate) {
       [ArtsyAPI getSiteFeatures:^(NSArray *features) {
           [ARDefaults setOnboardingDefaults:features];

       } failure:^(NSError *error) {
           ARErrorLog(@"Couldn't get site features. Error %@", error.localizedDescription);
       }];
    }];
}

- (void)countNumberOfRuns
{
    NSInteger numberOfRuns = [[NSUserDefaults standardUserDefaults] integerForKey:ARAnalyticsAppUsageCountProperty] + 1;
    if (numberOfRuns == 1) {
        [ARAnalytics event:ARAnalyticsFreshInstall];
        [Adjust trackEvent:[ADJEvent eventWithEventToken:ARAdjustFirstUserInstall]];
    }

    [[NSUserDefaults standardUserDefaults] setInteger:numberOfRuns forKey:ARAnalyticsAppUsageCountProperty];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)checkForiOS8Deprecation

{
    // To totally deprecate all iOS8 devices
    // set the "iOS8 Redirection URL" featured link's HREF to something like /404/ios8
    // https://admin.artsy.net/set/54e4aab97261692d085a1c00

    // This was added in iOS9
    if (&UIApplicationOpenURLOptionsAnnotationKey != NULL) {
        return;
    }

    [ArtsyAPI getOrderedSetWithKey:@"eigen-ios-deprecation-featured-links" success:^(OrderedSet *set) {
        [set getItems:^(NSArray *items) {
            FeaturedLink *link = [items detect:^BOOL(FeaturedLink *link) {
                return [link.title isEqualToString:@"iOS8 Redirection URL"];
            }];

            // By default it be 0 length
            if (link.href.length) {
                UINavigationController *navigationController = ARTopMenuViewController.sharedController.rootNavigationController;
                NSURL *url = [NSURL URLWithString:link.href relativeToURL:[ARRouter baseWebURL]];
                UIViewController *martsyWarning = [[AREndOfLineInternalMobileWebViewController alloc] initWithURL:url];
                [navigationController setViewControllers:@[martsyWarning] animated:NO];
            }

        }];
    } failure:nil];
}

@end


@implementation ARWindow

- (void)sendEvent:(UIEvent *)event
{
    [super sendEvent:event];

    if (event.type == UIEventTypeTouches) {
        self.lastTouchPoint = [[[event allTouches] anyObject] locationInView:self];
    }
}

@end
