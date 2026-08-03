# Virtual Mac on iPad

People have dreamed of running macOS on iPad for [more](https://www.macstories.net/stories/macpad-how-i-created-the-hybrid-mac-ipad-laptop-and-tablet-that-apple-wont-make/) [than](https://github.com/khanhduytran0/MacWSBootingGuide) [a](https://khronokernel.com/apple/silicon/2021/01/17/QEMU-AS.html) [decade](https://worthdoingbadly.com/macappsios/). Today, that dream comes true. With Virtual Mac, iPad finally breaks free from iPadOS, enabling pro apps like Xcode and Terminal to run directly on device. Requires iPad Pro (M1, M2) or iPad Air (M1) running iPadOS 16 up to 16.3.1.

![Screenshot of Virtual Mac on iPad](VirtualMac/screenshots/VirtualMac.png)

Virtual Mac on iPad is a community project and is not affiliated with Dopamine, UTM, VirtualBuddy, or Apple. Contributions are welcome!

## Installation

1. [Jailbreak an iPad Pro (M1, M2) or iPad Air (M1) running iPadOS 16 up to 16.3.1](https://ios.cfw.guide/installing-dopamine-trollstore/). Choose "TrollInstallerX (16.0..." on the page to view the appropriate instructions. If jailbreak fails, switch to a different exploit in Dopamine settings.
2. Add the [https://nfzerox.github.io/cydia/](https://nfzerox.github.io/cydia/) repository in Sileo, then search and install Virtual Mac.

## Frequently Asked Questions

### Which iPad and iPadOS versions does this require?

Virtual Mac on iPad requires an iPad Pro (M1, M2) or iPad Air (M1) running iPadOS 16 up to 16.3.1. iPad Pro models with 1 TB or 2 TB of storage have 16 GB of RAM and provide the best performance and experience.

### Which versions of macOS does this support?

Virtual Mac on iPad is compatible with macOS 12 Monterey up to macOS 27 Golden Gate. macOS 13 Ventura up to macOS 15 Sequoia are the recommended versions to install. Because signing into iCloud or Apple Account is not supported, choose Set Up Later when asked. Support for macOS 26 Tahoe and macOS 27 Golden Gate is experimental, and you may encounter visual or performance issues.

To use Xcode in Virtual Mac on iPad, download [Xcode 26.3](https://developer.apple.com/services-account/download?path=/Developer_Tools/Xcode_26.3/Xcode_26.3_Apple_silicon.xip) for macOS 15 Sequoia, [Xcode 16.2](https://developer.apple.com/services-account/download?path=/Developer_Tools/Xcode_16.2/Xcode_16.2.xip) for macOS 14 Sonoma, [Xcode 15.2](https://developer.apple.com/services-account/download?path=/Developer_Tools/Xcode_15.2/Xcode_15.2.xip) for macOS 13 Ventura, and [Xcode 14.2](https://developer.apple.com/services-account/download?path=/Developer_Tools/Xcode_14.2/Xcode_14.2.xip) for macOS 12 Monterey.

### Do I need a Magic Keyboard?

Magic Keyboard is not required, but is recommended for the best experience. If you don't have a Magic Keyboard, you can use the touchscreen and virtual keyboard instead:

- To select a menu item, tap and drag.
- To open a document or folder, tap it, then press Command + O using the virtual keyboard.
- To make scrolling easier, go to System Settings > Appearance > Show Scroll Bars and set it to Always.
- To access the virtual keyboard, tap the keyboard icon. If the virtual keyboard gets in the way, press and hold the bottom-right icon to switch to Floating mode.
- If the HUD gets in the way, move it to a different corner or hide it from the More menu. To show it again, press and hold the Virtual Mac icon on the iPad Home Screen, then tap Show Virtual Mac Controls.
- To automatically start up your virtual Mac, enable System Settings > Users & Groups > Automatically log in, and set System Settings > Lock Screen to Never. Then in Virtual Mac's in app Settings, change Start on Launch from Show Library to the name of your virtual Mac. To show library again, press and hold the Virtual Mac icon on the iPad Home Screen, then tap Show Library.

### Is it possible to support additional versions of iPadOS?

Supporting iPadOS 16.4 or later presents additional challenges because [Hypervisor support was removed from the iPadOS XNU kernel](https://x.com/UTMapp/status/1708907045314035986). Adding support for iPadOS 15 should be relatively straightforward. Contributions toward either goal are welcome!

### What kind of performance does Virtual Mac on iPad offer?

Virtual Mac on iPad uses hardware CPU virtualization and supports graphics acceleration, providing excellent performance for everyday tasks. Because it uses an extracted and modified version of Apple's macOS virtualization stack, it provides roughly the same class of CPU and GPU performance as VirtualBuddy or UTM virtualizing macOS on an M1 or M2 Mac.

### What if I encounter crashes, bugs, or other issues?

[Open a GitHub issue](https://github.com/nfzerox/VirtualMacOniPad/issues) when you encounter a crash, bug, or other problem. Include clear reproduction steps, a screenshot or screen recording, and the corresponding crash log from Settings > Privacy & Security > Analytics & Improvements > Analytics Data.

If you have access to Codex or Claude Code, you can also point it to this repository and ask it to diagnose and fix the issue. If you find a solution, please update the issue or open a pull request. Contributions are welcome!

## Technical Overview

Creating Virtual Mac on iPad begins with extracting Hypervisor, Virtualization, ParavirtualizedGraphics, and supporting frameworks from macOS. Because dyld shared cache creation is a one way optimization process, extractions are lossy and can't be loaded directly.

To fix this, [`uncache.py`](VirtualMac/vz/uncache.py) makes these extracted arm64e libraries loadable. It walks the cache's slide information, separates in image rebases from cross image binds, resolves their symbols and source images, lays out the Mach-O segments again, and emits new chained pointer fixups while preserving pointer authentication metadata.

The pipeline then rebuilds GOT and authenticated GOT slots, rewrites cross segment PC relative references, repairs Objective-C selectors, protocols, relative method lists, and exports, adds a new chained fixups load command, [restamps the platform to iOS](VirtualMac/vz/stamp_ios.py), and [shims](VirtualMac/vz/host/NSViewShim.m) [many](VirtualMac/vz/host/metalshim.m) [missing](VirtualMac/vz/host/vmmhook.m) [API](VirtualMac/vz/host/vzxpchook.m) expected by these frameworks.

To install macOS into the virtual machine, macOS normally connects to the virtual machine's DFU device through the AppleUSBUserHCI kernel service, which is absent from iPadOS. To bridge this gap, [`installation_usb_shim.m`](VirtualMac/vz/host/installation_usb_shim.m) reconstructs its controller path in userspace and forwards virtual USB endpoint traffic to the matching MobileDevice and usbmuxd components.

## Credits

This project would not be possible without years of prior research by talented developers. The culmination of the following community projects, combined with recent advances in agentic coding, made Virtual Mac on iPad possible:

[dsce](https://github.com/moraea/dsce) proved that loadable x86_64 framework libraries could be extracted from the dyld shared cache. [DyldExtractor](https://github.com/arandomdev/dyldextractor) formed the basis of our [first ever loadable arm64e framework extractor](VirtualMac/vz/uncache.py). [MacWSBootingGuide](https://github.com/khanhduytran0/MacWSBootingGuide) and [iOS-run-macOS-executables-tools](https://worthdoingbadly.com/macappsios/) proved that macOS system frameworks could be restamped and patched to work on iPadOS.

[HvDecompile](https://worthdoingbadly.com/hv/) and [UTM](https://github.com/utmapp/UTM) laid the groundwork for running Windows and Linux VMs with full Hypervisor performance on iPad, while [reims-vgpu](https://github.com/steelbrain/reims-vgpu) proved that accelerated macOS guests on a foreign host were possible with paravirtualized graphics acceleration. [ipsw](https://github.com/blacktop/ipsw) provides essential firmware and dyld shared cache analysis tools, and [VirtualBuddy](https://github.com/insidegui/VirtualBuddy) provides an invaluable reference for Apple's macOS virtualization and restore APIs.
