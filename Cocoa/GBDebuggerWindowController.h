#import <AppKit/AppKit.h>

@class Document;

/* A BGB-style graphical debugger window: disassembly view with a clickable
   breakpoint gutter, register and stack panes, and stepping controls. */
@interface GBDebuggerWindowController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSControlTextEditingDelegate, NSSplitViewDelegate, NSWindowDelegate>
+ (instancetype)controllerWithDocument:(Document *)document;

/* Shows the window and populates it — even while the emulator is running (it
   is briefly stopped to sweep the address space). */
- (void)present;

/* Called on the main thread while the debugger is stopped (the emulation
   thread is parked inside the debugger input callback), or while the
   emulation is fully paused. Reloads every data pane. */
- (void)debuggerDidRefresh;

/* Called on the main thread whenever the paused/running state may have
   changed. Updates control states, and reloads the data panes when the
   emulator newly became paused. */
- (void)updateRunningState;

/* Invalidates the state poll timer and closes the window. Must be called
   before the owning document releases the controller. */
- (void)teardown;
@end
