#import "ExceptionCatcher.h"

@implementation CineException

+ (nullable NSString *)catching:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@ — %@", exception.name, exception.reason ?: @""];
    }
}

@end
