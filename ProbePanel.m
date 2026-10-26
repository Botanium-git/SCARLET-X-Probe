#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <string.h>
#include <math.h>
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
// Read-only ABI preflight for the profile owner's own bio configuration path.
// No method replacement, argument invocation, or text extraction.
// ABI-only check for the bio font getter found in the older X binary.
static void SXRecordBioFontCandidates(void) {
    NSMutableArray *hits=[NSMutableArray array];
    for(NSString *name in @[@"T1ProfileUserInfoView",@"T1UserView",@"TFNAttributedTextView"]) {
        Class cls=objc_getClass(name.UTF8String);
        SEL selector=NSSelectorFromString(@"bioFont");
        Method method=cls?class_getInstanceMethod(cls,selector):NULL;
        const char *types=method?method_getTypeEncoding(method):NULL;
        [hits addObject:@{@"class":name,@"exists":@(method!=NULL),
          @"typeEncoding":types?[NSString stringWithUTF8String:types]:@"",
          @"implementationImage":method?SXIMPImageName(method_getImplementation(method)):@"missing"}];
    }
    SXRecord(@"profile-bio-font-candidates",@{@"methods":hits,@"valuesRead":@NO});
}
// Read ABI and Objective-C member declarations only; do not invoke private methods or read values.
static void SXRecordProfileTypographyStructure(void) {
    Class cls=objc_getClass("T1ProfileUserInfoView");
    NSMutableArray *methods=[NSMutableArray array];
    for(NSString *name in @[@"updateFontSize",@"_t1_setBioLabel:withText:entities:isUTF16Entities:"]) {
        SEL selector=NSSelectorFromString(name);
        Method method=cls?class_getInstanceMethod(cls,selector):NULL;
        const char *encoding=method?method_getTypeEncoding(method):NULL;
        [methods addObject:@{@"selector":name,@"exists":@(method!=NULL),
          @"encoding":encoding?[NSString stringWithUTF8String:encoding]:@""}];
    }
    NSMutableArray *members=[NSMutableArray array];
    for(Class owner=cls;owner && members.count<60;owner=class_getSuperclass(owner)) {
        unsigned int count=0;
        Ivar *ivars=class_copyIvarList(owner,&count);
        for(unsigned int i=0;ivars && i<count && members.count<60;i++) {
            const char *raw=ivar_getName(ivars[i]);
            NSString *name=raw?[NSString stringWithUTF8String:raw]:@"";
            NSString *lower=name.lowercaseString;
            if([lower containsString:@"bio"]||[lower containsString:@"font"]||[lower containsString:@"text"]) {
                const char *type=ivar_getTypeEncoding(ivars[i]);
                [members addObject:@{@"owner":NSStringFromClass(owner),@"name":name,
                  @"type":type?[NSString stringWithUTF8String:type]:@""}];
            }
        }
        if(ivars)free(ivars);
    }
    SXRecord(@"profile-typography-structure",@{@"methods":methods,@"ivars":members,@"valuesRead":@NO});
}
// Discover private text view storage signatures without invoking getters or reading ivar values.
static void SXRecordBioTextViewStructure(void) {
    Class cls=objc_getClass("TFNAttributedTextView");
    NSMutableArray *members=[NSMutableArray array];
    NSMutableArray *properties=[NSMutableArray array];
    for(Class owner=cls;owner && members.count<75;owner=class_getSuperclass(owner)) {
        unsigned int count=0;
        Ivar *ivars=class_copyIvarList(owner,&count);
        for(unsigned int i=0;ivars && i<count && members.count<75;i++) {
            const char *raw=ivar_getName(ivars[i]);
            NSString *name=raw?[NSString stringWithUTF8String:raw]:@"";
            NSString *lower=name.lowercaseString;
            if([lower containsString:@"font"]||[lower containsString:@"text"]||[lower containsString:@"attribut"]||[lower containsString:@"layout"]||[lower containsString:@"render"]||[lower containsString:@"style"]||[lower containsString:@"paragraph"]) {
                const char *type=ivar_getTypeEncoding(ivars[i]);
                [members addObject:@{@"owner":NSStringFromClass(owner),@"name":name,
                  @"type":type?[NSString stringWithUTF8String:type]:@""}];
            }
        }
        if(ivars)free(ivars);
        count=0;
        objc_property_t *props=class_copyPropertyList(owner,&count);
        for(unsigned int i=0;props && i<count && properties.count<75;i++) {
            const char *raw=property_getName(props[i]);
            NSString *name=raw?[NSString stringWithUTF8String:raw]:@"";
            NSString *lower=name.lowercaseString;
            if([lower containsString:@"font"]||[lower containsString:@"text"]||[lower containsString:@"attribut"]||[lower containsString:@"layout"]||[lower containsString:@"render"]||[lower containsString:@"style"]||[lower containsString:@"paragraph"]) {
                const char *type=property_getAttributes(props[i]);
                [properties addObject:@{@"owner":NSStringFromClass(owner),@"name":name,
                  @"attributes":type?[NSString stringWithUTF8String:type]:@""}];
            }
        }
        if(props)free(props);
    }
    SXRecord(@"profile-bio-textview-structure",@{@"class":cls?NSStringFromClass(cls):@"missing",
      @"ivars":members,@"properties":properties,@"valuesRead":@NO});
}
// Class metadata only. This does not access any model/renderer instance or content.
static void SXRecordBioModelRendererStructure(void) {
    NSMutableArray *classes=[NSMutableArray array];
    for(NSString *className in @[@"TFNAttributedTextModel",@"TFNAttributedTextRenderer"]) {
        Class cls=objc_getClass(className.UTF8String);
        NSMutableArray *ivars=[NSMutableArray array];
        NSMutableArray *properties=[NSMutableArray array];
        NSMutableArray *methods=[NSMutableArray array];
        unsigned int count=0;
        Ivar *items=cls?class_copyIvarList(cls,&count):NULL;
        for(unsigned int i=0;items && i<count && ivars.count<100;i++) {
            const char *name=ivar_getName(items[i]), *type=ivar_getTypeEncoding(items[i]);
            [ivars addObject:@{@"name":name?[NSString stringWithUTF8String:name]:@"",
                              @"type":type?[NSString stringWithUTF8String:type]:@""}];
        }
        if(items)free(items);
        count=0;
        objc_property_t *props=cls?class_copyPropertyList(cls,&count):NULL;
        for(unsigned int i=0;props && i<count && properties.count<100;i++) {
            const char *name=property_getName(props[i]), *attrs=property_getAttributes(props[i]);
            [properties addObject:@{@"name":name?[NSString stringWithUTF8String:name]:@"",
                                   @"attributes":attrs?[NSString stringWithUTF8String:attrs]:@""}];
        }
        if(props)free(props);
        count=0;
        Method *ms=cls?class_copyMethodList(cls,&count):NULL;
        for(unsigned int i=0;ms && i<count && methods.count<100;i++) {
            SEL sel=method_getName(ms[i]);
            NSString *name=sel?NSStringFromSelector(sel):@"";
            NSString *lower=name.lowercaseString;
            if([lower containsString:@"font"]||[lower containsString:@"text"]||
               [lower containsString:@"attribut"]||[lower containsString:@"line"]||
               [lower containsString:@"paragraph"]||[lower containsString:@"layout"]||
               [lower containsString:@"render"]) {
                const char *type=method_getTypeEncoding(ms[i]);
                [methods addObject:@{@"selector":name,
                                   @"encoding":type?[NSString stringWithUTF8String:type]:@""}];
            }
        }
        if(ms)free(ms);
        [classes addObject:@{@"class":className,@"exists":@(cls!=Nil),
                             @"ivars":ivars,@"properties":properties,@"methods":methods}];
    }
    SXRecord(@"profile-bio-model-renderer-structure",@{@"classes":classes,@"valuesRead":@NO});
}
static void SXRecordProfileBioSetterABI(void) {
    Class cls=objc_getClass("T1ProfileUserInfoView");
    SEL sel=NSSelectorFromString(@"_t1_setBioLabel:withText:entities:isUTF16Entities:");
    Method method=cls?class_getInstanceMethod(cls,sel):NULL;
    const char *encoding=method?method_getTypeEncoding(method):NULL;
    NSMethodSignature *sig=encoding?[NSMethodSignature signatureWithObjCTypes:encoding]:nil;
    NSMutableArray *arguments=[NSMutableArray array];
    for(NSUInteger i=0;sig && i<sig.numberOfArguments;i++) {
        const char *type=[sig getArgumentTypeAtIndex:i];
        [arguments addObject:type?[NSString stringWithUTF8String:type]:@"unknown"];
    }
    IMP imp=method?method_getImplementation(method):NULL;
    SXRecord(@"profile-bio-setter-abi",@{
        @"class":@"T1ProfileUserInfoView",
        @"selector":NSStringFromSelector(sel),
        @"exists":@(method!=NULL),
        @"typeEncoding":encoding?[NSString stringWithUTF8String:encoding]:@"",
        @"argumentTypes":arguments,
        @"returnType":sig?[NSString stringWithUTF8String:sig.methodReturnType]:@"",
        @"implementationImage":SXIMPImageName(imp),
        @"textCaptured":@NO
    });
}
// Typed, metadata-only observer for X 12.35 profile bio setter.
typedef void (*SXBioSetterIMP)(id,SEL,id,id,id,BOOL);
static SXBioSetterIMP SXOriginalBioSetter=NULL;
static BOOL SXBioSetterInstalled=NO;
static NSUInteger SXBioSetterCalls=0;
// Inspect supported object-returning getters after X has set the bio; do not read text content.
static NSDictionary *SXBioPostSetTypography(id label) {
    if(!label)return @{};
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    for(NSString *name in @[@"font",@"attributedText",@"attributedString",@"attributedActiveTextModel"]) {
        SEL selector=NSSelectorFromString(name);
        Method method=class_getInstanceMethod([label class],selector);
        const char *encoding=method?method_getTypeEncoding(method):NULL;
        NSMethodSignature *sig=encoding?[NSMethodSignature signatureWithObjCTypes:encoding]:nil;
        BOOL safe=(sig && sig.numberOfArguments==2 && strcmp(sig.methodReturnType,"@")==0);
        result[[name stringByAppendingString:@"Available"]]=@(safe);
        if(!safe)continue;
        id value=((id(*)(id,SEL))objc_msgSend)(label,selector);
        if([value isKindOfClass:UIFont.class]) {
            UIFont *font=(UIFont *)value;
            result[@"fontName"]=font.fontName?:@"";
            result[@"fontPointSize"]=@(font.pointSize);
            result[@"fontLineHeight"]=@(font.lineHeight);
        } else if([value isKindOfClass:NSAttributedString.class]) {
            NSAttributedString *rich=(NSAttributedString *)value;
            result[[name stringByAppendingString:@"Length"]]=@(rich.length);
            result[[name stringByAppendingString:@"Typography"]]=SXTypographyMetrics(rich);
        } else {
            result[[name stringByAppendingString:@"Class"]]=value?NSStringFromClass([value class]):@"nil";
        }
    }
    return result;
}
// Inspect the actual TFNAttributedTextModel, not absent UILabel-style font getters.
static NSDictionary *SXBioModelFontSnapshot(id label) {
    if(!label || ![label isKindOfClass:objc_getClass("TFNAttributedTextView")])
        return @{@"status":@"not-bio-textview"};
    SEL modelSel=NSSelectorFromString(@"textModel");
    Method modelMethod=class_getInstanceMethod([label class],modelSel);
    if(!modelMethod || strcmp(method_getTypeEncoding(modelMethod),"@16@0:8")!=0)
        return @{@"status":@"model-getter-unavailable"};
    id model=((id(*)(id,SEL))objc_msgSend)(label,modelSel);
    if(!model)return @{@"status":@"model-not-set"};
    SEL richSel=NSSelectorFromString(@"attributedString");
    Method richMethod=class_getInstanceMethod([model class],richSel);
    if(!richMethod || strcmp(method_getTypeEncoding(richMethod),"@16@0:8")!=0)
        return @{@"status":@"attributed-getter-unavailable"};
    id rich=((id(*)(id,SEL))objc_msgSend)(model,richSel);
    if(![rich isKindOfClass:NSAttributedString.class])
        return @{@"status":@"attributed-string-unavailable"};
    NSAttributedString *styled=(NSAttributedString *)rich;
    return @{@"status":@"captured", @"textLength":@(styled.length),
             @"styleRuns":SXTypographyMetrics(styled),@"textCaptured":@NO};
}
// Observe only setTextModel: calls made synchronously by the profile Bio setter.
typedef void (*SXTextModelSetterIMP)(id,SEL,id);
static SXTextModelSetterIMP SXOriginalTextModelSetter=NULL;
static BOOL SXTextModelSetterInstalled=NO;
static volatile int SXTextModelSetterCalls=0;
static __thread void *SXActiveBioLabel=NULL;
static __thread NSUInteger SXActiveBioCall=0;
// Read-only Bio-scoped initializer snapshots, matching X 12.35 arm64 ABI.
typedef id (*SXModelInit1IMP)(id,SEL,id);
typedef id (*SXModelInit2IMP)(id,SEL,id,id);
static SXModelInit1IMP SXOriginalModelInit1=NULL;
static SXModelInit2IMP SXOriginalModelInit2=NULL;
static BOOL SXModelInit1Installed=NO, SXModelInit2Installed=NO;
static volatile int SXModelInitSamples=0;
static void SXRecordModelInitInput(id rich, NSString *kind) {
    if(!SXEnabled || SXActiveBioCall==0)return;
    int sample=__sync_add_and_fetch(&SXModelInitSamples,1);
    if(sample>24)return;
    NSDictionary *snapshot=@{@"status":@"not-attributed-string"};
    if([rich isKindOfClass:NSAttributedString.class]) {
        NSAttributedString *styled=(NSAttributedString *)rich;
        snapshot=@{@"status":@"captured", @"textLength":@(styled.length),
          @"styleRuns":SXTypographyMetrics(styled), @"textCaptured":@NO};
    }
    SXRecord(@"profile-bio-model-init",@{
      @"callIndex":@(SXActiveBioCall), @"sampleIndex":@(sample),
      @"initializer":kind, @"incomingAttributedString":snapshot,
      @"textCaptured":@NO});
}
static id SXObservedModelInit1(id receiver, SEL selector, id rich) {
    SXRecordModelInitInput(rich,@"initWithAttributedString:");
    return SXOriginalModelInit1?SXOriginalModelInit1(receiver,selector,rich):receiver;
}
static id SXObservedModelInit2(id receiver, SEL selector, id rich, id colorView) {
    SXRecordModelInitInput(rich,@"initWithAttributedString:colorProviderView:");
    return SXOriginalModelInit2?SXOriginalModelInit2(receiver,selector,rich,colorView):receiver;
}
static void SXInstallModelInitObservers(void) {
    Class cls=objc_getClass("TFNAttributedTextModel");
    if(!cls)return;
    SEL first=NSSelectorFromString(@"initWithAttributedString:");
    SEL second=NSSelectorFromString(@"initWithAttributedString:colorProviderView:");
    Method a=class_getInstanceMethod(cls,first);
    Method b=class_getInstanceMethod(cls,second);
    if(!SXModelInit1Installed && a && strcmp(method_getTypeEncoding(a),"@24@0:8@16")==0) {
        IMP imp=method_getImplementation(a);
        if(imp && imp!=(IMP)SXObservedModelInit1) {
            SXOriginalModelInit1=(SXModelInit1IMP)imp;
            class_replaceMethod(cls,first,(IMP)SXObservedModelInit1,method_getTypeEncoding(a));
            SXModelInit1Installed=YES;
        }
    }
    if(!SXModelInit2Installed && b && strcmp(method_getTypeEncoding(b),"@32@0:8@16@24")==0) {
        IMP imp=method_getImplementation(b);
        if(imp && imp!=(IMP)SXObservedModelInit2) {
            SXOriginalModelInit2=(SXModelInit2IMP)imp;
            class_replaceMethod(cls,second,(IMP)SXObservedModelInit2,method_getTypeEncoding(b));
            SXModelInit2Installed=YES;
        }
    }
    SXRecord(@"profile-bio-model-init-hook-status",@{
      @"oneArgumentInstalled":@(SXModelInit1Installed),
      @"twoArgumentInstalled":@(SXModelInit2Installed),
      @"sampleLimit":@24, @"textCaptured":@NO});
}
static void SXObservedTextModelSetter(id receiver,SEL selector,id model) {
    BOOL relevant=((__bridge void *)receiver==SXActiveBioLabel && SXActiveBioCall>0);
    NSUInteger index=SXActiveBioCall;
    int sample=(relevant && SXEnabled)?__sync_add_and_fetch(&SXTextModelSetterCalls,1):0;
    if(sample>0 && sample<=24) {
        NSDictionary *incoming=@{@"status":@"nil-model"};
        if(model) {
            incoming=@{@"status":@"attributed-getter-unavailable"};
            SEL s=NSSelectorFromString(@"attributedString");
            Method m=class_getInstanceMethod([model class],s);
            if(m && strcmp(method_getTypeEncoding(m),"@16@0:8")==0) {
                id rich=((id(*)(id,SEL))objc_msgSend)(model,s);
                if([rich isKindOfClass:NSAttributedString.class]) {
                    NSAttributedString *styled=(NSAttributedString *)rich;
                    incoming=@{@"status":@"captured",@"textLength":@(styled.length),
                      @"styleRuns":SXTypographyMetrics(styled),@"textCaptured":@NO};
                }
            }
        }
        SXRecord(@"profile-bio-set-text-model",@{@"callIndex":@(index),
          @"sampleIndex":@(sample),@"incomingModel":incoming,@"textCaptured":@NO});
    }
    if(SXOriginalTextModelSetter)SXOriginalTextModelSetter(receiver,selector,model);
}
static void SXInstallTextModelSetterObserver(void) {
    if(SXTextModelSetterInstalled)return;
    Class cls=objc_getClass("TFNAttributedTextView");
    SEL sel=NSSelectorFromString(@"setTextModel:");
    Method method=cls?class_getInstanceMethod(cls,sel):NULL;
    const char *abi=method?method_getTypeEncoding(method):NULL;
    if(!abi || strcmp(abi,"v24@0:8@16")!=0)return;
    IMP previous=method_getImplementation(method);
    if(!previous || previous==(IMP)SXObservedTextModelSetter)return;
    SXOriginalTextModelSetter=(SXTextModelSetterIMP)previous;
    class_replaceMethod(cls,sel,(IMP)SXObservedTextModelSetter,abi);
    SXTextModelSetterInstalled=YES;
    SXRecord(@"profile-bio-text-model-hook-installed",@{
      @"abiVerified":@YES,@"originalImage":SXIMPImageName(previous),
      @"textCaptured":@NO,@"sampleLimit":@24});
}
static void SXObservedBioSetter(id target,SEL selector,id label,id text,id entities,BOOL utf16) {
    SXBioSetterCalls++;
    if(SXEnabled && SXBioSetterCalls<=40) {
        NSMutableDictionary *meta=[@{
            @"callIndex":@(SXBioSetterCalls),
            @"labelClass":label?NSStringFromClass([label class]):@"nil",
            @"textClass":text?NSStringFromClass([text class]):@"nil",
            @"entitiesClass":entities?NSStringFromClass([entities class]):@"nil",
            @"utf16Entities":@(utf16),
            @"textCaptured":@NO
        } mutableCopy];
        if([label isKindOfClass:UIView.class]) {
            UIView *view=(UIView *)label;
            meta[@"labelWidth"]=@(view.bounds.size.width);
            meta[@"labelHeight"]=@(view.bounds.size.height);
        }
        SXRecord(@"profile-bio-setter-call",meta);
    }
    // Same label and call index as post-set: capture the model before X mutates it.
    if(SXEnabled && SXBioSetterCalls<=20 && [label isKindOfClass:UIView.class]) {
        SXRecord(@"profile-bio-model-before",@{
            @"callIndex":@(SXBioSetterCalls),
            @"model":SXBioModelFontSnapshot(label),
            @"textCaptured":@NO});
    }
    void *previousLabel=SXActiveBioLabel;
    NSUInteger previousCall=SXActiveBioCall;
    SXActiveBioLabel=(__bridge void *)label;
    SXActiveBioCall=SXBioSetterCalls;
    if(SXOriginalBioSetter)SXOriginalBioSetter(target,selector,label,text,entities,utf16);
    SXActiveBioLabel=previousLabel;
    SXActiveBioCall=previousCall;
    if(SXEnabled && SXBioSetterCalls<=20 && [label isKindOfClass:UIView.class]) {
        NSMutableDictionary *meta=[SXBioPostSetTypography(label) mutableCopy];
        meta[@"callIndex"]=@(SXBioSetterCalls);
        meta[@"textCaptured"]=@NO;
        SXRecord(@"profile-bio-postset-typography",meta);
        SXRecord(@"profile-bio-model-immediate",@{
            @"callIndex":@(SXBioSetterCalls),
            @"model":SXBioModelFontSnapshot(label),@"textCaptured":@NO});
        NSUInteger capturedIndex=SXBioSetterCalls;
        __weak id weakLabel=label;
        dispatch_async(dispatch_get_main_queue(), ^{
            id currentLabel=weakLabel;
            if(currentLabel) SXRecord(@"profile-bio-model-next-tick",@{
                @"callIndex":@(capturedIndex),
                @"model":SXBioModelFontSnapshot(currentLabel),@"textCaptured":@NO});
        });
    }
}
static void SXInstallBioSetterObserver(void) {
    if(SXBioSetterInstalled)return;
    Class cls=objc_getClass("T1ProfileUserInfoView");
    SEL sel=NSSelectorFromString(@"_t1_setBioLabel:withText:entities:isUTF16Entities:");
    Method method=cls?class_getInstanceMethod(cls,sel):NULL;
    const char *abi=method?method_getTypeEncoding(method):NULL;
    if(!abi || strcmp(abi,"v44@0:8@16@24@32B40"))return;
    IMP previous=method_getImplementation(method);
    if(!previous)return;
    SXOriginalBioSetter=(SXBioSetterIMP)previous;
    class_replaceMethod(cls,sel,(IMP)SXObservedBioSetter,abi);
    SXBioSetterInstalled=YES;
    SXRecord(@"profile-bio-setter-observer-installed",@{@"abiVerified":@YES,@"textCaptured":@NO});
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
// Only called by the explicit manual profile measurement, not by startup scans.
static void SXCaptureVisibleBioText(UIView *view,NSMutableDictionary *entry) {
    if(!view.window || view.hidden || view.alpha<=0.01 || CGRectIsEmpty(view.bounds))return;
    NSString *value=nil;NSString *source=nil;
    if([view isKindOfClass:UILabel.class]){value=((UILabel *)view).text;source=@"UILabel.text";}
    else if([view isKindOfClass:UITextView.class]){value=((UITextView *)view).text;source=@"UITextView.text";}
    else if([NSStringFromClass(view.class) isEqualToString:@"TFNAttributedTextView"]) {
        // No invocation of unknown private getters: only UIKit accessibility metadata.
        value=view.accessibilityLabel;source=@"accessibilityLabel";
    }
    if(![value isKindOfClass:NSString.class] || !value.length)return;
    NSUInteger limit=1500;
    entry[@"visibleText"]=[value substringToIndex:MIN(value.length,limit)];
    entry[@"textLength"]=@(value.length);
    entry[@"textTruncated"]=@(value.length>limit);
    entry[@"explicitNewlines"]=@([[value componentsSeparatedByString:@"\n"] count]-1);
    entry[@"textSource"]=source;
}
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
            if([kind isEqualToString:@"TFNAttributedTextView"])SXCaptureVisibleBioText(v,entry);
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
// Manual, main-thread-only capture of typography from the actual profile bio view.
// Never export the user's bio text or attributed-string contents.
// Read-only font decision context; this enumerates possible providers, not a proven call graph.
// Manual read-only snapshot of the actual UIFont class token used by the bio setter.
// No interception, content access, global-state mutation, or calls to private setters.
// ABI-gated, pass-through observation of the verified TAEFontSettings class method.
// No content or account identifiers are collected; the return value is unchanged.
typedef double (*SXFontWidthCalcIMP)(id,SEL,double,id,NSInteger,CGSize);
static SXFontWidthCalcIMP SXOriginalFontWidthCalc=NULL;
static BOOL SXFontWidthCalcInstalled=NO;
static int SXFontWidthCalcCalls=0;
static int SXFontWidthCalcEligible=0;
static int SXFontWidthCalcQueued=0;
static double SXObservedFontWidthCalc(id receiver,SEL selector,double baseline,id category,
                                      NSInteger modifier,CGSize windowSize) {
    SXFontWidthCalcIMP original=SXOriginalFontWidthCalc;
    if(!original)return baseline; // installation always checks this first
    double result=original(receiver,selector,baseline,category,modifier,windowSize);
    int call=__sync_add_and_fetch(&SXFontWidthCalcCalls,1);
    if(call<=64 && SXEnabled && SXQueue) {
        __sync_add_and_fetch(&SXFontWidthCalcEligible,1);
        NSString *categoryName=[category isKindOfClass:NSString.class]?(NSString *)category:@"(non-string)";
        NSDictionary *fields=@{@"callIndex":@(call),@"baseline":@(baseline),
          @"contentSizeCategory":categoryName,@"modifier":@(modifier),
          @"windowSize":@[@(windowSize.width),@(windowSize.height)],
          @"result":@(result),@"textCaptured":@NO};
        __sync_add_and_fetch(&SXFontWidthCalcQueued,1);
        dispatch_async(dispatch_get_main_queue(), ^{ SXRecord(@"font-width-calculation-call",fields); });
    }
    return result;
}
static void SXInstallFontWidthCalcObserver(void) {
    if(SXFontWidthCalcInstalled)return;
    Class cls=objc_getClass("TAEFontSettings");
    if(!cls)return;
    SEL sel=NSSelectorFromString(@"fontSizeWithBaselineFontSize:contentSizeCategory:contentSizeModifier:windowSize:");
    Method method=class_getClassMethod(cls,sel);
    const char *abi=method?method_getTypeEncoding(method):NULL;
    if(!abi || strcmp(abi,"d56@0:8d16@24q32{CGSize=dd}40")!=0)return;
    IMP imp=method_getImplementation(method);
    if(!imp || imp==(IMP)SXObservedFontWidthCalc)return;
    SXOriginalFontWidthCalc=(SXFontWidthCalcIMP)imp;
    class_replaceMethod(object_getClass(cls),sel,(IMP)SXObservedFontWidthCalc,abi);
    SXFontWidthCalcInstalled=YES;
    SXRecord(@"font-width-calculation-hook-installed",@{@"abiVerified":@YES,
      @"originalImage":SXIMPImageName(imp),@"limit":@64,@"textCaptured":@NO});
}
static NSDictionary *SXBioRenderedMetrics(void);
// Passive, ABI-checked observer: preserves the original font updater.
typedef void (*SXProfileUpdateFontIMP)(id,SEL);
static SXProfileUpdateFontIMP SXOriginalProfileUpdateFont=NULL;
static BOOL SXProfileUpdateFontInstalled=NO;
static volatile int SXProfileUpdateFontCalls=0;
static void SXObservedProfileUpdateFont(id receiver, SEL selector) {
    SXProfileUpdateFontIMP original=SXOriginalProfileUpdateFont;
    if(!original)return;
    original(receiver,selector);
    int index=__sync_add_and_fetch(&SXProfileUpdateFontCalls,1);
    if(index<=12 && SXEnabled && SXQueue) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDictionary *metrics=SXBioRenderedMetrics();
            SXRecord(@"profile-update-font-call",@{
                @"callIndex":@(index),@"renderedMetricsStatus":metrics[@"status"]?:@"captured",
                @"bioStyleRuns":metrics[@"styleRuns"]?:@[],
                @"bioFrame":metrics[@"bioFrame"]?:@[],
                @"textCaptured":@NO
            });
        });
    }
}
static void SXInstallProfileUpdateFontObserver(void) {
    if(SXProfileUpdateFontInstalled)return;
    Class cls=objc_getClass("T1ProfileUserInfoView");
    SEL selector=NSSelectorFromString(@"updateFontSize");
    Method method=cls?class_getInstanceMethod(cls,selector):NULL;
    const char *abi=method?method_getTypeEncoding(method):NULL;
    if(!abi || strcmp(abi,"v16@0:8")!=0)return;
    IMP current=method_getImplementation(method);
    if(!current || current==(IMP)SXObservedProfileUpdateFont)return;
    SXOriginalProfileUpdateFont=(SXProfileUpdateFontIMP)current;
    class_replaceMethod(cls,selector,(IMP)SXObservedProfileUpdateFont,abi);
    SXProfileUpdateFontInstalled=YES;
    SXRecord(@"profile-update-font-hook-installed",@{
      @"originalImage":SXIMPImageName(current),@"abiVerified":@YES,
      @"sampleLimit":@12,@"textCaptured":@NO});
}
// Targeted, read-only ABI discovery. No class-list enumeration or method replacement.
static void SXRecordFontWidthABIMetadata(void) {
    NSArray<NSString *> *names=@[@"tfn_defaultFontSize",
      @"fontSizeWithBaselineFontSize:contentSizeCategory:contentSizeModifier:windowSize:",
      @"isFontSizeIgnoreDeviceWidthEnabled",
      @"tfn_dynamicFontSizeOffsetBy:",@"tfn_dynamicFontSize"];
    NSMutableArray *methods=[NSMutableArray array];
    // UIFont is confirmed by the original X binary as the default-font receiver.
    // Other classes are inspected only if named explicitly, without runtime-wide enumeration.
    for(NSString *className in @[@"UIFont",@"TAEFontSettings"]) {
        Class cls=objc_getClass(className.UTF8String);
        if(!cls)continue;
        for(NSString *name in names) {
            SEL sel=NSSelectorFromString(name);
            for(int kind=0;kind<2;kind++) {
                Method method=kind?class_getClassMethod(cls,sel):class_getInstanceMethod(cls,sel);
                if(!method)continue;
                const char *encoding=method_getTypeEncoding(method);
                [methods addObject:@{@"class":className,@"selector":name,
                  @"classMethod":@(kind!=0),
                  @"typeEncoding":encoding?[NSString stringWithUTF8String:encoding]:@"",
                  @"implementationImage":SXIMPImageName(method_getImplementation(method))}];
            }
        }
    }
    CGSize screen=UIScreen.mainScreen.bounds.size;
    NSMutableArray *windows=[NSMutableArray array];
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class] ||
           scene.activationState!=UISceneActivationStateForegroundActive)continue;
        for(UIWindow *window in ((UIWindowScene *)scene).windows) {
            if(window.hidden)continue;
            CGSize size=window.bounds.size;
            [windows addObject:@{@"points":@[@(size.width),@(size.height)],
              @"key":@(window.isKeyWindow)}];
        }
    }
    SXRecord(@"font-width-abi-metadata",@{@"methods":methods,
      @"screenPoints":@[@(screen.width),@(screen.height)],
      @"visibleWindows":windows,@"actualHelperArgumentsObserved":@NO,
      @"privateMethodsInvoked":@NO,@"textCaptured":@NO});
}
static void SXRecordBioFontTokenRuntime(void) {
    Class fontClass=objc_getClass("UIFont");
    SEL tokenSel=NSSelectorFromString(@"xds_body");
    Method tokenMethod=fontClass?class_getClassMethod(fontClass,tokenSel):NULL;
    NSMutableDictionary *result=[@{@"selector":@"xds_body",
      @"methodPresent":@(tokenMethod!=NULL),@"valuesRead":@NO,
      @"textCaptured":@NO} mutableCopy];
    if(tokenMethod) {
        const char *types=method_getTypeEncoding(tokenMethod);
        result[@"typeEncoding"]=types?[NSString stringWithUTF8String:types]:@"";
        result[@"implementationImage"]=SXIMPImageName(method_getImplementation(tokenMethod));
        // Only invoke the known zero-argument object-returning getter on UIFont.
        NSMethodSignature *signature=types?[NSMethodSignature signatureWithObjCTypes:types]:nil;
        if(signature && signature.numberOfArguments==2 &&
           signature.methodReturnLength==sizeof(id) && types[0]=='@') {
            @try {
                UIFont *(*getter)(id,SEL)=(UIFont *(*)(id,SEL))method_getImplementation(tokenMethod);
                id value=getter(fontClass,tokenSel);
                if([value isKindOfClass:UIFont.class]) {
                    UIFont *font=(UIFont *)value;
                    result[@"fontName"]=font.fontName?:@"";
                    result[@"pointSize"]=@(font.pointSize);
                    result[@"lineHeight"]=@(font.lineHeight);
                    result[@"valuesRead"]=@YES;
                } else result[@"returnedClass"]=value?NSStringFromClass([value class]):@"nil";
            } @catch(NSException *exception) {
                result[@"getterException"]=exception.name?:@"unknown";
            }
        } else result[@"reason"]=@"ABI mismatch; getter not called";
    }
    SXRecord(@"profile-bio-xds-body-runtime",result);
}
static NSDictionary *SXBioFontDecisionContext(void) {
    NSMutableArray *classes=[NSMutableArray array];
    for(NSString *className in @[@"T1ProfileUserInfoView",@"T1ProfileHeaderView",@"TFNAttributedTextView",@"TFNLayoutMetrics"]) {
        Class cls=objc_getClass(className.UTF8String);
        NSMutableArray *methods=[NSMutableArray array];
        if(cls) {
            unsigned int count=0;
            Method *items=class_copyMethodList(cls,&count);
            for(unsigned int i=0;items&&i<count;i++) {
                SEL sel=method_getName(items[i]);
                NSString *name=NSStringFromSelector(sel);
                NSString *lower=name.lowercaseString;
                if([lower containsString:@"font"]||[lower containsString:@"textsize"]||
                   [lower containsString:@"contentsize"]||[lower containsString:@"layoutmetrics"]) {
                    const char *encoding=method_getTypeEncoding(items[i]);
                    Dl_info info={0};
                    dladdr((void *)method_getImplementation(items[i]),&info);
                    NSString *path=info.dli_fname?[NSString stringWithUTF8String:info.dli_fname]:@"";
                    [methods addObject:@{@"selector":name,@"typeEncoding":encoding?[NSString stringWithUTF8String:encoding]:@"",
                                         @"implementationImage":path.lastPathComponent?:@""}];
                }
            }
            if(items)free(items);
        }
        [classes addObject:@{@"class":className,@"exists":@(cls!=Nil),@"methods":methods}];
    }
    UIScreen *screen=UIScreen.mainScreen;
    UIWindow *window=nil;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class]||scene.activationState!=UISceneActivationStateForegroundActive)continue;
        for(UIWindow *w in ((UIWindowScene *)scene).windows)if(!w.hidden){window=w;break;}
        if(window)break;
    }
    CGSize screenSize=screen.bounds.size;
    CGSize windowSize=window?window.bounds.size:CGSizeZero;
    NSString *category=window.traitCollection.preferredContentSizeCategory?:@"";
    return @{@"classes":classes,@"screenPoints":@[@(screenSize.width),@(screenSize.height)],
             @"windowPoints":@[@(windowSize.width),@(windowSize.height)],
             @"displayScale":@(screen.scale),@"contentSizeCategory":category,
             @"windowHorizontalSizeClass":@(window.traitCollection.horizontalSizeClass),
             @"textCaptured":@NO};
}
static NSDictionary *SXBioRenderedMetrics(void) {
    if(![NSThread isMainThread])return @{@"status":@"main-thread-required"};
    Class profileClass=objc_getClass("T1ProfileUserInfoView");
    Class textClass=objc_getClass("TFNAttributedTextView");
    Class modelClass=objc_getClass("TFNAttributedTextModel");
    Ivar bioIvar=profileClass?class_getInstanceVariable(profileClass,"_bioLabel"):NULL;
    Ivar modelIvar=textClass?class_getInstanceVariable(textClass,"_textModel"):NULL;
    if(!bioIvar||!modelIvar||!modelClass)return @{@"status":@"missing-required-class-or-ivar"};
    SEL getRendered=NSSelectorFromString(@"renderedAttributedString");
    Method renderedMethod=class_getInstanceMethod(modelClass,getRendered);
    if(!renderedMethod||strcmp(method_getTypeEncoding(renderedMethod),"@16@0:8")!=0)
        return @{@"status":@"rendered-getter-abi-mismatch"};
    NSMutableArray *stack=[NSMutableArray array];
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class]||scene.activationState!=UISceneActivationStateForegroundActive)continue;
        for(UIWindow *w in ((UIWindowScene *)scene).windows)if(!w.hidden)[stack addObject:w];
    }
    NSUInteger visited=0;
    while(stack.count&&visited++<1500) {
        UIView *v=stack.lastObject;[stack removeLastObject];
        if([v isKindOfClass:profileClass]&&v.window&&!v.hidden) {
            id label=object_getIvar(v,bioIvar);
            if(!label||![label isKindOfClass:textClass])continue;
            id model=object_getIvar(label,modelIvar);
            if(!model||![model isKindOfClass:modelClass])return @{@"status":@"model-unavailable"};
            id value=((id(*)(id,SEL))objc_msgSend)(model,getRendered);
            if(![value isKindOfClass:NSAttributedString.class])return @{@"status":@"rendered-string-unavailable"};
            NSAttributedString *a=(NSAttributedString *)value;
            NSMutableArray *styles=[NSMutableArray array];
            if(a.length) {
                [a enumerateAttributesInRange:NSMakeRange(0,a.length) options:0 usingBlock:^(NSDictionary *attrs,NSRange range,BOOL *stop) {
                    if(styles.count>=12){*stop=YES;return;}
                    id font=attrs[NSFontAttributeName], paragraph=attrs[NSParagraphStyleAttributeName];
                    NSMutableDictionary *one=[NSMutableDictionary dictionary];
                    one[@"rangeLength"]=@(range.length);
                    if([font isKindOfClass:UIFont.class]) {
                        UIFont *f=(UIFont *)font;
                        one[@"fontName"]=f.fontName?:@"";
                        one[@"pointSize"]=@(f.pointSize);
                        one[@"lineHeight"]=@(f.lineHeight);
                    }
                    if([paragraph isKindOfClass:NSParagraphStyle.class]) {
                        NSParagraphStyle *p=(NSParagraphStyle *)paragraph;
                        one[@"lineSpacing"]=@(p.lineSpacing);
                        one[@"paragraphSpacing"]=@(p.paragraphSpacing);
                        one[@"minimumLineHeight"]=@(p.minimumLineHeight);
                        one[@"maximumLineHeight"]=@(p.maximumLineHeight);
                        one[@"lineHeightMultiple"]=@(p.lineHeightMultiple);
                        one[@"alignment"]=@(p.alignment);
                        one[@"lineBreakMode"]=@(p.lineBreakMode);
                    }
                    [styles addObject:one];
                }];
            }
            NSMutableDictionary *layout=[NSMutableDictionary dictionary];
            Ivar rangesIvar=class_getInstanceVariable(modelClass,"_lineRanges");
            if(rangesIvar && strcmp(ivar_getTypeEncoding(rangesIvar),"@\"NSArray\"")==0) {
                id ranges=object_getIvar(model,rangesIvar);
                if([ranges isKindOfClass:NSArray.class]) {
                    NSMutableArray *lineLengths=[NSMutableArray array];
                    for(id item in (NSArray *)ranges) {
                        if(lineLengths.count>=40)break;
                        if([item isKindOfClass:NSValue.class] && strcmp([(NSValue *)item objCType],@encode(NSRange))==0) {
                            NSRange line=[(NSValue *)item rangeValue];
                            [lineLengths addObject:@{@"location":@(line.location),@"length":@(line.length)}];
                        }
                    }
                    layout[@"lineCount"]=@([(NSArray *)ranges count]);
                    layout[@"lineRanges"]=lineLengths;
                }
            }
            // Independently measure the same CTFrame line widths used by the
            // suspected X 12.25 sizing function. Read-only diagnostic.
            SEL frameSEL=NSSelectorFromString(@"coreTextFrame");
            Method frameMethod=class_getInstanceMethod(modelClass,frameSEL);
            if(frameMethod && strncmp(method_getTypeEncoding(frameMethod),"^{__CTFrame=}",12)==0) {
                CTFrameRef ctFrame=((CTFrameRef(*)(id,SEL))objc_msgSend)(model,frameSEL);
                if(ctFrame) {
                    CFArrayRef lines=CTFrameGetLines(ctFrame);
                    CFIndex count=lines?CFArrayGetCount(lines):0;
                    NSMutableArray *widths=[NSMutableArray array];
                    double largest=0;
                    for(CFIndex idx=0;idx<count && idx<100;idx++) {
                        CTLineRef line=(CTLineRef)CFArrayGetValueAtIndex(lines,idx);
                        double w=CTLineGetTypographicBounds(line,NULL,NULL,NULL);
                        if(isfinite(w)&&w>=0) {
                            [widths addObject:@(w)];
                            largest=fmax(largest,w);
                        }
                    }
                    // OX-012 height verification: report native Core Text baseline
                    // geometry without altering the model or its CTFrame.
                    if(count>0 && count<=100) {
                        CGPoint origins[100]={0};
                        CTFrameGetLineOrigins(ctFrame,CFRangeMake(0,count),origins);
                        NSMutableArray *lineGeometry=[NSMutableArray arrayWithCapacity:(NSUInteger)count];
                        for(CFIndex idx=0;idx<count;idx++) {
                            CTLineRef line=(CTLineRef)CFArrayGetValueAtIndex(lines,idx);
                            CGFloat ascent=0,descent=0,leading=0;
                            double lineWidth=CTLineGetTypographicBounds(line,&ascent,&descent,&leading);
                            if(isfinite(lineWidth)&&isfinite(ascent)&&isfinite(descent)&&isfinite(leading)&&
                               isfinite(origins[idx].x)&&isfinite(origins[idx].y)) {
                                CFRange range=CTLineGetStringRange(line);
                                [lineGeometry addObject:@{@"index":@(idx),@"origin":@[@(origins[idx].x),@(origins[idx].y)],
                                  @"ascent":@(ascent),@"descent":@(descent),@"leading":@(leading),
                                  @"typographicWidth":@(lineWidth),
                                  @"stringRange":@{@"location":@(range.location),@"length":@(range.length)}}];
                            }
                        }
                        layout[@"coreTextLineGeometry"]=lineGeometry;
                        CGPathRef path=CTFrameGetPath(ctFrame);
                        CGRect rect=CGRectZero;
                        BOOL rectPath=path && CGPathIsRect(path,&rect);
                        layout[@"coreTextPathIsRect"]=@(rectPath);
                        if(rectPath && isfinite(CGRectGetMaxY(rect))) {
                            layout[@"coreTextPathRect"]=@[@(rect.origin.x),@(rect.origin.y),@(rect.size.width),@(rect.size.height)];
                            if([lineGeometry count]==(NSUInteger)count) {
                                NSDictionary *last=lineGeometry.lastObject;
                                double originY=[last[@"origin"][1] doubleValue];
                                double asc=[last[@"ascent"] doubleValue];
                                double desc=[last[@"descent"] doubleValue];
                                float base=fmaxf((float)(CGRectGetMaxY(rect)-originY),(float)asc);
                                float raw=(float)((double)base+desc+3.0);
                                if(isfinite(raw)) {
                                    layout[@"coreTextHeightOX012Candidate"]=@(ceilf(raw));
                                    layout[@"coreTextHeightOX012Raw"]=@(raw);
                                    layout[@"coreTextHeightOX012LastLineIndex"]=@(count-1);
                                }
                            }
                        }
                    }
                    layout[@"coreTextLineWidths"]=widths;
                    layout[@"coreTextLineCount"]=@(count);
                    layout[@"coreTextMaxLineWidthCeil"]=@(ceil(largest));
                }
            }
            Ivar actualIvar=class_getInstanceVariable(modelClass,"_actualSize");
            if(actualIvar && ivar_getTypeEncoding(actualIvar)[0]=='{') {
                CGSize size=CGSizeZero;
                memcpy(&size,(const char *)(__bridge const void *)model+ivar_getOffset(actualIvar),sizeof(size));
                if(isfinite(size.width)&&isfinite(size.height)&&size.width>=0&&size.height>=0)
                    layout[@"actualSize"]=@[@(size.width),@(size.height)];
            }
            // Compare caller-requested Core Text bounds with the measured output.
            Ivar requestedIvar=class_getInstanceVariable(modelClass,"_requestedSize");
            if(requestedIvar && ivar_getTypeEncoding(requestedIvar) && ivar_getTypeEncoding(requestedIvar)[0]=='{') {
                CGSize requested=CGSizeZero;
                memcpy(&requested,(const char *)(__bridge const void *)model+ivar_getOffset(requestedIvar),sizeof(requested));
                if(isfinite(requested.width)&&isfinite(requested.height)) {
                    layout[@"requestedSize"]=@[@(requested.width),@(requested.height)];
                    if(layout[@"actualSize"]) {
                        NSArray *actual=layout[@"actualSize"];
                        layout[@"requestedMinusActualWidth"]=@(requested.width-[actual[0] doubleValue]);
                    }
                }
            }
            double preferred=[label respondsToSelector:NSSelectorFromString(@"preferredMaxLayoutWidth")]?
                ((double(*)(id,SEL))objc_msgSend)(label,NSSelectorFromString(@"preferredMaxLayoutWidth")):NAN;
            if(isfinite(preferred))layout[@"preferredMaxLayoutWidth"]=@(preferred);
            for(NSString *name in @[@"_contentTopPadding",@"_contentBottomPadding"]) {
                Ivar paddingIvar=class_getInstanceVariable(modelClass,name.UTF8String);
                if(paddingIvar && strcmp(ivar_getTypeEncoding(paddingIvar),"d")==0) {
                    double value=0;
                    memcpy(&value,(const char *)(__bridge const void *)model+ivar_getOffset(paddingIvar),sizeof(value));
                    if(isfinite(value))layout[[name substringFromIndex:1]]=@(value);
                }
            }
            CGRect bioFrame=((UIView *)label).frame;
            return @{@"status":@"captured",@"textLength":@(a.length),
                     @"bioFrame":@[@(bioFrame.origin.x),@(bioFrame.origin.y),@(bioFrame.size.width),@(bioFrame.size.height)],
                     @"styleRuns":styles,@"layoutMetrics":layout,@"textCaptured":@NO};
        }
        for(UIView *child in v.subviews)if(stack.count<2000)[stack addObject:child];
    }
    return @{@"status":@"profile-view-not-found"};
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
             @"manualVisibleTextCapture":@YES};
}

@interface SXProbePanel : UITableViewController
@property(nonatomic,copy) NSString *updateNotice;
@property(nonatomic,strong) NSTimer *updatePollTimer;
@property(nonatomic,assign) BOOL updateRequestInFlight;
@property(nonatomic,copy) NSString *downloadStatus;
@end

@implementation SXProbePanel
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SXP";
    self.updateNotice = @"更新確認中…";
    self.downloadStatus = [[NSUserDefaults standardUserDefaults] stringForKey:SXOperationStatusKey] ?: @"未実行";
    [self refreshUpdateNotice];
    if (SXEnabled && !SXRecordingRestored) {
        SXRecordingRestored = YES;
        SXRecord(@"recording-restored",@{@"enabled":@YES});
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(driveUpdated:) name:@"SXDriveStateChanged" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(operationUpdated:) name:@"SXPOperationStatusChanged" object:nil];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closePanel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"共有" style:UIBarButtonItemStylePlain target:self action:@selector(exportJSON)];
}
- (void)dealloc { [self.updatePollTimer invalidate]; [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.updatePollTimer invalidate];self.updatePollTimer=nil;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshUpdateNotice];
}
- (void)refreshUpdateNotice {
    if(self.updateRequestInFlight || !self.isViewLoaded || !self.view.window)return;
    self.updateRequestInFlight=YES;
    __weak typeof(self) weakSelf=self;
    SXProbeCheckUpdateNotice(^(NSString *notice) {
        __strong typeof(weakSelf) strongSelf=weakSelf;
        if(!strongSelf)return;
        strongSelf.updateRequestInFlight=NO;
        strongSelf.updateNotice=notice?:@"";
        [strongSelf.tableView reloadData];
        [strongSelf.updatePollTimer invalidate];strongSelf.updatePollTimer=nil;
        BOOL building=[notice isEqualToString:@"ビルド中"] || [notice isEqualToString:@"ビルド待機中"];
        if(building && strongSelf.view.window)
            strongSelf.updatePollTimer=[NSTimer scheduledTimerWithTimeInterval:5.0 target:strongSelf selector:@selector(refreshUpdateNotice) userInfo:nil repeats:NO];
    });
}

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
        BOOL building=[self.updateNotice isEqualToString:@"ビルド中"] || [self.updateNotice isEqualToString:@"ビルド待機中"];
        cell.detailTextLabel.text=[NSString stringWithFormat:@"%@  %@",SXProbeOwnVersion(),building?@"":(self.updateNotice?:@"")];
        cell.detailTextLabel.adjustsFontSizeToFitWidth=YES;
        if(building) {
            UILabel *statusLabel=[UILabel new];statusLabel.text=self.updateNotice;
            statusLabel.font=[UIFont systemFontOfSize:12];statusLabel.textColor=UIColor.secondaryLabelColor;
            [statusLabel sizeToFit];
            UIActivityIndicatorView *spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [spinner startAnimating];
            UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[statusLabel,spinner]];
            stack.axis=UILayoutConstraintAxisHorizontal;stack.alignment=UIStackViewAlignmentCenter;stack.spacing=5;
            stack.frame=CGRectMake(0,0,statusLabel.bounds.size.width+spinner.bounds.size.width+5,MAX(statusLabel.bounds.size.height,spinner.bounds.size.height));
            cell.accessoryView=stack;
        } else cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
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
    SXRecordProfileBioSetterABI();
    SXRecordBioFontCandidates();
    SXRecordBioFontTokenRuntime();
    SXRecordFontWidthABIMetadata();
    // Read-only IMP identity of the actual v12.35 profile font updater.
    Class profileClass=objc_getClass("T1ProfileUserInfoView");
    SEL updateSel=NSSelectorFromString(@"updateFontSize");
    Method updateMethod=profileClass?class_getInstanceMethod(profileClass,updateSel):NULL;
    IMP updateIMP=updateMethod?method_getImplementation(updateMethod):NULL;
    Dl_info updateInfo={0};
    BOOL resolved=updateIMP && dladdr((const void *)updateIMP,&updateInfo)!=0;
    NSString *imageName=resolved && updateInfo.dli_fname?
      [[NSString stringWithUTF8String:updateInfo.dli_fname] lastPathComponent]:@"unknown";
    uintptr_t imageOffset=resolved && updateInfo.dli_fbase?
      (uintptr_t)updateIMP-(uintptr_t)updateInfo.dli_fbase:0;
    const char *updateTypes=updateMethod?method_getTypeEncoding(updateMethod):NULL;
    SXRecord(@"profile-update-font-imp",@{
      @"class":@"T1ProfileUserInfoView", @"selector":@"updateFontSize",
      @"exists":@(updateMethod!=NULL), @"typeEncoding":updateTypes?
        [NSString stringWithUTF8String:updateTypes]:@"",
      @"implementationImage":imageName, @"imageRelativeOffset":@(imageOffset),
      @"imageResolved":@(resolved), @"impReadOnly":@YES, @"textCaptured":@NO
    });
    // Compare selected, known profile font selectors without invoking them.
    NSMutableArray *fontImplementations=[NSMutableArray array];
    NSArray *targets=@[
      @[@"T1ProfileUserInfoView",@"updateFontSize"],
      @[@"T1UserView",@"socialTextFont"],
      @[@"T1UserView",@"socialTextFixedFont"]
    ];
    for(NSArray *target in targets) {
        NSString *className=target[0], *selectorName=target[1];
        Class targetClass=objc_getClass(className.UTF8String);
        Method candidate=targetClass?class_getInstanceMethod(targetClass,NSSelectorFromString(selectorName)):NULL;
        IMP candidateIMP=candidate?method_getImplementation(candidate):NULL;
        Dl_info candidateInfo={0};
        BOOL candidateResolved=candidateIMP && dladdr((const void *)candidateIMP,&candidateInfo)!=0;
        NSString *candidateImage=candidateResolved && candidateInfo.dli_fname?
          [[NSString stringWithUTF8String:candidateInfo.dli_fname] lastPathComponent]:@"unknown";
        uintptr_t candidateOffset=candidateResolved && candidateInfo.dli_fbase?
          (uintptr_t)candidateIMP-(uintptr_t)candidateInfo.dli_fbase:0;
        const char *candidateTypes=candidate?method_getTypeEncoding(candidate):NULL;
        [fontImplementations addObject:@{@"class":className,@"selector":selectorName,
          @"exists":@(candidate!=NULL),@"typeEncoding":candidateTypes?
            [NSString stringWithUTF8String:candidateTypes]:@"",
          @"implementationImage":candidateImage,@"imageRelativeOffset":@(candidateOffset),
          @"imageResolved":@(candidateResolved)}];
    }
    SXRecord(@"profile-font-implementation-comparison",@{
      @"methods":fontImplementations,@"methodsInvoked":@NO,@"methodsReplaced":@NO,
      @"textCaptured":@NO
    });


    Class fontClass=objc_getClass("TAEFontSettings");
    SEL fontSel=NSSelectorFromString(@"fontSizeWithBaselineFontSize:contentSizeCategory:contentSizeModifier:windowSize:");
    Method fontMethod=fontClass?class_getClassMethod(fontClass,fontSel):NULL;
    IMP currentFontIMP=fontMethod?method_getImplementation(fontMethod):NULL;
    int observed=__sync_fetch_and_add(&SXFontWidthCalcCalls,0);
    int eligible=__sync_fetch_and_add(&SXFontWidthCalcEligible,0);
    int queued=__sync_fetch_and_add(&SXFontWidthCalcQueued,0);
    SXRecord(@"font-width-calculation-counters",@{@"hookInstalled":@(SXFontWidthCalcInstalled),
      @"currentIsObserver":@(currentFontIMP==(IMP)SXObservedFontWidthCalc),
      @"originalAvailable":@(SXOriginalFontWidthCalc!=NULL),
      @"totalCalls":@(observed),@"eligibleCalls":@(eligible),@"queuedCalls":@(queued),
      @"suppressedByLimit":@(observed>64?observed-64:0),
      @"recordingEnabled":@(SXEnabled),@"queueAvailable":@(SXQueue!=NULL),
      @"sampleLimit":@64,@"textCaptured":@NO});

    SXRecordProfileTypographyStructure();
    SXRecordBioTextViewStructure();
    SXRecordBioModelRendererStructure();
    SXRecord(@"profile-bio-font-decision-context",SXBioFontDecisionContext());
    SXRecord(@"profile-update-font-counters",@{
      @"installed":@(SXProfileUpdateFontInstalled),
      @"calls":@(SXProfileUpdateFontCalls),
      @"sampleLimit":@12,@"textCaptured":@NO
    });
    SXRecord(@"profile-bio-rendered-metrics",SXBioRenderedMetrics());
    SXRecord(@"profile-bio-setter-counters",@{@"installed":@(SXBioSetterInstalled),@"calls":@(SXBioSetterCalls),@"textCaptured":@NO});
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
                SXInstallBioSetterObserver();
                SXInstallTextModelSetterObserver();
                SXInstallModelInitObservers();
                SXInstallFontWidthCalcObserver();
                SXInstallProfileUpdateFontObserver();
            }];
            SXInstallTemporaryEntry();
            SXInstallProfileFontObservers();
            SXInstallBioSetterObserver();
            SXInstallTextModelSetterObserver();
                SXInstallModelInitObservers();
            SXInstallFontWidthCalcObserver();
                SXInstallProfileUpdateFontObserver();
            SXCollectAutomaticMethodMetadataIfEnabled();
        });
            [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                SXInstallTemporaryEntry();
            }];
    }
}
