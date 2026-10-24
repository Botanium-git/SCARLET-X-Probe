// SCARLET-X-Probe 0.1.25
// No method hooks or user-content capture; Drive networking is explicitly user-triggered.
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

        // Persistent per-app marker; no account, session, or tweet contents.
        // Filza > Apps > X > Documents can check this even after app exit.
        NSURL *documents = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                                   inDomains:NSUserDomainMask] firstObject];
        NSURL *markerURL = [documents URLByAppendingPathComponent:@"SCARLET-X-Probe-loaded.txt"];
        NSString *marker = [NSString stringWithFormat:@"SCARLET-X-Probe 0.1.21 loaded\\nbundle=%@\\n", bundleID];
        NSError *markerError = nil;
        BOOL markerWritten = (markerURL && [marker writeToURL:markerURL atomically:YES
                                                encoding:NSUTF8StringEncoding error:&markerError]);
        NSLog(@"[SCARLET-X-Probe] v0.1.21 persistent marker %@ at %@ (%@)",
              markerWritten ? @"written" : @"failed", markerURL.path ?: @"no Documents",
              markerError.localizedDescription ?: @"ok");

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
