// phone: open the UI-automation session on this phone — no Mac, no second app.
//
// Two halves meet here. The Rust launcher (native/poki-launcher) pairs the phone with
// itself and mounts the developer disk image; in the in-process mode this app uses it
// then stops short of starting a runner and leaves the image for the app to load.
// PKInProcess (native/poki-phone, Poki's execution layer) is the half that puts touches
// on the screen from the app's own process.
//
// `probe` is deliberately first and answers three questions at once, because from the
// agent's side their failures all look alike — "the tap did nothing":
//   launcher: is the Rust archive linked, does it read the config this app writes?
//   ddi:      is a developer disk image mounted (/System/Developer)?
//   session:  can an automation session be opened at all?
#import "dsh_ios_native.h"
#import "../poki-phone/InProcess.h"
#include "../poki-launcher/include/poki_launcher.h"

/// A launcher built from the config this app will use, asked for its status and freed
/// again — never started, so nothing touches the network. It proves the archive is
/// linked and that the Rust config reader agrees with the JSON written here.
///
/// Every field is spelled out: `pairing_file` has no default in the reader, and a
/// launcher that cannot be deserialized comes back NULL, which would otherwise surface
/// much later as an unrelated failure.
static NSDictionary *phone_launcher_self_test(void) {
  NSString *config = @"{"
    @"\"device_address\":\"10.7.0.1\","
    @"\"pairing_file\":\"/dev/null\","
    @"\"host_name\":\"Fish Pocket\","
    @"\"ddi_dir\":\"\","
    @"\"wda_host\":\"127.0.0.1\","
    @"\"wda_port\":8100,"
    @"\"in_process\":true"
    @"}";
  PokiLauncher *launcher = poki_launcher_new(config.UTF8String, NULL, NULL);
  if (launcher == NULL) {
    return @{@"linked": @YES, @"config": @NO};
  }
  char *raw = poki_launcher_status(launcher);
  NSString *status = raw ? [NSString stringWithUTF8String:raw] : nil;
  if (raw != NULL) {
    poki_string_free(raw);
  }
  poki_launcher_free(launcher);
  return @{@"linked": @YES, @"config": @YES, @"status": status ?: @""};
}

static void phone_probe(DshNativeReply reply) {
  NSDictionary *launcher = phone_launcher_self_test();
  if (![launcher[@"config"] boolValue]) {
    reply(@{@"launcher": launcher, @"ddi": @NO, @"session": @NO},
          @"The Rust launcher is linked but would not build from the app's config.");
    return;
  }
  PKInProcess *core = [PKInProcess shared];
  BOOL frameworks = [core developerFrameworksAvailable];
  if (!frameworks) {
    reply(@{
      @"launcher": launcher,
      @"ddi": @NO,
      @"session": @NO,
      @"reason": @"The developer frameworks are not on this phone (/System/Developer is missing), "
                   "so no automation session can be opened. Mount a developer disk image first.",
    }, nil);
    return;
  }
  // Opens a session; on this phone iOS asks for the automation allowance first, so this
  // call can take seconds.
  NSDictionary *prepared = [core prepare];
  reply(@{@"launcher": launcher, @"ddi": @YES, @"session": prepared ?: @{}}, nil);
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
