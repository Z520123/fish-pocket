// phone: drive this iPhone from inside the app — no Mac, no iCTRL, no second app.
//
// Three pieces meet here:
//   · PhoneLink (app/DshIOS/PhoneLink.swift) pairs the phone with itself, downloads the
//     developer disk image and has Rust's launcher mount it;
//   · PKInProcess (native/poki-phone, Poki's execution layer) opens the XCTest session in
//     this app's own process and puts touches, text and reads through it;
//   · this file is the edge the agent reaches: one C function, one operation per call.
//
// `probe` stays first because from the agent's side every failure looks alike — "the tap
// did nothing". It answers which of the three is missing: the image, the session, or the
// launcher's reach to the phone.
#import "dsh_ios_native.h"
#import "../poki-phone/InProcess.h"
#import "DshIOS-Swift.h"

/// PKInProcess blocks on every call and one session operation should be in flight at a
/// time, so the operations of this capability take turns.
static NSLock *PhoneLock(void) {
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSLock new]; });
  return lock;
}

/// The two doors Swift needs from this file: is a developer image mounted, and can a
/// session be opened? PhoneLink asks before it decides to download anything.
BOOL DshPhoneFrameworksAvailable(void) {
  return [[PKInProcess shared] developerFrameworksAvailable];
}

NSDictionary<NSString *, id> *DshPhonePrepareSession(void) {
  return [[PKInProcess shared] prepare] ?: @{};
}

/// What the execution layer says about a dispatched event.
static NSDictionary *PhoneOutcome(PKOutcome *outcome) {
  if (outcome == nil) {
    return @{@"delivery": @0, @"code": @"no_outcome"};
  }
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  out[@"delivery"] = @(outcome.delivery);
  out[@"seconds"] = @(outcome.seconds);
  if (outcome.code.length > 0) out[@"code"] = outcome.code;
  if (outcome.detail.length > 0) out[@"detail"] = outcome.detail;
  return out;
}

/// A session has to be open before anything is dispatched; prepare reuses one it already has.
static id PhoneReady(NSDictionary **refusal) {
  NSDictionary *prepared = [[PKInProcess shared] prepare];
  if (prepared == nil) {
    *refusal = @{@"reason": @"the automation session could not be opened"};
    return nil;
  }
  if ([prepared[@"ok"] boolValue]) return prepared;
  *refusal = @{@"session": prepared,
               @"reason": @"the automation session was refused"};
  return nil;
}

static void PhoneProbe(DshNativeReply reply) {
  PKInProcess *core = [PKInProcess shared];
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  out[@"launcher"] = [[PhoneLink shared] stateJSON];
  BOOL frameworks = [core developerFrameworksAvailable];
  out[@"ddi"] = @(frameworks);
  if (!frameworks) {
    out[@"session"] = @NO;
    out[@"reason"] = @"No developer disk image is mounted (/System/Developer is missing). "
                      "Open 操控手机 → 本机操控 and connect once; it downloads the image and mounts it.";
    reply(out, nil);
    return;
  }
  // Opening a session waits for iOS's allow-automation prompt the first time, so this
  // is the slow call in the probe.
  out[@"session"] = [core prepare] ?: @{};
  reply(out, nil);
}

static void PhoneTap(NSDictionary *args, DshNativeReply reply) {
  NSDictionary *refusal = nil;
  if (PhoneReady(&refusal) == nil) { reply(refusal, nil); return; }
  double x = [args[@"x"] doubleValue];
  double y = [args[@"y"] doubleValue];
  PKTouchPoint *point = [PKTouchPoint at:CGPointMake(x, y) offset:0];
  PKOutcome *outcome = [[PKInProcess shared] touch:@[@[point]] timeout:8];
  NSMutableDictionary *out = [PhoneOutcome(outcome) mutableCopy];
  out[@"x"] = @(x);
  out[@"y"] = @(y);
  reply(out, nil);
}

static void PhoneSwipe(NSDictionary *args, DshNativeReply reply) {
  NSDictionary *refusal = nil;
  if (PhoneReady(&refusal) == nil) { reply(refusal, nil); return; }
  double x1 = [args[@"x1"] doubleValue], y1 = [args[@"y1"] doubleValue];
  double x2 = [args[@"x2"] doubleValue], y2 = [args[@"y2"] doubleValue];
  double seconds = [args[@"seconds"] doubleValue];
  if (seconds <= 0) seconds = 0.4;
  PKTouchPoint *from = [PKTouchPoint at:CGPointMake(x1, y1) offset:0];
  PKTouchPoint *to = [PKTouchPoint at:CGPointMake(x2, y2) offset:seconds];
  PKOutcome *outcome = [[PKInProcess shared] touch:@[@[from, to]] timeout:8];
  reply(PhoneOutcome(outcome), nil);
}

static void PhoneType(NSDictionary *args, DshNativeReply reply) {
  NSDictionary *refusal = nil;
  if (PhoneReady(&refusal) == nil) { reply(refusal, nil); return; }
  NSString *text = args[@"text"];
  if (![text isKindOfClass:NSString.class] || text.length == 0) {
    reply(nil, @"phone_type needs `text`");
    return;
  }
  PKOutcome *outcome = [[PKInProcess shared] type:text timeout:12];
  reply(PhoneOutcome(outcome), nil);
}

static void PhoneScreen(DshNativeReply reply) {
  NSDictionary *refusal = nil;
  if (PhoneReady(&refusal) == nil) { reply(refusal, nil); return; }
  NSDictionary *focused = nil;
  NSString *code = nil;
  // The bounds WebDriverAgent uses: a dense screen otherwise takes too long to serialize.
  NSString *xml = [[PKInProcess shared] sourceXML:&focused maxDepth:0 maxChildren:0 code:&code];
  if (xml == nil) {
    reply(@{@"code": code ?: @"no_source"}, @"the screen could not be read");
    return;
  }
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  out[@"source"] = xml;
  out[@"front"] = [[PKInProcess shared] frontApp] ?: @{};
  if (focused != nil) out[@"focused"] = focused;
  reply(out, nil);
}

static void PhoneScreenshot(DshNativeReply reply) {
  NSDictionary *refusal = nil;
  if (PhoneReady(&refusal) == nil) { reply(refusal, nil); return; }
  NSString *code = nil;
  NSData *data = [[PKInProcess shared] screenshot:&code refreshViewport:YES];
  if (data.length == 0) {
    reply(@{@"code": code ?: @"no_picture"}, @"the screen could not be captured");
    return;
  }
  NSString *name = [NSString stringWithFormat:@"phone-%lld.jpg", (long long)(NSDate.date.timeIntervalSince1970 * 1000)];
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
  [data writeToFile:path atomically:YES];
  reply(@{@"path": path, @"bytes": @(data.length)}, nil);
}

static void PhonePress(NSDictionary *args, DshNativeReply reply) {
  NSDictionary *refusal = nil;
  if (PhoneReady(&refusal) == nil) { reply(refusal, nil); return; }
  NSString *name = args[@"name"];
  NSString *why = [[PKInProcess shared] press:name];
  if (why != nil) { reply(nil, why); return; }
  reply(@{@"pressed": name}, nil);
}

static void PhoneApp(NSDictionary *args, DshNativeReply reply) {
  NSDictionary *refusal = nil;
  if (PhoneReady(&refusal) == nil) { reply(refusal, nil); return; }
  NSString *bundle = args[@"bundle"];
  NSString *action = args[@"action"] ?: @"launch";
  NSString *why = [[PKInProcess shared] app:bundle action:action];
  if (why != nil) { reply(nil, why); return; }
  reply(@{@"bundle": bundle, @"action": action}, nil);
}

void dsh_native_phone(NSString *op, NSDictionary *args, DshNativeReply reply) {
  // start and stop are the launcher's: they hand back before the work is done, so they
  // must not hold the lock the session operations take.
  if ([op isEqualToString:@"state"]) {
    reply([[PhoneLink shared] stateJSON], nil);
    return;
  }
  if ([op isEqualToString:@"start"]) {
    [[PhoneLink shared] prepareDevice:^(NSString *problem) {
      if (problem != nil) {
        reply(@{@"ok": @NO, @"detail": problem}, problem);
      } else {
        reply(@{@"ok": @YES, @"state": [[PhoneLink shared] stateJSON]}, nil);
      }
    }];
    return;
  }
  if ([op isEqualToString:@"stop"]) {
    [[PhoneLink shared] stopDevice];
    reply(@{@"ok": @YES}, nil);
    return;
  }
  if ([op isEqualToString:@"pair"]) {
    [[PhoneLink shared] startPairing];
    reply([[PhoneLink shared] stateJSON], nil);
    return;
  }

  [PhoneLock() lock];
  @try {
    if ([op isEqualToString:@"probe"]) {
      PhoneProbe(reply);
    } else if ([op isEqualToString:@"tap"]) {
      PhoneTap(args, reply);
    } else if ([op isEqualToString:@"swipe"]) {
      PhoneSwipe(args, reply);
    } else if ([op isEqualToString:@"type"]) {
      PhoneType(args, reply);
    } else if ([op isEqualToString:@"screen"]) {
      PhoneScreen(reply);
    } else if ([op isEqualToString:@"screenshot"]) {
      PhoneScreenshot(reply);
    } else if ([op isEqualToString:@"press"]) {
      PhonePress(args, reply);
    } else if ([op isEqualToString:@"app"]) {
      PhoneApp(args, reply);
    } else {
      reply(nil, [NSString stringWithFormat:@"phone has no operation '%@'", op]);
    }
  } @finally {
    [PhoneLock() unlock];
  }
}
