// SCARLET-X-Probe 0.1.2
// No method hooks, user-content capture, or network access.
// A minimal launch marker distinguishes dylib injection from UI-entry failure.
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

        // Written before querying classes or touching UIKit; never includes account data.
        NSString *markerPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"SCARLET-X-Probe-loaded.txt"];
        NSString *marker = [NSString stringWithFormat:@"SCARLET-X-Probe 0.1.2 loaded\\nprocess=%@\\n", bundleID];
        NSError *markerError = nil;
        BOOL markerWritten = [marker writeToFile:markerPath atomically:YES encoding:NSUTF8StringEncoding error:&markerError];
        NSLog(@"[SCARLET-X-Probe] v0.1.2 load marker %@ at %@ (%@)", markerWritten ? @"written" : @"failed", markerPath, markerError.localizedDescription ?: @"ok");

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
