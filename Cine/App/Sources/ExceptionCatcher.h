#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Attrape les exceptions Objective-C (réglages refusés par AVFoundation…), que Swift ne sait pas attraper.
@interface CineException : NSObject
/// Exécute le bloc ; renvoie nil si tout va bien, sinon le nom et la raison de l'exception.
+ (nullable NSString *)catching:(NS_NOESCAPE void (^)(void))block;
@end

NS_ASSUME_NONNULL_END
