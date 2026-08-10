// iPadOS 14 still exports the URL-loading Objective-C classes from CFNetwork,
// while Ventura records Foundation as their import owner. Re-export both so
// dyld can resolve the original symbols without trampolines or interposition.
int VirtualMacFoundation14CompatAnchor;
