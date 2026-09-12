import Foundation
import CoreFoundation
import Darwin

// MARK: - Private IOReport entry points loaded via dlopen
//
// IOReport is a stable but private framework. It cannot be link-resolved under
// Command Line Tools because the SDK doesn't ship its .tbd file, so we open
// the live system framework with dlopen and resolve each entry point at runtime.
// Signatures are resolved at runtime because the SDK does not ship the stub.

nonisolated(unsafe) private let ioreportHandle: UnsafeMutableRawPointer? = dlopen(
    "/System/Library/PrivateFrameworks/IOReport.framework/IOReport",
    RTLD_LAZY
)

private func loadSymbol<T>(_ name: String, as type: T.Type = T.self) -> T? {
    guard let handle = ioreportHandle, let sym = dlsym(handle, name) else { return nil }
    return unsafeBitCast(sym, to: type)
}

// MARK: - Function pointer types

typealias IOReportCopyChannelsInGroup_t = @convention(c) (
    CFString?, CFString?, UInt64, UInt64, UInt64
) -> Unmanaged<CFMutableDictionary>?

typealias IOReportCreateSubscription_t = @convention(c) (
    UnsafeRawPointer?,
    CFMutableDictionary,
    UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
    UInt64,
    CFTypeRef?
) -> Unmanaged<CFTypeRef>?

typealias IOReportCreateSamples_t = @convention(c) (
    CFTypeRef, CFMutableDictionary, CFTypeRef?
) -> Unmanaged<CFDictionary>?

typealias IOReportCreateSamplesDelta_t = @convention(c) (
    CFDictionary, CFDictionary, CFTypeRef?
) -> Unmanaged<CFDictionary>?

typealias IOReportSimpleGetIntegerValue_t = @convention(c) (CFDictionary, Int32) -> Int64

typealias IOReportChannelGetGroup_t = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
typealias IOReportChannelGetSubGroup_t = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
typealias IOReportChannelGetChannelName_t = @convention(c) (CFDictionary) -> Unmanaged<CFString>?

typealias IOReportIterateBlock = @convention(block) (CFDictionary) -> Int32
typealias IOReportIterate_t = @convention(c) (CFDictionary, IOReportIterateBlock) -> Int32

// MARK: - Resolved symbols

let IOReport_CopyChannelsInGroup: IOReportCopyChannelsInGroup_t? =
    loadSymbol("IOReportCopyChannelsInGroup")
let IOReport_CreateSubscription: IOReportCreateSubscription_t? =
    loadSymbol("IOReportCreateSubscription")
let IOReport_CreateSamples: IOReportCreateSamples_t? =
    loadSymbol("IOReportCreateSamples")
let IOReport_CreateSamplesDelta: IOReportCreateSamplesDelta_t? =
    loadSymbol("IOReportCreateSamplesDelta")
let IOReport_SimpleGetIntegerValue: IOReportSimpleGetIntegerValue_t? =
    loadSymbol("IOReportSimpleGetIntegerValue")
let IOReport_ChannelGetGroup: IOReportChannelGetGroup_t? =
    loadSymbol("IOReportChannelGetGroup")
let IOReport_ChannelGetSubGroup: IOReportChannelGetSubGroup_t? =
    loadSymbol("IOReportChannelGetSubGroup")
let IOReport_ChannelGetChannelName: IOReportChannelGetChannelName_t? =
    loadSymbol("IOReportChannelGetChannelName")
let IOReport_Iterate: IOReportIterate_t? =
    loadSymbol("IOReportIterate")

/// True if all required IOReport symbols resolved at startup.
public var ioReportAvailable: Bool {
    return IOReport_CopyChannelsInGroup != nil
        && IOReport_CreateSubscription != nil
        && IOReport_CreateSamples != nil
        && IOReport_CreateSamplesDelta != nil
        && IOReport_SimpleGetIntegerValue != nil
        && IOReport_ChannelGetChannelName != nil
        && IOReport_Iterate != nil
}
