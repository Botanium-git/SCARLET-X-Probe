#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <string.h>
extern BOOL SXDriveIsConnected(void);
extern NSString *SXDriveCurrentStatus(void);
extern void SXDriveHandleRow(NSInteger row, UIViewController *host);
extern void SXOpenPrivateUpdater(UIViewController *host);
extern void SXStartProbeDownload(UIViewController *host, void (^status)(NSString *));
extern void SXProbeCheckUpdateNotice(void(^done)(NSString *notice));
extern NSString *SXProbeOwnVersion(void);

static NSMutableArray<NSDictionary *> *SXEntries;
static dispatch_queue_t SXQueue;
static BOOL SXEnabled = NO;
static BOOL SXRecordingRestored = NO;
static NSString * const SXRecordingKey = @"com.botanium.sxprobe.metadata.enabled";
static NSString * const SXOperationStatusKey = @"com.botanium.sxprobe.operation.last-status";
static NSString *SXLogPath(void) {
    NSURL *dir = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    dir = [dir URLByAppendingPathComponent:@"ScarletXProbe" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [[dir URLByAppendingPathComponent:@"diagnostics.json"] path];
}
static void SXInitializeLog(void) {
    SXQueue = dispatch_queue_create("com.botanium.sxprobe.entries", DISPATCH_QUEUE_SERIAL);
    NSData *data = [NSData dataWithContentsOfFile:SXLogPath()];
    id decoded = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    SXEntries = [decoded isKindOfClass:NSArray.class] ? [decoded mutableCopy] : [NSMutableArray new];
    if(SXEntries.count>300) [SXEntries removeObjectsInRange:NSMakeRange(0,SXEntries.count-300)];
    SXEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:SXRecordingKey];
}
static void SXSaveEntries(void) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:SXEntries options:0 error:nil];
    if(data) [data writeToFile:SXLogPath() atomically:YES];
}
static void SXRecord(NSString *event, NSDictionary *fields) {
    if (!SXQueue) return;
    NSDictionary *item = @{@"event":event ?: @"unknown",
                           @"timestamp":@([[NSDate date] timeIntervalSince1970]),
                           @"fields":fields ?: @{}};
    dispatch_sync(SXQueue, ^{
        [SXEntries addObject:item];
        if(SXEntries.count>300) [SXEntries removeObjectsInRange:NSMakeRange(0,SXEntries.count-300)];
        SXSaveEntries();
    });
}
static void SXClearEntries(void) {
    if (!SXQueue) return;
    dispatch_sync(SXQueue, ^{ [SXEntries removeAllObjects]; SXSaveEntries(); });
}
static NSDictionary *SXLogSummary(void) {
    __block NSDictionary *result=@{@"count":@0,@"last":@"なし"};
    if(SXQueue) dispatch_sync(SXQueue, ^{
        NSDictionary *last = SXEntries.lastObject;
        NSString *name = [last[@"event"] isKindOfClass:NSString.class] ? last[@"event"] : @"なし";
        result=@{@"count":@(SXEntries.count),@"last":name};
    });
    return result;
}

NSDictionary *SXProbeDiagnosticPayload(void) {
    __block NSArray *entries=nil;
    if(SXQueue) dispatch_sync(SXQueue, ^{ entries=[SXEntries copy]; });
    NSBundle *b=NSBundle.mainBundle;
    return @{@"format":@"ScarletXProbe",@"schemaVersion":@1,
             @"generatedAt":@(NSDate.date.timeIntervalSince1970),
             @"xVersion":[b objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"",
             @"xBuild":[b objectForInfoDictionaryKey:@"CFBundleVersion"]?:@"",
             @"entries":entries?:@[]};
}

// Read-only collection; one automatic sample per process when metadata recording is enabled.
static BOOL SXAutomaticMethodSnapshotDone = NO;
static void SXCollectMethodMetadata(BOOL automatic) {
 if (!SXQueue) return;
 SXRecord(@"method-probe-invoked",@{@"recordingWasEnabled":@(SXEnabled),@"automatic":@(automatic)});
 const char *names[]={"TTAStatusBodyTextView","T1StatusCell","T1StandardStatusView","T1StatusTableRowAdapter","T1UserView","T1UserViewLayoutParameters","T1UserViewLayoutState","T1ProfileUserInfoView","T1ProfileHeaderView","T1ProfileUserInfoViewController"};
 NSArray *terms=@[@"height",@"size",@"layout",@"display",@"text",@"row",@"status",@"viewmodel",@"frame",@"font"];
 for(NSUInteger i=0;i<sizeof(names)/sizeof(names[0]);i++){
  Class cls=objc_getClass(names[i]);if(!cls)continue;
  unsigned int count=0;Method *methods=class_copyMethodList(cls,&count);
  NSMutableArray *selected=[NSMutableArray array];
  for(unsigned int j=0;j<count;j++){
   const char *cname=sel_getName(method_getName(methods[j]));if(!cname)continue;
   NSString *name=[NSString stringWithUTF8String:cname],*lower=name.lowercaseString;
   for(NSString *term in terms){if([lower containsString:term]){if(selected.count<60)[selected addObject:name];break;}}
  }
  if(methods)free(methods);
  SXRecord(@"method-names",@{@"class":[NSString stringWithUTF8String:names[i]],@"instanceMethodCount":@(count),@"matchingSelectors":selected});
 }
 SXRecord(@"method-probe-completed",@{@"classesChecked":@(sizeof(names)/sizeof(names[0])),@"automatic":@(automatic)});

}
static void SXCollectAutomaticMethodMetadataIfEnabled(void) {
 if (!SXEnabled || SXAutomaticMethodSnapshotDone) return;
 SXAutomaticMethodSnapshotDone = YES;
 SXCollectMethodMetadata(YES);
}


// Typography metrics only. No text content or attributed strings leave this function.
static NSArray *SXTypographyMetrics(NSAttributedString *value) {
    if(![value isKindOfClass:NSAttributedString.class] || value.length==0)return @[];
    NSMutableArray *found=[NSMutableArray array];
    [value enumerateAttributesInRange:NSMakeRange(0,value.length) options:0 usingBlock:^(NSDictionary *attrs,NSRange range,BOOL *stop) {
        UIFont *font=attrs[NSFontAttributeName];
        NSParagraphStyle *paragraph=attrs[NSParagraphStyleAttributeName];
        NSMutableDictionary *metric=[NSMutableDictionary dictionary];
        if([font isKindOfClass:UIFont.class]) {
            metric[@"fontName"]=font.fontName?:@"";
            metric[@"fontPointSize"]=@(font.pointSize);
            metric[@"lineHeight"]=@(font.lineHeight);
        }
        if([paragraph isKindOfClass:NSParagraphStyle.class]) {
            metric[@"lineSpacing"]=@(paragraph.lineSpacing);
            metric[@"paragraphSpacing"]=@(paragraph.paragraphSpacing);
            metric[@"lineHeightMultiple"]=@(paragraph.lineHeightMultiple);
            metric[@"minimumLineHeight"]=@(paragraph.minimumLineHeight);
            metric[@"maximumLineHeight"]=@(paragraph.maximumLineHeight);
        }
        // Export only a bounded set of distinct styles, never ranges or text length.
        if(metric.count && ![found containsObject:metric] && found.count<12)[found addObject:metric];
    }];
    return found;
}
static NSArray *SXTextViewMetricSelectorNames(Class cls) {
    NSMutableArray *selected=[NSMutableArray array];
    for(Class cur=cls;cur && cur!=NSObject.class && selected.count<30;cur=class_getSuperclass(cur)) {
        unsigned int count=0;Method *methods=class_copyMethodList(cur,&count);
        for(unsigned int i=0;i<count && selected.count<30;i++) {
            NSString *name=NSStringFromSelector(method_getName(methods[i]));
            NSString *lower=name.lowercaseString;
            if(([lower containsString:@"font"] || [lower containsString:@"attributed"] ||
                [lower containsString:@"layout"] || [lower containsString:@"lineheight"]) &&
                ![selected containsObject:name])[selected addObject:name];
        }
        if(methods)free(methods);
    }
    return selected;
}

// Inspect Objective-C ABI metadata before considering an invasive font-argument hook.
static NSArray *SXFontUpdateABIMetadata(Class cls) {
    NSArray *wanted=@[
      @"ocf_updateForText:activeRanges:font:color:activeRangesFont:textAlignment:lineBreakMode:",
      @"ocf_updateForExpandedRichText:font:color:activeRangesFont:textAlignment:lineBreakMode:",
      @"_ocf_updateForText:activeRanges:attributedStringFactory:"
    ];
    NSMutableArray *result=[NSMutableArray array];
    for(NSString *selectorName in wanted) {
        SEL selector=NSSelectorFromString(selectorName);
        Method method=class_getInstanceMethod(cls,selector);
        if(!method)continue;
        const char *raw=method_getTypeEncoding(method);
        NSMethodSignature *signature=raw?[NSMethodSignature signatureWithObjCTypes:raw]:nil;
        NSMutableArray *argumentTypes=[NSMutableArray array];
        for(NSUInteger i=0;signature && i<signature.numberOfArguments;i++) {
            const char *type=[signature getArgumentTypeAtIndex:i];
            [argumentTypes addObject:type?[NSString stringWithUTF8String:type]:@"unknown"];
        }
        [result addObject:@{@"selector":selectorName,@"typeEncoding":raw?[NSString stringWithUTF8String:raw]:@"",
                             @"argumentTypes":argumentTypes,@"returns":signature?@(signature.methodReturnLength):@0}];
    }
    return result;
}

// Narrow opt-in-free observation: inspect only the font object supplied to
// profile-owned TFNAttributedTextView updates; pass every argument unchanged.
typedef void (*SXTextUpdateIMP)(id,SEL,id,id,id,id,id,NSInteger,NSInteger);
typedef void (*SXRichUpdateIMP)(id,SEL,id,id,id,id,NSInteger,NSInteger);
static SXTextUpdateIMP SXOriginalTextUpdate=NULL;
static SXRichUpdateIMP SXOriginalRichUpdate=NULL;
static NSUInteger SXFontEvents=0;
static NSUInteger SXFontTotalText=0, SXFontTotalRich=0, SXFontAccepted=0, SXFontRejected=0;
static NSUInteger SXFontNoSuperview=0, SXFontNotProfile=0;
static void SXFlushFontCounters(void) {
    SXRecord(@"profile-font-observer-counters",@{@"textCalls":@(SXFontTotalText),@"richCalls":@(SXFontTotalRich),@"accepted":@(SXFontAccepted),@"rejected":@(SXFontRejected),@"noSuperview":@(SXFontNoSuperview),@"notProfileAncestor":@(SXFontNotProfile),@"textCaptured":@NO});
}

static BOOL SXFontHooksInstalled=NO;
static BOOL SXIsProfileOwned(id object) {
    if(![object isKindOfClass:UIView.class])return NO;
    UIView *parent=(UIView *)object;
    for(NSUInteger i=0;parent && i<24;i++,parent=parent.superview)
        if([NSStringFromClass(parent.class) isEqualToString:@"T1ProfileUserInfoView"])return YES;
    return NO;
}
static void SXCaptureProfileFont(id object, id font, NSString *source) {
    if(!SXEnabled)return;
    BOOL isProfile=SXIsProfileOwned(object);
    if(!isProfile) { SXFontRejected++; if([object isKindOfClass:UIView.class] && !((UIView *)object).superview)SXFontNoSuperview++; else SXFontNotProfile++; }
    else SXFontAccepted++;
    if(((SXFontTotalText+SXFontTotalRich)%25)==1)SXFlushFontCounters();
    if(!isProfile || SXFontEvents>=40)return;
    NSMutableDictionary *data=[@{@"source":source,@"viewClass":NSStringFromClass([object class])?:@"",
          @"fontObjectClass":font?NSStringFromClass([font class]):@"nil",
          @"textCaptured":@NO} mutableCopy];
    if([font isKindOfClass:UIFont.class]) {
        UIFont *f=(UIFont *)font;
        data[@"fontName"]=f.fontName?:@"";
        data[@"pointSize"]=@(f.pointSize);
        data[@"lineHeight"]=@(f.lineHeight);
    }
    UIView *view=(UIView *)object;
    data[@"width"]=@(view.bounds.size.width);
    data[@"height"]=@(view.bounds.size.height);
    SXFontEvents++;
    SXRecord(@"profile-bio-font-argument",data);
}
static void SXObservedTextUpdate(id target, SEL selector, id text, id ranges,
                                 id font, id color, id activeFont, NSInteger alignment, NSInteger breakMode) {
    SXFontTotalText++;
    SXCaptureProfileFont(target,font,@"text-update");
    if(SXOriginalTextUpdate)SXOriginalTextUpdate(target,selector,text,ranges,font,color,activeFont,alignment,breakMode);
}
static void SXObservedRichUpdate(id target,SEL selector,id rich,id font,id color,
                                 id activeFont,NSInteger alignment,NSInteger breakMode) {
    SXFontTotalRich++;
    SXCaptureProfileFont(target,font,@"rich-update");
    if(SXOriginalRichUpdate)SXOriginalRichUpdate(target,selector,rich,font,color,activeFont,alignment,breakMode);
}
// Diagnose dispatch ownership and IMP replacement without recording raw addresses.
static BOOL SXOwnsSelector(Class cls,SEL selector) {
    unsigned int count=0;Method *methods=class_copyMethodList(cls,&count);BOOL found=NO;
    for(unsigned int i=0;i<count;i++)if(method_getName(methods[i])==selector){found=YES;break;}
    if(methods)free(methods);return found;
}
static NSString *SXIMPImageName(IMP imp) {
    if(!imp)return @"missing";
    Dl_info details={0};
    if(!dladdr((const void *)imp,&details) || !details.dli_fname)return @"unknown";
    return [[NSString stringWithUTF8String:details.dli_fname] lastPathComponent]?:@"unknown";
}
static NSDictionary *SXDispatchEntry(Class cls,SEL selector,IMP observer,IMP original) {
    Method method=cls?class_getInstanceMethod(cls,selector):NULL;
    IMP actual=method?method_getImplementation(method):NULL;
    NSMutableArray *owners=[NSMutableArray array];
    for(Class current=cls;current && owners.count<20;current=class_getSuperclass(current)) {
        if(SXOwnsSelector(current,selector))[owners addObject:NSStringFromClass(current)?:@"unknown"];
    }
    return @{@"selector":NSStringFromSelector(selector),@"targetClass":cls?NSStringFromClass(cls):@"missing",
             @"ownerClasses":owners,@"exists":@(method!=NULL),
             @"currentIsObserver":@(actual!=NULL && actual==observer),
             @"currentIsOriginal":@(actual!=NULL && actual==original),
             @"currentImage":SXIMPImageName(actual),@"originalImage":SXIMPImageName(original)};
}
static void SXRecordFontDispatchStatus(void) {
    Class cls=objc_getClass("TFNAttributedTextView");
    SEL textSel=NSSelectorFromString(@"ocf_updateForText:activeRanges:font:color:activeRangesFont:textAlignment:lineBreakMode:");
    SEL richSel=NSSelectorFromString(@"ocf_updateForExpandedRichText:font:color:activeRangesFont:textAlignment:lineBreakMode:");
    SXRecord(@"profile-font-dispatch-status",@{@"installed":@(SXFontHooksInstalled),
      @"text":SXDispatchEntry(cls,textSel,(IMP)SXObservedTextUpdate,(IMP)SXOriginalTextUpdate),
      @"rich":SXDispatchEntry(cls,richSel,(IMP)SXObservedRichUpdate,(IMP)SXOriginalRichUpdate),
      @"textCaptured":@NO});
}
static void SXInstallProfileFontObservers(void) {
    if(SXFontHooksInstalled)return;
    Class cls=objc_getClass("TFNAttributedTextView");
    if(!cls)return;
    SEL textSel=NSSelectorFromString(@"ocf_updateForText:activeRanges:font:color:activeRangesFont:textAlignment:lineBreakMode:");
    SEL richSel=NSSelectorFromString(@"ocf_updateForExpandedRichText:font:color:activeRangesFont:textAlignment:lineBreakMode:");
    Method textMethod=class_getInstanceMethod(cls,textSel);
    Method richMethod=class_getInstanceMethod(cls,richSel);
    const char *textABI=textMethod?method_getTypeEncoding(textMethod):NULL;
    const char *richABI=richMethod?method_getTypeEncoding(richMethod):NULL;
    // Exact encodings observed on official X 12.35 arm64; disable on ABI changes.
    if(!textABI || !richABI || strcmp(textABI,"v72@0:8@16@24@32@40@48q56q64") ||
       strcmp(richABI,"v64@0:8@16@24@32@40q48q56"))return;
    SXOriginalTextUpdate=(SXTextUpdateIMP)method_getImplementation(textMethod);
    SXOriginalRichUpdate=(SXRichUpdateIMP)method_getImplementation(richMethod);
    if(!SXOriginalTextUpdate || !SXOriginalRichUpdate)return;
    // class_replaceMethod installs subclass overrides even if methods were inherited.
    class_replaceMethod(cls,textSel,(IMP)SXObservedTextUpdate,textABI);
    class_replaceMethod(cls,richSel,(IMP)SXObservedRichUpdate,richABI);
    SXFontHooksInstalled=YES;
    SXRecord(@"profile-font-observer-installed",@{@"abiVerified":@YES,@"textCaptured":@NO});
    SXRecordFontDispatchStatus();
}

// Explicit, read-only snapshot. Never exports text, account IDs or view descriptions.
static void SXScanBioViews(UIView *node, NSMutableArray *samples, NSUInteger *visited) {
    if(!node || *visited>=1500 || samples.count>=12)return;
    (*visited)++;
    NSString *cls=NSStringFromClass(node.class);
    if([cls isEqualToString:@"T1ProfileUserInfoView"]) {
        NSMutableArray *children=[NSMutableArray array];
        NSMutableArray *pending=[NSMutableArray arrayWithObject:node];
        NSUInteger examined=0;
        while(pending.count && examined<300 && children.count<100) {
            UIView *v=pending.firstObject;[pending removeObjectAtIndex:0];examined++;
            NSString *kind=NSStringFromClass(v.class);
            CGRect frame=v.frame, bounds=v.bounds;
            NSMutableDictionary *entry=[@{@"class":kind?:@"unknown",
              @"frame":@[@(frame.origin.x),@(frame.origin.y),@(frame.size.width),@(frame.size.height)],
              @"bounds":@[@(bounds.origin.x),@(bounds.origin.y),@(bounds.size.width),@(bounds.size.height)]} mutableCopy];
            UIFont *font=nil;
            if([v isKindOfClass:UILabel.class])font=((UILabel *)v).font;
            else if([v isKindOfClass:UITextView.class])font=((UITextView *)v).font;
            if(font){entry[@"fontName"]=font.fontName?:@"";entry[@"fontPointSize"]=@(font.pointSize);entry[@"fontLineHeight"]=@(font.lineHeight);}
            entry[@"hidden"]=@(v.hidden);
            entry[@"alpha"]=@(v.alpha);
            entry[@"onScreen"]=@(v.window!=nil && !v.hidden && v.alpha>0.01 && bounds.size.width>0 && bounds.size.height>0);
            NSAttributedString *rich=nil;
            if([v isKindOfClass:UILabel.class])rich=((UILabel *)v).attributedText;
            else if([v isKindOfClass:UITextView.class])rich=((UITextView *)v).attributedText;
            if(rich.length)entry[@"typography"]=SXTypographyMetrics(rich);
            if([kind isEqualToString:@"TFNAttributedTextView"])
                {
                entry[@"availableMetricSelectors"]=SXTextViewMetricSelectorNames(v.class);
                entry[@"fontUpdateABI"]=SXFontUpdateABIMetadata(v.class);
            }
            if(v==node || font || [kind localizedCaseInsensitiveContainsString:@"bio"] ||
               [kind localizedCaseInsensitiveContainsString:@"attributedtext"]) [children addObject:entry];
            for(UIView *child in v.subviews)if(pending.count<300)[pending addObject:child];
        }
        [samples addObject:@{@"rootClass":cls,@"subviews":children,@"examined":@(examined)}];
        return;
    }
    for(UIView *child in node.subviews)SXScanBioViews(child,samples,visited);
}
static NSDictionary *SXBioSnapshot(void) {
    if (![NSThread isMainThread]) return @{@"profileViewCount":@0,@"visitedViewCount":@0,@"samples":@[],@"error":@"main-thread-required",@"noTextCollected":@YES};
    NSMutableArray *samples=[NSMutableArray array];
    NSUInteger visited=0;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class] || scene.activationState!=UISceneActivationStateForegroundActive)continue;
        for(UIWindow *window in ((UIWindowScene *)scene).windows) {
            if(window.hidden)continue;
            SXScanBioViews(window,samples,&visited);
        }
    }
    return @{@"profileViewCount":@(samples.count),@"visitedViewCount":@(visited),@"samples":samples,
             @"noTextCollected":@YES};
}

@interface SXProbePanel : UITableViewController
@property(nonatomic,copy) NSString *updateNotice;
@property(nonatomic,copy) NSString *downloadStatus;
@end

@implementation SXProbePanel
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SXP";
    self.updateNotice = @"更新確認中…";
    self.downloadStatus = [[NSUserDefaults standardUserDefaults] stringForKey:SXOperationStatusKey] ?: @"未実行";
    __weak typeof(self) weakSelf=self;
    SXProbeCheckUpdateNotice(^(NSString *notice){
        __strong typeof(weakSelf) self=weakSelf;
        if(self){self.updateNotice=notice;[self.tableView reloadData];}
    });
    if (SXEnabled && !SXRecordingRestored) {
        SXRecordingRestored = YES;
        SXRecord(@"recording-restored",@{@"enabled":@YES});
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(driveUpdated:) name:@"SXDriveStateChanged" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(operationUpdated:) name:@"SXPOperationStatusChanged" object:nil];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closePanel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"共有" style:UIBarButtonItemStylePlain target:self action:@selector(exportJSON)];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)driveUpdated:(NSNotification *)note { [self.tableView reloadData]; }
- (void)operationUpdated:(NSNotification *)note {
    NSString *message=note.userInfo[@"message"];
    if (![message isKindOfClass:NSString.class] || !message.length)return;
    dispatch_async(dispatch_get_main_queue(),^{[self setOperationStatus:message];});
}
- (void)setOperationStatus:(NSString *)message {
    self.downloadStatus=message;
    [[NSUserDefaults standardUserDefaults] setObject:message forKey:SXOperationStatusKey];
    [self.tableView reloadData];
}
- (void)closePanel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section==0 ? 2 : (section==1 ? 5 : 3); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return @[@"情報",@"診断",@"連携・管理"][section];}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:(path.section==2 && path.row==2 ? UITableViewCellStyleSubtitle : UITableViewCellStyleValue1) reuseIdentifier:nil];
    NSBundle *bundle=NSBundle.mainBundle;
    NSInteger s=path.section,r=path.row;
    if(s==0 && r==0) {
        cell.textLabel.text=@"X バージョン";
        cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ (%@)",[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"?",[bundle objectForInfoDictionaryKey:@"CFBundleVersion"]?:@"?"];
    } else if(s==0 && r==1) {
        cell.textLabel.text=@"SXP バージョン";
        cell.detailTextLabel.text=[NSString stringWithFormat:@"%@  %@",SXProbeOwnVersion(),self.updateNotice?:@""];
        cell.detailTextLabel.adjustsFontSizeToFitWidth=YES;
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    } else if(s==1 && r==0) {
        cell.textLabel.text=@"メタデータ記録";
        UISwitch *toggle=[UISwitch new];toggle.on=SXEnabled;
        [toggle addTarget:self action:@selector(toggleRecording:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView=toggle;
    } else if(s==1 && r==1) {
        cell.textLabel.text=@"クラスメソッド情報を記録";
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    } else if(s==1 && r==2) {
        cell.textLabel.text=@"プロフィール表示を計測";
        cell.detailTextLabel.text=@"文字列を取得しません";
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    } else if(s==1 && r==3) {
        cell.textLabel.text=@"診断ログを消去";cell.textLabel.textColor=UIColor.systemRedColor;
    } else if(s==1 && r==4) {
        cell.textLabel.text=@"記録イベント数";
        cell.detailTextLabel.text=[SXLogSummary()[@"count"] description];
    } else if(s==2 && r==0) {
        cell.textLabel.text=@"診断JSONをDriveへ送信";
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    } else if(s==2 && r==1) {
        cell.textLabel.text=@"SXP更新";
        cell.detailTextLabel.text=@"debを取得・共有";
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    } else if(s==2 && r==2) {
        cell.textLabel.text=@"現在の状態";
        cell.detailTextLabel.text=self.downloadStatus;
        cell.detailTextLabel.numberOfLines=0;
    }
    return cell;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    return path.section==2 && path.row==2 ? UITableViewAutomaticDimension : 44.0;
}
- (void)toggleRecording:(UISwitch *)sender {
    SXEnabled = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:SXEnabled forKey:SXRecordingKey];
    if (SXEnabled) {
        SXRecordingRestored = YES;
        NSBundle *b = NSBundle.mainBundle;
        SXRecord(@"probe-enabled", @{@"version":[b objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown"});
        SXCollectAutomaticMethodMetadataIfEnabled();
        const char *names[]={"TTAStatusBodyTextView","T1StatusCell","T1StandardStatusView","T1StatusTableRowAdapter","T1UserView","T1UserViewLayoutParameters","T1UserViewLayoutState","T1ProfileUserInfoView","T1ProfileHeaderView","T1ProfileUserInfoViewController"};
        for (NSUInteger i = 0; i < sizeof(names)/sizeof(names[0]); ++i)
            SXRecord(@"class-check", @{@"class":[NSString stringWithUTF8String:names[i]], @"present":@(objc_getClass(names[i]) != nil)});
    }
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if(path.section==0 && path.row==1) SXOpenPrivateUpdater(self);
    else if(path.section==1 && path.row==1) [self recordMethodMetadata];
    else if(path.section==1 && path.row==2) [self captureProfileLayout];
    else if(path.section==1 && path.row==3) {
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"診断ログを消去？" message:@"記録済みの診断イベントを削除します。" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"消去" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *x){ SXClearEntries();[self.tableView reloadData]; }]];
        [self presentViewController:a animated:YES completion:nil];
    }
    else if(path.section==2 && path.row==0) SXDriveHandleRow(1,self);
    else if(path.section==2 && path.row==1) {
        [self setOperationStatus:@"更新: debを取得中…"];
        __weak typeof(self) weakSelf=self;
        SXStartProbeDownload(self, ^(NSString *status){
            __strong typeof(weakSelf) strong=weakSelf;
            if(strong){[strong setOperationStatus:[@"更新: " stringByAppendingString:status?:@"状態不明"]];}
        });
    }
}
- (void)captureProfileLayout {
    if(SXFontHooksInstalled)SXFlushFontCounters();
    SXRecordFontDispatchStatus();
    NSDictionary *snapshot=SXBioSnapshot();
    SXRecord(@"profile-bio-view-snapshot",snapshot);
    [self.tableView reloadData];
    NSUInteger count=[snapshot[@"profileViewCount"] unsignedIntegerValue];
    NSString *message=count?[NSString stringWithFormat:@"プロフィール表示の計測結果を%lu件記録しました。診断JSONをDriveへ送信してください。",(unsigned long)count]:
       @"対象のプロフィール表示が見つかりませんでした。プロフィール画面を表示した状態で再実行してください。";
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"プロフィール表示計測" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)recordMethodMetadata {
 // Manual capture remains available even when metadata recording is disabled.
 SXCollectMethodMetadata(NO);
 [self.tableView reloadData];
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"記録完了" message:@"関連メソッド名を記録しました。必要に応じてDriveへ送信してください。" preferredStyle:UIAlertControllerStyleAlert];
 [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
 [self presentViewController:a animated:YES completion:nil];
}
- (void)exportJSON {
    __block NSArray *entries;
    dispatch_sync(SXQueue, ^{ entries = [SXEntries copy]; });
    NSBundle *bundle = NSBundle.mainBundle;
    NSDictionary *payload = @{
        @"format":@"ScarletXProbe",
        @"schemaVersion":@1,
        @"generatedAt":@([[NSDate date] timeIntervalSince1970]),
        @"xVersion":[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"",
        @"xBuild":[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"",
        @"entries":entries ?: @[]
    };
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:&error];
    if (!json) return;
    NSString *filename = [NSString stringWithFormat:@"SXProbe_%lld.json", (long long)[NSDate.date timeIntervalSince1970]];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
    if (![json writeToURL:url atomically:YES]) return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:share animated:YES completion:nil];
}
@end

// Temporary opt-in diagnostic entry point for validating the panel on X 12.35.
// No X-private menu classes are modified. Actual side-menu integration follows
// after native menu classes have been observed on the installed app.
static NSArray<UIWindow *> *SXProbeWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    return windows;
}
static void SXOpenPanel(void) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ SXOpenPanel(); }); return; }
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.atebits.Tweetie2"]) return;
    UIWindow *window = nil;
    for (UIWindow *w in SXProbeWindows()) {
        if (w.isKeyWindow) { window = w; break; }
    }
    UIViewController *current = window.rootViewController;
    if (!current) return;
    while (current.presentedViewController) current = current.presentedViewController;
    if ([current isKindOfClass:UINavigationController.class] && [[(UINavigationController *)current topViewController] isKindOfClass:SXProbePanel.class]) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[SXProbePanel new]];
    [current presentViewController:nav animated:YES completion:nil];
}
@interface SXProbeGestureTarget : NSObject
@end
@implementation SXProbeGestureTarget
- (void)trigger:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) SXOpenPanel();
}
- (void)openFromButton:(__unused UIButton *)sender { SXOpenPanel(); }
@end
static SXProbeGestureTarget *SXGestureTarget;
static char SXInstalledEntryKey;
static void SXInstallTemporaryEntry(void) {
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.atebits.Tweetie2"]) return;
    if (!SXGestureTarget) SXGestureTarget = [SXProbeGestureTarget new];
    for (UIWindow *w in SXProbeWindows()) {
        if (!w.isKeyWindow || !w.rootViewController) continue;
        if (objc_getAssociatedObject(w, &SXInstalledEntryKey)) continue;
        // Visible temporary entry proves that the dylib loaded into official X.
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(54, 26, 42, 32);
        button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        [button setTitle:@"SX" forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        button.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.90];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.layer.cornerRadius = 8;
        [button addTarget:SXGestureTarget action:@selector(openFromButton:) forControlEvents:UIControlEventTouchUpInside];
        [w addSubview:button];
        objc_setAssociatedObject(w, &SXInstalledEntryKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
__attribute__((constructor))
static void SXProbeInit(void) {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.atebits.Tweetie2"]) return;
        SXInitializeLog();
        if(SXEnabled) SXRecord(@"recording-restored",@{@"enabled":@YES});
        SXRecordingRestored=SXEnabled;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                SXInstallTemporaryEntry();
                SXInstallProfileFontObservers();
            }];
            SXInstallTemporaryEntry();
            SXInstallProfileFontObservers();
            SXCollectAutomaticMethodMetadataIfEnabled();
        });
            [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                SXInstallTemporaryEntry();
            }];
    }
}
