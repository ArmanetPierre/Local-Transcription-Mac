#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Execute un bloc et intercepte une exception Objective-C (que Swift ne sait pas attraper).
/// AVAudioEngine en leve sur des conditions recuperables (unite audio introuvable,
/// format incompatible) : sans cela, l'app plante en plein enregistrement.
/// Retourne NO et remplit `error` si une exception a ete levee.
BOOL VoxaCatchObjCException(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
