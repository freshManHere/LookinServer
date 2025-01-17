//
//  LKS_ConnectionManager.m
//  LookinServer
//
//  Copyright © 2019 Lookin. All rights reserved.
//

#import "LKS_ConnectionManager.h"
#import "PTChannel.h"
#import "LookinDefines.h"
#import "LKS_RequestHandler.h"
#import "LookinConnectionResponseAttachment.h"
#import "LKS_LocalInspectManager.h"
#import "LKS_ExportManager.h"
#import "LKS_PerspectiveManager.h"

NSString *const LKS_ConnectionDidEndNotificationName = @"LKS_ConnectionDidEndNotificationName";

@interface LKS_ConnectionManager () <PTChannelDelegate>

@property(nonatomic, weak) PTChannel *peerChannel_;

@property(nonatomic, strong) LKS_RequestHandler *requestHandler;

@end

@implementation LKS_ConnectionManager

+ (instancetype)sharedInstance {
    static LKS_ConnectionManager *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[LKS_ConnectionManager alloc] init];
    });
    return sharedInstance;
}

+ (void)load {
    [LKS_ConnectionManager sharedInstance];
}

- (instancetype)init {
    if (self = [super init]) {
        NSLog(@"LookinServer - Will launch. Framework version: %@", LOOKIN_SERVER_READABLE_VERSION);
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleApplicationDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleWillResignActiveNotification) name:UIApplicationWillResignActiveNotification object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleLocalInspectIn2D:) name:@"Lookin_2D" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleLocalInspectIn3D:) name:@"Lookin_3D" object:nil];
        [[NSNotificationCenter defaultCenter] addObserverForName:@"Lookin_Export" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            [[LKS_ExportManager sharedInstance] exportAndShare];
        }];
        
        self.requestHandler = [LKS_RequestHandler new];
    }
    return self;
}

- (void)_handleWillResignActiveNotification {
    self.applicationIsActive = NO;
}

- (void)_handleApplicationDidBecomeActive {
    self.applicationIsActive = YES;
    if (self.peerChannel_ && (self.peerChannel_.isConnected || self.peerChannel_.isListening)) {
        return;
    }
    NSLog(@"LookinServer - Trying to connect ...");
#if TARGET_OS_SIMULATOR
    [self _tryToListenOnPortFrom:LookinSimulatorIPv4PortNumberStart to:LookinSimulatorIPv4PortNumberEnd current:LookinSimulatorIPv4PortNumberStart];
#else
    [self _tryToListenOnPortFrom:LookinUSBDeviceIPv4PortNumberStart to:LookinUSBDeviceIPv4PortNumberEnd current:LookinUSBDeviceIPv4PortNumberStart];
#endif
}

- (void)_tryToListenOnPortFrom:(int)fromPort to:(int)toPort current:(int)currentPort  {
    PTChannel *channel = [PTChannel channelWithDelegate:self];
    [channel listenOnPort:currentPort IPv4Address:INADDR_LOOPBACK callback:^(NSError *error) {
        if (error) {
            if (error.code == 48) {
                // 该地址已被占用
            } else {
                // 未知失败
            }
            
            if (currentPort < toPort) {
                // 尝试下一个端口
                NSLog(@"LookinServer - 127.0.0.1:%d is unavailable(%@). Will try anothor address ...", currentPort, error);
                [self _tryToListenOnPortFrom:fromPort to:toPort current:(currentPort + 1)];
            } else {
                // 所有端口都尝试完毕，全部失败
                NSLog(@"LookinServer - 127.0.0.1:%d is unavailable(%@).", currentPort, error);
                NSLog(@"LookinServer - Connect failed in the end. Ask for help: lookin@lookin.work");
            }
            
        } else {
            // 成功
            NSLog(@"LookinServer - Connected successfully on 127.0.0.1:%d", currentPort);
        }
    }];
}

- (void)dealloc {
    if (self.peerChannel_) {
        [self.peerChannel_ close];
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)isConnected {
    return self.peerChannel_ && self.peerChannel_.isConnected;
}

- (void)respond:(LookinConnectionResponseAttachment *)data requestType:(uint32_t)requestType tag:(uint32_t)tag {
    [self _sendData:data frameOfType:requestType tag:tag];
}

- (void)pushData:(NSObject *)data type:(uint32_t)type {
    [self _sendData:data frameOfType:type tag:0];
}

- (void)_sendData:(NSObject *)data frameOfType:(uint32_t)frameOfType tag:(uint32_t)tag {
    if (self.peerChannel_) {
        NSData *archivedData = [NSKeyedArchiver archivedDataWithRootObject:data];
        dispatch_data_t payload = [archivedData createReferencingDispatchData];
        
        [self.peerChannel_ sendFrameOfType:frameOfType tag:tag withPayload:payload callback:^(NSError *error) {
            if (error) {
            }
        }];
    }
}

#pragma mark - PTChannelDelegate

- (BOOL)ioFrameChannel:(PTChannel*)channel shouldAcceptFrameOfType:(uint32_t)type tag:(uint32_t)tag payloadSize:(uint32_t)payloadSize {
    if (channel != self.peerChannel_) {
        return NO;
    } else if ([self.requestHandler canHandleRequestType:type]) {
        return YES;
    } else {
        [channel close];
        return NO;
    }
}

- (void)ioFrameChannel:(PTChannel*)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(PTData*)payload {
    id object = nil;
    if (payload) {
        id unarchivedObject = [NSKeyedUnarchiver unarchiveObjectWithData:[NSData dataWithContentsOfDispatchData:payload.dispatchData]];
        if ([unarchivedObject isKindOfClass:[LookinConnectionAttachment class]]) {
            LookinConnectionAttachment *attachment = (LookinConnectionAttachment *)unarchivedObject;
            object = attachment.data;
        } else {
            object = unarchivedObject;
        }
    }
    [self.requestHandler handleRequestType:type tag:tag object:object];
}

- (void)ioFrameChannel:(PTChannel*)channel didEndWithError:(NSError*)error {
    [[NSNotificationCenter defaultCenter] postNotificationName:LKS_ConnectionDidEndNotificationName object:self];
}

- (void)ioFrameChannel:(PTChannel*)channel didAcceptConnection:(PTChannel*)otherChannel fromAddress:(PTAddress*)address {
    if (self.peerChannel_) {
        [self.peerChannel_ cancel];
    }
    
    self.peerChannel_ = otherChannel;
    self.peerChannel_.userInfo = address;
}

#pragma mark - Handler

- (void)_handleLocalInspectIn2D:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<UIWindow *> *includedWindows = nil;
        NSArray<UIWindow *> *excludedWindows = nil;
        [self parseUserInfo:note.userInfo toIncludedWindows:&includedWindows excludedWindows:&excludedWindows];

        [[LKS_LocalInspectManager sharedInstance] startLocalInspectWithIncludedWindows:includedWindows excludedWindows:excludedWindows];
    });
}

- (void)_handleLocalInspectIn3D:(NSNotification *)note {
    NSArray<UIWindow *> *includedWindows = nil;
    NSArray<UIWindow *> *excludedWindows = nil;
    [self parseUserInfo:note.userInfo toIncludedWindows:&includedWindows excludedWindows:&excludedWindows];
    
    [[LKS_PerspectiveManager sharedInstance] showWithIncludedWindows:includedWindows excludedWindows:excludedWindows];
}

- (void)parseUserInfo:(NSDictionary *)info toIncludedWindows:(NSArray<UIWindow *> **)includedWindowsPtr excludedWindows:(NSArray<UIWindow *> **)excludedWindowsPtr {
    if (info[@"includedWindows"] && info[@"excludedWindows"]) {
        NSLog(@"LookinServer - Do not pass 'includedWindows' and 'excludedWindows' in the same time. Learn more: https://lookin.work/faq/lookin-ios/");
    }
    
    [info enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        if ([key isEqual:@"includedWindows"] || [key isEqual:@"excludedWindows"]) {
            return;
        }
        NSLog(@"LookinServer - The key '%@' you passed is not valid. Learn more: https://lookin.work/faq/lookin-ios/", key);
    }];
    
    NSArray<UIWindow *> *includedWindows = [info objectForKey:@"includedWindows"];
    if (includedWindows) {
        if ([includedWindows isKindOfClass:[NSArray class]]) {
            includedWindows = [includedWindows lookin_filter:^BOOL(UIWindow *obj) {
                if ([obj isKindOfClass:[UIWindow class]]) {
                    return YES;
                }
                NSLog(@"LookinServer - Error. The class of element in 'includedWindows' array must be UIWindow, but you've passed '%@'. Learn more: https://lookin.work/faq/lookin-ios/", NSStringFromClass(obj.class));
                return NO;
            }];
            
        } else {
            NSLog(@"LookinServer - Error. The 'includedWindows' must be a NSArray, but you've passed '%@'. Learn more: https://lookin.work/faq/lookin-ios/", NSStringFromClass([includedWindows class]));
            includedWindows = nil;
        }
    }
    
    NSArray<UIWindow *> *excludedWindows = nil;
    // 只有当 includedWindows 无效时，才会应用 excludedWindows
    if (includedWindows.count == 0) {
        excludedWindows = [info objectForKey:@"excludedWindows"];
        if (excludedWindows) {
            if ([excludedWindows isKindOfClass:[NSArray class]]) {
                excludedWindows = [excludedWindows lookin_filter:^BOOL(UIWindow *obj) {
                    if ([obj isKindOfClass:[UIWindow class]]) {
                        return YES;
                    }
                    NSLog(@"LookinServer - Error. The class of element in 'excludedWindows' array must be UIWindow, but you've passed '%@'. Learn more: https://lookin.work/faq/lookin-ios/", NSStringFromClass(obj.class));
                    return NO;
                }];
                
            } else {
                NSLog(@"LookinServer - Error. The 'excludedWindows' must be a NSArray, but you've passed '%@'. Learn more: https://lookin.work/faq/lookin-ios/", NSStringFromClass([excludedWindows class]));
                excludedWindows = nil;
            }
        }
    }
    
    if (includedWindowsPtr) {
        *includedWindowsPtr = includedWindows;
    }
    if (excludedWindowsPtr) {
        *excludedWindowsPtr = excludedWindows;
    }
}

@end

@interface Lookin : NSObject

@end

@implementation Lookin

@end
