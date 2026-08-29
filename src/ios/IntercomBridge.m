#import "IntercomBridge.h"
#import "AppDelegate+IntercomPush.h"
#import "ICMHelpCenterCollection+DictionaryConversion.h"
#import "ICMHelpCenterArticleSearchResult+DictionaryConversion.h"
#import "ICMHelpCenterCollectionContent+DictionaryConversion.h"
#import "ICMUserAttributes+DictionaryConversion.h"
#import <Intercom/Intercom.h>

@interface Intercom (Cordoava)
+ (void)setCordovaVersion:(NSString *)v;
@end

static NSTimeInterval const IntercomLogoutPollInterval = 0.1;
static NSTimeInterval const IntercomLogoutMaximumWait = 0.75;
static NSUInteger const IntercomLogoutRequiredClearChecks = 3;
static NSUInteger IntercomDiagnosticOperationSequence = 0;

#ifdef DEBUG
#define INTERCOM_DIAGNOSTIC_LOG(...) NSLog(__VA_ARGS__)
#else
#define INTERCOM_DIAGNOSTIC_LOG(...)
#endif

@interface IntercomBridge ()
- (void)sendLogoutResult:(CDVInvokedUrlCommand *)command
               stabilized:(BOOL)stabilized
                 elapsed:(NSTimeInterval)elapsed
                 loggedIn:(BOOL)loggedIn
        attributesPresent:(BOOL)attributesPresent
              clearChecks:(NSUInteger)clearChecks;
- (void)waitForIntercomLogout:(CDVInvokedUrlCommand *)command
                    startedAt:(NSTimeInterval)startedAt
           consecutiveClears:(NSUInteger)consecutiveClears
                    operation:(NSUInteger)operation;
@end

@implementation IntercomBridge : CDVPlugin


#pragma mark - Intercom Initialisation

- (void)pluginInitialize {
    [Intercom setCordovaVersion:@"16.5.0"];
    #ifdef DEBUG
        [Intercom enableLogging];
    #endif

    //Get app credentials from config.xml or the info.plist if they can't be found
    NSString* apiKey = self.commandDelegate.settings[@"intercom-ios-api-key"] ?: [[NSBundle mainBundle] objectForInfoDictionaryKey:@"IntercomApiKey"];
    NSString* appId = self.commandDelegate.settings[@"intercom-app-id"] ?: [[NSBundle mainBundle] objectForInfoDictionaryKey:@"IntercomAppId"];

    [Intercom setApiKey:apiKey forAppId:appId];
    INTERCOM_DIAGNOSTIC_LOG(@"[Intercom-Cordova-Diagnostic] stage=plugin_initialized");
}

- (void)setUserHash:(CDVInvokedUrlCommand*)command {
    NSString *hmac = command.arguments[0];
    NSUInteger operation = ++IntercomDiagnosticOperationSequence;

    INTERCOM_DIAGNOSTIC_LOG(@"[Intercom-Cordova-Diagnostic] stage=set_user_hash_requested operation=%lu hashPresent=%@",
                           (unsigned long)operation,
                           hmac.length > 0 ? @"true" : @"false");
    [Intercom setUserHash:hmac];
    INTERCOM_DIAGNOSTIC_LOG(@"[Intercom-Cordova-Diagnostic] stage=set_user_hash_completed operation=%lu",
                           (unsigned long)operation);
    [self sendSuccess:command];
}

#pragma mark - User Login

- (void)loginUserWithUserAttributes:(CDVInvokedUrlCommand*)command {
    NSDictionary* options = command.arguments[0];
    NSString* userId = options[@"userId"];
    NSString* userEmail = options[@"email"];
    NSUInteger operation = ++IntercomDiagnosticOperationSequence;
    NSTimeInterval startedAt = [NSDate timeIntervalSinceReferenceDate];
    BOOL loggedInBefore = [Intercom isUserLoggedIn];
    BOOL attributesPresentBefore = [Intercom fetchLoggedInUserAttributes] != nil;

    if ([userId isKindOfClass:[NSNumber class]]) {
        userId = [(NSNumber *)userId stringValue];
    }

    ICMUserAttributes *userAttributes = [ICMUserAttributes new];
    INTERCOM_DIAGNOSTIC_LOG(@"[Intercom-Cordova-Diagnostic] stage=identified_login_requested operation=%lu loggedIn=%@ attributesPresent=%@ hasUserId=%@ hasEmail=%@",
                           (unsigned long)operation,
                           loggedInBefore ? @"true" : @"false",
                           attributesPresentBefore ? @"true" : @"false",
                           userId.length > 0 ? @"true" : @"false",
                           userEmail.length > 0 ? @"true" : @"false");
    
    if (userId.length > 0 && userEmail.length > 0) {
        userAttributes.userId = userId;
        userAttributes.email = userEmail;
    } else if (userId.length > 0) {
        userAttributes.userId = userId;
    } else if (userEmail.length > 0) {
        userAttributes.email = userEmail;
    } else {
        NSLog(@"[Intercom-Cordova] ERROR - No user registered. You must supply an email, a userId or both");
        NSError *error = [NSError errorWithDomain:@"IntercomCordovaBridge"
                                             code:1001
                                         userInfo:@{NSLocalizedDescriptionKey: @"An identified Intercom user requires an email or user ID."}];
        [self sendFailure:command withError:error];
        return;
    }
    
    [Intercom loginUserWithUserAttributes:userAttributes success:^{
        NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - startedAt;
        INTERCOM_DIAGNOSTIC_LOG(@"[Intercom-Cordova-Diagnostic] stage=identified_login_completed operation=%lu elapsedMs=%.0f",
                               (unsigned long)operation,
                               elapsed * 1000.0);
        NSLog(@"[Intercom-Cordova] INFO - Identified user login completed");
        [self sendSuccess:command];
    } failure:^(NSError * _Nonnull error) {
        NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - startedAt;
        INTERCOM_DIAGNOSTIC_LOG(@"[Intercom-Cordova-Diagnostic] stage=identified_login_failed operation=%lu elapsedMs=%.0f domain=%@ code=%ld",
                               (unsigned long)operation,
                               elapsed * 1000.0,
                               error.domain,
                               (long)error.code);
        NSLog(@"[Intercom-Cordova] ERROR - Identified user login failed: domain=%@ code=%ld", error.domain, (long)error.code);
        [self sendFailure:command withError:error];
    }];
}

- (void)loginUnidentifiedUser:(CDVInvokedUrlCommand*)command {
    [Intercom loginUnidentifiedUserWithSuccess:^{
        [self sendSuccess:command];
    } failure:^(NSError * _Nonnull error) {
        [self sendFailure:command withError:error];
    }];
}

- (void)logout:(CDVInvokedUrlCommand*)command {
    NSUInteger operation = ++IntercomDiagnosticOperationSequence;
    NSTimeInterval startedAt = [NSDate timeIntervalSinceReferenceDate];
    BOOL loggedInBefore = [Intercom isUserLoggedIn];
    BOOL attributesPresentBefore = [Intercom fetchLoggedInUserAttributes] != nil;
    INTERCOM_DIAGNOSTIC_LOG(@"[Intercom-Cordova-Diagnostic] stage=logout_requested operation=%lu loggedIn=%@ attributesPresent=%@",
                           (unsigned long)operation,
                           loggedInBefore ? @"true" : @"false",
                           attributesPresentBefore ? @"true" : @"false");
    [Intercom logout];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self waitForIntercomLogout:command
                          startedAt:startedAt
                 consecutiveClears:0
                          operation:operation];
    });
}

- (void)waitForIntercomLogout:(CDVInvokedUrlCommand *)command
                    startedAt:(NSTimeInterval)startedAt
           consecutiveClears:(NSUInteger)consecutiveClears
                    operation:(NSUInteger)operation {
    BOOL loggedIn = [Intercom isUserLoggedIn];
    BOOL attributesPresent = [Intercom fetchLoggedInUserAttributes] != nil;
    BOOL identityCleared = !loggedIn && !attributesPresent;
    NSUInteger nextConsecutiveClears = identityCleared ? consecutiveClears + 1 : 0;
    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - startedAt;
    INTERCOM_DIAGNOSTIC_LOG(@"[Intercom-Cordova-Diagnostic] stage=logout_observation operation=%lu elapsedMs=%.0f loggedIn=%@ attributesPresent=%@ clearChecks=%lu",
                           (unsigned long)operation,
                           elapsed * 1000.0,
                           loggedIn ? @"true" : @"false",
                           attributesPresent ? @"true" : @"false",
                           (unsigned long)nextConsecutiveClears);

    if (nextConsecutiveClears >= IntercomLogoutRequiredClearChecks) {
        NSLog(@"[Intercom-Cordova] INFO - Logout state stabilized after %.0f ms operation=%lu",
              elapsed * 1000.0,
              (unsigned long)operation);
        [self sendLogoutResult:command
                    stabilized:YES
                      elapsed:elapsed
                      loggedIn:loggedIn
             attributesPresent:attributesPresent
                   clearChecks:nextConsecutiveClears];
        return;
    }

    if (elapsed >= IntercomLogoutMaximumWait) {
        NSLog(@"[Intercom-Cordova] WARN - Logout state did not stabilize after %.0f ms; continuing best effort (operation=%lu loggedIn=%@ attributesPresent=%@ clearChecks=%lu)",
              elapsed * 1000.0,
              (unsigned long)operation,
              loggedIn ? @"true" : @"false",
              attributesPresent ? @"true" : @"false",
              (unsigned long)nextConsecutiveClears);
        [self sendLogoutResult:command
                    stabilized:NO
                      elapsed:elapsed
                      loggedIn:loggedIn
             attributesPresent:attributesPresent
                   clearChecks:nextConsecutiveClears];
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(IntercomLogoutPollInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self waitForIntercomLogout:command
                          startedAt:startedAt
                 consecutiveClears:nextConsecutiveClears
                          operation:operation];
    });
}

- (void)isUserLoggedIn:(CDVInvokedUrlCommand*)command {
    BOOL loggedIn = [Intercom isUserLoggedIn];
    INTERCOM_DIAGNOSTIC_LOG(@"[Intercom-Cordova-Diagnostic] stage=login_state_read loggedIn=%@",
                           loggedIn ? @"true" : @"false");
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:loggedIn];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)fetchLoggedInUserAttributes:(CDVInvokedUrlCommand*)command {
    ICMUserAttributes *attributes = [Intercom fetchLoggedInUserAttributes];
    INTERCOM_DIAGNOSTIC_LOG(@"[Intercom-Cordova-Diagnostic] stage=attributes_read attributesPresent=%@",
                           attributes ? @"true" : @"false");
    if (attributes) {
        NSString *jsonString = [self stringValueForDictionary:[attributes toDictionary]];
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:jsonString];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    } else {
        NSError *error = [NSError errorWithDomain:@"IntercomCordovaBridge"
                                             code:1002
                                         userInfo:@{NSLocalizedDescriptionKey: @"No logged-in Intercom user attributes were available."}];
        [self sendFailure:command withError:error];
    }
}

- (void)updateUser:(CDVInvokedUrlCommand*)command {
    NSDictionary* attributesDict = command.arguments[0];
    [Intercom updateUser:[self userAttributesForDictionary:attributesDict] success:^{
        [self sendSuccess:command];
    } failure:^(NSError * _Nonnull error) {
        [self sendFailure:command withError:error];
    }];
}

#pragma mark - Events

- (void)logEvent:(CDVInvokedUrlCommand*)command {
    NSString *eventName = command.arguments[0];
    NSDictionary *metaData = command.arguments[1];

    if ([metaData isKindOfClass:[NSDictionary class]] && metaData.count > 0) {
        [Intercom logEventWithName:eventName metaData:metaData];
    } else {
        [Intercom logEventWithName:eventName];
    }
    [self sendSuccess:command];
}


#pragma mark - Present Intercom UI

- (void)present:(CDVInvokedUrlCommand*)command {
    [Intercom presentIntercom];
    [self sendSuccess:command];
}

- (void)presentIntercomSpace:(CDVInvokedUrlCommand*)command {
    NSString *space = command.arguments[0];
    Space selectedSpace = home;
    if ([space isEqualToString:@"HOME"]) {
        selectedSpace = home;
    } else if ([space isEqualToString:@"HELP_CENTER"]) {
        selectedSpace = helpCenter;
    } else if ([space isEqualToString:@"MESSAGES"]) {
        selectedSpace = messages;
    } else if ([space isEqualToString:@"TICKETS"]) {
        selectedSpace = tickets;
    }
    [Intercom presentIntercom:selectedSpace];
    [self sendSuccess:command];
}

- (void)presentContent:(CDVInvokedUrlCommand*)command {
    NSDictionary *content = command.arguments[0];
    IntercomContent *intercomContent;
    NSString *contentType = content[@"type"];
    if ([contentType isEqualToString:@"ARTICLE"]) {
        intercomContent = [IntercomContent articleWithId:content[@"id"]];
    } else if ([contentType isEqualToString:@"CAROUSEL"]) {
        intercomContent = [IntercomContent carouselWithId:content[@"id"]];
    } else if ([contentType isEqualToString:@"SURVEY"]) {
        intercomContent = [IntercomContent surveyWithId:content[@"id"]];
    } else if ([contentType isEqualToString:@"HELP_CENTER_COLLECTIONS"]) {
        NSArray<NSString *> *collectionIds = content[@"ids"];
        intercomContent = [IntercomContent helpCenterCollectionsWithIds:collectionIds];
    } else if ([contentType isEqualToString:@"CONVERSATION"]) {
        intercomContent = [IntercomContent conversationWithId:content[@"id"]];
    }
    if (intercomContent) {
        [Intercom presentContent:intercomContent];
        [self sendSuccess:command];
    }
}

- (void)presentMessageComposer:(CDVInvokedUrlCommand*)command {
    NSString *initialMessage = command.arguments[0];
    [Intercom presentMessageComposer:initialMessage];
    [self sendSuccess:command];
}

#pragma mark - Help Center Data API

- (void)fetchHelpCenterCollections:(CDVInvokedUrlCommand*)command {
    [Intercom fetchHelpCenterCollectionsWithCompletion:^(NSArray<ICMHelpCenterCollection *> * _Nullable collections, NSError * _Nullable error) {
        if (error) {
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsNSInteger:error.code];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        } else {
            NSMutableArray *array = [[NSMutableArray alloc] init];
            for (ICMHelpCenterCollection *collection in collections) {
                [array addObject:[collection toDictionary]];
            }
            NSString *jsonString = [self stringValueForDictionaries:(NSArray *)array];
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:jsonString];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        }
    }];
}

- (void)fetchHelpCenterCollection:(CDVInvokedUrlCommand*)command {
    NSString *collectionId = command.arguments[0];
    [Intercom fetchHelpCenterCollection:collectionId withCompletion:^(ICMHelpCenterCollectionContent * _Nullable collectionContent, NSError * _Nullable error) {
        if (error) {
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsNSInteger:error.code];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        } else {
            NSString *jsonString = [self stringValueForDictionary:[collectionContent toDictionary]];
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:jsonString];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        }
    }];
}

- (void)searchHelpCenter:(CDVInvokedUrlCommand*)command {
    NSString *searchTerm = command.arguments[0];
    [Intercom searchHelpCenter:searchTerm withCompletion:^(NSArray<ICMHelpCenterArticleSearchResult *> * _Nullable articleSearchResults, NSError * _Nullable error) {
        if (error) {
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsNSInteger:error.code];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        } else {
            NSMutableArray *array = [[NSMutableArray alloc] init];
            for (ICMHelpCenterArticleSearchResult *articleSearchResult in articleSearchResults) {
                [array addObject:[articleSearchResult toDictionary]];
            }
            NSString *jsonString = [self stringValueForDictionaries:(NSArray *)array];
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:jsonString];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        }
    }];
}


#pragma mark - Intercom UI Visibility

- (void)hideIntercom:(CDVInvokedUrlCommand*)command {
    [Intercom hideIntercom];
    [self sendSuccess:command];
}

- (void)setLauncherVisibility:(CDVInvokedUrlCommand*)command {
    NSString *visibilityString = command.arguments[0];
    BOOL visible = NO;
    if ([visibilityString isEqualToString:@"VISIBLE"]) {
        visible = YES;
    }
    [Intercom setLauncherVisible:visible];
    [self sendSuccess:command];
}

- (void)setInAppMessageVisibility:(CDVInvokedUrlCommand*)command {
    NSString *visibilityString = command.arguments[0];
    BOOL visible = NO;
    if ([visibilityString isEqualToString:@"VISIBLE"]) {
        visible = YES;
    }
    [Intercom setInAppMessagesVisible:visible];
    [self sendSuccess:command];
}

- (void)suppressProactiveContent:(CDVInvokedUrlCommand*)command {
    NSArray<NSString *> *typeStrings = command.arguments[0];
    NSMutableArray<NSNumber *> *types = [NSMutableArray array];
    for (NSString *typeString in typeStrings) {
        if ([typeString isEqualToString:@"CAROUSEL"]) {
            [types addObject:@(IntercomProactiveContentTypeCarousel)];
        } else if ([typeString isEqualToString:@"SURVEY"]) {
            [types addObject:@(IntercomProactiveContentTypeSurvey)];
        }
    }
    [Intercom suppressProactiveContent:types];
    [self sendSuccess:command];
}

- (void)setBottomPadding:(CDVInvokedUrlCommand*)command {
    double bottomPadding = [[command.arguments objectAtIndex:0] doubleValue];
    [Intercom setBottomPadding:bottomPadding];
    [self sendSuccess:command];
}

#pragma mark - Unread Conversation Count

- (void)unreadConversationCount:(CDVInvokedUrlCommand*)command {
    NSUInteger count = [Intercom unreadConversationCount];
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsNSUInteger:count];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}


#pragma mark - Push Notifications

- (void)registerForPush:(CDVInvokedUrlCommand*)command {
    UIApplication *application = [UIApplication sharedApplication];
    [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:(UNAuthorizationOptionAlert
                                                                                           | UNAuthorizationOptionBadge
                                                                                           | UNAuthorizationOptionSound)
                                                                        completionHandler:^(BOOL granted, NSError * _Nullable error) {
        if (error) {
            [self sendFailure:command withError:error];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [application registerForRemoteNotifications];
            [self sendSuccess:command];
        });
    }];
}

- (void)sendPushTokenToIntercom:(CDVInvokedUrlCommand*)command {
  NSLog(@"[Intercom-Cordova] INFO - sendPushTokenToIntercom called. Ignored by iOS as we automatically send the token when the app is registered for push.");
}





#pragma mark - User attributes

- (ICMUserAttributes *)userAttributesForDictionary:(NSDictionary *)attributesDict {
    ICMUserAttributes *attributes = [ICMUserAttributes new];
    if ([self stringValueForKey:@"email" inDictionary:attributesDict]) {
        attributes.email = [self stringValueForKey:@"email" inDictionary:attributesDict];
    }
    if ([self stringValueForKey:@"user_id" inDictionary:attributesDict]) {
        attributes.userId = [self stringValueForKey:@"user_id" inDictionary:attributesDict];
    }
    if ([self stringValueForKey:@"name" inDictionary:attributesDict]) {
        attributes.name = [self stringValueForKey:@"name" inDictionary:attributesDict];
    }
    if ([self stringValueForKey:@"phone" inDictionary:attributesDict]) {
        attributes.phone = [self stringValueForKey:@"phone" inDictionary:attributesDict];
    }
    if ([self stringValueForKey:@"language_override" inDictionary:attributesDict]) {
        attributes.languageOverride = [self stringValueForKey:@"language_override" inDictionary:attributesDict];
    }
    if ([self dateValueForKey:@"signed_up_at" inDictionary:attributesDict]) {
        attributes.signedUpAt = [self dateValueForKey:@"signed_up_at" inDictionary:attributesDict];
    }
    if ([self stringValueForKey:@"unsubscribed_from_emails" inDictionary:attributesDict]) {
        attributes.unsubscribedFromEmails = [self stringValueForKey:@"unsubscribed_from_emails" inDictionary:attributesDict];
    }
    if (attributesDict[@"custom_attributes"]) {
        attributes.customAttributes = attributesDict[@"custom_attributes"];
    }
    if (attributesDict[@"companies"]) {
        NSMutableArray<ICMCompany *> *companies = [NSMutableArray new];
        for (NSDictionary *companyDict in attributesDict[@"companies"]) {
            [companies addObject:[self companyForDictionary:companyDict]];
        }
        attributes.companies = companies;
    }
    return attributes;
}

- (ICMCompany *)companyForDictionary:(NSDictionary *)attributesDict {
    ICMCompany *company = [ICMCompany new];
    if ([self stringValueForKey:@"company_id" inDictionary:attributesDict]) {
        company.companyId = [self stringValueForKey:@"company_id" inDictionary:attributesDict];
    }
    if ([self stringValueForKey:@"name" inDictionary:attributesDict]) {
        company.name = [self stringValueForKey:@"name" inDictionary:attributesDict];
    }
    if ([self dateValueForKey:@"created_at" inDictionary:attributesDict]) {
        company.createdAt = [self dateValueForKey:@"created_at" inDictionary:attributesDict];
    }
    if ([self numberValueForKey:@"monthly_spend" inDictionary:attributesDict]) {
        company.monthlySpend = [self numberValueForKey:@"monthly_spend" inDictionary:attributesDict];
    }
    if ([self stringValueForKey:@"plan" inDictionary:attributesDict]) {
        company.plan = [self stringValueForKey:@"plan" inDictionary:attributesDict];
    }
    if (attributesDict[@"custom_attributes"]) {
        company.customAttributes = attributesDict[@"custom_attributes"];
    }
    return company;
}

- (NSString *)stringValueForKey:(NSString *)key inDictionary:(NSDictionary *)dictionary {
    NSString *value = dictionary[key];
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [NSString stringWithFormat:@"%@", value];
    }
    if ([value isKindOfClass:[NSNull class]]) {
        return [ICMUserAttributes nullStringAttribute];
    }
    return nil;
}

- (NSString *)stringValueForDictionaries:(NSArray *)dictionaries {
    NSError *error;
    NSString *jsonString;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dictionaries options:0 error:&error];
    if (!jsonData) {
        NSLog(@"Got an error: %@", error);
    } else {
        jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    }
    return jsonString;
}


- (NSString *)stringValueForDictionary:(NSDictionary *)dictionary {
    NSError *error;
    NSString *jsonString;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:&error];
    if (!jsonData) {
        NSLog(@"Got an error: %@", error);
    } else {
        jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    }
    return jsonString;
}

- (NSNumber *)numberValueForKey:(NSString *)key inDictionary:(NSDictionary *)dictionary {
    NSNumber *value = dictionary[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSNull class]]) {
        return [ICMUserAttributes nullNumberAttribute];
    }
    return nil;
}

- (NSDate *)dateValueForKey:(NSString *)key inDictionary:(NSDictionary *)dictionary {
    NSNumber *value = dictionary[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [NSDate dateWithTimeIntervalSince1970:[value doubleValue]];
    }
    if ([value isKindOfClass:[NSNull class]]) {
        return [ICMUserAttributes nullDateAttribute];
    }
    return nil;
}


#pragma mark - Private methods

- (void)sendLogoutResult:(CDVInvokedUrlCommand *)command
               stabilized:(BOOL)stabilized
                 elapsed:(NSTimeInterval)elapsed
                 loggedIn:(BOOL)loggedIn
        attributesPresent:(BOOL)attributesPresent
              clearChecks:(NSUInteger)clearChecks {
    NSDictionary *details = @{
        @"stabilized": @(stabilized),
        @"elapsedMs": @(elapsed * 1000.0),
        @"loggedIn": @(loggedIn),
        @"attributesPresent": @(attributesPresent),
        @"clearChecks": @(clearChecks)
    };
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                   messageAsDictionary:details];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)sendSuccess:(CDVInvokedUrlCommand*)command {
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (NSString *)sanitizedErrorDomain:(NSString *)domain {
    if (![domain isKindOfClass:[NSString class]] || domain.length == 0) {
        return @"IntercomError";
    }
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:@"[^A-Za-z0-9._-]"
                                                                                 options:0
                                                                                   error:nil];
    NSString *sanitized = [expression stringByReplacingMatchesInString:domain
                                                                options:0
                                                                  range:NSMakeRange(0, domain.length)
                                                           withTemplate:@"_"];
    return sanitized.length > 120 ? [sanitized substringToIndex:120] : sanitized;
}

- (NSString *)sanitizedErrorMessage:(NSString *)message {
    if (![message isKindOfClass:[NSString class]] || message.length == 0) {
        return @"Intercom operation failed.";
    }
    NSString *sanitized = [[message componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    NSArray<NSDictionary<NSString *, NSString *> *> *replacements = @[
        @{@"pattern": @"[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", @"value": @"[redacted-email]"},
        @{@"pattern": @"(?i)(password|sessionToken|masterKey|javascriptKey|authorization|token|user[_-]?hash|user[_-]?id)(\\s*[:=]\\s*)[^\\s,;]+", @"value": @"$1$2[redacted]"},
        @{@"pattern": @"https?://[^\\s]+", @"value": @"[redacted-url]"}
    ];
    for (NSDictionary<NSString *, NSString *> *replacement in replacements) {
        NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:replacement[@"pattern"]
                                                                                     options:NSRegularExpressionCaseInsensitive
                                                                                       error:nil];
        sanitized = [expression stringByReplacingMatchesInString:sanitized
                                                          options:0
                                                            range:NSMakeRange(0, sanitized.length)
                                                     withTemplate:replacement[@"value"]];
    }
    sanitized = [sanitized stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (sanitized.length == 0) {
        return @"Intercom operation failed.";
    }
    return sanitized.length > 300 ? [sanitized substringToIndex:300] : sanitized;
}

- (void)sendFailure:(CDVInvokedUrlCommand*)command withError:(NSError *)error {
    NSDictionary *details = @{
        @"code": @(error.code),
        @"domain": [self sanitizedErrorDomain:error.domain],
        @"message": [self sanitizedErrorMessage:error.localizedDescription]
    };
    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                   messageAsDictionary:details];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

@end
