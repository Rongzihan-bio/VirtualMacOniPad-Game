#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

BOOL VZInstallNativeBCTextureSupport(void);
BOOL VZNativeBCTextureSupportInstalled(void);
BOOL VZIsBCPixelFormat(MTLPixelFormat format);
MTLPixelFormat VZBCValidationSurrogate(MTLPixelFormat format);
