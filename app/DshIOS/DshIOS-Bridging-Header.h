// Objective-C the SwiftUI side needs. Keep this to headers that are free of
// Node: the addon's N-API entry is for the engine, not for the app.
#import "DshNativeCapabilities.h"
#import "DshNativeAudit.h"
#import "DshNativeBridge.h"
// alarm and weather are the capabilities whose native half is Swift: AlarmKit
// and WeatherKit have no Objective-C surface at all, so these protocols are
// what the Swift providers register against. Node-free like the rest of this list.
#import "DshAlarmBridge.h"
#import "DshWeatherBridge.h"
// The browser's native half is Swift too: it is the workbench's WKWebView.
#import "DshBrowserBridge.h"
// The engine's filesystem view (DshRoot), so the browser can turn the engine's paths into the app's
// when it saves a download or uploads a file. Plain C, no Node.
#import "root.h"
// WebRTC's echo canceller for the voice call (native/aec3): plain C in front of C++.
#import "dsh_aec3.h"

// 手机操控（native/poki-launcher）：把自己和本机配对、把开发者镜像挂上。Rust 的 C 接口，
// 只有 PhoneLink.swift 调它。镜像的下载和校验在 PokiCore 里，点按和读屏在 native/poki-phone。
#include "../../native/poki-launcher/include/poki_launcher.h"
// native/ios-native/caps_phone.m 交给 Swift 的两道门：镜像在不在、会话能不能开。PhoneLink
// 靠它们决定要不要去下载镜像。
FOUNDATION_EXPORT BOOL DshPhoneFrameworksAvailable(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *DshPhonePrepareSession(void);
