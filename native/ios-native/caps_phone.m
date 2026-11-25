// phone: open the UI-automation session and, later, put touches on the screen.
//
// The work is Poki's (native/poki-phone, AGPL-3.0, vendored for this fork only):
// PKInProcess loads the developer frameworks a mounted DDI provides and drives
// the phone through them. This file is the capability edge — the part the agent
// is allowed to reach — so it starts with the one operation that answers a
// question instead of changing anything: can a session be opened at all?
//
// `probe` is deliberately first. Every later operation (tap, type, read,
// screenshot) is worth nothing if the frameworks are missing or the session
// cannot be opened, and those two failures look identical to "the tap did
// nothing" from the agent's side. Asking once, and reporting what came back,
// keeps that apart.
#import "dsh_ios_native.h"
#import "../poki-phone/InProcess.h"

/// Answer with what the execution layer says about itself.
///
/// `developerFrameworksAvailable` only reports whether the four developer
/// frameworks could be loaded, which is a DDI question: with no image mounted
/// the paths do not exist. `prepare` then opens a session and, on this phone,
/// waits for iOS's own allow-automation prompt, so this call can take seconds.
static void phone_probe(DshNativeReply reply) {
  PKInProcess *core = [PKInProcess shared];
  BOOL frameworks = [core developerFrameworksAvailable];
  if (!frameworks) {
    reply(@{
      @"ddi": @NO,
      @"session": @NO,
      @"reason": @"The developer frameworks are not on this phone (/System/Developer is missing), "
                   "so no automation session can be opened. Mount a developer disk image first.",
    }, nil);
    return;
  }
  NSDictionary *prepared = [core prepare];
  reply(@{@"ddi": @YES, @"session": prepared ?: @{}}, nil);
}

void dsh_native_phone(NSString *op, NSDictionary *args, DshNativeReply reply) {
  (void)args;
  if ([op isEqualToString:@"probe"]) {
    phone_probe(reply);
    return;
  }
  // Unreachable: the dispatcher checked `op` against the table first.
  reply(nil, [NSString stringWithFormat:@"phone has no operation '%@'", op]);
}
