#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, EVMBiometryKind) {
    EVMBiometryKindUnavailable = 0,
    EVMBiometryKindFaceID = 1,
    EVMBiometryKindTouchID = 2,
    EVMBiometryKindOpticID = 3,
    EVMBiometryKindGeneric = 4
};

typedef NS_ENUM(NSInteger, EVMBiometricAuthenticationResult) {
    EVMBiometricAuthenticationResultSucceeded = 0,
    EVMBiometricAuthenticationResultCancelled = 1,
    EVMBiometricAuthenticationResultUnavailable = 2,
    EVMBiometricAuthenticationResultFailed = 3,
    EVMBiometricAuthenticationResultFallbackRequested = 4,
    EVMBiometricAuthenticationResultInterrupted = 5
};

@class EVMBiometricAuthenticationBridge;

@protocol EVMBiometricAuthenticationBridgeDelegate <NSObject>

- (void)biometricAuthenticationBridge:
            (EVMBiometricAuthenticationBridge *)bridge
        didCompleteWithResult:(EVMBiometricAuthenticationResult)result;

@end

@interface EVMBiometricAuthenticationBridge : NSObject

@property(nonatomic, weak, nullable)
    id<EVMBiometricAuthenticationBridgeDelegate> delegate;

+ (EVMBiometryKind)availableBiometryKind;
+ (BOOL)isDeviceOwnerAuthenticationAvailable;

- (void)startAuthenticationWithReason:(NSString *)reason
                        fallbackTitle:(NSString *)fallbackTitle
                          cancelTitle:(NSString *)cancelTitle;
- (void)startDeviceOwnerAuthenticationWithReason:(NSString *)reason
                                      cancelTitle:(NSString *)cancelTitle;
- (void)cancelAuthentication;

@end

NS_ASSUME_NONNULL_END
