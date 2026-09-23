#import "EVMBiometricAuthenticationBridge.h"

#import <LocalAuthentication/LocalAuthentication.h>

@interface EVMBiometricAuthenticationBridge ()

@property(nonatomic, strong, nullable) LAContext *context;

@end

@implementation EVMBiometricAuthenticationBridge

+ (EVMBiometryKind)availableBiometryKind {
    LAContext *context = [[LAContext alloc] init];
    NSError *error = nil;
    if (![context canEvaluatePolicy:
                      LAPolicyDeviceOwnerAuthenticationWithBiometrics
                                error:&error]) {
        return EVMBiometryKindUnavailable;
    }

    switch (context.biometryType) {
        case LABiometryTypeFaceID:
            return EVMBiometryKindFaceID;
        case LABiometryTypeTouchID:
            return EVMBiometryKindTouchID;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 170000
        case LABiometryTypeOpticID:
            return EVMBiometryKindOpticID;
#endif
        default:
            return EVMBiometryKindGeneric;
    }
}

+ (BOOL)isDeviceOwnerAuthenticationAvailable {
    LAContext *context = [[LAContext alloc] init];
    NSError *error = nil;
    return [context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication
                                error:&error];
}

- (void)startAuthenticationWithReason:(NSString *)reason
                        fallbackTitle:(NSString *)fallbackTitle
                          cancelTitle:(NSString *)cancelTitle {
    LAContext *context = [[LAContext alloc] init];
    context.localizedFallbackTitle = fallbackTitle;
    context.localizedCancelTitle = cancelTitle;
    self.context = context;

    NSError *availabilityError = nil;
    if (![context canEvaluatePolicy:
                      LAPolicyDeviceOwnerAuthenticationWithBiometrics
                                error:&availabilityError]) {
        [self completeWithResult:
                  EVMBiometricAuthenticationResultUnavailable];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [context
        evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
        localizedReason:reason
        reply:^(BOOL succeeded, NSError *_Nullable error) {
          EVMBiometricAuthenticationResult result =
              EVMBiometricAuthenticationResultFailed;
          if (succeeded) {
              result = EVMBiometricAuthenticationResultSucceeded;
          } else if ([error.domain isEqualToString:LAErrorDomain]) {
              switch ((LAError)error.code) {
                  case LAErrorUserCancel:
                      result =
                          EVMBiometricAuthenticationResultCancelled;
                      break;
                  case LAErrorSystemCancel:
                  case LAErrorAppCancel:
                  case LAErrorNotInteractive:
                      result =
                          EVMBiometricAuthenticationResultInterrupted;
                      break;
                  case LAErrorUserFallback:
                      result =
                          EVMBiometricAuthenticationResultFallbackRequested;
                      break;
                  case LAErrorBiometryNotAvailable:
                      result =
                          EVMBiometricAuthenticationResultUnavailable;
                      break;
                  case LAErrorBiometryNotEnrolled:
                      result =
                          EVMBiometricAuthenticationResultUnavailable;
                      break;
                  case LAErrorBiometryLockout:
                      result =
                          EVMBiometricAuthenticationResultUnavailable;
                      break;
                  case LAErrorPasscodeNotSet:
                      result =
                          EVMBiometricAuthenticationResultUnavailable;
                      break;
                  case LAErrorAuthenticationFailed:
                  case LAErrorInvalidContext:
                      break;
                  default:
                      break;
              }
          }

          dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf completeWithResult:result];
          });
        }];
}

- (void)startDeviceOwnerAuthenticationWithReason:(NSString *)reason
                                      cancelTitle:(NSString *)cancelTitle {
    LAContext *context = [[LAContext alloc] init];
    context.localizedCancelTitle = cancelTitle;
    self.context = context;

    NSError *availabilityError = nil;
    if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication
                                error:&availabilityError]) {
        [self completeWithResult:
                  EVMBiometricAuthenticationResultUnavailable];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
            localizedReason:reason
                      reply:^(BOOL succeeded, NSError *_Nullable error) {
      EVMBiometricAuthenticationResult result =
          EVMBiometricAuthenticationResultFailed;
      if (succeeded) {
          result = EVMBiometricAuthenticationResultSucceeded;
      } else if ([error.domain isEqualToString:LAErrorDomain]) {
          switch ((LAError)error.code) {
              case LAErrorUserCancel:
              case LAErrorSystemCancel:
              case LAErrorAppCancel:
              case LAErrorNotInteractive:
                  result = EVMBiometricAuthenticationResultCancelled;
                  break;
              case LAErrorBiometryNotAvailable:
              case LAErrorBiometryNotEnrolled:
              case LAErrorBiometryLockout:
              case LAErrorPasscodeNotSet:
                  result = EVMBiometricAuthenticationResultUnavailable;
                  break;
              case LAErrorAuthenticationFailed:
              case LAErrorInvalidContext:
              case LAErrorUserFallback:
                  break;
              default:
                  break;
          }
      }

      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf completeWithResult:result];
      });
        }];
}

- (void)cancelAuthentication {
    [self.context invalidate];
}

- (void)completeWithResult:(EVMBiometricAuthenticationResult)result {
    id<EVMBiometricAuthenticationBridgeDelegate> delegate = self.delegate;
    self.context = nil;
    [delegate biometricAuthenticationBridge:self
                       didCompleteWithResult:result];
}

@end
