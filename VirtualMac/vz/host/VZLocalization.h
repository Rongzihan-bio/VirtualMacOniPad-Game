#import <Foundation/Foundation.h>

// Keep localization at the thin UIKit layer. Framework and compatibility
// code must never depend on the user's language or mutate host behavior.
#define VZL(key) NSLocalizedString((key), nil)
