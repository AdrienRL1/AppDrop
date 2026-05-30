#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "CheckpointLog.h"

// Catch any uncaught Objective-C exception and log its name, reason, and
// call-stack to /var/mobile/Documents/appdrop-launch.log before the app
// terminates. On iOS 5 this is critical for diagnosing launch-time crashes
// since we don't have proper debug symbols on-device.
static void appdropUncaughtExceptionHandler(NSException *e) {
    NSString *callStack = @"(unavailable)";
    @try {
        NSArray *frames = [e callStackSymbols];
        if (frames.count) {
            callStack = [frames componentsJoinedByString:@"\n"];
        }
    } @catch (__unused id err) {}
    NSString *line = [NSString stringWithFormat:
        @"!!! UNCAUGHT %@ : %@\nuserInfo=%@\nstack:\n%@",
        e.name, e.reason, e.userInfo, callStack];
    CPLog(line);
}

int main(int argc, char *argv[]) {
    NSSetUncaughtExceptionHandler(appdropUncaughtExceptionHandler);
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
