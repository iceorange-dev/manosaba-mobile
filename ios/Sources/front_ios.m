// iOS front end (implements front.h): the Metal view the game presents to, letterboxed to the game picture's aspect ratio; touches → dm_touch_set;
// game controllers; the software keyboard
// dialog; scene lifecycle, audio session and thermal logging. main.m builds the window and forwards the scene events to front_ios_focus_event.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/sysctl.h>
#include "cloud.h"
#include "dm_input.h"
#include "fit_rect.h"
#include "front.h"
#include "game.h"
#include "native_size.h"
#include "hle.h"

int mtl_fps_target(void);   // gfx/nvn/nvn_mtl.m: 60, or 30 in the power-saving mode
static CAMetalLayer *g_layer;

// Game picture size: DM_GAME_RES=<w>x<h>, else the profile's screen size. The presenter keeps this aspect ratio and centers the picture; the game view
// below is laid out the same way, so normalized touch coordinates match the picture
static void game_size(double *w, double *h) {
    static double gw, gh;
    if (!gw) {
        unsigned ew, eh; const char *e = getenv("DM_GAME_RES");
        if (e && sscanf(e, "%ux%u", &ew, &eh) == 2 && ew && eh) { gw = ew; gh = eh; }
        else { gw = dm_game.screen_w > 0 ? dm_game.screen_w : 1280; gh = dm_game.screen_h > 0 ? dm_game.screen_h : 720; }
    }
    *w = gw; *h = gh;
}
// The largest rectangle of the game's aspect ratio centered in f (a difference under 1% fills f; host/fit_rect.h)
static CGRect letterbox_rect(CGRect f) {
    double gw, gh; game_size(&gw, &gh);
    dm_rect r = dm_fit_center((dm_rect){f.origin.x, f.origin.y, f.size.width, f.size.height}, gw / gh);
    return CGRectMake(r.x, r.y, r.w, r.h);
}
// Where the game view goes in the black container v (plan item 302): centered as letterbox_rect, or clear of the front camera's cutout, moved within
// the bars at its size (made smaller only when no place there clears it; host/fit_rect.h): the picture keeps its size and more of it shows. The
// cutout: the regions the system reserves for a camera (iOS 27.1 reservedRegionsOfKind: occlusion), or where it reports none the measured one
// (dm_known_cutout: the iPhone Duo's outer display, whose cutout is over the picture's corner and which reported none). *how: 0 centered, 1 moved,
// 2 smaller; *src: "the system's" or "measured" (the log). The hinge's fold (division) is not avoided: the picture crosses it like an open book
static CGRect picture_rect(UIView *v, int *how, const char **src) {
    double gw, gh; game_size(&gw, &gh); CGRect b = v.bounds; dm_rect av[8]; int n = 0; *src = "";
    if (@available(iOS 27.1, *)) if (!getenv("DM_TEST_NO_RESERVED"))   // (the test switch: the measured cutout where the system reports one too)
        for (UIViewReservedRegion *r in [v reservedRegionsOfKind:[UIViewReservedRegionKind occlusionRegionKind]])
            if (r.active && n < 8) { CGRect f = r.frame; av[n++] = (dm_rect){f.origin.x, f.origin.y, f.size.width, f.size.height}; *src = "the system's"; }
    if (!n) {
        static char hw[64]; if (!hw[0]) { size_t hn = sizeof hw; if (sysctlbyname("hw.machine", hw, &hn, NULL, 0)) strlcpy(hw, "?", sizeof hw);
#if TARGET_OS_SIMULATOR   // the Simulator's machine is the Mac's: the device it stands in for
            const char *sm = getenv("SIMULATOR_MODEL_IDENTIFIER"); if (sm) strlcpy(hw, sm, sizeof hw);
#endif
        }
        CGSize px = v.window.windowScene.screen.nativeBounds.size; UIEdgeInsets in = v.safeAreaInsets;
        if (dm_known_cutout(hw, (unsigned)px.width, (unsigned)px.height, b.size.width, b.size.height, in.left, in.right, &av[0])) { n = 1; *src = "measured"; }
    }
    dm_rect o; *how = dm_fit_rect((dm_rect){b.origin.x, b.origin.y, b.size.width, b.size.height}, gw / gh, av, n, &o);
    return CGRectMake(o.x, o.y, o.w, o.h);
}
// The screen the game's window is on (plan item 302: the iPhone Duo has two, the outer and the inner display): its maximum refresh rate, kept on
// the main thread for mtl_display_hz (gfx/nvn/mtl/texdump.m, read on the game thread), which read UIScreen.mainScreen before
static _Atomic int g_screen_hz;
int front_ios_screen_hz(void) { return atomic_load(&g_screen_hz); }
static void screen_note(UIScreen *s) { if (s) atomic_store(&g_screen_hz, (int)s.maximumFramesPerSecond); }
// The setting "Native" (plan item 302): the screen the game's window is on is reported to the game when it changes (the iPhone Duo opened or
// closed moves the window between its displays; games/manosaba/graphics.c renders at that screen's size from a later frame). The largest screen
// seen is kept as dm.native_screen_max for the next launch's window textures (ios/Sources/main.m)
static int g_follow; static unsigned g_follow_w, g_follow_h;
static void native_remember(unsigned w, unsigned h) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults; NSString *mx = [d stringForKey:@"dm.native_screen_max"]; unsigned a, b, W, H, MW, MH;
    if (!dm_native_size(w, h, &W, &H)) return;
    if (mx && sscanf(mx.UTF8String, "%ux%u", &a, &b) == 2 && dm_native_size(a, b, &MW, &MH) && MH >= H) return;
    [d setObject:[NSString stringWithFormat:@"%ux%u", w, h] forKey:@"dm.native_screen_max"];
}
void front_ios_native_follow(unsigned w, unsigned h) { g_follow = 1; g_follow_w = w; g_follow_h = h; native_remember(w, h); }   // main thread
static void native_follow(UIScreen *s) {
    unsigned w = (unsigned)s.nativeBounds.size.width, h = (unsigned)s.nativeBounds.size.height;
    if (!g_follow || !w || !h || (w == g_follow_w && h == g_follow_h)) return;
    g_follow_w = w; g_follow_h = h; native_remember(w, h);
    LOG("front: the window is now on a screen of %ux%u pixels: reported to the game (Native)", w, h);
    dm_game_native_screen(w, h);
}
// The window, its screen and the game view, logged when they change (the iPhone Duo opened or closed, a turn), a hundred times at most. The
// interface orientation is only logged: the side its safe area insets name is the side of the outer display's front camera (plan item 302)
static void layout_note(UIView *v, CGRect g, int how, const char *src) {
    static char last[512]; static int logged; if (logged >= 100) return;
    UIWindowScene *ws = v.window.windowScene; UIScreen *s = ws.screen; UIEdgeInsets in = v.safeAreaInsets; CGSize b = v.bounds.size; long ori = 0; char line[512];
    if (@available(iOS 26.0, *)) ori = (long)ws.effectiveGeometry.interfaceOrientation;
    snprintf(line, sizeof line, "window %.0fx%.0f on a screen of %.0fx%.0f pixels up to %ld Hz (interface orientation %ld, safe area top %.0f left %.0f bottom %.0f right %.0f); "
             "game view %.0fx%.0f at (%.0f, %.0f)%s%s%s", b.width, b.height, s.nativeBounds.size.width, s.nativeBounds.size.height, (long)s.maximumFramesPerSecond, ori,
             in.top, in.left, in.bottom, in.right, g.size.width, g.size.height, g.origin.x, g.origin.y,
             how == 1 ? ", moved clear of the camera (" : how == 2 ? ", made smaller to clear the camera (" : "", how ? src : "", how ? " cutout)" : "");
    if (strcmp(line, last)) { strlcpy(last, line, sizeof last); logged++; LOG("front: %s", line); }
}

// The drawable's size: the view's pixels, or with DM_IOS_DRAWABLE_H=<rows> that many rows at the view's shape, so the system compositor scales
// the layer to the screen and our GPU fills fewer pixels a frame (MacNativeGames' TOTK_IOS_DRAWABLE_H, MIT, written anew; kxn/d2r-mobile measured
// 9.5 % fewer GPU writes on an Adreno 735 with its buffer at the game's size; plan item 270, an A/B on the phone)
static CGSize drawable_size(CGSize pt, CGFloat scale) {
    static int rows = -1; if (rows < 0) { const char *e = getenv("DM_IOS_DRAWABLE_H"); rows = e ? atoi(e) : 0; if (rows < 0) rows = 0;
        if (rows) LOG("front: drawable %d rows at the view's shape (DM_IOS_DRAWABLE_H), the compositor scales it", rows); }
    if (!rows || pt.height <= 0 || rows >= pt.height * scale) return CGSizeMake(pt.width * scale, pt.height * scale);
    return CGSizeMake(round(pt.width * rows / pt.height), rows);
}

// ---------- Game view: CAMetalLayer + touches ----------
// Touches: every finger gets the lowest free slot 0–15 on touch down and keeps it until it lifts; the whole set goes to the host in coordinates
// normalized to this view on every change (hle_touch.c scales them to the game's touch space)
@interface DmMetalView : UIView
- (void)liftAll;
@end
@implementation DmMetalView { UITouch *_slot[16]; }
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.multipleTouchEnabled = YES;
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    l.drawableSize = drawable_size(self.bounds.size, l.contentsScale);
}
- (void)push {
    dm_touch pt[16]; int n = 0; CGSize b = self.bounds.size;
    if (b.width > 0 && b.height > 0)
        for (int i = 0; i < 16; i++) if (_slot[i]) {
            CGPoint p = [_slot[i] locationInView:self];
            pt[n++] = (dm_touch){(uint32_t)i, (float)fmin(fmax(p.x / b.width, 0), .99999), (float)fmin(fmax(p.y / b.height, 0), .99999)};
        }
    dm_touch_set(pt, n);
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    (void)e;
    for (UITouch *t in ts) for (int i = 0; i < 16; i++) if (!_slot[i]) { _slot[i] = t; break; }
    [self push];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { (void)ts; (void)e; [self push]; }
- (void)lift:(NSSet<UITouch *> *)ts { for (UITouch *t in ts) for (int i = 0; i < 16; i++) if (_slot[i] == t) _slot[i] = nil; [self push]; }
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { (void)e; [self lift:ts]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { (void)e; [self lift:ts]; }
- (void)liftAll { for (int i = 0; i < 16; i++) _slot[i] = nil; dm_touch_set(NULL, 0); }
@end
static __weak DmMetalView *g_view;

// Black container that keeps the game view at the game's aspect ratio, centered or clear of the front camera's cutout (picture_rect; the user,
// 2026-11-01: moved within the bars it keeps its size and shows more). Laid out again when its size changes (the iPhone Duo opened or closed moves
// the window between its displays, plan item 302) and when its safe area does (a turn by 180 degrees keeps the size and takes the cutout to the
// other corner)
@interface DmLetterboxView : UIView
@property (nonatomic, strong) UIView *game;
@end
@implementation DmLetterboxView
- (void)layoutSubviews {
    [super layoutSubviews]; UIScreen *s = self.window.windowScene.screen; screen_note(s); if (s) native_follow(s);
    if (self.bounds.size.width > 0 && self.bounds.size.height > 0) { int how; const char *src; self.game.frame = picture_rect(self, &how, &src); layout_note(self, self.game.frame, how, src); }
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
@end

static void front_panel_open(void);
static UIViewController *top_controller(void);
// A line over the game for 12 s when the signature expires within 48 hours (plan item 317b; main.m reads the date): the app does not open after it
extern long long dm_prov_expiry_at;
static void prov_banner(UIView *box) {
    long long now = (long long)time(NULL), ex = dm_prov_expiry_at; if (!ex || ex - now >= 48 * 3600) return;
    int h = ex > now ? (int)((ex - now + 3599) / 3600) : 0; NSString *lang = NSLocale.preferredLanguages.firstObject ?: @"en", *t;
    if ([lang hasPrefix:@"zh-Hans"]) t = [NSString stringWithFormat:@"签名将在 %d 小时后到期，之后 App 无法打开：请重新签名。", h];
    else if ([lang hasPrefix:@"zh"]) t = [NSString stringWithFormat:@"簽章將在 %d 小時後到期，之後 App 無法開啟：請重新簽署。", h];
    else if ([lang hasPrefix:@"ja"]) t = [NSString stringWithFormat:@"署名の有効期限まであと %d 時間です。期限後はアプリを開けません。再署名してください。", h];
    else t = [NSString stringWithFormat:@"The app's signature expires in %d hours; after that the app will not open. Sign it again.", h];
    UILabel *l = [UILabel new]; l.text = t; l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter; l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]; l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65];
    l.layer.cornerRadius = 10; l.clipsToBounds = YES; l.userInteractionEnabled = NO; l.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:l];
    [NSLayoutConstraint activateConstraints:@[[l.topAnchor constraintEqualToAnchor:box.safeAreaLayoutGuide.topAnchor constant:64],
        [l.centerXAnchor constraintEqualToAnchor:box.centerXAnchor], [l.widthAnchor constraintLessThanOrEqualToAnchor:box.safeAreaLayoutGuide.widthAnchor multiplier:0.8]]];
    LOG("front: the signature expires in %d hours: a line shown for 12 s", h);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.5 animations:^{ l.alpha = 0; } completion:^(BOOL f) { (void)f; [l removeFromSuperview]; }]; });
}
// The settings panel (plan item 148; BotWRecomp's in-game settings and lordran-native's floating menu, MIT, the ideas): the Settings page's choices
// while the game runs, from a three-finger tap. It writes the same user defaults, so what applies
// while the game runs (frame rate, MetalFX, the frame rate line) applies at once; the render resolution at the
// next launch. The game goes on behind it.
@interface DmPanel : UIViewController
@end
@implementation DmPanel
static UIStackView *panel_row(NSString *title, UIView *ctl) {
    UILabel *l = [UILabel new]; l.text = title; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:15];
    UIStackView *r = [[UIStackView alloc] initWithArrangedSubviews:@[l, ctl]]; r.axis = UILayoutConstraintAxisHorizontal; r.spacing = 12; r.alignment = UIStackViewAlignmentCenter;
    [l setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    return r;
}
static UISwitch *panel_switch(NSString *key) {
    UISwitch *s = [UISwitch new]; s.on = [NSUserDefaults.standardUserDefaults boolForKey:key];
    [s addAction:[UIAction actionWithHandler:^(UIAction *a) { [NSUserDefaults.standardUserDefaults setBool:((UISwitch *)a.sender).on forKey:key]; }] forControlEvents:UIControlEventValueChanged];
    return s;
}
static UISwitch *panel_switch_on(NSString *key) {   // a switch whose unset key reads as on (dm.hot_hold)
    UISwitch *s = panel_switch(key); id v = [NSUserDefaults.standardUserDefaults objectForKey:key]; s.on = v ? [v boolValue] : YES; return s;
}
static UISegmentedControl *panel_choice(NSString *key, NSArray<NSString *> *titles, NSArray<NSNumber *> *values) {
    UISegmentedControl *c = [[UISegmentedControl alloc] initWithItems:titles]; NSInteger v = [NSUserDefaults.standardUserDefaults integerForKey:key];
    c.selectedSegmentIndex = MAX(0, (NSInteger)[values indexOfObject:@(v)] == NSNotFound ? 0 : (NSInteger)[values indexOfObject:@(v)]);
    [c addAction:[UIAction actionWithHandler:^(UIAction *a) { [NSUserDefaults.standardUserDefaults setInteger:values[((UISegmentedControl *)a.sender).selectedSegmentIndex].integerValue forKey:key]; }]
        forControlEvents:UIControlEventValueChanged];
    return c;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    UIView *card = [UIView new]; card.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.95]; card.layer.cornerRadius = 14; card.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *sc = [UIScrollView new]; sc.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *st = [UIStackView new]; st.axis = UILayoutConstraintAxisVertical; st.spacing = 10; st.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card]; [card addSubview:sc]; [sc addSubview:st];
    UILabel *t = [UILabel new]; t.text = @"Settings"; t.textColor = UIColor.whiteColor; t.font = [UIFont boldSystemFontOfSize:18]; [st addArrangedSubview:t];
    [st addArrangedSubview:panel_row(@"Frame rate", panel_choice(@"dm.fps", @[@"60", @"30"], @[@60, @30]))];
    [st addArrangedSubview:panel_row(@"Hold 30 fps when hot", panel_switch_on(@"dm.hot_hold"))];
    [st addArrangedSubview:panel_row(@"Render resolution (next launch)", panel_choice(@"dm.render_height", @[@"Game", @"Native", @"900", @"720", @"540"], @[@0, @-1, @900, @720, @540]))];
    [st addArrangedSubview:panel_row(@"MetalFX upscaling", panel_switch(@"dm.metalfx"))];
    [st addArrangedSubview:panel_row(@"Show frame rate", panel_switch(@"dm.perf_line"))];
    __weak DmPanel *ws = self;
    UIButton *done = [UIButton systemButtonWithPrimaryAction:[UIAction actionWithTitle:@"Done" image:nil identifier:nil handler:^(UIAction *a) { (void)a; [ws dismissViewControllerAnimated:YES completion:nil]; }]];
    [st addArrangedSubview:done];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:g.centerXAnchor], [card.centerYAnchor constraintEqualToAnchor:g.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:460], [card.heightAnchor constraintLessThanOrEqualToAnchor:g.heightAnchor constant:-16],
        [sc.topAnchor constraintEqualToAnchor:card.topAnchor constant:14], [sc.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [sc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18], [sc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [st.topAnchor constraintEqualToAnchor:sc.contentLayoutGuide.topAnchor], [st.bottomAnchor constraintEqualToAnchor:sc.contentLayoutGuide.bottomAnchor],
        [st.leadingAnchor constraintEqualToAnchor:sc.contentLayoutGuide.leadingAnchor], [st.trailingAnchor constraintEqualToAnchor:sc.contentLayoutGuide.trailingAnchor],
        [st.widthAnchor constraintEqualToAnchor:sc.frameLayoutGuide.widthAnchor],
    ]];
    NSLayoutConstraint *h = [card.heightAnchor constraintEqualToAnchor:st.heightAnchor constant:28]; h.priority = UILayoutPriorityDefaultHigh; h.active = YES;
}
@end
static void front_panel_open(void) {   // main thread
    UIViewController *top = top_controller();
    if (!top || [top isKindOfClass:DmPanel.class]) return;
    DmPanel *p = [DmPanel new]; p.modalPresentationStyle = UIModalPresentationOverFullScreen; p.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    LOG("front: settings panel");
    [top presentViewController:p animated:YES completion:nil];
}
@interface DmPanelTap : NSObject
@end
@implementation DmPanelTap
- (void)tap:(UITapGestureRecognizer *)r { if (r.state == UIGestureRecognizerStateEnded) front_panel_open(); }
@end
static DmPanelTap *g_panel_tap;
// Frame rate hint for ProMotion screens: 60 Hz, or 30 Hz while the graphics layer is in its power-saving mode
// System volume changes are logged with the time since the display link's last callback: after a volume button press the display link was seen to
// stop while active (nvn_mtl.m rescue), and the log otherwise does not show when the button was pressed
double mtl_link_tick_age_ms(void);
@interface DmVolumeWatch : NSObject
@end
@implementation DmVolumeWatch
- (void)observeValueForKeyPath:(NSString *)k ofObject:(id)o change:(NSDictionary *)c context:(void *)x {
    (void)k; (void)o; (void)x;
    LOG("front: system volume %.2f → %.2f (display link last called back %.0f ms ago)", [c[NSKeyValueChangeOldKey] doubleValue], [c[NSKeyValueChangeNewKey] doubleValue], mtl_link_tick_age_ms());
}
@end
@interface DmRateHint : NSObject
- (void)tick:(CADisplayLink *)l;
@end
// The display link asked for the player's frame rate target: 60, or 30 (the setting, Low Power Mode, the thermal hold)
@implementation DmRateHint
- (void)tick:(CADisplayLink *)l {
    static int last = -1; int want = mtl_fps_target();
    if (want != last) { last = want; l.preferredFrameRateRange = want == 30 ? CAFrameRateRangeMake(30, 30, 30) : CAFrameRateRangeMake(60, 60, 60); }
}
@end
static CADisplayLink *g_rate_link;

UIView *front_ios_view(CGRect frame, UIScreen *screen) {
    CGFloat scale = screen.nativeScale; screen_note(screen);
    DmLetterboxView *box = [[DmLetterboxView alloc] initWithFrame:frame];
    box.backgroundColor = UIColor.blackColor;
    if (@available(iOS 27.1, *))   // the hinge's state (the iPhone Duo; a device without one never calls back with a hinge): logged when it changes
        [box addInteraction:[[UIHingeInteraction alloc] initWithUpdateHandler:^(UIHingeInteraction *i, UIHingeInteractionUpdate *u) {
            (void)i; static long last = -2; UIHinge *h = u.hinge; long st = h ? (long)h.status : -1;
            static const char *name[] = {"unknown", "closed", "partially open", "fully open"};
            if (st == last || st < -1 || st > 3) return;
            last = st;
            if (h) LOG("front: hinge %s, %.0f degrees", name[st], h.angle * 180 / M_PI); else LOG("front: no hinge updates (the view left a hierarchy that has them)"); }]];
    DmMetalView *v = [[DmMetalView alloc] initWithFrame:letterbox_rect(frame)];
    box.game = v; [box addSubview:v]; g_view = v;
    prov_banner(box);
    g_panel_tap = [DmPanelTap new];   // a three-finger tap opens the settings panel in any game (plan item 148); the touches still reach the game
    UITapGestureRecognizer *tap3 = [[UITapGestureRecognizer alloc] initWithTarget:g_panel_tap action:@selector(tap:)]; tap3.numberOfTouchesRequired = 3; tap3.cancelsTouchesInView = NO;
    [box addGestureRecognizer:tap3];
    g_layer = (CAMetalLayer *)v.layer;
    g_layer.device = MTLCreateSystemDefaultDevice();
    g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    g_layer.contentsScale = scale;
    g_layer.drawableSize = drawable_size(v.bounds.size, g_layer.contentsScale);
    g_rate_link = [CADisplayLink displayLinkWithTarget:[DmRateHint new] selector:@selector(tick:)];
    g_rate_link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
    [g_rate_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    double gw, gh; game_size(&gw, &gh);
    LOG("front: window %.0fx%.0f, game picture %.0fx%.0f, game view %.0fx%.0f at (%.0f, %.0f)", frame.size.width, frame.size.height, gw, gh,
        v.frame.size.width, v.frame.size.height, v.frame.origin.x, v.frame.origin.y);
    dm_gamepad_start();
    return box;
}
void *front_metal_layer(void) { return (__bridge void *)g_layer; }

void front_run(void (*guest)(void)) {
    static char alt[65536];   // the alternate signal stack is per thread: the crash report must run even when a guest thread overflows its stack
    stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);
    // This thread inherits the UIKit main thread's signal mask, which blocks SIGUSR2 / SIGALRM (measured on a device); the host's diagnostics need them
    sigset_t all; sigfillset(&all); pthread_sigmask(SIG_UNBLOCK, &all, NULL);
    guest();
}

// ---------- Presenting on the main thread ----------
static UIViewController *top_controller(void) {   // key window first; else a window of the active scene; else any window
    UIViewController *vc = nil, *alt = nil, *any = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (!w.rootViewController) continue;
            if (w.isKeyWindow) vc = w.rootViewController;
            else if (s.activationState == UISceneActivationStateForegroundActive && !alt) alt = w.rootViewController;
            else if (!any) any = w.rootViewController;
        }
    if (!vc) vc = alt ?: any;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// Software keyboard (front.h): the main thread shows an alert with a text field, the calling guest thread waits for OK / Cancel. max_chars limits the
// text while typing (UTF-16 units, as swkbd counts; text still being composed by an input method is left alone).
// Test switch DM_TEST_KBD_TYPE="text" or ":cancel": 1.5 s after the dialog appears the text is filled in through the same editing path, then OK / Cancel
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    if (!g_layer) return -1;
    NSString *t = title && *title ? @(title) : @"Enter text";
    NSString *msg = [NSString stringWithFormat:@"%@%@%@", sub ? @(sub) : @"", sub && *sub && guide && *guide ? @"\n" : @"", guide ? @(guide) : @""];
    NSString *init = initial ? @(initial) : @"", *ph = guide && *guide ? @(guide) : nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block int r = 0; __block NSString *text = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:t message:msg.length ? msg : nil preferredStyle:UIAlertControllerStyleAlert];
        a.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        __weak UIAlertController *wa = a;
        [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
            f.text = init; f.placeholder = ph; f.clearButtonMode = UITextFieldViewModeWhileEditing; f.keyboardAppearance = UIKeyboardAppearanceDark;
            if (max_chars > 0) [f addAction:[UIAction actionWithHandler:^(UIAction *act) {
                UITextField *tf = (UITextField *)act.sender;
                if (tf.markedTextRange || (int)tf.text.length <= max_chars) return;
                NSRange keep = [tf.text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, (NSUInteger)max_chars)];
                if ((int)NSMaxRange(keep) > max_chars) keep = [tf.text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, (NSUInteger)max_chars - 1)];
                tf.text = [tf.text substringWithRange:keep];
            }] forControlEvents:UIControlEventEditingChanged];
        }];
        void (^finish)(int) = ^(int ok) { if (ok) text = wa.textFields.firstObject.text; r = ok; dispatch_semaphore_signal(done); };
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { (void)x; finish(0); }]];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { (void)x; finish(1); }]];
        UIViewController *vc = top_controller();
        if (!vc) { LOG("[red] front: no view controller to show the keyboard dialog on; cancelled"); finish(0); return; }
        [vc presentViewController:a animated:YES completion:^{
            const char *tk = getenv("DM_TEST_KBD_TYPE"); if (!tk) return;
            NSString *typed = @(tk);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500000000), dispatch_get_main_queue(), ^{
                int cancel = [typed isEqualToString:@":cancel"];
                UITextField *tf = a.textFields.firstObject;
                if (!cancel) { tf.text = typed; [tf sendActionsForControlEvents:UIControlEventEditingChanged]; }
                LOG("front: DM_TEST_KBD_TYPE %s, text field now \"%s\"", cancel ? "cancel" : "typed", tf.text.UTF8String ?: "");
                [a dismissViewControllerAnimated:NO completion:^{ finish(!cancel); }];
            });
        }];
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (!r) return 0;
    snprintf(out, (size_t)out_cap, "%s", text.UTF8String ? text.UTF8String : "");
    return 1;
}

// A save transaction was refused (hle_fs.c, on the game thread): tell the player without blocking; the next transaction commits as usual
void front_save_failed(int err) {
    LOG("front: save write failed, errno=%d", err);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = top_controller();
        if (!vc) { LOG("[red] front: no view controller for the save failure alert"); return; }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Not enough storage" message:@"The game could not save its progress." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

// ---------- Lifecycle → host (hle.h: dm_focus_set, dm_audio_suspend; dm.h: dm_gfx_suspend, guest_clock_freeze_for) ----------
// Audio pauses for two independent reasons, background and an audio interruption (call, alarm); it resumes only when both are gone
static int g_audio_bg, g_audio_intr;
static void audio_apply(void) { dm_audio_suspend(g_audio_bg || g_audio_intr); }
// Scene events from main.m: 0 resign active, 1 enter background, 2 return to the foreground, 3 become active.
// In the background the guest clock is frozen too (like a Switch suspend), so in-game time does not jump by the time spent away
void front_ios_focus_event(int ev) {
    static const char *k[] = {"sceneWillResignActive", "sceneDidEnterBackground", "sceneWillEnterForeground", "sceneDidBecomeActive"};
    LOG("front: %s (guest clock %.3f s, audio callbacks %llu)", k[ev], guest_ns() / 1e9, (unsigned long long)dm_audio_render_calls());
    switch (ev) {
    case 0: [g_view liftAll]; dm_gamepad_reset(); dm_focus_set(2); break;   // held buttons / touches released in the background never report it
    case 1: dm_focus_set(3); g_audio_bg = 1; audio_apply(); dm_cloud_flush(1); guest_clock_freeze_for(1, 1); dm_gfx_suspend(1); break;
    // Back in the foreground any interruption counts as over: the system interrupts the session when the app goes to the background but does not
    // promise an "ended" on return; if the session is really still taken, starting the audio unit fails harmlessly and is retried on activation
    case 2: dm_cloud_foreground(); dm_gfx_suspend(0); guest_clock_freeze_for(1, 0); g_audio_bg = g_audio_intr = 0; audio_apply(); dm_focus_set(2); break;
    case 3: dm_focus_set(1); audio_apply(); break;
    }
}

// Called by main.m when the host starts: no auto-lock, thermal logging, audio session (Playback: sound plays with the mute switch on, as games do,
// mixed with other apps' sound; stopping in the background and on interruptions is handled here)
void front_ios_lifecycle_install(void) {
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    NSProcessInfo *pi = NSProcessInfo.processInfo;
    int sustained = -1; if (@available(iOS 18.0, *)) sustained = (int)[pi hasPerformanceProfile:NSProcessPerformanceProfileSustained];   // -1: no such query before iOS 18
    LOG("front: thermal state %ld, sustained performance profile %d", (long)pi.thermalState, sustained);
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter; NSOperationQueue *mq = NSOperationQueue.mainQueue;
    [nc addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:mq usingBlock:^(NSNotification *n) {
        (void)n; LOG("front: thermal state %ld", (long)NSProcessInfo.processInfo.thermalState); }];
    AVAudioSession *as = AVAudioSession.sharedInstance; NSError *e = nil;
    // Playback: sound with the silent switch on. MixWithOthers: Playback alone does not mix, and activating the session interrupted other apps'
    // sound (music, a voice call, screen sharing) for as long as the game was in front, whatever its volume (upstream 9393b00, #77)
    // 48 kHz (the game's rate: no resampling) and a 5 ms I/O buffer (plan item 134): asked for nothing, RemoteIO pulled about 1,024 frames a callback
    // against the 4 x 240 frames queued, so callbacks underran (nxnative 18c6143; Touchable asks the same). The actual values are logged: the system
    // may give others (a Bluetooth route)
    static void (^setup)(void) = ^{ AVAudioSession *s = AVAudioSession.sharedInstance; NSError *er = nil;
        if (![s setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&er]) LOG("[red] front: audio session category: %s", er.localizedDescription.UTF8String);
        if (![s setPreferredSampleRate:48000 error:&er]) LOG("[red] front: audio session sample rate: %s", er.localizedDescription.UTF8String);
        if (![s setPreferredIOBufferDuration:0.005 error:&er]) LOG("[red] front: audio session I/O buffer: %s", er.localizedDescription.UTF8String);
        if (![s setActive:YES error:&er]) LOG("[red] front: audio session activation: %s", er.localizedDescription.UTF8String);
        LOG("front: audio session %.0f Hz, I/O buffer %.2f ms (asked 48000 Hz, 5 ms), output latency %.1f ms", s.sampleRate, s.IOBufferDuration * 1000, s.outputLatency * 1000); };
    setup(); (void)e;
    LOG("front: audio session category %s, options %#lx (mixes with other apps: %s), other audio playing %d", as.category.UTF8String, (unsigned long)as.categoryOptions,
        (as.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers) ? "yes" : "no", (int)as.isOtherAudioPlaying);
    [nc addObserverForName:AVAudioSessionInterruptionNotification object:as queue:mq usingBlock:^(NSNotification *n) {
        AVAudioSessionInterruptionType t = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
        if (t == AVAudioSessionInterruptionTypeBegan) { LOG("front: audio interrupted"); g_audio_intr = 1; audio_apply(); return; }
        // Ended: clear the reason whether or not the system says "should resume" (a dismissed alarm comes without it)
        g_audio_intr = 0; [AVAudioSession.sharedInstance setActive:YES error:nil]; audio_apply();
        LOG("front: audio interruption ended%s", g_audio_bg ? " (still in the background)" : "");
    }];
    // The media services were reset (the audio server restarted): every AudioUnit is invalid; set the session up again and make the units again
    [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:as queue:mq usingBlock:^(NSNotification *n) {
        (void)n; LOG("front: audio media services were reset"); setup(); dm_audio_reset(); }];
    static DmVolumeWatch *vw; vw = [DmVolumeWatch new];
    [as addObserver:vw forKeyPath:@"outputVolume" options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew context:NULL];
    [nc addObserverForName:AVAudioSessionRouteChangeNotification object:as queue:mq usingBlock:^(NSNotification *n) {
        LOG("front: audio route changed, reason %lu (display link last called back %.0f ms ago)", (unsigned long)[n.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue], mtl_link_tick_age_ms()); }];
    // Test switch DM_TEST_BG=<start s>,<duration s>[;...]: simulated "enter background → return" through the same handlers
    const char *tb = getenv("DM_TEST_BG"); double tb_at, tb_dur;
    for (const char *tp = tb; tp && sscanf(tp, "%lf,%lf", &tb_at, &tb_dur) == 2; tp = strchr(tp, ';') ? strchr(tp, ';') + 1 : NULL) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(tb_at * 1e9)), dispatch_get_main_queue(), ^{
            LOG("front: DM_TEST_BG enter background"); front_ios_focus_event(0); front_ios_focus_event(1); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((tb_at + tb_dur) * 1e9)), dispatch_get_main_queue(), ^{
            LOG("front: DM_TEST_BG return"); front_ios_focus_event(2); front_ios_focus_event(3); });
    }
}
