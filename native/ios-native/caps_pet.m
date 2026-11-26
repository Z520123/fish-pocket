// The desk pet: a word to the app's own mascot, nothing more.
//
// Nothing is drawn here — the pet is a SwiftUI view, and its state lives in
// Swift (`PetBus`). This capability only turns an operation into a notification
// the app listens for, so the agent can make the pet react without going near
// the UI: no user data, no permission, no file, and nothing to audit beyond the
// action's name.
#import "dsh_ios_native.h"
#import <Foundation/Foundation.h>

void dsh_native_pet(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if (![op isEqualToString:@"react"]) {
    reply(nil, [NSString stringWithFormat:@"pet has no operation '%@'", op]);
    return;
  }
  NSString *action = [args[@"action"] isKindOfClass:NSString.class] ? args[@"action"] : nil;
  if (action.length == 0) {
    reply(nil, @"pet_react needs `action`");
    return;
  }
  NSString *text = [args[@"text"] isKindOfClass:NSString.class] ? args[@"text"] : @"";
  // Clamped here, not in Swift: a caller asking for an hour would leave the pet
  // stuck on one expression long after the conversation moved on.
  double asked = [args[@"seconds"] isKindOfClass:NSNumber.class] ? [args[@"seconds"] doubleValue] : 3.0;
  NSNumber *seconds = @(MIN(MAX(asked, 0.5), 30.0));
  // Posted straight away: the observer subscribes on the main queue, and
  // NotificationCenter is safe to post to from Node's thread.
  [NSNotificationCenter.defaultCenter postNotificationName:@"DshPetAction"
                                                    object:nil
                                                  userInfo:@{@"action": action,
                                                             @"text": text,
                                                             @"seconds": seconds}];
  reply(@{@"ok": @YES, @"action": action, @"seconds": seconds}, nil);
}
