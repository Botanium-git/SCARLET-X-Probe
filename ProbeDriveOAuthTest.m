#import <UIKit/UIKit.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

// v0.1.5: explicit user-triggered Google Drive upload of Probe metadata only.
// No X content, cookies, authorization headers or browsing data are collected.
static __weak UIViewController *SXDriveHost;
static NSString * const SXClientID = @"336218902468-g2t9ha7h9jhfckilh1l8k2k1gl64sltr.apps.googleusercontent.com";
static NSString * const SXKeychainService=@"com.botanium.scarletxprobe.google-drive";
static NSString * const SXKeychainAccount=@"drive.file";
extern NSDictionary *SXProbeDiagnosticPayload(void);
static NSString * const SXCallbackScheme = @"com.googleusercontent.apps.336218902468-g2t9ha7h9jhfckilh1l8k2k1gl64sltr";
static NSString *SXEncoded(NSData *data) {
    NSString *s = [data base64EncodedStringWithOptions:0];
    return [[[s stringByReplacingOccurrencesOfString:@"+" withString:@"-"]
             stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
            stringByReplacingOccurrencesOfString:@"=" withString:@""];
}
static NSString *SXNonce(NSUInteger bytes) {
    NSMutableData *data = [NSMutableData dataWithLength:bytes];
    return SecRandomCopyBytes(kSecRandomDefault, bytes, data.mutableBytes) == errSecSuccess ? SXEncoded(data) : nil;
}

static NSMutableDictionary *SXKeyQuery(void) {
 return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:SXKeychainService,(__bridge id)kSecAttrAccount:SXKeychainAccount} mutableCopy];
}
static NSDictionary *SXReadToken(void) {
 NSMutableDictionary *q=SXKeyQuery();q[(__bridge id)kSecReturnData]=@YES;q[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
 CFTypeRef output=NULL;OSStatus rc=SecItemCopyMatching((__bridge CFDictionaryRef)q,&output);
 if(rc!=errSecSuccess||!output)return nil;
 id obj=[NSJSONSerialization JSONObjectWithData:CFBridgingRelease(output) options:0 error:nil];
 return [obj isKindOfClass:NSDictionary.class]?obj:nil;
}
static BOOL SXStoreToken(NSDictionary *obj) {
 NSData *d=[NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];if(!d)return NO;
 NSMutableDictionary *q=SXKeyQuery();SecItemDelete((__bridge CFDictionaryRef)q);
 q[(__bridge id)kSecValueData]=d;q[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
 return SecItemAdd((__bridge CFDictionaryRef)q,NULL)==errSecSuccess;
}
static NSString *SXEsc(NSString *s) {
 NSMutableCharacterSet *allowed=[NSCharacterSet URLQueryAllowedCharacterSet].mutableCopy;
 [allowed removeCharactersInString:@"&+=?"];
 return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed]?:@"";
}
static NSData *SXForm(NSDictionary *pairs) {
 NSMutableArray *v=[NSMutableArray array];
 for(NSString *k in pairs)[v addObject:[NSString stringWithFormat:@"%@=%@",SXEsc(k),SXEsc(pairs[k])]];
 return [[v componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
}
typedef void(^SXDone)(NSDictionary *,NSError *);
static void SXHTTP(NSURLRequest *req,SXDone done) {
 [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
  id obj=data.length?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
  NSDictionary *json=[obj isKindOfClass:NSDictionary.class]?obj:@{};
  NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse *)response).statusCode:0;
  if(!error&&(status<200||status>=300)) {
   NSString *msg=[json[@"error_description"] isKindOfClass:NSString.class]?json[@"error_description"]:nil;
   if(!msg)msg=[json[@"error"] isKindOfClass:NSString.class]?json[@"error"]:nil;
   error=[NSError errorWithDomain:@"SXProbeDrive" code:status userInfo:@{NSLocalizedDescriptionKey:msg?:[NSString stringWithFormat:@"HTTP %ld",(long)status]}];
  }
  dispatch_async(dispatch_get_main_queue(),^{done(json,error);});
 }] resume];
}
static NSURLRequest *SXDriveRequest(NSString *url,NSString *method,NSString *token,NSDictionary *json) {
 NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
 r.HTTPMethod=method;
 [r setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
 if(json){[r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];r.HTTPBody=[NSJSONSerialization dataWithJSONObject:json options:0 error:nil];}
 return r;
}

@interface SXProbeOAuthTest : UITableViewController <ASWebAuthenticationPresentationContextProviding>
@property(nonatomic,strong) ASWebAuthenticationSession *auth;
@property(nonatomic,copy) NSString *expectedState;
@property(nonatomic,copy) NSString *statusText;
@property(nonatomic,copy) NSString *verifier;
@property(nonatomic,assign) BOOL busy;
@end
@implementation SXProbeOAuthTest
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"Google Drive連携";
    self.statusText=SXReadToken()?@"接続済み":@"未接続";
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 4; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)p {
    UITableViewCell *c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSArray *titles=@[@"Googleアカウントで接続",@"診断JSONをDriveへ送信",@"Google Drive接続を解除",@"現在の状態"];
    c.textLabel.text=titles[p.row];
    c.detailTextLabel.text=p.row==0?@"Driveのファイル作成権限のみ":p.row==1?@"手動送信：ScarletX/Probe":p.row==3?self.statusText:@"";
    c.detailTextLabel.numberOfLines=0;
    c.accessoryType=p.row<2?UITableViewCellAccessoryDisclosureIndicator:UITableViewCellAccessoryNone;
    return c;
}
- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    return SXDriveHost.view.window ?: self.view.window;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)p {
    [tableView deselectRowAtIndexPath:p animated:YES];
    if(self.busy || self.auth) return;
    if(p.row==1){[self uploadProbe];return;}
    if(p.row==2){[self confirmDisconnect];return;}
    if(p.row!=0)return;
    NSString *verifier=SXNonce(32),*state=SXNonce(24);
    if(!verifier.length||!state.length){self.statusText=@"乱数生成に失敗";[self.tableView reloadData];return;}
    NSData *v=[verifier dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(v.bytes,(CC_LONG)v.length,hash);
    NSString *redirect=[NSString stringWithFormat:@"%@:/oauth2redirect/google",SXCallbackScheme];
    NSURLComponents *url=[NSURLComponents componentsWithString:@"https://accounts.google.com/o/oauth2/v2/auth"];
    url.queryItems=@[
        [NSURLQueryItem queryItemWithName:@"client_id" value:SXClientID],
        [NSURLQueryItem queryItemWithName:@"redirect_uri" value:redirect],
        [NSURLQueryItem queryItemWithName:@"response_type" value:@"code"],
        [NSURLQueryItem queryItemWithName:@"scope" value:@"https://www.googleapis.com/auth/drive.file"],
        [NSURLQueryItem queryItemWithName:@"code_challenge" value:SXEncoded([NSData dataWithBytes:hash length:sizeof(hash)])],
        [NSURLQueryItem queryItemWithName:@"code_challenge_method" value:@"S256"],
        [NSURLQueryItem queryItemWithName:@"state" value:state]
    ];
    self.expectedState=state;self.verifier=verifier;
    self.statusText=@"認証画面を起動中…";
    [self.tableView reloadData];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SXDriveStateChanged" object:nil];
    __weak typeof(self) weakSelf=self;
    self.auth=[[ASWebAuthenticationSession alloc] initWithURL:url.URL callbackURLScheme:SXCallbackScheme completionHandler:^(NSURL *callback,NSError *error){
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self=weakSelf;if(!self)return;
            self.auth=nil;
            if(error){self.statusText=[NSString stringWithFormat:@"戻り失敗: %@ (%ld)",error.domain,(long)error.code];}
            else {
                NSURLComponents *parts=[NSURLComponents componentsWithURL:callback resolvingAgainstBaseURL:NO];
                NSString *gotState=nil,*code=nil,*oauthError=nil;
                for(NSURLQueryItem *item in parts.queryItems) {
                    if([item.name isEqualToString:@"state"])gotState=item.value;
                    if([item.name isEqualToString:@"code"])code=item.value;
                    if([item.name isEqualToString:@"error"])oauthError=item.value;
                }
                if(![callback.scheme isEqualToString:SXCallbackScheme] || ![gotState isEqualToString:self.expectedState])
                    self.statusText=@"認証応答の検証に失敗";
                else if(oauthError.length) self.statusText=[@"Google認証エラー: " stringByAppendingString:oauthError];
                else if(code.length) { NSString *verifier=self.verifier;self.verifier=nil;self.expectedState=nil;[self exchangeCode:code verifier:verifier redirect:redirect];return; }
                else self.statusText=@"戻りは受信したが認証コードなし";
            }
            self.expectedState=nil;self.verifier=nil;
            [self.tableView reloadData];
        });
    }];
    self.auth.presentationContextProvider=self;
    if(![self.auth start]){
        self.auth=nil;self.expectedState=nil;self.verifier=nil;self.statusText=@"認証セッションを開始できません";
        [self.tableView reloadData];
    }
}

- (void)status:(NSString *)message {
 self.statusText=message;[self.tableView reloadData];
 [[NSNotificationCenter defaultCenter] postNotificationName:@"SXDriveStateChanged" object:nil];
}
- (void)uploadStatus:(NSString *)message {
 [self status:message];
 [[NSNotificationCenter defaultCenter] postNotificationName:@"SXPOperationStatusChanged"
                                                     object:nil
                                                   userInfo:@{@"message":[@"Drive: " stringByAppendingString:message?:@"状態不明"]}];
}
- (void)tokenRequest:(NSDictionary *)fields finish:(SXDone)finish {
 NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://oauth2.googleapis.com/token"]];
 r.HTTPMethod=@"POST";[r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];r.HTTPBody=SXForm(fields);
 SXHTTP(r,finish);
}
- (void)exchangeCode:(NSString *)code verifier:(NSString *)verifier redirect:(NSString *)redirect {
 self.busy=YES;[self status:@"認証コードを交換中…"];
 [self tokenRequest:@{@"client_id":SXClientID,@"code":code,@"code_verifier":verifier,@"redirect_uri":redirect,@"grant_type":@"authorization_code"} finish:^(NSDictionary *obj,NSError *error) {
  self.busy=NO;
  NSString *access=[obj[@"access_token"] isKindOfClass:NSString.class]?obj[@"access_token"]:nil;
  NSString *refresh=[obj[@"refresh_token"] isKindOfClass:NSString.class]?obj[@"refresh_token"]:nil;
  if(error||!access.length||!refresh.length){[self status:[NSString stringWithFormat:@"接続失敗: %@",error.localizedDescription?:@"アクセストークン/更新トークンを取得できません"]];return;}
  NSDictionary *cred=@{@"access":access,@"refresh":refresh,@"expires":@(NSDate.date.timeIntervalSince1970+[obj[@"expires_in"] doubleValue]-60)};
  [self status:SXStoreToken(cred)?@"接続成功（送信未検証）":@"Keychainへの保存に失敗"];
 }];
}
- (void)withToken:(void(^)(NSString *,NSError *))finish {
 NSDictionary *cred=SXReadToken();NSString *refresh=cred[@"refresh"],*access=cred[@"access"];
 if(!refresh.length){finish(nil,[NSError errorWithDomain:@"SXProbeDrive" code:401 userInfo:@{NSLocalizedDescriptionKey:@"先にGoogleアカウントを接続してね"}]);return;}
 if(access.length&&[cred[@"expires"] doubleValue]>NSDate.date.timeIntervalSince1970){finish(access,nil);return;}
 [self tokenRequest:@{@"client_id":SXClientID,@"refresh_token":refresh,@"grant_type":@"refresh_token"} finish:^(NSDictionary *obj,NSError *error){
  NSString *newAccess=[obj[@"access_token"] isKindOfClass:NSString.class]?obj[@"access_token"]:nil;
  if(error||!newAccess.length){finish(nil,error?:[NSError errorWithDomain:@"SXProbeDrive" code:401 userInfo:@{NSLocalizedDescriptionKey:@"Googleへの再接続が必要"}]);return;}
  NSDictionary *updated=@{@"access":newAccess,@"refresh":refresh,@"expires":@(NSDate.date.timeIntervalSince1970+[obj[@"expires_in"] doubleValue]-60)};
  if(!SXStoreToken(updated)){finish(nil,[NSError errorWithDomain:@"SXProbeDrive" code:500 userInfo:@{NSLocalizedDescriptionKey:@"Keychainの更新に失敗"}]);return;}
  finish(newAccess,nil);
 }];
}
- (void)findFolder:(NSString *)name parent:(NSString *)parent token:(NSString *)token finish:(void(^)(NSString *,NSError *))finish {
 NSString *safe=[name stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
 NSString *q=[NSString stringWithFormat:@"name = '%@' and mimeType = 'application/vnd.google-apps.folder' and trashed = false and '%@' in parents",safe,parent];
 NSURLComponents *c=[NSURLComponents componentsWithString:@"https://www.googleapis.com/drive/v3/files"];
 c.queryItems=@[[NSURLQueryItem queryItemWithName:@"q" value:q],[NSURLQueryItem queryItemWithName:@"fields" value:@"nextPageToken,files(id,name)"],[NSURLQueryItem queryItemWithName:@"pageSize" value:@"100"]];
 SXHTTP(SXDriveRequest(c.URL.absoluteString,@"GET",token,nil),^(NSDictionary *result,NSError *error){
  if(error){finish(nil,error);return;}
  NSArray *files=[result[@"files"] isKindOfClass:NSArray.class]?result[@"files"]:@[];
  NSString *fid=[files.firstObject isKindOfClass:NSDictionary.class]?files.firstObject[@"id"]:nil;
  if(fid.length){finish(fid,nil);return;}
  NSDictionary *meta=@{@"name":name,@"mimeType":@"application/vnd.google-apps.folder",@"parents":@[parent]};
  SXHTTP(SXDriveRequest(@"https://www.googleapis.com/drive/v3/files?fields=id", @"POST",token,meta),^(NSDictionary *obj,NSError *e){
   NSString *created=[obj[@"id"] isKindOfClass:NSString.class]?obj[@"id"]:nil;
   finish(created,e?:(!created.length?[NSError errorWithDomain:@"SXProbeDrive" code:500 userInfo:@{NSLocalizedDescriptionKey:@"フォルダ作成結果にIDなし"}]:nil));
  });
 });
}
- (void)uploadProbe {
 NSDictionary *payload=SXProbeDiagnosticPayload();
 NSData *data=payload?[NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:nil]:nil;
 if(!data){[self uploadStatus:@"診断JSON作成に失敗"];return;}
 self.busy=YES;[self uploadStatus:@"Google Driveへ接続中…"];
 [self withToken:^(NSString *token,NSError *error){
  if(error){self.busy=NO;[self uploadStatus:error.localizedDescription];return;}
  [self findFolder:@"ScarletX" parent:@"root" token:token finish:^(NSString *root,NSError *e){
   if(e){self.busy=NO;[self uploadStatus:e.localizedDescription];return;}
   [self findFolder:@"Probe" parent:root token:token finish:^(NSString *folder,NSError *e2){
    if(e2){self.busy=NO;[self uploadStatus:e2.localizedDescription];return;}
    [self sendJSON:data token:token folder:folder];
   }];
  }];
 }];
}
- (void)sendJSON:(NSData *)data token:(NSString *)token folder:(NSString *)folder {
 NSDateFormatter *f=[NSDateFormatter new];f.dateFormat=@"yyyy-MM-dd_HHmmss";
 NSString *name=[NSString stringWithFormat:@"SXProbe_%@.json",[f stringFromDate:NSDate.date]];
 NSDictionary *meta=@{@"name":name,@"mimeType":@"application/json",@"parents":@[folder]};
 NSData *metaData=[NSJSONSerialization dataWithJSONObject:meta options:0 error:nil];
 NSString *boundary=[@"SXProbe" stringByAppendingString:SXNonce(12)?:@"Upload"];
 NSMutableData *body=[NSMutableData data];
 [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n",boundary] dataUsingEncoding:NSUTF8StringEncoding]];
 [body appendData:metaData];
 [body appendData:[[NSString stringWithFormat:@"\r\n--%@\r\nContent-Type: application/json\r\n\r\n",boundary] dataUsingEncoding:NSUTF8StringEncoding]];
 [body appendData:data];
 [body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n",boundary] dataUsingEncoding:NSUTF8StringEncoding]];
 NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name"]];
 r.HTTPMethod=@"POST";[r setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
 [r setValue:[NSString stringWithFormat:@"multipart/related; boundary=%@",boundary] forHTTPHeaderField:@"Content-Type"];
 r.HTTPBody=body;
 SXHTTP(r,^(NSDictionary *result,NSError *error){
  self.busy=NO;
  NSString *fid=[result[@"id"] isKindOfClass:NSString.class]?result[@"id"]:nil;
  [self uploadStatus:error?[NSString stringWithFormat:@"送信失敗: %@",error.localizedDescription]:fid.length?[NSString stringWithFormat:@"送信成功: ScarletX/Probe/%@",name]:@"送信応答にファイルIDなし"];
 });
}
- (void)confirmDisconnect {
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Google Drive接続を解除" message:@"この端末の認証情報だけを削除します。Drive上のファイルは残ります。" preferredStyle:UIAlertControllerStyleAlert];
 [a addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
 [a addAction:[UIAlertAction actionWithTitle:@"解除" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){
  OSStatus rc=SecItemDelete((__bridge CFDictionaryRef)SXKeyQuery());
  [self status:(rc==errSecSuccess||rc==errSecItemNotFound)?@"未接続":@"認証情報の削除に失敗"];
 }]];
 [(SXDriveHost ?: self) presentViewController:a animated:YES completion:nil];
}
@end
UIViewController *SXCreateProbeOAuthTestController(void) { return [SXProbeOAuthTest new]; }

static SXProbeOAuthTest *SXDriveController(void) {
 static SXProbeOAuthTest *controller=nil;
 static dispatch_once_t once;
 dispatch_once(&once, ^{ controller=[SXProbeOAuthTest new]; });
 return controller;
}
BOOL SXDriveIsConnected(void) { return [SXReadToken()[@"refresh"] length]>0; }
NSString *SXDriveCurrentStatus(void) { return SXDriveController().statusText?:@"未接続"; }
void SXDriveHandleRow(NSInteger row,UIViewController *host) {
 SXDriveHost=host;
 SXProbeOAuthTest *controller=SXDriveController();
 [controller loadViewIfNeeded];
 if(controller.busy||controller.auth)return;
 if(row==0) {
  if(SXDriveIsConnected()) [controller confirmDisconnect];
  else [controller tableView:controller.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
 } else if(row==1) [controller uploadProbe];
 else if(row==2) [controller confirmDisconnect];
}
