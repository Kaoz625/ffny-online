/* iOS host glue (blz/ios, Kaoz625 fork).
 *
 * Runs before main(): the game looks for game/default.xbe in the working folder and keeps
 * its settings, saves and logs beside it, so the working folder is the app's Documents
 * folder (visible in Files and Finder through UIFileSharingEnabled). Copy the extracted
 * dump there as Documents/game. DEFJAM_DATA names the same folder, as the setup's data
 * folder does on the Mac.
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>

__attribute__((constructor)) static void defjam_ios_folders(void)
{
    @autoreleasepool {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!docs) return;
        const char *path = docs.fileSystemRepresentation;
        if (chdir(path) != 0) return;
        {   /* An install from a page carries the game in the app bundle (Def Jam FFNY.app/game):
             * point Documents/game at it unless the player put their own copy there. */
            struct stat st;
            NSString *bundled = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"game"];
            if (stat("game/default.xbe", &st) != 0 &&
                stat([bundled stringByAppendingPathComponent:@"default.xbe"].fileSystemRepresentation, &st) == 0) {
                unlink("game");
                symlink(bundled.fileSystemRepresentation, "game");
            }
        }
        if (!getenv("DEFJAM_DATA")) setenv("DEFJAM_DATA", path, 1);
        /* No keyboard player on a phone: the touch pad (or a real controller) is player 1. */
        setenv("RECOMP_KEYBOARD_PLAYER", "off", 0);
        /* Logs: Documents/logs/ios-<time>.log, readable with devicectl copy from. */
        mkdir("logs", 0755);
        if (!getenv("DEFJAM_IOS_CONSOLE")) {
            char name[128];
            time_t now = time(NULL);
            strftime(name, sizeof name, "logs/ios-%Y%m%d-%H%M%S.log", localtime(&now));
            freopen(name, "w", stderr);
            dup2(fileno(stderr), fileno(stdout));
        }
    }
}

/* The display shape for widescreen "auto": the whole screen (landscape). */
int host_macos_display_size(int *w, int *h) { (void)w; (void)h; return 0; }

/* ── Touch controls (blz/ios) ───────────────────────────────────────────────
 * A transparent multi-touch layer over SDL's view drives an SDL virtual gamepad, so the game
 * sees an ordinary controller (player 1). Left half: a floating stick where the thumb lands.
 * Right side: A/B/X/Y, LB/RB/LT/RT above them; Back and Start at the top centre. Every touch is
 * followed on its own, so a thumb can slide from one button to the next. The layer hides itself
 * while a real controller (MFi, DualSense, Xbox) is connected and comes back when it goes.
 */
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#include <SDL3/SDL.h>

enum { TB_A, TB_B, TB_X, TB_Y, TB_LB, TB_RB, TB_LT, TB_RT, TB_BACK, TB_START, TB_COUNT };
static const char *const k_tb_label[TB_COUNT] = { "A", "B", "X", "Y", "LB", "RB", "LT", "RT", "BACK", "START" };

static SDL_JoystickID s_vpad_id;
static SDL_Joystick *s_vpad;

static void vpad_open(void)
{
    SDL_VirtualJoystickDesc d;
    if (s_vpad) return;
    SDL_INIT_INTERFACE(&d);
    d.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    d.naxes = SDL_GAMEPAD_AXIS_COUNT;                    /* index == SDL_GamepadAxis */
    d.nbuttons = SDL_GAMEPAD_BUTTON_DPAD_RIGHT + 1;      /* index == SDL_GamepadButton */
    d.axis_mask = (1u << SDL_GAMEPAD_AXIS_COUNT) - 1;
    d.button_mask = (1u << (SDL_GAMEPAD_BUTTON_DPAD_RIGHT + 1)) - 1;
    d.name = "Touch controls";
    s_vpad_id = SDL_AttachVirtualJoystick(&d);
    if (!s_vpad_id) { fprintf(stderr, "[TOUCH] no virtual pad: %s\n", SDL_GetError()); return; }
    s_vpad = SDL_OpenJoystick(s_vpad_id);
    if (s_vpad) {   /* triggers rest at the bottom of the axis */
        SDL_SetJoystickVirtualAxis(s_vpad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER, SDL_JOYSTICK_AXIS_MIN);
        SDL_SetJoystickVirtualAxis(s_vpad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER, SDL_JOYSTICK_AXIS_MIN);
    }
    fprintf(stderr, "[TOUCH] virtual pad %u attached\n", (unsigned)s_vpad_id);
}

static void vpad_button(int tb, bool down)
{
    static const int map[TB_COUNT] = { SDL_GAMEPAD_BUTTON_SOUTH, SDL_GAMEPAD_BUTTON_EAST, SDL_GAMEPAD_BUTTON_WEST,
        SDL_GAMEPAD_BUTTON_NORTH, SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, -1, -1,
        SDL_GAMEPAD_BUTTON_BACK, SDL_GAMEPAD_BUTTON_START };
    if (!s_vpad) return;
    if (tb == TB_LT || tb == TB_RT)
        SDL_SetJoystickVirtualAxis(s_vpad, tb == TB_LT ? SDL_GAMEPAD_AXIS_LEFT_TRIGGER : SDL_GAMEPAD_AXIS_RIGHT_TRIGGER,
                                   down ? SDL_JOYSTICK_AXIS_MAX : SDL_JOYSTICK_AXIS_MIN);
    else
        SDL_SetJoystickVirtualButton(s_vpad, map[tb], down);
}

static void vpad_stick(float x, float y)    /* -1..1 each */
{
    if (!s_vpad) return;
    SDL_SetJoystickVirtualAxis(s_vpad, SDL_GAMEPAD_AXIS_LEFTX, (Sint16)(x * 32767.0f));
    SDL_SetJoystickVirtualAxis(s_vpad, SDL_GAMEPAD_AXIS_LEFTY, (Sint16)(y * 32767.0f));
}

@interface DJTouchLayer : UIView
@end

@implementation DJTouchLayer {
    CGRect _btn[TB_COUNT];
    int _held[TB_COUNT];                 /* touches on each button */
    NSMapTable *_owner;                  /* UITouch -> button index (NSNumber), or -1 for the stick */
    UITouch *_stickTouch;
    CGPoint _stickCentre, _stickAt;
}

- (instancetype)initWithFrame:(CGRect)f
{
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES;
        self.backgroundColor = UIColor.clearColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _owner = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    UIEdgeInsets in = self.safeAreaInsets;
    CGFloat r = MIN(s.width, s.height) * 0.085;          /* face button radius */
    CGFloat cx = s.width - in.right - r * 3.4, cy = s.height - in.bottom - r * 3.2;
    _btn[TB_A] = CGRectMake(cx - r, cy + r * 0.9, 2 * r, 2 * r);
    _btn[TB_B] = CGRectMake(cx + r * 0.9, cy - r, 2 * r, 2 * r);
    _btn[TB_X] = CGRectMake(cx - r * 2.9, cy - r, 2 * r, 2 * r);
    _btn[TB_Y] = CGRectMake(cx - r, cy - r * 2.9, 2 * r, 2 * r);
    CGFloat sw = r * 2.4, sh = r * 1.2, top = in.top + r * 0.4;
    _btn[TB_LT] = CGRectMake(in.left + r * 0.6, top, sw, sh);
    _btn[TB_LB] = CGRectMake(in.left + r * 0.6, top + sh * 1.25, sw, sh);
    _btn[TB_RT] = CGRectMake(s.width - in.right - r * 0.6 - sw, top, sw, sh);
    _btn[TB_RB] = CGRectMake(s.width - in.right - r * 0.6 - sw, top + sh * 1.25, sw, sh);
    _btn[TB_BACK] = CGRectMake(s.width / 2 - sw * 1.1, top, sw, sh * 0.85);
    _btn[TB_START] = CGRectMake(s.width / 2 + sw * 0.1, top, sw, sh * 0.85);
    [self setNeedsDisplay];
}

- (int)buttonAt:(CGPoint)p
{
    for (int i = 0; i < TB_COUNT; i++)
        if (CGRectContainsPoint(CGRectInset(_btn[i], -8, -8), p)) return i;
    return -1;
}

- (void)setOwner:(UITouch *)t to:(int)b
{
    NSNumber *old = [_owner objectForKey:t];
    if (old && old.intValue == b) return;
    if (old && old.intValue >= 0 && --_held[old.intValue] == 0) vpad_button(old.intValue, false);
    if (b >= 0 && _held[b]++ == 0) vpad_button(b, true);
    [_owner setObject:@(b) forKey:t];
    [self setNeedsDisplay];
}

- (void)stickTo:(CGPoint)p
{
    CGFloat R = MIN(self.bounds.size.width, self.bounds.size.height) * 0.16;
    CGFloat dx = p.x - _stickCentre.x, dy = p.y - _stickCentre.y, d = hypot(dx, dy);
    if (d > R) { dx *= R / d; dy *= R / d; }
    _stickAt = CGPointMake(_stickCentre.x + dx, _stickCentre.y + dy);
    vpad_stick((float)(dx / R), (float)(dy / R));
    [self setNeedsDisplay];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e
{
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        int b = [self buttonAt:p];
        if (b < 0 && !_stickTouch && p.x < self.bounds.size.width * 0.45) {
            _stickTouch = t; _stickCentre = p; [self stickTo:p];
        } else
            [self setOwner:t to:b];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e
{
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        if (t == _stickTouch) [self stickTo:p];
        else [self setOwner:t to:[self buttonAt:p]];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e
{
    for (UITouch *t in touches) {
        if (t == _stickTouch) { _stickTouch = nil; vpad_stick(0, 0); [self setNeedsDisplay]; }
        else { [self setOwner:t to:-1]; [_owner removeObjectForKey:t]; }
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e { [self touchesEnded:touches withEvent:e]; }

- (void)drawRect:(CGRect)rect
{
    CGContextRef c = UIGraphicsGetCurrentContext();
    NSDictionary *font = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:15],
                            NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.85] };
    for (int i = 0; i < TB_COUNT; i++) {
        CGRect b = _btn[i];
        UIBezierPath *path = i <= TB_Y ? [UIBezierPath bezierPathWithOvalInRect:b]
                                       : [UIBezierPath bezierPathWithRoundedRect:b cornerRadius:b.size.height / 2];
        [[UIColor colorWithWhite:_held[i] ? 0.9 : 0.15 alpha:_held[i] ? 0.45 : 0.30] setFill];
        [path fill];
        [[UIColor colorWithWhite:1 alpha:0.45] setStroke];
        path.lineWidth = 2; [path stroke];
        NSString *l = [NSString stringWithUTF8String:k_tb_label[i]];
        CGSize ls = [l sizeWithAttributes:font];
        [l drawAtPoint:CGPointMake(CGRectGetMidX(b) - ls.width / 2, CGRectGetMidY(b) - ls.height / 2) withAttributes:font];
    }
    if (_stickTouch) {
        CGFloat R = MIN(self.bounds.size.width, self.bounds.size.height) * 0.16;
        CGContextSetRGBStrokeColor(c, 1, 1, 1, 0.4); CGContextSetLineWidth(c, 2);
        CGContextStrokeEllipseInRect(c, CGRectMake(_stickCentre.x - R, _stickCentre.y - R, 2 * R, 2 * R));
        CGContextSetRGBFillColor(c, 1, 1, 1, 0.35);
        CGContextFillEllipseInRect(c, CGRectMake(_stickAt.x - R * 0.4, _stickAt.y - R * 0.4, R * 0.8, R * 0.8));
    }
}
@end

static DJTouchLayer *s_layer;
static UIWindow *s_touch_window;

/* The overlay's own window, above SDL's: it keeps the landscape orientations of the game. */
@interface DJTouchController : UIViewController
@end
@implementation DJTouchController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
@end

static void touch_layer_update_visibility(void)
{
    BOOL real = NO;
    for (GCController *g in GCController.controllers)
        if (g.extendedGamepad) real = YES;
    BOOL hide = real || getenv("DEFJAM_NO_TOUCH") != NULL;
    s_layer.hidden = hide;
    s_touch_window.hidden = hide;      /* a hidden overlay window takes no touches */
}

void host_ios_window_made(SDL_Window *window)
{
    UIWindow *w = (__bridge UIWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(window),
                                                            SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
    if (!w) { fprintf(stderr, "[TOUCH] no UIKit window\n"); return; }
    vpad_open();
    DJTouchController *vc = [DJTouchController new];
    s_layer = [[DJTouchLayer alloc] initWithFrame:w.bounds];
    vc.view = s_layer;
    s_touch_window = w.windowScene ? [[UIWindow alloc] initWithWindowScene:w.windowScene]
                                   : [[UIWindow alloc] initWithFrame:w.bounds];
    s_touch_window.windowLevel = UIWindowLevelNormal + 1;
    s_touch_window.backgroundColor = UIColor.clearColor;
    s_touch_window.opaque = NO;
    s_touch_window.rootViewController = vc;
    s_touch_window.hidden = NO;
    [w makeKeyWindow];                 /* SDL's window keeps the keyboard and focus */
    touch_layer_update_visibility();
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { touch_layer_update_visibility(); }];
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { touch_layer_update_visibility(); }];
    fprintf(stderr, "[TOUCH] controls %s\n", s_layer.hidden ? "hidden (a controller is connected)" : "shown");
}
