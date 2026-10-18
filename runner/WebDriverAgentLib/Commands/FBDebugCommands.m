/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBDebugCommands.h"

#import "FBRouteRequest.h"
#import "FBSession.h"
#import "FBXMLGenerationOptions.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIElement+FBUtilities.h"
#import "FBXPath.h"

@implementation FBDebugCommands

#pragma mark - <FBCommandHandler>

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/source"] respondWithTarget:self action:@selector(handleGetSourceCommand:)],
    [[FBRoute GET:@"/source"].withoutSession respondWithTarget:self action:@selector(handleGetSourceCommand:)],
    [[FBRoute GET:@"/wda/accessibleSource"] respondWithTarget:self action:@selector(handleGetAccessibleSourceCommand:)],
    [[FBRoute GET:@"/wda/accessibleSource"].withoutSession respondWithTarget:self action:@selector(handleGetAccessibleSourceCommand:)],
  ];
}


#pragma mark - Commands

static NSString *const SOURCE_FORMAT_XML = @"xml";
static NSString *const SOURCE_FORMAT_JSON = @"json";
static NSString *const SOURCE_FORMAT_DESCRIPTION = @"description";

+ (id<FBResponsePayload>)handleGetSourceCommand:(FBRouteRequest *)request
{
  // This method might be called without session
  XCUIApplication *application = request.session.activeApplication ?: XCUIApplication.fb_activeApplication;
  NSString *sourceType = request.parameters[@"format"] ?: SOURCE_FORMAT_XML;
  NSString *sourceScope = request.parameters[@"scope"];
  id result;
  if ([sourceType caseInsensitiveCompare:SOURCE_FORMAT_XML] == NSOrderedSame) {
    NSArray<NSString *> *excludedAttributes = nil == request.parameters[@"excluded_attributes"]
      ? nil
      : [request.parameters[@"excluded_attributes"] componentsSeparatedByString:@","];
    result = [application fb_xmlRepresentationWithOptions:
        [[[FBXMLGenerationOptions new]
          withExcludedAttributes:excludedAttributes]
         withScope:sourceScope]];
  } else if ([sourceType caseInsensitiveCompare:SOURCE_FORMAT_JSON] == NSOrderedSame) {
    NSString *excludedAttributesString = request.parameters[@"excluded_attributes"];
    NSSet<NSString *> *excludedAttributes = (excludedAttributesString == nil)
          ? nil
          : [NSSet setWithArray:[excludedAttributesString componentsSeparatedByString:@","]];

    result = [application fb_tree:excludedAttributes];
  } else if ([sourceType caseInsensitiveCompare:SOURCE_FORMAT_DESCRIPTION] == NSOrderedSame) {
    result = application.fb_descriptionRepresentation;
  } else {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:[NSString stringWithFormat:@"Unknown source format '%@'. Only %@ source formats are supported.",
                                                                                  sourceType, @[SOURCE_FORMAT_XML, SOURCE_FORMAT_JSON, SOURCE_FORMAT_DESCRIPTION]] traceback:nil]);
  }
  if (nil == result) {
    return FBResponseWithUnknownErrorFormat(@"Cannot get '%@' source of the current application", sourceType);
  }
  return FBResponseWithObject(result);
}

+ (id<FBResponsePayload>)handleGetAccessibleSourceCommand:(FBRouteRequest *)request
{
  // This method might be called without session
  XCUIApplication *application = request.session.activeApplication ?: XCUIApplication.fb_activeApplication;
  return FBResponseWithObject(application.fb_accessibilityTree ?: @{});
}

@end


#pragma mark - Hermes compact observation (local addition, not part of upstream WebDriverAgent 16.15.3)

#import <math.h>
#import <time.h>
#import <CommonCrypto/CommonDigest.h>
#import "FBConfiguration.h"
#import "FBMacros.h"
#import "FBMathUtils.h"
#import "FBXCAccessibilityElement.h"
#import "FBXCElementSnapshot.h"
#import "FBXCElementSnapshotWrapper.h"
#import "XCUIApplication.h" // private header: processID, interfaceOrientation (as FBCustomCommands.m/FBOrientationCommands.m)
#import "XCUIElement+FBWebDriverAttributes.h"

/*
 GET /session/:sessionID/hermes/observation[?max_nodes=N][&bind=1[&expected_bundle_id=B]]

 One `fb_standardSnapshot` of the session's active application (the snapshot call `/source` and `fb_tree:` also use),
 after the same idle wait, projected straight into a flat pre-order node list. No libxml, no `fb_tree`
 dictionary, no element cache. Per node only snapshot-backed fields are read (type, name, label, value, enabled,
 visible, frame); `accessible`, `index`, `hittable`, `traits` and `placeholderValue` are never requested.
 The walk is bounded by `max_nodes`; stopping early is reported as `truncated`, never silent.
 A snapshot failure still raises through WDA's exception handler, exactly as for `/source`.
 Element text is never logged.
 */
static NSString *const FBHermesObservationSchema = @"hermes-observation/1";
static const NSInteger FBHermesObservationEndpointVersion = 1;
static const NSUInteger FBHermesDefaultMaxNodes = 6000;
static const NSUInteger FBHermesHardMaxNodes = 20000;

@interface FBHermesObservationCommands : NSObject <FBCommandHandler>
@end

/// `screen_digest` ("s1:" + SHA-256 hex): one fingerprint of a snapshot walk, computed by this one helper in both
/// `/hermes/observation` and `/hermes/target` over the same per-node values (pre-order position of the parent, depth,
/// type, name, label, value, enabled, visible, frame) plus bundle, window and orientation. Only comparable with
/// itself: a target answer's digest is the baseline the next full observation's digest is compared against.
@interface FBHermesScreenDigest : NSObject
- (void)nodeType:(NSString *)type name:(nullable NSString *)name label:(nullable NSString *)label value:(nullable NSString *)value
         enabled:(BOOL)enabled visible:(BOOL)visible frame:(CGRect)frame parent:(NSInteger)parent depth:(NSUInteger)depth;
- (NSString *)finishWithBundle:(nullable NSString *)bundle window:(CGSize)window orientation:(nullable NSString *)orientation;
@end

@implementation FBHermesScreenDigest {
  CC_SHA256_CTX _ctx;
}
- (instancetype)init
{
  if ((self = [super init])) {
    CC_SHA256_Init(&_ctx);
  }
  return self;
}
- (void)u64:(uint64_t)v { CC_SHA256_Update(&_ctx, &v, sizeof v); }
- (void)str:(nullable NSString *)s
{
  if (nil == s) {
    [self u64:UINT64_MAX];
    return;
  }
  NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES] ?: [NSData data];
  [self u64:d.length];
  CC_SHA256_Update(&_ctx, d.bytes, (CC_LONG)d.length);
}
- (void)dbl:(double)x
{
  uint64_t b = UINT64_MAX - 1;
  if (isfinite(x)) {
    double y = (x == 0) ? 0.0 : x;  // -0 and 0 alike
    memcpy(&b, &y, sizeof b);
  }
  [self u64:b];
}
- (void)nodeType:(NSString *)type name:(NSString *)name label:(NSString *)label value:(NSString *)value
         enabled:(BOOL)enabled visible:(BOOL)visible frame:(CGRect)frame parent:(NSInteger)parent depth:(NSUInteger)depth
{
  [self u64:(uint64_t)(int64_t)parent];
  [self u64:depth];
  [self str:type]; [self str:name]; [self str:label]; [self str:value];
  [self u64:(enabled ? 1 : 0) | (visible ? 2 : 0)];
  [self dbl:frame.origin.x]; [self dbl:frame.origin.y]; [self dbl:frame.size.width]; [self dbl:frame.size.height];
}
- (NSString *)finishWithBundle:(NSString *)bundle window:(CGSize)window orientation:(NSString *)orientation
{
  [self u64:UINT64_MAX - 2];
  [self str:bundle]; [self dbl:window.width]; [self dbl:window.height]; [self str:orientation];
  unsigned char md[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(md, &_ctx);
  NSMutableString *hex = [NSMutableString stringWithString:@"s1:"];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
    [hex appendFormat:@"%02x", md[i]];
  }
  return hex.copy;
}
@end

@implementation FBHermesObservationCommands

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/hermes/observation"] respondWithTarget:self action:@selector(handleGetObservation:)],
    [[FBRoute POST:@"/hermes/target"] respondWithTarget:self action:@selector(handlePostTarget:)],
  ];
}

/// Monotonic (CLOCK_UPTIME_RAW) nanoseconds, for stage durations only; never compared across processes.
static uint64_t FBHermesMonoNs(void)
{
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

/// Milliseconds between two FBHermesMonoNs readings, rounded to 0.1 ms.
static NSNumber *FBHermesSpanMs(uint64_t from, uint64_t to)
{
  return @(round((double)(to - from) / 1e5) / 10.0);
}

static NSNumber *FBHermesNowMs(void)
{
  return @((long long)llround(NSDate.date.timeIntervalSince1970 * 1000.0));
}

/// The value as a string that is safe to serialize: lossless when possible, otherwise an explicit lossy copy that is
/// counted in `lossy`, so one bad string (for example an unpaired surrogate) neither aborts the body nor vanishes.
+ (nullable NSString *)hermesString:(nullable id)value lossy:(NSUInteger *)lossy
{
  if (nil == value || [value isKindOfClass:NSNull.class]) {
    return nil;
  }
  NSString *s = [value isKindOfClass:NSString.class]
    ? (NSString *)value
    : ([value respondsToSelector:@selector(stringValue)] ? [value stringValue] : [value description]);
  if (NULL != [s UTF8String] && [s canBeConvertedToEncoding:NSUTF8StringEncoding]) {
    return s;
  }
  *lossy += 1;
  NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
  NSString *copy = nil == data ? nil : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return copy ?: @"";
}

/// Same values `GET /orientation` answers (`FBOrientationCommands` maps upside down to PORTRAIT and both
/// landscapes to LANDSCAPE); anything else is null so the client refuses it.
+ (id)hermesOrientation:(XCUIApplication *)application
{
#if TARGET_OS_TV
  return NSNull.null;
#else
  switch (application.interfaceOrientation) {
    case UIInterfaceOrientationPortrait:
    case UIInterfaceOrientationPortraitUpsideDown:
      return @"PORTRAIT";
    case UIInterfaceOrientationLandscapeLeft:
    case UIInterfaceOrientationLandscapeRight:
      return @"LANDSCAPE";
    default:
      return NSNull.null;
  }
#endif
}

/// `bind=1` (endpoint version 2, `hermes-observation/2`): the identity the client used to read separately
/// (`activeAppInfo`/`apps/state` before and after, `/window/size`, `/orientation`) is read here, around the one
/// snapshot, and checked here. Bundle, pid and orientation of the session's active application are read before and
/// after the snapshot; with `expected_bundle_id` that app must be the one in front, running foreground, both times.
/// Any difference is refused (`identity.refused`) and no node is returned, so nothing from a changed screen is usable.
/// Window and orientation come from this snapshot's root and from these reads, never from an older request.
static NSString *const FBHermesBoundObservationSchema = @"hermes-observation/2";
static const NSInteger FBHermesBoundEndpointVersion = 2;

+ (NSDictionary *)hermesIdentity:(FBRouteRequest *)request expected:(nullable NSString *)expected
{
  XCUIApplication *app = request.session.activeApplication ?: XCUIApplication.fb_activeApplication;
  NSUInteger unusedLossy = 0;
  NSMutableDictionary *identity = [@{
    @"bundle_id": FBValueOrNull([self hermesString:app.bundleID lossy:&unusedLossy]),
    @"pid": @(app.processID),
    @"orientation": [self hermesOrientation:app],
  } mutableCopy];
  if (nil != expected) {
    identity[@"expected_state"] = @([request.session applicationStateWithBundleId:expected]);
  }
  return identity.copy;
}

/// nil when `before` and `after` show the same app (and the expected one, running foreground) in one orientation.
+ (nullable NSString *)hermesRefusalBefore:(NSDictionary *)before after:(nullable NSDictionary *)after expected:(nullable NSString *)expected
{
  if (nil != expected) {
    if (![before[@"bundle_id"] isEqual:expected]) {
      return @"foreground_mismatch";
    }
    if ([before[@"expected_state"] integerValue] != XCUIApplicationStateRunningForeground) {
      return @"target_not_foreground_before";
    }
  }
  if (nil == after) {
    return nil;
  }
  if (nil != expected && [after[@"expected_state"] integerValue] != XCUIApplicationStateRunningForeground) {
    return @"target_not_foreground_after";
  }
  if (![before[@"bundle_id"] isEqual:after[@"bundle_id"]] || ![before[@"pid"] isEqual:after[@"pid"]]) {
    return @"foreground_changed_during_observation";
  }
  if (![before[@"orientation"] isEqual:after[@"orientation"]]) {
    return @"orientation_changed_during_observation";
  }
  return nil;
}

+ (id<FBResponsePayload>)handleGetObservation:(FBRouteRequest *)request
{
  NSUInteger maxNodes = FBHermesDefaultMaxNodes;
  id maxNodesParam = request.parameters[@"max_nodes"];
  if (nil != maxNodesParam) {
    NSInteger n = [[maxNodesParam description] integerValue];
    if (n < 1 || (NSUInteger)n > FBHermesHardMaxNodes) {
      NSString *message = [NSString stringWithFormat:@"max_nodes must be within 1..%lu", (unsigned long)FBHermesHardMaxNodes];
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:message traceback:nil]);
    }
    maxNodes = (NSUInteger)n;
  }
  BOOL bind = nil != request.parameters[@"bind"];
  id expectedParam = request.parameters[@"expected_bundle_id"];
  if (nil != expectedParam && (!bind || ![expectedParam isKindOfClass:NSString.class] || 0 == [expectedParam length])) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"expected_bundle_id must be a non-empty string and needs bind=1" traceback:nil]);
  }
  NSString *expected = expectedParam;
  uint64_t monoStart = FBHermesMonoNs();
  NSDictionary *before = bind ? [self hermesIdentity:request expected:expected] : nil;
  uint64_t monoIdentityBefore = FBHermesMonoNs();
  NSString *refused = bind ? [self hermesRefusalBefore:before after:nil expected:expected] : nil;
  if (nil != refused) {
    // Not the expected app in front: no snapshot is taken at all.
    return FBResponseWithObject(@{
      @"schema": FBHermesBoundObservationSchema,
      @"runner": @{@"endpoint": @"hermes/observation", @"endpoint_version": @(FBHermesBoundEndpointVersion)},
      @"identity": @{@"expected_bundle_id": FBValueOrNull(expected), @"before": before, @"after": NSNull.null,
                     @"stable": @NO, @"refused": refused},
      @"node_count": @0,
      @"nodes": @[],
    });
  }

  XCUIApplication *application = request.session.activeApplication ?: XCUIApplication.fb_activeApplication;
  NSNumber *startedMs = FBHermesNowMs();
  // The same idle wait `/source` XML does first (`FBXPath waitUntilStableWithElement:`).
  [application fb_waitUntilStableWithTimeout:FBConfiguration.sharedInstance.animationCoolOffTimeout];
  uint64_t monoIdle = FBHermesMonoNs();
  NSNumber *snapshotStartedMs = FBHermesNowMs();
  id<FBXCElementSnapshot> root = [application fb_standardSnapshot];
  NSNumber *snapshotFinishedMs = FBHermesNowMs();
  uint64_t monoSnapshot = FBHermesMonoNs();
  if (nil == root) {
    return FBResponseWithUnknownErrorFormat(@"hermes_observation: snapshot_nil");
  }

  NSMutableArray<NSDictionary *> *nodes = [NSMutableArray array];
  FBHermesScreenDigest *screenDigest = [FBHermesScreenDigest new];
  NSMutableArray<NSArray *> *pending = [NSMutableArray arrayWithObject:@[root, @(-1), @0]];
  NSUInteger lossyStrings = 0;
  NSUInteger nonFiniteRects = 0;
  NSUInteger maxDepthSeen = 0;
  BOOL truncated = NO;
  while (pending.count > 0) {
    if (nodes.count >= maxNodes) {
      truncated = YES;
      break;
    }
    NSArray *entry = pending.lastObject;
    [pending removeLastObject];
    @autoreleasepool {
      id<FBXCElementSnapshot> snapshot = entry[0];
      NSUInteger depth = [entry[2] unsignedIntegerValue];
      maxDepthSeen = MAX(maxDepthSeen, depth);
      FBXCElementSnapshotWrapper *wrapped = [FBXCElementSnapshotWrapper ensureWrapped:snapshot];
      NSUInteger nodeLossy = 0;
      NSMutableDictionary *node = [NSMutableDictionary dictionary];
      NSInteger nodeId = (NSInteger)nodes.count;
      node[@"id"] = @(nodeId);
      node[@"parent"] = entry[1];
      node[@"depth"] = @(depth);
      node[@"type"] = [self hermesString:wrapped.wdType lossy:&nodeLossy] ?: @"";
      NSString *name = [self hermesString:wrapped.wdName lossy:&nodeLossy];
      NSString *label = [self hermesString:wrapped.wdLabel lossy:&nodeLossy];
      NSString *value = [self hermesString:wrapped.wdValue lossy:&nodeLossy];
      if (nil != name) node[@"name"] = name;
      if (nil != label) node[@"label"] = label;
      if (nil != value) node[@"value"] = value;
      node[@"enabled"] = @(wrapped.isWDEnabled);
      node[@"visible"] = @(wrapped.isWDVisible);
      CGRect frame = wrapped.wdFrame;
      if (isfinite(frame.origin.x) && isfinite(frame.origin.y) && isfinite(frame.size.width) && isfinite(frame.size.height)) {
        node[@"rect"] = @[@(CGRectGetMinX(frame)), @(CGRectGetMinY(frame)), @(CGRectGetWidth(frame)), @(CGRectGetHeight(frame))];
      } else {
        node[@"rect"] = NSNull.null;
        nonFiniteRects += 1;
      }
      if (nodeLossy > 0) {
        node[@"lossy_strings"] = @(nodeLossy);
        lossyStrings += nodeLossy;
      }
      [screenDigest nodeType:node[@"type"] name:name label:label value:value enabled:wrapped.isWDEnabled
                     visible:wrapped.isWDVisible frame:frame parent:[entry[1] integerValue] depth:depth];
      [nodes addObject:node.copy];
      NSArray<id<FBXCElementSnapshot>> *children = snapshot.children;
      for (NSInteger i = (NSInteger)children.count - 1; i >= 0; i--) {
        [pending addObject:@[children[(NSUInteger)i], @(nodeId), @(depth + 1)]];
      }
    }
  }

  uint64_t monoProjection = FBHermesMonoNs();
  FBXCElementSnapshotWrapper *wrappedRoot = [FBXCElementSnapshotWrapper ensureWrapped:root];
  CGRect rootFrame = wrappedRoot.wdFrame;
#if TARGET_OS_TV || TARGET_OS_WATCH
  CGSize windowSize = rootFrame.size;
#else
  CGSize windowSize = FBAdjustDimensionsForApplication(rootFrame.size, application.interfaceOrientation);
#endif
  NSBundle *lib = [NSBundle bundleForClass:self];
  NSUInteger unusedLossy = 0;
  id orientationValue = [self hermesOrientation:application];
  // Only for a complete walk: a truncated tree has no fingerprint.
  id observationDigest = truncated ? NSNull.null
    : [screenDigest finishWithBundle:[self hermesString:application.bundleID lossy:&unusedLossy] window:windowSize
                         orientation:[orientationValue isKindOfClass:NSString.class] ? orientationValue : nil];
  NSMutableDictionary *result = [@{
    @"schema": FBHermesObservationSchema,
    @"observation_id": NSUUID.UUID.UUIDString,
    @"runner": @{
      @"endpoint": @"hermes/observation",
      @"endpoint_version": @(FBHermesObservationEndpointVersion),
      @"wda_version": FBValueOrNull(lib.infoDictionary[@"CFBundleShortVersionString"]),
      @"runner_bundle_id": FBValueOrNull(NSBundle.mainBundle.bundleIdentifier),
    },
    @"app": @{
      @"bundle_id": FBValueOrNull([self hermesString:application.bundleID lossy:&unusedLossy]),
      @"pid": @(application.processID),
      @"root_pid": @([root.accessibilityElement processIdentifier]),
    },
    @"window": (isfinite(windowSize.width) && isfinite(windowSize.height))
      ? @{@"width": @(windowSize.width), @"height": @(windowSize.height)}
      : NSNull.null,
    @"orientation": [self hermesOrientation:application],
    @"attributes": @[@"type", @"name", @"label", @"value", @"enabled", @"visible", @"rect"],
    @"limits": @{
      @"max_nodes": @(maxNodes),
      @"snapshot_max_depth": @(FBConfiguration.sharedInstance.snapshotMaxDepth),
    },
    @"max_depth_seen": @(maxDepthSeen),
    @"truncated": @(truncated),
    @"screen_digest": observationDigest,
    @"node_count": @(nodes.count),
    @"lossy_strings": @(lossyStrings),
    @"nonfinite_rects": @(nonFiniteRects),
    @"started_unix_ms": startedMs,
    @"snapshot_started_unix_ms": snapshotStartedMs,
    @"snapshot_finished_unix_ms": snapshotFinishedMs,
    @"nodes": nodes,
  } mutableCopy];
  if (truncated) {
    result[@"truncation"] = @{@"reason": @"max_nodes", @"pending_subtrees": @(pending.count)};
  }
  NSMutableDictionary *timings = [@{
    @"clock": @"monotonic_uptime_raw",
    @"identity_before": FBHermesSpanMs(monoStart, monoIdentityBefore),
    @"idle_wait": FBHermesSpanMs(monoIdentityBefore, monoIdle),
    @"snapshot": FBHermesSpanMs(monoIdle, monoSnapshot),
    @"projection": FBHermesSpanMs(monoSnapshot, monoProjection),
  } mutableCopy];
  if (bind) {
    uint64_t monoAfterStart = FBHermesMonoNs();
    NSDictionary *after = [self hermesIdentity:request expected:expected];
    timings[@"identity_after"] = FBHermesSpanMs(monoAfterStart, FBHermesMonoNs());
    refused = [self hermesRefusalBefore:before after:after expected:expected];
    // The snapshot's own application must be the identity read around it.
    NSDictionary *snapshotApp = result[@"app"];
    if (nil == refused && (![snapshotApp[@"bundle_id"] isEqual:before[@"bundle_id"]] || ![snapshotApp[@"pid"] isEqual:before[@"pid"]])) {
      refused = @"foreground_changed_during_observation";
    }
    result[@"schema"] = FBHermesBoundObservationSchema;
    NSMutableDictionary *runner = [result[@"runner"] mutableCopy];
    runner[@"endpoint_version"] = @(FBHermesBoundEndpointVersion);
    result[@"runner"] = runner.copy;
    result[@"orientation"] = after[@"orientation"];
    result[@"identity"] = @{@"expected_bundle_id": FBValueOrNull(expected), @"before": before, @"after": after,
                            // `@(nil == refused)` would box a C int and serialize as `1`, not `true`.
                            @"stable": (nil == refused) ? @YES : @NO, @"refused": FBValueOrNull(refused)};
    if (nil != refused) {
      // Read, but the screen changed under it: nothing of it is returned.
      result[@"nodes"] = @[];
      result[@"node_count"] = @0;
      result[@"screen_digest"] = NSNull.null;
      [result removeObjectForKey:@"truncation"];
    }
  }
  timings[@"total"] = FBHermesSpanMs(monoStart, FBHermesMonoNs());
  result[@"timings_ms"] = timings.copy;
  result[@"finished_unix_ms"] = FBHermesNowMs();
  return FBResponseWithObject(result.copy);
}

/*
 POST /session/:sessionID/hermes/target  (endpoint version 3, `hermes-target/1`)
 {"expected_bundle_id": B, "expected_pid": P, "expected_orientation": O, "name": N|null, "label": L|null,
  "max_matches": 1..32}

 Pre-action revalidation of one chosen target instead of a second full observation. Identity (bundle, pid,
 orientation, expected app running foreground) is read before and after and must equal the expected values the
 client took from the observation the model decided on; any difference refuses with no element data returned.
 Then ONE `fb_standardSnapshot` of the same application (the capture `/hermes/observation` uses, so `visible` and
 `rect` are computed exactly as there) is walked in-process; only elements whose wdName/wdLabel match the selector
 (same rule as the client's `TargetSelector.matches`) and keyboards are returned, in the same pre-order. No idle wait
 (`fb_waitUntilStableWithTimeout`) and no full node projection or serialization. The device-side accessibility
 capture itself is NOT reduced by this route. The client compares every match (type, strings, enabled, visible,
 rect, order) with the observation; this route decides nothing about the tap and never taps.
 Element text is never logged.
 */
static NSString *const FBHermesTargetSchema = @"hermes-target/1";
static const NSInteger FBHermesTargetEndpointVersion = 3;
static const NSUInteger FBHermesTargetDefaultMaxMatches = 16;
static const NSUInteger FBHermesTargetHardMaxMatches = 32;

+ (id<FBResponsePayload>)handlePostTarget:(FBRouteRequest *)request
{
  uint64_t monoStart = FBHermesMonoNs();
  NSDictionary *args = request.arguments;
  id expected = args[@"expected_bundle_id"], pidArg = args[@"expected_pid"], oriArg = args[@"expected_orientation"];
  id nameArg = args[@"name"], labelArg = args[@"label"], maxArg = args[@"max_matches"];
  BOOL nameOk = nil == nameArg || [nameArg isKindOfClass:NSNull.class] || [nameArg isKindOfClass:NSString.class];
  BOOL labelOk = nil == labelArg || [labelArg isKindOfClass:NSNull.class] || [labelArg isKindOfClass:NSString.class];
  NSString *name = [nameArg isKindOfClass:NSString.class] ? nameArg : nil;
  NSString *label = [labelArg isKindOfClass:NSString.class] ? labelArg : nil;
  if (![expected isKindOfClass:NSString.class] || 0 == [expected length] || ![pidArg isKindOfClass:NSNumber.class]
      || [pidArg integerValue] <= 0 || ![oriArg isKindOfClass:NSString.class] || !nameOk || !labelOk
      || (nil == name && nil == label)) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"hermes/target needs expected_bundle_id, expected_pid > 0, expected_orientation and a name and/or label string" traceback:nil]);
  }
  NSUInteger maxMatches = FBHermesTargetDefaultMaxMatches;
  if (nil != maxArg) {
    NSInteger n = [maxArg isKindOfClass:NSNumber.class] ? [maxArg integerValue] : 0;
    if (n < 1 || (NSUInteger)n > FBHermesTargetHardMaxMatches) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"max_matches must be within 1..32" traceback:nil]);
    }
    maxMatches = (NSUInteger)n;
  }
  NSDictionary *runner = @{@"endpoint": @"hermes/target", @"endpoint_version": @(FBHermesTargetEndpointVersion)};
  NSMutableDictionary *timings = [@{@"clock": @"monotonic_uptime_raw"} mutableCopy];
  NSDictionary *(^refusal)(NSDictionary *, id, NSString *) = ^NSDictionary *(NSDictionary *before, id after, NSString *why) {
    timings[@"total"] = FBHermesSpanMs(monoStart, FBHermesMonoNs());
    return @{@"schema": FBHermesTargetSchema, @"runner": runner,
             @"identity": @{@"expected_bundle_id": expected, @"expected_pid": pidArg, @"expected_orientation": oriArg,
                            @"before": before, @"after": after ?: NSNull.null, @"stable": @NO, @"refused": why},
             @"match_count": @0, @"matches": @[], @"keyboards": @[], @"timings_ms": timings.copy};
  };

  NSDictionary *before = [self hermesIdentity:request expected:expected];
  timings[@"identity_before"] = FBHermesSpanMs(monoStart, FBHermesMonoNs());
  NSString *refused = [self hermesRefusalBefore:before after:nil expected:expected];
  if (nil == refused && ![before[@"pid"] isEqual:pidArg]) {
    refused = @"process_changed";
  } else if (nil == refused && ![before[@"orientation"] isEqual:oriArg]) {
    refused = @"orientation_changed";
  }
  if (nil != refused) {
    // Not the app/process/orientation the model saw: no snapshot at all.
    return FBResponseWithObject(refusal(before, nil, refused));
  }

  XCUIApplication *application = request.session.activeApplication ?: XCUIApplication.fb_activeApplication;
  uint64_t monoSnapStart = FBHermesMonoNs();
  id<FBXCElementSnapshot> root = [application fb_standardSnapshot];
  uint64_t monoSnap = FBHermesMonoNs();
  timings[@"snapshot"] = FBHermesSpanMs(monoSnapStart, monoSnap);
  if (nil == root) {
    return FBResponseWithUnknownErrorFormat(@"hermes_target: snapshot_nil");
  }

  NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
  NSMutableArray<NSDictionary *> *keyboards = [NSMutableArray array];
  FBHermesScreenDigest *screenDigest = [FBHermesScreenDigest new];
  // Same walk as /hermes/observation (pre-order, parent position, depth) so `screen_digest` is the same function.
  NSMutableArray<NSArray *> *pending = [NSMutableArray arrayWithObject:@[root, @(-1), @0]];
  NSUInteger walked = 0, matchCount = 0, lossyStrings = 0;
  while (pending.count > 0) {
    NSArray *entry = pending.lastObject;
    [pending removeLastObject];
    @autoreleasepool {
      id<FBXCElementSnapshot> snapshot = entry[0];
      NSInteger nodeId = (NSInteger)walked;
      NSUInteger depth = [entry[2] unsignedIntegerValue];
      walked += 1;
      FBXCElementSnapshotWrapper *wrapped = [FBXCElementSnapshotWrapper ensureWrapped:snapshot];
      NSUInteger nodeLossy = 0;
      NSString *type = [self hermesString:wrapped.wdType lossy:&nodeLossy] ?: @"";
      NSString *wdName = [self hermesString:wrapped.wdName lossy:&nodeLossy];
      NSString *wdLabel = [self hermesString:wrapped.wdLabel lossy:&nodeLossy];
      NSString *wdValue = [self hermesString:wrapped.wdValue lossy:&nodeLossy];
      BOOL enabled = wrapped.isWDEnabled, visible = wrapped.isWDVisible;
      CGRect nodeFrame = wrapped.wdFrame;
      [screenDigest nodeType:type name:wdName label:wdLabel value:wdValue enabled:enabled visible:visible frame:nodeFrame
                      parent:[entry[1] integerValue] depth:depth];
      BOOL isMatch = (nil == name || [wdName isEqualToString:name]) && (nil == label || [wdLabel isEqualToString:label]);
      BOOL isKeyboard = [type isEqualToString:@"XCUIElementTypeKeyboard"];
      if (isMatch || isKeyboard) {
        CGRect frame = nodeFrame;
        id rect = (isfinite(frame.origin.x) && isfinite(frame.origin.y) && isfinite(frame.size.width) && isfinite(frame.size.height))
          ? @[@(CGRectGetMinX(frame)), @(CGRectGetMinY(frame)), @(CGRectGetWidth(frame)), @(CGRectGetHeight(frame))]
          : NSNull.null;
        if (isMatch) {
          matchCount += 1;
          lossyStrings += nodeLossy;
          if (matches.count < maxMatches) {
            NSMutableDictionary *m = [NSMutableDictionary dictionary];
            m[@"type"] = type;
            if (nil != wdName) m[@"name"] = wdName;
            if (nil != wdLabel) m[@"label"] = wdLabel;
            if (nil != wdValue) m[@"value"] = wdValue;
            m[@"enabled"] = enabled ? @YES : @NO;
            m[@"visible"] = visible ? @YES : @NO;
            m[@"rect"] = rect;
            [matches addObject:m.copy];
          }
        }
        if (isKeyboard) {
          [keyboards addObject:@{@"rect": rect, @"visible": visible ? @YES : @NO}];
        }
      }
      NSArray<id<FBXCElementSnapshot>> *children = snapshot.children;
      for (NSInteger i = (NSInteger)children.count - 1; i >= 0; i--) {
        [pending addObject:@[children[(NSUInteger)i], @(nodeId), @(depth + 1)]];
      }
    }
  }
  uint64_t monoMatch = FBHermesMonoNs();
  timings[@"match"] = FBHermesSpanMs(monoSnap, monoMatch);

  CGRect rootFrame = [FBXCElementSnapshotWrapper ensureWrapped:root].wdFrame;
#if TARGET_OS_TV || TARGET_OS_WATCH
  CGSize windowSize = rootFrame.size;
#else
  CGSize windowSize = FBAdjustDimensionsForApplication(rootFrame.size, application.interfaceOrientation);
#endif
  NSUInteger digestLossy = 0;
  id targetOrientation = [self hermesOrientation:application];
  NSString *baselineDigest = [screenDigest finishWithBundle:[self hermesString:application.bundleID lossy:&digestLossy]
                                                     window:windowSize
                                                orientation:[targetOrientation isKindOfClass:NSString.class] ? targetOrientation : nil];
  NSDictionary *after = [self hermesIdentity:request expected:expected];
  timings[@"identity_after"] = FBHermesSpanMs(monoMatch, FBHermesMonoNs());
  refused = [self hermesRefusalBefore:before after:after expected:expected];
  NSUInteger unusedLossy = 0;
  NSDictionary *app = @{
    @"bundle_id": FBValueOrNull([self hermesString:application.bundleID lossy:&unusedLossy]),
    @"pid": @(application.processID),
    @"root_pid": @([root.accessibilityElement processIdentifier]),
  };
  if (nil == refused && (![app[@"bundle_id"] isEqual:before[@"bundle_id"]] || ![app[@"pid"] isEqual:before[@"pid"]]
                         || ![app[@"root_pid"] isEqual:before[@"pid"]])) {
    refused = @"foreground_changed_during_observation";
  }
  if (nil != refused) {
    return FBResponseWithObject(refusal(before, after, refused));
  }
  timings[@"total"] = FBHermesSpanMs(monoStart, FBHermesMonoNs());
  return FBResponseWithObject(@{
    @"schema": FBHermesTargetSchema,
    @"runner": runner,
    @"identity": @{@"expected_bundle_id": expected, @"expected_pid": pidArg, @"expected_orientation": oriArg,
                   @"before": before, @"after": after, @"stable": @YES, @"refused": NSNull.null},
    @"app": app,
    @"window": (isfinite(windowSize.width) && isfinite(windowSize.height))
      ? @{@"width": @(windowSize.width), @"height": @(windowSize.height)}
      : NSNull.null,
    @"orientation": after[@"orientation"],
    @"max_matches": @(maxMatches),
    @"match_count": @(matchCount),
    @"truncated": matchCount > matches.count ? @YES : @NO,
    @"matches": matches,
    @"keyboards": keyboards,
    @"nodes_walked": @(walked),
    // Fingerprint of this fresh pre-tap snapshot: the post-tap observation's `screen_digest` is compared with it.
    @"screen_digest": baselineDigest,
    @"lossy_strings": @(lossyStrings),
    @"timings_ms": timings.copy,
  });
}

@end
