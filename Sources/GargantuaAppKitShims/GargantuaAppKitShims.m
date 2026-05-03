#import "GargantuaAppKitShims.h"

#import <Foundation/Foundation.h>
#import <objc/message.h>

bool GargantuaSetNativeToolTipDelay(double seconds) {
    if (seconds < 0) {
        seconds = 0;
    }

    @try {
        Class managerClass = NSClassFromString(@"NSToolTipManager");
        SEL sharedSelector = NSSelectorFromString(@"sharedToolTipManager");

        if (managerClass == Nil || ![managerClass respondsToSelector:sharedSelector]) {
            return false;
        }

        id (*sendShared)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id manager = sendShared((id)managerClass, sharedSelector);

        SEL delaySelector = NSSelectorFromString(@"setInitialToolTipDelay:");
        if (manager == nil || ![manager respondsToSelector:delaySelector]) {
            return false;
        }

        void (*sendDelay)(id, SEL, double) = (void (*)(id, SEL, double))objc_msgSend;
        sendDelay(manager, delaySelector, seconds);

        return true;
    } @catch (NSException *exception) {
        return false;
    }
}
