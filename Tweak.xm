// SCARLET-X-Probe 0.1.0
// Deliberately no method hooks, data capture, network access or persistence.
// The constructor only reports app version and presence of known Objective-C
// classes to the device's unified logging system when loaded into official X.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

__attribute__((constructor))
static void ScarletXProbeStart(void) {
    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *bundleID = bundle.bundleIdentifier ?: @"unknown";
        if (![bundleID isEqualToString:@"com.atebits.Tweetie2"]) {
            return;
        }

        NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
        NSString *build = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";
        const char *names[] = {
            "TTAStatusBodyTextView",
            "T1StatusCell",
            "T1StandardStatusView",
            "T1StatusTableRowAdapter"
        };
        NSLog(@"[SCARLET-X-Probe] started bundle=%@ version=%@ build=%@",
              bundleID, version, build);
        for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
            NSLog(@"[SCARLET-X-Probe] class=%s present=%@",
                  names[i], objc_getClass(names[i]) ? @"YES" : @"NO");
        }
    }
}
