#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <zlib.h>

// Stage 1: private GitHub credentials and read-only update discovery.
// Deliberately does not download, extract, install or run privileged commands.
// Runs inside the official X app process, so its Keychain access is under X's
// effective app identity. Never collect credentials into diagnostic JSON.
static NSString * const SXUpdateService = @"com.botanium.scarletxprobe.github.actions";
static NSString * const SXUpdateAccount = @"private-actions-read";
static NSString * const SXUpdateRepo = @"Botanium-git/SCARLET-X-Probe";

static NSMutableDictionary *SXUpdateKeyQuery(void) {
    return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService:SXUpdateService,
              (__bridge id)kSecAttrAccount:SXUpdateAccount} mutableCopy];
}
static NSString *SXUpdateToken(void) {
    NSMutableDictionary *q = SXUpdateKeyQuery();
    q[(__bridge id)kSecReturnData] = @YES;
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef output = NULL;
    OSStatus rc = SecItemCopyMatching((__bridge CFDictionaryRef)q, &output);
    if (rc != errSecSuccess || !output) return nil;
    NSData *d = CFBridgingRelease(output);
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}
static BOOL SXUpdateSaveToken(NSString *token) {
    NSData *d = [token dataUsingEncoding:NSUTF8StringEncoding];
    if (!d.length) return NO;
    NSMutableDictionary *q = SXUpdateKeyQuery();
    SecItemDelete((__bridge CFDictionaryRef)q);
    q[(__bridge id)kSecValueData] = d;
    q[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    return SecItemAdd((__bridge CFDictionaryRef)q, NULL) == errSecSuccess;
}
static BOOL SXUpdateDeleteToken(void) {
    OSStatus rc = SecItemDelete((__bridge CFDictionaryRef)SXUpdateKeyQuery());
    return rc == errSecSuccess || rc == errSecItemNotFound;
}

@interface SXNoCredentialRedirect : NSObject <NSURLSessionTaskDelegate>
@end
@implementation SXNoCredentialRedirect
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    completionHandler(nil);
}
@end


static uint16_t SXZip16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1]<<8)); }
static uint32_t SXZip32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1]<<8) | ((uint32_t)p[2]<<16) | ((uint32_t)p[3]<<24); }
// ZIP must contain one ordinary root-level .deb. No paths, symlinks, encryption or ZIP64.
static NSData *SXExtractSingleDeb(NSData *zip) {
    const uint8_t *b=zip.bytes; NSUInteger n=zip.length;
    if(n<76)return nil;
    NSUInteger start=n>65557?n-65557:0, end=NSNotFound;
    for(NSUInteger i=n-22;;i--) {
        if(SXZip32(b+i)==0x06054b50 && i+22+SXZip16(b+i+20)==n) {end=i;break;}
        if(i==start)break;
    }
    if(end==NSNotFound || SXZip16(b+end+4)!=0 || SXZip16(b+end+6)!=0 ||
       SXZip16(b+end+8)!=1 || SXZip16(b+end+10)!=1)return nil;
    NSUInteger central=SXZip32(b+end+16),centralSize=SXZip32(b+end+12);
    if(central>n || centralSize>n-central || centralSize<46 || SXZip32(b+central)!=0x02014b50)return nil;
    NSUInteger count=SXZip16(b+central+28)+SXZip16(b+central+30)+SXZip16(b+central+32)+46;
    if(count!=centralSize || central+count>n)return nil;
    NSUInteger comp=SXZip32(b+central+20),raw=SXZip32(b+central+24),local=SXZip32(b+central+42);
    uint16_t flag=SXZip16(b+central+8),method=SXZip16(b+central+10);
    NSUInteger type=(SXZip32(b+central+38)>>16)&0170000;
    if((flag&1)|| (method!=0 && method!=8) || raw<80 || raw>20*1024*1024 || comp==0 ||
       (type!=0 && type!=0100000) || local>n || n-local<30 || SXZip32(b+local)!=0x04034b50 ||
       SXZip16(b+local+8)!=method)return nil;
    NSData *nameBytes=[NSData dataWithBytes:b+central+46 length:SXZip16(b+central+28)];
    NSString *name=[[NSString alloc]initWithData:nameBytes encoding:NSUTF8StringEncoding];
    if(!name.length || name.length>180 || [name containsString:@"/"] || [name containsString:@"\\"] || ![name hasSuffix:@".deb"])return nil;
    NSUInteger offset=local+30+SXZip16(b+local+26)+SXZip16(b+local+28);
    if(offset>n || comp>n-offset)return nil;
    NSData *deb=nil;
    if(method==0 && comp==raw)deb=[zip subdataWithRange:NSMakeRange(offset,comp)];
    if(method==8) {
        NSMutableData *buf=[NSMutableData dataWithLength:raw];
        z_stream z={0};
        if(inflateInit2(&z,-MAX_WBITS)!=Z_OK)return nil;
        z.next_in=(Bytef *)(b+offset);z.avail_in=(uInt)comp;
        z.next_out=buf.mutableBytes;z.avail_out=(uInt)raw;
        int rc=inflate(&z,Z_FINISH);BOOL ok=rc==Z_STREAM_END && z.total_out==raw && z.total_in==comp;
        inflateEnd(&z);
        if(ok)deb=buf;
    }
    if(!deb || crc32(0,(const Bytef *)deb.bytes,(uInt)deb.length)!=SXZip32(b+central+16))return nil;
    // Minimal Debian ar layout check; internal control metadata is NOT validated here.
    const uint8_t *d=deb.bytes;
    return deb.length>=8 && memcmp(d,(const uint8_t[]){33,60,97,114,99,104,62,10},8)==0 ? deb:nil;
}


// Installed version is generated at package build time for this known Probe revision.
// Never use the official X application's CFBundle version as the Probe version.
NSString *SXProbeOwnVersion(void) { return @"0.1.38"; }
void SXProbeCheckUpdateNotice(void(^done)(NSString *notice)) {
    if(!done)return;
    NSString *token=SXUpdateToken();
    if(!token.length){done(@"認証未設定");return;}
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSString *result=@"確認できませんでした";
        dispatch_semaphore_t sem=dispatch_semaphore_create(0);
        NSString *url=[NSString stringWithFormat:@"https://api.github.com/repos/%@/actions/workflows/build.yml/runs?branch=develop&event=push&per_page=20",SXUpdateRepo];
        NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        req.timeoutInterval=25;
        [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
        NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delegate:[SXNoCredentialRedirect new] delegateQueue:nil];
        __block NSData *raw=nil;__block NSURLResponse *response=nil;__block NSError *failure=nil;
        NSURLSessionDataTask *task=[session dataTaskWithRequest:req completionHandler:^(NSData *data,NSURLResponse *r,NSError *e){raw=data;response=r;failure=e;dispatch_semaphore_signal(sem);}];
        [task resume];
        if(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,40*NSEC_PER_SEC))) {[task cancel];failure=[NSError errorWithDomain:@"SXP" code:1 userInfo:nil];}
        [session invalidateAndCancel];
        if(!failure && [(NSHTTPURLResponse *)response statusCode]==200 && raw.length<2097152) {
            NSDictionary *json=[NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
            NSDictionary *best=nil;
            for(NSDictionary *run in json[@"workflow_runs"]) {
                if(![run isKindOfClass:NSDictionary.class] || ![run[@"head_branch"] isEqual:@"develop"] ||
                   ![run[@"event"] isEqual:@"push"] || ![run[@"path"] hasSuffix:@"build.yml"])continue;
                if(!best || [run[@"id"] longLongValue]>[best[@"id"] longLongValue])best=run;
            }
            NSString *state=[best[@"status"] isKindOfClass:NSString.class]?best[@"status"]:@"";
            NSString *conclusion=[best[@"conclusion"] isKindOfClass:NSString.class]?best[@"conclusion"]:@"";
            if([state isEqual:@"queued"] || [state isEqual:@"waiting"] || [state isEqual:@"pending"] ||
               [state isEqual:@"requested"])result=@"ビルド待機中";
            else if([state isEqual:@"in_progress"])result=@"ビルド中";
            else if([state isEqual:@"completed"] && ![conclusion isEqual:@"success"])
                result=[conclusion isEqual:@"failure"]?@"ビルド失敗":@"ビルド未成功";
            NSString *sha=[best[@"head_sha"] isKindOfClass:NSString.class]?best[@"head_sha"]:nil;
            if([state isEqual:@"completed"] && [conclusion isEqual:@"success"] && sha.length==40) {
                NSString *endpoint=[NSString stringWithFormat:@"https://api.github.com/repos/%@/contents/control?ref=%@",SXUpdateRepo,sha];
                NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
                r.timeoutInterval=25;
                [r setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
                [r setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
                dispatch_semaphore_t gate=dispatch_semaphore_create(0);
                __block NSData *data=nil;__block NSURLResponse *res=nil;__block NSError *err=nil;
                NSURLSession *s2=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delegate:[SXNoCredentialRedirect new] delegateQueue:nil];
                NSURLSessionDataTask *t=[s2 dataTaskWithRequest:r completionHandler:^(NSData *d,NSURLResponse *rr,NSError *e){data=d;res=rr;err=e;dispatch_semaphore_signal(gate);}];
                [t resume];
                if(dispatch_semaphore_wait(gate,dispatch_time(DISPATCH_TIME_NOW,40*NSEC_PER_SEC))){[t cancel];err=[NSError errorWithDomain:@"SXP" code:2 userInfo:nil];}
                [s2 invalidateAndCancel];
                if(!err && [(NSHTTPURLResponse *)res statusCode]==200 && data.length<65536) {
                    NSDictionary *obj=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    NSString *encoded=[obj[@"content"] isKindOfClass:NSString.class]?obj[@"content"]:nil;
                    NSData *decoded=[[NSData alloc]initWithBase64EncodedString:encoded options:NSDataBase64DecodingIgnoreUnknownCharacters];
                    NSString *control=[[NSString alloc]initWithData:decoded encoding:NSUTF8StringEncoding];
                    NSMutableDictionary *fields=[NSMutableDictionary dictionary];
                    for(NSString *line in [control componentsSeparatedByString:@"\n"]) {
                        NSRange separator=[line rangeOfString:@": "];
                        if(separator.location!=NSNotFound)fields[[line substringToIndex:separator.location]]=[line substringFromIndex:separator.location+2];
                    }
                    NSString *v=fields[@"Version"];
                    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"0123456789."];
                    if([fields[@"Package"] isEqual:@"com.botanium.scarletxprobe"] &&
                       [fields[@"Architecture"] isEqual:@"iphoneos-arm64e"] && v.length && v.length<30 &&
                       [v rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound) {
                        NSComparisonResult order=[v compare:SXProbeOwnVersion() options:NSNumericSearch];
                        result=order==NSOrderedDescending?[NSString stringWithFormat:@"最新版 %@ あり",v]:@"";
                    }
                }
            }
        }
        NSString *notice=result;
        dispatch_async(dispatch_get_main_queue(),^{done(notice);});
    });
}

extern BOOL SXDriveIsConnected(void);
extern void SXDriveHandleRow(NSInteger row, UIViewController *host);
@interface SXPrivateUpdater : UITableViewController
@property(nonatomic,copy) NSString *statusText;
@property(nonatomic,assign) BOOL busy;
@property(nonatomic,weak) UIViewController *shareHost;
@property(nonatomic,copy) void (^progress)(NSString *);
@end

@implementation SXPrivateUpdater
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"連携設定";
    self.statusText = @"";
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 2; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)p {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSArray *titles = @[@"Google連携", @"GitHub認証"];
    c.textLabel.text = titles[p.row];
    if (p.row == 0) c.detailTextLabel.text = SXDriveIsConnected() ? @"接続済み" : @"未接続";
    
    if (p.row == 1) c.detailTextLabel.text = SXUpdateToken().length ? @"登録済み" : @"未登録";
    
    
    c.detailTextLabel.numberOfLines = 0;
    c.accessoryType = p.row <= 1 ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return c;
}
- (void)setStatus:(NSString *)message {
    self.statusText = message;
    if(self.progress)self.progress(message);
    [self.tableView reloadData];
}
- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)p {
    [tableView deselectRowAtIndexPath:p animated:YES];
    if (self.busy) return;
    if (p.row == 0) { SXDriveHandleRow(0,self.navigationController ?: self); return; }
    if (p.row == 1) {
        if(SXUpdateToken().length) {
            UIAlertController *manage=[UIAlertController alertControllerWithTitle:@"GitHub認証設定" message:@"GitHubトークンは登録済みです。" preferredStyle:UIAlertControllerStyleActionSheet];
            [manage addAction:[UIAlertAction actionWithTitle:@"変更" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[self promptToken];}]];
            [manage addAction:[UIAlertAction actionWithTitle:@"削除" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){[self confirmTokenDelete];}]];
            [manage addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
            manage.popoverPresentationController.sourceView=self.view;
            manage.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),40,1,1);
            [self presentViewController:manage animated:YES completion:nil];
        } else [self promptToken];
    }
}
- (void)promptToken {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"GitHub認証"
            message:@"SCARLET-X-ProbeのみにActions: Read / Contents: Readを許可した期限付きトークンを入力。公式Xのアプリ領域のKeychainに保存されます。"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"github_pat_...";
            field.secureTextEntry = YES;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        __weak typeof(self) weakSelf = self;
        [a addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            NSString *token = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!token.length || [token containsString:@"\n"]) { [self alert:@"保存できません" message:@"トークンを確認してください。"]; return; }
            [self setStatus:SXUpdateSaveToken(token) ? @"✅ Keychainに保存しました（API認証は未検証）" : @"❌ Keychainへの保存に失敗"];
        }]];
        [self presentViewController:a animated:YES completion:nil];
    }
- (void)confirmTokenDelete {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"トークンを削除？" message:@"削除後は再登録するまで更新できません。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"削除" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self setStatus:SXUpdateDeleteToken()?@"Keychainから削除しました":@"削除に失敗しました"];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)downloadArtifact {
    NSString *token=SXUpdateToken();
    if (!token.length) { [self alert:@"未設定" message:@"GitHubトークンを登録してください。"]; return; }
    self.busy=YES; [self setStatus:@"非公開Actionsの成果物を確認中…"];
    SXPrivateUpdater *worker=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSString *base=[NSString stringWithFormat:@"https://api.github.com/repos/%@",SXUpdateRepo];
        __block NSError *failure=nil;
        __block NSURL *saved=nil;
        NSString *message=nil;
        @try {
            NSDictionary *runs=[self updateJSON:[base stringByAppendingString:@"/actions/workflows/build.yml/runs?branch=develop&event=push&status=success&per_page=20"] token:token error:&failure];
            NSDictionary *best=nil;
            for(NSDictionary *r in runs[@"workflow_runs"]) {
                if (![r isKindOfClass:NSDictionary.class] || ![r[@"head_branch"] isEqual:@"develop"] ||
                    ![r[@"event"] isEqual:@"push"] || ![r[@"status"] isEqual:@"completed"] ||
                    ![r[@"conclusion"] isEqual:@"success"] || ![r[@"path"] hasSuffix:@"build.yml"]) continue;
                if(!best || [r[@"id"] longLongValue]>[best[@"id"] longLongValue])best=r;
            }
            if(!failure && !best)failure=[NSError errorWithDomain:@"SXUpdate" code:1 userInfo:@{NSLocalizedDescriptionKey:@"成功ビルドがない"}];
            NSDictionary *artifactList=!failure?[self updateJSON:[NSString stringWithFormat:@"%@/actions/runs/%@/artifacts?per_page=100",base,best[@"id"]] token:token error:&failure]:nil;
            NSDictionary *artifact=nil; NSInteger count=0;
            for(NSDictionary *a in artifactList[@"artifacts"]) {
                if([a isKindOfClass:NSDictionary.class] && [a[@"name"] isEqual:@"SCARLET-X-Probe-roothide"] && ![a[@"expired"] boolValue]) {artifact=a;count++;}
            }
            if(!failure && count!=1)failure=[NSError errorWithDomain:@"SXUpdate" code:2 userInfo:@{NSLocalizedDescriptionKey:@"有効な成果物が1つに決まらない"}];
            NSHTTPURLResponse *redirect=nil;
            if(!failure)[self updateFetch:[NSString stringWithFormat:@"%@/actions/artifacts/%@/zip",base,artifact[@"id"]] token:token maximum:2048 response:&redirect error:&failure];
            NSString *signedURL=nil;
            if(!failure) {
                for(id key in redirect.allHeaderFields)if([[key description] caseInsensitiveCompare:@"Location"]==NSOrderedSame)signedURL=[redirect.allHeaderFields[key] description];
                NSURLComponents *c=[NSURLComponents componentsWithString:signedURL];
                if(redirect.statusCode!=302 || ![c.scheme isEqual:@"https"] || !c.host.length || c.user || c.password) {
                    failure=[NSError errorWithDomain:@"SXUpdate" code:3 userInfo:@{NSLocalizedDescriptionKey:@"GitHubの配布URLが不正"}];
                }
            }
            NSHTTPURLResponse *zipResponse=nil;
            NSData *zip=!failure?[self updateFetch:signedURL token:nil maximum:33554432 response:&zipResponse error:&failure]:nil;
            if(!failure && (zipResponse.statusCode!=200 || zip.length<22 || memcmp(zip.bytes,(const unsigned char[]){0x50,0x4b,0x03,0x04},4)!=0))
                failure=[NSError errorWithDomain:@"SXUpdate" code:4 userInfo:@{NSLocalizedDescriptionKey:@"ZIPの受信・形式確認に失敗"}];
            NSData *deb=!failure?SXExtractSingleDeb(zip):nil;
            if(!failure && !deb)failure=[NSError errorWithDomain:@"SXUpdate" code:6 userInfo:@{NSLocalizedDescriptionKey:@"単一debの抽出・整合性確認に失敗"}];
            if(!failure) {
                NSString *name=[NSString stringWithFormat:@"SXProbe-build-%@.deb",best[@"id"]];
                NSURL *dir=[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
                saved=[dir URLByAppendingPathComponent:name];
                if(![deb writeToURL:saved options:NSDataWritingAtomic error:&failure])saved=nil;
            }
            if(!failure) message=@"debを取得しました。Sileoでパッケージ情報を確認してインストールしてください。";
        } @catch(NSException *e) {
            failure=[NSError errorWithDomain:@"SXUpdate" code:5 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"取得処理の例外: %@",e.name]}];
        }
        if(!message)message=[NSString stringWithFormat:@"❌ 取得失敗: %@",failure.localizedDescription?:@"不明なエラー"];
        dispatch_async(dispatch_get_main_queue(),^{
            SXPrivateUpdater *strong=worker;
            strong.busy=NO;[strong setStatus:message];
            UIViewController *presenter=strong.shareHost ?: strong;
            if(saved && !presenter.view.window) [strong setStatus:@"共有画面を表示できません。SXPを開き直してください。"];
            if(saved && presenter.view.window) {
                UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[saved] applicationActivities:nil];
                share.popoverPresentationController.sourceView=presenter.view;
                share.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(presenter.view.bounds),20,1,1);
                [presenter presentViewController:share animated:YES completion:nil];
            }
        });
    });
}
- (NSData *)updateFetch:(NSString *)url token:(NSString *)token maximum:(NSUInteger)maximum response:(NSHTTPURLResponse **)response error:(NSError **)error {
    NSURLComponents *c=[NSURLComponents componentsWithString:url];
    if(![c.scheme isEqual:@"https"] || !c.host.length || c.user || c.password || (token && ![c.host isEqual:@"api.github.com"])) {
        if(error)*error=[NSError errorWithDomain:@"SXUpdate" code:10 userInfo:@{NSLocalizedDescriptionKey:@"不正な接続先"}]; return nil;
    }
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:c.URL];
    r.timeoutInterval=40;
    [r setValue:@"SCARLET-X-Probe-updater" forHTTPHeaderField:@"User-Agent"];
    [r setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    if(token)[r setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delegate:[SXNoCredentialRedirect new] delegateQueue:nil];
    dispatch_semaphore_t sem=dispatch_semaphore_create(0);
    __block NSData *body=nil;__block NSError *failure=nil;__block NSURLResponse *res=nil;
    NSURLSessionDataTask *task=[session dataTaskWithRequest:r completionHandler:^(NSData *d,NSURLResponse *resp,NSError *e){body=d;res=resp;failure=e;dispatch_semaphore_signal(sem);}];
    [task resume];
    if(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,65*NSEC_PER_SEC))) { [task cancel];failure=[NSError errorWithDomain:@"SXUpdate" code:11 userInfo:@{NSLocalizedDescriptionKey:@"通信タイムアウト"}]; }
    [session invalidateAndCancel];
    if(response)*response=[res isKindOfClass:NSHTTPURLResponse.class]?(NSHTTPURLResponse *)res:nil;
    if(body.length>maximum)failure=[NSError errorWithDomain:@"SXUpdate" code:12 userInfo:@{NSLocalizedDescriptionKey:@"取得ファイルが大きすぎる"}];
    if(error)*error=failure;
    return failure?nil:body;
}
- (NSDictionary *)updateJSON:(NSString *)url token:(NSString *)token error:(NSError **)error {
    NSHTTPURLResponse *response=nil;
    NSData *d=[self updateFetch:url token:token maximum:2097152 response:&response error:error];
    if(!d)return nil;
    if(response.statusCode!=200) {
        if(error)*error=[NSError errorWithDomain:@"SXUpdate" code:response.statusCode userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"GitHub HTTP %ld",(long)response.statusCode]}];return nil;
    }
    id obj=[NSJSONSerialization JSONObjectWithData:d options:0 error:error];
    return [obj isKindOfClass:NSDictionary.class]?obj:nil;
}

- (void)checkLatest {
    NSString *token = SXUpdateToken();
    if (!token.length) { [self alert:@"未設定" message:@"先にGitHubトークンを登録してね。"]; return; }
    self.busy = YES;
    [self setStatus:@"GitHub Actionsを確認中…"];
    NSString *u = [NSString stringWithFormat:@"https://api.github.com/repos/%@/actions/workflows/build.yml/runs?branch=develop&event=push&status=success&per_page=20", SXUpdateRepo];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u]];
    r.timeoutInterval = 30;
    [r setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [r setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [r setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [r setValue:@"SCARLET-X-Probe-updater" forHTTPHeaderField:@"User-Agent"];
    // Prevent credentialed redirects to untrusted hosts.
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:[SXNoCredentialRedirect new] delegateQueue:nil];
    __weak typeof(self) weakSelf = self;
    [[session dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger code = [(NSHTTPURLResponse *)response statusCode];
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *runs = [json isKindOfClass:NSDictionary.class] && [json[@"workflow_runs"] isKindOfClass:NSArray.class] ? json[@"workflow_runs"] : @[];
        NSDictionary *best = nil;
        for (id item in runs) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            if (![item[@"head_branch"] isEqual:@"develop"] || ![item[@"event"] isEqual:@"push"] ||
                ![item[@"conclusion"] isEqual:@"success"] || ![item[@"status"] isEqual:@"completed"]) continue;
            if (![item[@"path"] isKindOfClass:NSString.class] || ![item[@"path"] hasSuffix:@"build.yml"]) continue;
            if (!best || [item[@"id"] longLongValue] > [best[@"id"] longLongValue]) best = item;
        }
        NSString *message;
        if (error) message = [NSString stringWithFormat:@"❌ 通信エラー: %@", error.localizedDescription];
        else if (code != 200) message = [NSString stringWithFormat:@"❌ GitHub API HTTP %ld", (long)code];
        else if (!best) message = @"⚠️ 成功したdevelopのpushビルドが見つからない";
        else message = [NSString stringWithFormat:@"✅ ビルド確認済み: %@ / commit %@（ダウンロード・更新は未実装）",
                      best[@"id"] ?: @"?", [best[@"head_sha"] isKindOfClass:NSString.class] ? [best[@"head_sha"] substringToIndex:MIN((NSUInteger)12, [best[@"head_sha"] length])] : @"?"];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self) { self.busy = NO; [self setStatus:message]; }
        });
        [session finishTasksAndInvalidate];
    }] resume];
}
@end

void SXOpenPrivateUpdater(UIViewController *host) {
    if (!host) return;
    SXPrivateUpdater *vc = [SXPrivateUpdater new];
    [host.navigationController pushViewController:vc animated:YES];
}

void SXStartProbeDownload(UIViewController *host, void (^status)(NSString *)) {
    if(!host)return;
    SXPrivateUpdater *worker=[SXPrivateUpdater new];
    worker.shareHost=host;
    worker.progress=status;
    [worker downloadArtifact];
}
