#import "GBDebuggerWindowController.h"
#import "Document.h"
#import "GBPanel.h"
#import "GBWarningPopover.h"
#import "HexFiend/HexFiend.h"
#import "GBMemoryByteArray.h"
#import "GBHexStatusBarRepresenter.h"
#import "GBSM83Assembler.h"
#import "GBDebuggerSupport.h"
#import <Core/gb.h>

static const unsigned GBStackRowCount = 32;
static const unsigned GBDisassemblyContextRows = 6;
static const unsigned GBDisassemblyChunkSize = 8192; // Instructions per GB_cpu_disassemble capture
static const CGFloat GBMinimumMainPaneHeight = 200; // Disassembly + side panes above the memory pane
static const CGFloat GBMinimumMainPaneWidth = 400; // Disassembly pane left of the side panes
static const CGFloat GBMinimumMemoryPaneHeight = 60;
static const CGFloat GBMinimumSidePaneWidth = 240;

/* The main registers, in _registersTable row order; the names index into
   GB_registers_t.registers, so the register table and the editor always
   agree on which register a row holds. */
static const char *const GBMainRegisterNames[GB_REGISTERS_16_BIT] = {
    [GB_REGISTER_AF] = "AF",
    [GB_REGISTER_BC] = "BC",
    [GB_REGISTER_DE] = "DE",
    [GB_REGISTER_HL] = "HL",
    [GB_REGISTER_SP] = "SP",
    [GB_REGISTER_PC] = "PC",
};

@interface GBBreakpointEntry : NSObject
@property unsigned bpID;
@property uint16_t address;
@property uint16_t bank; // GBDebuggerAnyBank = any bank
@end

@implementation GBBreakpointEntry
@end

/* Bookkeeping for Run to Cursor: a temporary breakpoint we created and must
   delete once the emulator stops somewhere else. */
@interface GBRunToState : NSObject
@property uint16_t address;
@property uint16_t bank;
@property unsigned refreshesToSkip;
@property NSSet<NSNumber *> *breakpointIDsBefore;
@end

@implementation GBRunToState
@end

static NSColor *GBBreakpointColor(void)
{
    if (@available(macOS 10.10, *)) {
        return [NSColor systemRedColor];
    }
    return [NSColor redColor];
}

static NSColor *GBPCRowColor(void)
{
    if (@available(macOS 10.14, *)) {
        return [[NSColor controlAccentColor] colorWithAlphaComponent:0.3];
    }
    return [NSColor colorWithCalibratedRed:0.25 green:0.5 blue:1.0 alpha:0.3];
}

/* Formats 1-3 instruction bytes the way the disassembly bytes column shows them */
static NSString *hexStringForBytes(const uint8_t *bytes, unsigned length)
{
    char buffer[12] = "";
    char *p = buffer;
    for (unsigned i = 0; i < length; i++) {
        p += snprintf(p, buffer + sizeof(buffer) - p, i? " %02x" : "%02x", bytes[i]);
    }
    return @(buffer);
}

/* GB_debugger_execute_command mutates the string it is given */
static void executeDebuggerCommand(GB_gameboy_t *gb, NSString *command)
{
    char *dupped = strdup(command.UTF8String);
    GB_debugger_execute_command(gb, dupped);
    free(dupped);
}

@implementation GBDebuggerWindowController
{
    __weak Document *_document;
    GBPanel *_window;

    NSTableView *_disassemblyTable;
    NSTableView *_stackTable;
    NSTableView *_registersTable;
    NSSplitView *_splitView;
    NSSplitView *_outerSplitView;
    NSView *_sidePane;
    HFController *_hexController;

    NSButton *_continueButton;
    NSButton *_stepInButton;
    NSButton *_stepOverButton;
    NSButton *_stepOutButton;
    NSButton *_backstepButton;
    NSButton *_runToCursorButton;
    NSButton *_toggleBreakpointButton;
    NSButton *_jumpToPCButton;
    NSTextField *_gotoField;
    NSTextField *_statusField;

    NSFont *_font;
    NSFont *_boldFont;

    /* The disassembly covers the entire $0000-$ffff address space. When
       paused, the sweep is anchored at the PC so the PC is always a row
       boundary; the anchored sweep is only redone when the PC no longer falls
       on a row boundary or the mapped ROM bank changed. */
    NSMutableArray<GBDisassemblyRow *> *_disassemblyRows;
    uint32_t *_rowIndexByAddress; // Instruction row index + 1 per address; 0 = none
    bool _sweepValid;
    GBDebuggerBankContext _currentBankContext;
    GBDebuggerBankContext _sweepBankContext;
    bool _pcValid; // False while running; the PC marker is hidden

    NSMutableArray<NSDictionary *> *_stackRows;
    NSMutableArray<NSDictionary *> *_registerRows;
    NSMutableArray<GBBreakpointEntry *> *_breakpoints;
    NSIndexSet *_breakpointAddresses;

    uint16_t _pc;
    bool _lastKnownPaused;

    /* The core has no "resumed" callback, and the pause state can change
       without any UI hook firing (e.g. `continue` finishing while the audio
       client is still starting up). A cheap poll reconciles the UI; it only
       reads volatile flags unless the state actually changed, plus the
       live-pane refresh while running. */
    NSTimer *_stateTimer;

    GBRunToState *_runToState; // nil when no Run to Cursor breakpoint is pending
}

+ (instancetype)controllerWithDocument:(Document *)document
{
    GBDebuggerWindowController *ret = [[self alloc] init];
    ret->_document = document;
    [ret createWindow];
    return ret;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _disassemblyRows = [NSMutableArray array];
        _stackRows = [NSMutableArray array];
        _registerRows = [NSMutableArray array];
        _breakpoints = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc
{
    if (_rowIndexByAddress) {
        free(_rowIndexByAddress);
    }
}

- (NSButton *)makeBarButton:(NSString *)title
                      image:(NSString *)imageName
                    keyCode:(unichar)keyCode
                  modifiers:(NSUInteger)modifiers
                    toolTip:(NSString *)toolTip
                     action:(SEL)action
{
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.title = title;
    button.bezelStyle = NSTexturedRoundedBezelStyle;
    if (imageName) {
        button.image = [NSImage imageNamed:imageName];
        button.imagePosition = NSImageLeft;
    }
    if (keyCode) {
        button.keyEquivalent = [NSString stringWithFormat:@"%C", keyCode];
        button.keyEquivalentModifierMask = modifiers;
    }
    button.toolTip = toolTip;
    button.target = self;
    button.action = action;
    [button sizeToFit];
    return button;
}

- (NSScrollView *)makeScrollViewForTable:(NSTableView *)table frame:(NSRect)frame
{
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:frame];
    scrollView.hasVerticalScroller = true;
    scrollView.borderType = NSNoBorder;
    scrollView.documentView = table;
    return scrollView;
}

- (NSTableView *)makeTable
{
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    table.headerView = nil;
    table.allowsMultipleSelection = false;
    table.allowsColumnReordering = false;
    table.allowsColumnResizing = false;
    table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    table.intercellSpacing = NSMakeSize(6, 1);
    table.dataSource = self;
    table.delegate = self;
    return table;
}

- (void)addColumnToTable:(NSTableView *)table identifier:(NSString *)identifier width:(CGFloat)width
{
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
    column.width = width;
    column.editable = false;
    ((NSTextFieldCell *)column.dataCell).drawsBackground = false;
    [table addTableColumn:column];
}

/* Top control bar: the stepping buttons and the go to / search field */
- (NSView *)makeControlBarWithFrame:(NSRect)frame
{
    const CGFloat barHeight = frame.size.height;
    NSView *bar = [[NSView alloc] initWithFrame:frame];
    bar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

    _continueButton = [self makeBarButton:@"Continue" image:@"ContinueTemplate"
                                  keyCode:NSF9FunctionKey modifiers:0
                                  toolTip:@"Continue (F9)" action:@selector(continueOrInterrupt:)];
    _stepInButton = [self makeBarButton:@"Step Into" image:@"StepTemplate"
                                keyCode:NSF7FunctionKey modifiers:0
                                toolTip:@"Step Into (F7)" action:@selector(stepInto:)];
    _stepOverButton = [self makeBarButton:@"Step Over" image:@"NextTemplate"
                                  keyCode:NSF8FunctionKey modifiers:0
                                  toolTip:@"Step Over (F8)" action:@selector(stepOver:)];
    _stepOutButton = [self makeBarButton:@"Step Out" image:@"FinishTemplate"
                                 keyCode:NSF8FunctionKey modifiers:NSEventModifierFlagShift
                                 toolTip:@"Step Out (Shift-F8)" action:@selector(stepOut:)];
    _backstepButton = [self makeBarButton:@"Backstep" image:@"BackstepTemplate"
                                  keyCode:NSF7FunctionKey modifiers:NSEventModifierFlagShift
                                  toolTip:@"Step Backwards (Shift-F7)" action:@selector(backstep:)];
    _runToCursorButton = [self makeBarButton:@"To Cursor" image:nil
                                     keyCode:NSF4FunctionKey modifiers:0
                                     toolTip:@"Run to Cursor (F4)" action:@selector(runToCursor:)];
    _toggleBreakpointButton = [self makeBarButton:@"Breakpoint" image:nil
                                          keyCode:NSF2FunctionKey modifiers:0
                                          toolTip:@"Toggle Breakpoint (F2)" action:@selector(toggleBreakpoint:)];
    _jumpToPCButton = [self makeBarButton:@"Go to PC" image:nil
                                  keyCode:0 modifiers:0
                                  toolTip:@"Scroll the disassembly back to the program counter" action:@selector(jumpToPC:)];

    CGFloat x = 8;
    for (NSButton *button in @[_continueButton, _stepInButton, _stepOverButton, _stepOutButton,
                               _backstepButton, _runToCursorButton, _toggleBreakpointButton, _jumpToPCButton]) {
        NSRect frame = button.frame;
        frame.origin.x = x;
        frame.origin.y = round((barHeight - frame.size.height) / 2);
        button.frame = frame;
        button.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
        [bar addSubview:button];
        x += frame.size.width + 4;
    }

    const CGFloat gotoWidth = 160;
    _gotoField = [[NSTextField alloc] initWithFrame:NSMakeRect(frame.size.width - gotoWidth - 8, round((barHeight - 22) / 2), gotoWidth, 22)];
    _gotoField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    [_gotoField.cell setPlaceholderString:@"Go to / Search"];
    _gotoField.toolTip = @"Jump to an address (hex, symbol or expression), or search the disassembly";
    ((NSTextFieldCell *)_gotoField.cell).sendsActionOnEndEditing = false;
    _gotoField.target = self;
    _gotoField.action = @selector(gotoAddress:);
    [bar addSubview:_gotoField];
    return bar;
}

- (NSScrollView *)makeDisassemblyPaneWithFrame:(NSRect)frame
{
    _disassemblyTable = [self makeTable];
    [self addColumnToTable:_disassemblyTable identifier:@"gutter" width:26];
    [self addColumnToTable:_disassemblyTable identifier:@"address" width:52];
    [self addColumnToTable:_disassemblyTable identifier:@"bytes" width:74];
    [self addColumnToTable:_disassemblyTable identifier:@"text" width:200];
    /* Bytes and instructions are editable (in RAM, while paused); gated by
       the delegate */
    [_disassemblyTable tableColumnWithIdentifier:@"bytes"].editable = true;
    [_disassemblyTable tableColumnWithIdentifier:@"text"].editable = true;
    _disassemblyTable.target = self;
    _disassemblyTable.action = @selector(disassemblyClicked:);
    _disassemblyTable.doubleAction = @selector(disassemblyDoubleClicked:);
    NSScrollView *disassemblyScroll = [self makeScrollViewForTable:_disassemblyTable frame:frame];
    disassemblyScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    return disassemblyScroll;
}

/* The registers table above the stack table */
- (NSView *)makeSidePaneWithFrame:(NSRect)frame
{
    NSView *sidePane = [[NSView alloc] initWithFrame:frame];
    sidePane.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _sidePane = sidePane;

    _registersTable = [self makeTable];
    [self addColumnToTable:_registersTable identifier:@"name" width:80];
    [self addColumnToTable:_registersTable identifier:@"value" width:200];
    /* Register values are editable while paused; gated by the delegate */
    [_registersTable tableColumnWithIdentifier:@"value"].editable = true;
    const CGFloat registersHeight = 240;
    NSScrollView *registersScroll = [self makeScrollViewForTable:_registersTable
                                                           frame:NSMakeRect(0, frame.size.height - registersHeight, frame.size.width, registersHeight)];
    registersScroll.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [sidePane addSubview:registersScroll];

    _stackTable = [self makeTable];
    [self addColumnToTable:_stackTable identifier:@"address" width:52];
    [self addColumnToTable:_stackTable identifier:@"value" width:52];
    [self addColumnToTable:_stackTable identifier:@"description" width:180];
    NSScrollView *stackScroll = [self makeScrollViewForTable:_stackTable
                                                       frame:NSMakeRect(0, 0, frame.size.width, frame.size.height - registersHeight - 1)];
    stackScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [sidePane addSubview:stackScroll];
    return sidePane;
}

/* Memory editor pane — same HexFiend machinery as the Memory window,
   including editing (writes go through GB_write_memory atomically; ROM
   edits behave like the Memory window's) */
- (NSView *)makeMemoryPaneWithFrame:(NSRect)frame
{
    Document *document = _document;
    _hexController = [[HFController alloc] init];
    _hexController.font = [document debuggerFontOfSize:12];
    [_hexController setBytesPerColumn:1];
    [_hexController setEditMode:HFOverwriteMode];
    GBMemoryByteArray *byteArray = [[GBMemoryByteArray alloc] initWithDocument:document];
    byteArray.mode = GBMemoryEntireSpace;
    [_hexController setByteArray:byteArray];

    HFLayoutRepresenter *layoutRep = [[HFLayoutRepresenter alloc] init];
    HFHexTextRepresenter *hexRep = [[HFHexTextRepresenter alloc] init];
    HFStringEncodingTextRepresenter *asciiRep = [[HFStringEncodingTextRepresenter alloc] init];
    HFVerticalScrollerRepresenter *scrollerRep = [[HFVerticalScrollerRepresenter alloc] init];
    HFLineCountingRepresenter *lineRep = [[HFLineCountingRepresenter alloc] init];
    lineRep.lineNumberFormat = HFLineNumberFormatHexadecimal;
    GBHexStatusBarRepresenter *statusRep = [[GBHexStatusBarRepresenter alloc] init];
    statusRep.gb = document.gb;
    statusRep.bankForDescription = -1;

    [_hexController addRepresenter:layoutRep];
    [_hexController addRepresenter:hexRep];
    [_hexController addRepresenter:asciiRep];
    [_hexController addRepresenter:scrollerRep];
    [_hexController addRepresenter:lineRep];
    [_hexController addRepresenter:statusRep];
    [layoutRep addRepresenter:hexRep];
    [layoutRep addRepresenter:scrollerRep];
    [layoutRep addRepresenter:asciiRep];
    [layoutRep addRepresenter:lineRep];
    [layoutRep addRepresenter:statusRep];
    [(NSView *)hexRep.view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    NSView *memoryPane = layoutRep.view;
    memoryPane.frame = frame;
    memoryPane.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    return memoryPane;
}

/* Outer split: the disassembly/registers area on top, the memory editor at
   the bottom; inner split: disassembly on the left, registers + stack on the
   right */
- (NSSplitView *)makeSplitViewsWithFrame:(NSRect)frame
{
    const CGFloat memoryHeight = 180;
    NSSplitView *outerSplitView = [[NSSplitView alloc] initWithFrame:frame];
    outerSplitView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    outerSplitView.vertical = false;
    outerSplitView.dividerStyle = NSSplitViewDividerStyleThin;
    outerSplitView.delegate = self;
    _outerSplitView = outerSplitView;
    const CGFloat paneHeight = frame.size.height - memoryHeight - outerSplitView.dividerThickness;

    NSSplitView *splitView = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, paneHeight)];
    splitView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    splitView.vertical = true;
    splitView.dividerStyle = NSSplitViewDividerStyleThin;
    splitView.delegate = self;
    _splitView = splitView;
    const CGFloat sideWidth = 340;

    [splitView addSubview:[self makeDisassemblyPaneWithFrame:
                           NSMakeRect(0, 0, frame.size.width - sideWidth - splitView.dividerThickness, paneHeight)]];
    [splitView addSubview:[self makeSidePaneWithFrame:NSMakeRect(0, 0, sideWidth, paneHeight)]];
    [outerSplitView addSubview:splitView];
    [outerSplitView addSubview:[self makeMemoryPaneWithFrame:NSMakeRect(0, 0, frame.size.width, memoryHeight)]];
    return outerSplitView;
}

- (void)createWindow
{
    const CGFloat width = 940;
    const CGFloat height = 780;
    const CGFloat barHeight = 34;
    const CGFloat statusHeight = 20;

    _window = [[GBPanel alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                           backing:NSBackingStoreBuffered
                                             defer:false];
    _window.title = @"Debugger";
    _window.delegate = self;
    _window.releasedWhenClosed = false;
    _window.hidesOnDeactivate = false;
    _window.restorable = false;
    _window.minSize = NSMakeSize(880, 560);
    _window.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
    _window.ownerWindow = _document.mainWindow;
    if (@available(macOS 11.0, *)) {
        _window.subtitle = _document.fileURL.lastPathComponent ?: @"";
    }

    NSView *content = _window.contentView;
    [content addSubview:[self makeControlBarWithFrame:NSMakeRect(0, height - barHeight, width, barHeight)]];

    /* Bottom status line */
    _statusField = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 2, width - 16, statusHeight - 4)];
    _statusField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    _statusField.editable = false;
    _statusField.selectable = false;
    _statusField.bordered = false;
    _statusField.drawsBackground = false;
    _statusField.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    _statusField.stringValue = @"";
    [content addSubview:_statusField];

    [content addSubview:[self makeSplitViewsWithFrame:NSMakeRect(0, statusHeight, width, height - barHeight - statusHeight)]];

    [self updateFonts];
    [_window center]; // Default position; overridden by the restored frame, if any
    [_window setFrameAutosaveName:@"GBDebuggerWindow"];
    [self updateRunningState];
}

/* The timer retains the controller until it is invalidated; it only runs
   while the window is open (see -windowWillClose:). */
- (void)startStateTimer
{
    if (_stateTimer) return;
    _stateTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                   target:self
                                                 selector:@selector(statePollTick)
                                                 userInfo:nil
                                                  repeats:true];
    _stateTimer.tolerance = 0.1;
}

- (void)windowWillClose:(NSNotification *)notification
{
    [_stateTimer invalidate];
    _stateTimer = nil;
    if (_runToState) {
        /* debuggerDidRefresh never fires while the window is closed, so the
           temporary breakpoint would outlive the window — delete it now. */
        [self performWithCoreAccessible:^{
            [self deleteRunToBreakpoint];
        }];
    }
}

- (void)present
{
    [self startStateTimer];
    [_window makeKeyAndOrderFront:nil];
    [self updateRunningState];
    if (_document.isPaused) {
        [self debuggerDidRefresh];
    }
    else if (!_disassemblyRows.count) {
        [self populateWhileRunning];
    }
}

- (void)statePollTick
{
    if (!_window.isVisible) return;
    if (_document.isPaused != _lastKnownPaused) {
        [self updateRunningState];
    }
    if (!_document.isPaused) {
        [self refreshLivePanes];
    }
}

/* While the emulator runs, keep the panes fresh the way the Memory window
   does: registers and stack are re-read every tick, and the bytes of the
   visible disassembly rows are compared against memory — rows whose bytes
   changed (e.g. RAM code) are re-disassembled in place. All core reads happen
   in a single atomic block, like the hex editor's I/O-page refresh; the main
   thread blocks until the block returns (it runs on the emulation thread at a
   safe point), so touching the row model from the block is safe. */
- (void)refreshLivePanes
{
    Document *document = _document;
    if (!document) return;

    NSRange visible = _disassemblyRows.count? [_disassemblyTable rowsInRect:_disassemblyTable.visibleRect] : NSMakeRange(0, 0);
    NSMutableIndexSet *changed = [NSMutableIndexSet indexSet];

    [document performAtomicBlock:^{
        GB_gameboy_t *gb = document.gb;
        [self reloadRegistersLive:true];
        [self reloadStack];

        for (NSUInteger i = visible.location; i < NSMaxRange(visible) && i < self->_disassemblyRows.count; i++) {
            GBDisassemblyRow *row = self->_disassemblyRows[i];
            if (row.isLabel || !row.bytes) continue;
            unsigned length = row.instructionLength;
            if (!length || length > 3) continue;
            uint8_t bytes[3];
            for (unsigned j = 0; j < length; j++) {
                bytes[j] = GB_safe_read_memory(gb, row.address + j);
            }
            NSString *newBytes = hexStringForBytes(bytes, length);
            if (![row.bytes isEqualToString:newBytes]) {
                row.bytes = newBytes;
                /* The instruction itself changed; re-disassemble it in place.
                   Its length may now differ from the row layout — the full
                   model is re-anchored on the next debugger stop anyway. */
                NSMutableArray<GBDisassemblyRow *> *reparsed = [self disassemblyRowsFrom:row.address count:1];
                for (GBDisassemblyRow *fresh in reparsed) {
                    if (!fresh.isLabel && fresh.address == row.address) {
                        row.text = fresh.text;
                        break;
                    }
                }
                [changed addIndex:i];
            }
        }
    }];

    [self reloadDataPanes];
    if (changed.count) {
        NSIndexSet *allColumns = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)_disassemblyTable.numberOfColumns)];
        [_disassemblyTable reloadDataForRowIndexes:changed columnIndexes:allColumns];
    }
}

/* Reloads the registers, stack and memory panes; the registers table is
   skipped mid-edit so a reload doesn't kill the edit session. */
- (void)reloadDataPanes
{
    if (_registersTable.editedRow == -1) {
        [_registersTable reloadData];
    }
    [_stackTable reloadData];
    [_hexController reloadData];
}

- (void)teardown
{
    [_window close]; // -windowWillClose: stops the state timer
}

- (void)updateFonts
{
    _font = [_document debuggerFontOfSize:11];
    _boldFont = [[NSFontManager sharedFontManager] convertFont:_font toHaveTrait:NSBoldFontMask];
    for (NSTableView *table in @[_disassemblyTable, _stackTable, _registersTable]) {
        table.rowHeight = round(_font.ascender - _font.descender + 4);
    }
    NSFont *hexFont = [_document debuggerFontOfSize:12];
    if (_hexController && ![_hexController.font isEqual:hexFont]) {
        _hexController.font = hexFont;
    }
}

/* The side pane keeps its width and the memory pane keeps its height when
   the window resizes, like the Debug Console's sidebar — unless the main
   pane would drop below its minimum, in which case they give way. */
- (void)splitView:(NSSplitView *)splitView resizeSubviewsWithOldSize:(NSSize)oldSize
{
    if (splitView.subviews.count != 2) {
        [splitView adjustSubviews];
        return;
    }
    NSView *first = splitView.subviews[0];
    NSView *second = splitView.subviews[1];
    if (splitView == _outerSplitView) {
        CGFloat total = splitView.bounds.size.height - splitView.dividerThickness;
        CGFloat width = splitView.bounds.size.width;
        CGFloat bottomHeight = MIN(second.frame.size.height, MAX(total - GBMinimumMainPaneHeight, 0));
        first.frame = NSMakeRect(0, 0, width, total - bottomHeight);
        second.frame = NSMakeRect(0, total - bottomHeight + splitView.dividerThickness, width, bottomHeight);
        return;
    }
    CGFloat total = splitView.bounds.size.width - splitView.dividerThickness;
    CGFloat height = splitView.bounds.size.height;
    CGFloat rightWidth = MIN(second.frame.size.width, MAX(total - GBMinimumMainPaneWidth, 0));
    first.frame = NSMakeRect(0, 0, total - rightWidth, height);
    second.frame = NSMakeRect(total - rightWidth + splitView.dividerThickness, 0, rightWidth, height);
}

- (CGFloat)splitView:(NSSplitView *)splitView constrainMinCoordinate:(CGFloat)proposedMinimumPosition ofSubviewAt:(NSInteger)dividerIndex
{
    if (splitView == _outerSplitView) {
        return GBMinimumMainPaneHeight;
    }
    return GBMinimumMainPaneWidth;
}

- (CGFloat)splitView:(NSSplitView *)splitView constrainMaxCoordinate:(CGFloat)proposedMaximumPosition ofSubviewAt:(NSInteger)dividerIndex
{
    if (splitView == _outerSplitView) {
        return splitView.frame.size.height - GBMinimumMemoryPaneHeight;
    }
    return splitView.frame.size.width - GBMinimumSidePaneWidth;
}

/* Runs a debugger command while the core is safely accessible from the main
   thread (debugger stopped or emulation paused), returning its log output. */
- (NSString *)outputOfCommand:(NSString *)command
{
    Document *document = _document;
    if (!document) return nil;
    GB_gameboy_t *gb = document.gb;
    return [document captureOutputForBlock:^{
        executeDebuggerCommand(gb, command);
    }];
}

/* Evaluates a debugger expression while the core is safely accessible from
   the main thread. Returns whether it succeeded; on failure `errorMessage`
   (if given) holds the debugger's log output. */
- (bool)evaluateExpression:(NSString *)expression result:(uint16_t *)value errorMessage:(NSString **)errorMessage
{
    Document *document = _document;
    if (!document) return false;
    GB_gameboy_t *gb = document.gb;
    __block bool error = true;
    __block uint16_t result = 0;
    NSString *output = [document captureOutputForBlock:^{
        uint16_t bank;
        error = GB_debugger_evaluate(gb, expression.UTF8String, &result, &bank);
    }];
    if (value) {
        *value = result;
    }
    if (errorMessage) {
        *errorMessage = output;
    }
    return !error;
}

/* Runs the block with the core safely accessible from the main thread. If the
   emulator is running, it is stopped for the duration of the block — the
   established pattern used all over Document (save panels, ROM loading…). */
- (void)performWithCoreAccessible:(void (^)(void))block
{
    Document *document = _document;
    if (!document) return;
    if (document.isPaused) {
        block();
        return;
    }
    [document stop];
    block();
    [document start];
}

- (IBAction)continueOrInterrupt:(id)sender
{
    if (_document.isPaused) {
        [_document queueDebuggerCommand:@"continue"];
    }
    else {
        [_document queueDebuggerCommand:@"interrupt"];
    }
}

- (IBAction)stepInto:(id)sender
{
    [_document queueDebuggerCommand:@"step"];
}

- (IBAction)stepOver:(id)sender
{
    [_document queueDebuggerCommand:@"next"];
}

- (IBAction)stepOut:(id)sender
{
    [_document queueDebuggerCommand:@"finish"];
}

- (IBAction)backstep:(id)sender
{
    [_document queueDebuggerCommand:@"backstep"];
}

- (GBDisassemblyRow *)selectedInstructionRow
{
    NSInteger row = _disassemblyTable.selectedRow;
    if (row < 0 || (NSUInteger)row >= _disassemblyRows.count) {
        if (!_pcValid) return nil;
        NSInteger pcRow = [self rowIndexForAddress:_pc];
        if (pcRow < 0) return nil;
        return _disassemblyRows[pcRow];
    }
    GBDisassemblyRow *selected = _disassemblyRows[row];
    if (selected.isLabel) return nil;
    return selected;
}

- (GBBreakpointEntry *)breakpointAtAddress:(uint16_t)address
{
    for (GBBreakpointEntry *breakpoint in _breakpoints) {
        if (GBDebuggerBreakpointMatchesAddress(breakpoint.address, breakpoint.bank, address, _currentBankContext)) {
            return breakpoint;
        }
    }
    return nil;
}

- (void)toggleBreakpointAtAddress:(uint16_t)address
{
    GBBreakpointEntry *existing = [self breakpointAtAddress:address];
    NSString *command = existing? [NSString stringWithFormat:@"delete %u", existing.bpID]
                                : GBDebuggerBreakpointCommandForAddress(address, _currentBankContext);
    if (_document.isPaused) {
        /* Echoes in the console; the panes refresh through the stop hook */
        [_document queueDebuggerCommand:command];
        return;
    }
    [self performWithCoreAccessible:^{
        Document *document = self->_document;
        if (!document) return;
        executeDebuggerCommand(document.gb, command);
        [self reloadBreakpoints];
    }];
    [_disassemblyTable reloadData];
}

- (IBAction)toggleBreakpoint:(id)sender
{
    GBDisassemblyRow *row = [self selectedInstructionRow];
    if (!row) {
        NSBeep();
        return;
    }
    [self toggleBreakpointAtAddress:row.address];
}

- (IBAction)runToCursor:(id)sender
{
    if (!_document.isPaused) {
        NSBeep();
        return;
    }
    GBDisassemblyRow *row = [self selectedInstructionRow];
    if (!row || row.address == _pc) {
        NSBeep();
        return;
    }
    GBBreakpointEntry *existing = [self breakpointAtAddress:row.address];
    if (!existing) {
        NSMutableSet *ids = [NSMutableSet set];
        for (GBBreakpointEntry *breakpoint in _breakpoints) {
            [ids addObject:@(breakpoint.bpID)];
        }
        GBRunToState *state = [[GBRunToState alloc] init];
        state.breakpointIDsBefore = ids;
        state.address = row.address;
        state.bank = GBDebuggerBankForNewBreakpointAtAddress(row.address, _currentBankContext);
        state.refreshesToSkip = 1;
        _runToState = state;
        [_document queueDebuggerCommand:GBDebuggerBreakpointCommandForAddress(row.address, _currentBankContext)];
    }
    [_document queueDebuggerCommand:@"continue"];
}

- (IBAction)jumpToPC:(id)sender
{
    if (!_document.isPaused || !_pcValid) {
        NSBeep();
        return;
    }
    [self scrollToRowIndex:[self rowIndexForAddress:_pc] force:true];
}

- (void)jumpToAddress:(uint16_t)address
{
    NSInteger row = [self rowIndexAtOrAfterAddress:address];
    if (row >= 0) {
        [_disassemblyTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:false];
        [self scrollToRowIndex:row force:true];
    }
    [_hexController setSelectedContentsRanges:@[[HFRangeWrapper withRange:HFRangeMake(address, 0)]]];
    [_hexController _ensureVisibilityOfLocation:address];
}

/* Searches the disassembly text (mnemonics, operands, labels) for a
   case-insensitive substring, starting below the current selection and
   wrapping around. */
- (bool)searchDisassemblyFor:(NSString *)query
{
    NSUInteger count = _disassemblyRows.count;
    if (!count) return false;
    NSUInteger start = (NSUInteger)(_disassemblyTable.selectedRow + 1);
    for (NSUInteger offset = 0; offset < count; offset++) {
        NSUInteger index = (start + offset) % count;
        GBDisassemblyRow *row = _disassemblyRows[index];
        if (row.text && [row.text rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [_disassemblyTable selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:false];
            [self scrollToRowIndex:(NSInteger)index force:true];
            return true;
        }
    }
    return false;
}

- (IBAction)gotoAddress:(NSTextField *)sender
{
    Document *document = _document;
    if (!document) return;
    NSString *expression = [sender.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!expression.length) return;

    /* Bare hex first, with or without a $ prefix — "4008" means $4008. This
       shadows symbols that read as hex ("face"); append "+0" to force symbol
       lookup. */
    uint16_t hexAddress;
    if (GBSM83ParseHexLiteral(expression, &hexAddress)) {
        [self jumpToAddress:hexAddress];
        [sender selectText:nil];
        return;
    }

    /* Then symbols, registers and full debugger expressions */
    __block uint16_t address = 0;
    __block bool ok = false;
    [self performWithCoreAccessible:^{
        ok = [self evaluateExpression:expression result:&address errorMessage:NULL];
    }];
    if (ok) {
        [self jumpToAddress:address];
        [sender selectText:nil];
        return;
    }

    /* Finally, treat the input as a text search over the disassembly;
       pressing Return again finds the next match. */
    if ([self searchDisassemblyFor:expression]) {
        [sender selectText:nil];
        return;
    }
    NSBeep();
    [GBWarningPopover popoverWithContents:[NSString stringWithFormat:@"“%@” not found", expression] onView:sender];
}

- (IBAction)disassemblyClicked:(id)sender
{
    NSInteger row = _disassemblyTable.clickedRow;
    NSInteger column = _disassemblyTable.clickedColumn;
    if (row < 0 || (NSUInteger)row >= _disassemblyRows.count) return;
    if (column != 0) return;
    GBDisassemblyRow *rowData = _disassemblyRows[row];
    if (rowData.isLabel) return;
    [self toggleBreakpointAtAddress:rowData.address];
}

/* Whether a disassembly row's contents can be edited in place. ROM cannot be
   edited here — use the Memory window's ROM mode for that. */
- (bool)canEditDisassemblyRow:(NSInteger)row
{
    if (row < 0 || (NSUInteger)row >= _disassemblyRows.count) return false;
    GBDisassemblyRow *rowData = _disassemblyRows[row];
    if (rowData.isLabel) return false;
    if (rowData.address < 0x8000) return false;
    return _document.isPaused;
}

- (IBAction)disassemblyDoubleClicked:(id)sender
{
    NSInteger row = _disassemblyTable.clickedRow;
    NSInteger column = _disassemblyTable.clickedColumn;
    if (column == 0) return; // Already handled by the single-click action
    if (row < 0 || (NSUInteger)row >= _disassemblyRows.count) return;

    /* Double-clicking the bytes or the instruction edits them in place;
       elsewhere it toggles a breakpoint */
    NSInteger columnIndex = [_disassemblyTable columnWithIdentifier:@"bytes"];
    if (column >= columnIndex && [self canEditDisassemblyRow:row]) {
        [_disassemblyTable editColumn:column row:row withEvent:nil select:true];
        return;
    }
    GBDisassemblyRow *rowData = _disassemblyRows[row];
    if (rowData.isLabel) return;
    [self toggleBreakpointAtAddress:rowData.address];
}

/* Shared tail of the two in-place edit paths: report a parse failure, or
   write the bytes. */
- (void)commitEditedBytes:(NSData *)bytes atAddress:(uint16_t)address error:(NSString *)error fallback:(NSString *)fallback
{
    if (!bytes) {
        NSBeep();
        [GBWarningPopover popoverWithContents:error ?: fallback onWindow:_window];
        return;
    }
    [self writeBytes:bytes atAddress:address];
}

/* Whether the breakpoint is in scope in the given bank context, i.e. its
   marker should show at its address in the disassembly gutter. */
static bool breakpointVisibleInContext(GBBreakpointEntry *breakpoint, GBDebuggerBankContext context)
{
    return GBDebuggerBreakpointMatchesAddress(breakpoint.address, breakpoint.bank, breakpoint.address, context);
}

- (void)writeBytes:(NSData *)bytes atAddress:(uint16_t)address
{
    Document *document = _document;
    if (!document) return;
    GB_gameboy_t *gb = document.gb;
    [document performAtomicBlock:^{
        const uint8_t *raw = bytes.bytes;
        for (NSUInteger i = 0; i < bytes.length; i++) {
            if (address + i > 0xFFFF) break; // Don't wrap around to $0000
            GB_write_memory(gb, address + i, raw[i]);
        }
    }];
    /* Instruction boundaries may have changed */
    _sweepValid = false;
    [self debuggerDidRefresh];
}

- (void)updateRunningState
{
    bool paused = _document.isPaused;
    bool pausedChanged = paused != _lastKnownPaused;
    _lastKnownPaused = paused;
    if (paused) {
        _continueButton.title = @"Continue";
        _continueButton.toolTip = @"Continue (F9)";
        _continueButton.image = [NSImage imageNamed:@"ContinueTemplate"];
        if (@available(macOS 10.14, *)) {
            _continueButton.contentTintColor = nil;
        }
    }
    else {
        _continueButton.title = @"Interrupt";
        _continueButton.toolTip = @"Interrupt (F9)";
        _continueButton.image = [NSImage imageNamed:@"InterruptTemplate"];
        if (@available(macOS 10.14, *)) {
            _continueButton.contentTintColor = [NSColor controlAccentColor];
        }
        _statusField.stringValue = @"Running…";
    }
    [_continueButton sizeToFit];
    _stepInButton.enabled = paused;
    _stepOverButton.enabled = paused;
    _stepOutButton.enabled = paused;
    _backstepButton.enabled = paused;
    _runToCursorButton.enabled = paused;
    _jumpToPCButton.enabled = paused;

    if (pausedChanged && !paused) {
        /* Resumed: hide the (now stale) PC marker */
        _pcValid = false;
        [_disassemblyTable reloadData];
    }
    if (pausedChanged && paused) {
        /* Transitioned to paused without a debugger stop (e.g. the pause menu
           item) — reload the data panes; the emulation thread is parked so
           core access is safe. Debugger stops are refreshed by the
           updateSideView hook instead, and skipped here to avoid touching the
           core while the emulation thread is still reaching its stop point. */
        Document *document = _document;
        if (document && !GB_debugger_is_stopped(document.gb)) {
            [self debuggerDidRefresh];
        }
    }
}

- (void)debuggerDidRefresh
{
    if (!_window.isVisible) return;
    Document *document = _document;
    if (!document || !document.isPaused) return;
    if (GB_debugger_is_stopped(document.gb) && !document.isDebuggerParked) {
        /* A debugger stop was just requested but the emulation thread has not
           parked in getDebuggerInput yet — core access from the main thread
           would race it. The updateSideView hook re-fires this once it parks. */
        return;
    }
    _lastKnownPaused = true; // Prevents the updateRunningState call below from re-triggering a reload

    /* Selection is by row index; keep it on the same instruction across the
       reload, where the row layout may change. */
    GBDisassemblyRow *selectedRow = nil;
    if (_disassemblyTable.selectedRow >= 0 && (NSUInteger)_disassemblyTable.selectedRow < _disassemblyRows.count) {
        selectedRow = _disassemblyRows[_disassemblyTable.selectedRow];
    }

    uint16_t previousPC = _pc;
    bool hadValidPC = _pcValid;

    [self updateFonts];
    [self reloadRegistersLive:false];
    _pcValid = true;
    [self cleanUpRunToBreakpoint];
    [self reloadBreakpoints]; // Also refreshes the bank context
    [self reloadDisassembly];
    [self reloadStack];

    [_disassemblyTable reloadData];
    [self reloadDataPanes];
    if (selectedRow && !selectedRow.isLabel) {
        NSInteger index = [self rowIndexForAddress:selectedRow.address];
        if (index >= 0) {
            [_disassemblyTable selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:false];
        }
        else {
            [_disassemblyTable deselectAll:nil];
        }
    }
    if (!hadValidPC || _pc != previousPC) {
        /* Follow the PC when it moved (stepping, breakpoints); stay put for
           refreshes that don't move it (edits far away from the PC) */
        [self scrollToRowIndex:[self rowIndexForAddress:_pc] force:false];
    }

    GB_gameboy_t *gb = document.gb;
    const char *description = GB_debugger_describe_address(gb, _pc, -1, false, true);
    _statusField.stringValue = [NSString stringWithFormat:@"Stopped at %s", description];
    [self updateRunningState];
}

/* Populates the disassembly and breakpoint gutter without requiring the user
   to interrupt first: the emulator is briefly stopped while the address space
   is swept. */
- (void)populateWhileRunning
{
    [self performWithCoreAccessible:^{
        [self rebuildDisassemblyWithAnchor:-1];
        [self reloadBreakpoints];
    }];
    _pcValid = false;
    [_disassemblyTable reloadData];
    NSInteger entryRow = [self rowIndexAtOrAfterAddress:0x100];
    if (entryRow >= 0) {
        [self scrollToRowIndex:entryRow force:true];
    }
}

/* The reloaders below run on the main thread with the core parked (debugger
   stopped or emulation paused), unless noted otherwise. */

- (void)updateCurrentBankContext
{
    Document *document = _document;
    if (!document) return;
    GB_gameboy_t *gb = document.gb;
    uint16_t rom0Bank = 0;
    uint16_t romBank = 0;
    uint16_t wramBank = 0;
    GB_get_direct_access(gb, GB_DIRECT_ACCESS_ROM0, NULL, &rom0Bank);
    GB_get_direct_access(gb, GB_DIRECT_ACCESS_ROM, NULL, &romBank);
    GB_get_direct_access(gb, GB_DIRECT_ACCESS_RAM, NULL, &wramBank);
    _currentBankContext = (GBDebuggerBankContext){
        .rom0Bank = rom0Bank,
        .romBank = romBank,
        .wramBank = wramBank,
    };
}

/* `live` is used while the emulator is running: values are read directly
   (tolerating tearing, like the Memory window), and anything that would
   require executing a debugger command is skipped. */
- (void)reloadRegistersLive:(bool)live
{
    Document *document = _document;
    if (!document) return;
    GB_gameboy_t *gb = document.gb;
    GB_registers_t *registers = GB_get_registers(gb);

    [_registerRows removeAllObjects];
    for (unsigned i = 0; i < GB_REGISTERS_16_BIT; i++) {
        [_registerRows addObject:@{
            @"name": @(GBMainRegisterNames[i]),
            @"value": [NSString stringWithFormat:@"$%04x", registers->registers[i]],
        }];
    }
    _pc = registers->pc;

    uint8_t flags = registers->af & 0xFF;
    NSString *flagsString = [NSString stringWithFormat:@"%c %c %c %c",
                             (flags & GB_ZERO_FLAG)? 'Z' : '-',
                             (flags & GB_SUBTRACT_FLAG)? 'N' : '-',
                             (flags & GB_HALF_CARRY_FLAG)? 'H' : '-',
                             (flags & GB_CARRY_FLAG)? 'C' : '-'];
    [_registerRows addObject:@{@"name": @"Flags", @"value": flagsString}];

    NSString *ime = @"—";
    if (!live) {
        NSString *registersOutput = [self outputOfCommand:@"registers"];
        for (NSString *line in [registersOutput componentsSeparatedByString:@"\n"]) {
            NSRange range = [line rangeOfString:@"IME = "];
            if (range.location != NSNotFound) {
                ime = [line substringFromIndex:range.location + range.length];
                break;
            }
        }
    }
    [_registerRows addObject:@{@"name": @"IME", @"value": ime}];

    uint16_t romBank = 0;
    GB_get_direct_access(gb, GB_DIRECT_ACCESS_ROM, NULL, &romBank);
    [_registerRows addObject:@{@"name": @"ROM Bank",
                               @"value": [NSString stringWithFormat:@"$%02x", romBank]}];

    static const struct {const char *name; uint16_t address;} ioRegisters[] = {
        {"LCDC", 0xFF40},
        {"STAT", 0xFF41},
        {"LY",   0xFF44},
        {"IF",   0xFF0F},
        {"IE",   0xFFFF},
        {"DIV",  0xFF04},
    };
    for (unsigned i = 0; i < sizeof(ioRegisters) / sizeof(ioRegisters[0]); i++) {
        [_registerRows addObject:@{
            @"name": @(ioRegisters[i].name),
            @"value": [NSString stringWithFormat:@"$%02x", GB_safe_read_memory(gb, ioRegisters[i].address)],
        }];
    }
}

- (void)reloadBreakpoints
{
    [self updateCurrentBankContext];
    NSString *output = [self outputOfCommand:@"list"];
    [_breakpoints removeAllObjects];
    NSMutableIndexSet *addresses = [NSMutableIndexSet indexSet];
    _breakpointAddresses = addresses;
    if (!output) return;

    static NSRegularExpression *entryRegex = nil;
    static NSRegularExpression *bankedRegex = nil;
    static NSRegularExpression *banklessRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        entryRegex = [NSRegularExpression regularExpressionWithPattern:@"^\\s*(\\d+)\\. (.*)$" options:0 error:nil];
        bankedRegex = [NSRegularExpression regularExpressionWithPattern:@"\\$([0-9a-fA-F]{1,4}):\\$([0-9a-fA-F]{1,4})" options:0 error:nil];
        banklessRegex = [NSRegularExpression regularExpressionWithPattern:@"\\$([0-9a-fA-F]{1,4})" options:0 error:nil];
    });

    bool inBreakpoints = false;
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        if ([line rangeOfString:@"breakpoint(s) set"].location != NSNotFound) {
            inBreakpoints = true;
            continue;
        }
        if ([line rangeOfString:@"watchpoint(s) set"].location != NSNotFound ||
            [line rangeOfString:@"No watchpoints set"].location != NSNotFound) {
            break;
        }
        if (!inBreakpoints) continue;

        NSTextCheckingResult *entry = [entryRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (!entry) continue;
        NSString *idString = [line substringWithRange:[entry rangeAtIndex:1]];
        NSString *rest = [line substringWithRange:[entry rangeAtIndex:2]];
        /* Condition expressions may contain their own addresses; don't let
           them win the address match below. */
        NSRange conditionRange = [rest rangeOfString:@"Condition:"];
        if (conditionRange.location != NSNotFound) {
            rest = [rest substringToIndex:conditionRange.location];
        }

        GBBreakpointEntry *breakpoint = [[GBBreakpointEntry alloc] init];
        breakpoint.bpID = (unsigned)idString.integerValue;
        breakpoint.bank = GBDebuggerAnyBank;

        NSTextCheckingResult *banked = [bankedRegex firstMatchInString:rest options:0 range:NSMakeRange(0, rest.length)];
        if (banked) {
            unsigned bank = 0, address = 0;
            sscanf([rest substringWithRange:[banked rangeAtIndex:1]].UTF8String, "%x", &bank);
            sscanf([rest substringWithRange:[banked rangeAtIndex:2]].UTF8String, "%x", &address);
            breakpoint.bank = bank;
            breakpoint.address = address;
        }
        else {
            NSTextCheckingResult *bankless = [banklessRegex firstMatchInString:rest options:0 range:NSMakeRange(0, rest.length)];
            if (!bankless) continue;
            unsigned address = 0;
            sscanf([rest substringWithRange:[bankless rangeAtIndex:1]].UTF8String, "%x", &address);
            breakpoint.address = address;
        }
        [_breakpoints addObject:breakpoint];
        if (breakpointVisibleInContext(breakpoint, _currentBankContext)) {
            [addresses addIndex:breakpoint.address];
        }
    }
}

- (void)cleanUpRunToBreakpoint
{
    GBRunToState *state = _runToState;
    if (!state) return;
    /* The debugger prompts for input again — refreshing this window once —
       right after the temporary breakpoint is set, before the queued
       `continue` executes; don't delete the breakpoint on that refresh.
       Comparing the PC against its value at arming time is not reliable
       here: execution can loop back and stop on the very same PC (e.g. an
       interrupt request from the user), which must still clean up. */
    if (state.refreshesToSkip) {
        state.refreshesToSkip--;
        return;
    }
    [self deleteRunToBreakpoint];
}

/* Deletes the pending Run to Cursor breakpoint unconditionally. Runs with the
   core accessible from the main thread. */
- (void)deleteRunToBreakpoint
{
    GBRunToState *state = _runToState;
    if (!state) return;
    _runToState = nil;

    [self reloadBreakpoints];
    for (GBBreakpointEntry *breakpoint in _breakpoints) {
        if (breakpoint.address == state.address &&
            breakpoint.bank == state.bank &&
            ![state.breakpointIDsBefore containsObject:@(breakpoint.bpID)]) {
            [self outputOfCommand:[NSString stringWithFormat:@"delete %u", breakpoint.bpID]];
            break;
        }
    }
}

/* Disassembles `count` instructions starting at `address` into rows; the
   parsing lives in GBDebuggerSupport so it is unit-testable. */
- (NSMutableArray<GBDisassemblyRow *> *)disassemblyRowsFrom:(uint16_t)address count:(unsigned)count
{
    Document *document = _document;
    if (!document) return [NSMutableArray array];
    GB_gameboy_t *gb = document.gb;

    NSString *output = [document captureOutputForBlock:^{
        GB_cpu_disassemble(gb, address, count);
    }];
    return GBDebuggerParseDisassembly(output);
}

/* Appends rows covering [start, end) to `result`, disassembling in chunks.
   The final instruction of each intermediate chunk is dropped and used as the
   next chunk's anchor, so instruction boundaries stay consistent. */
- (void)appendSweepTo:(NSMutableArray<GBDisassemblyRow *> *)result from:(uint32_t)start upTo:(uint32_t)end
{
    uint32_t cursor = start;
    while (cursor < end) {
        NSMutableArray<GBDisassemblyRow *> *chunk = [self disassemblyRowsFrom:(uint16_t)cursor count:GBDisassemblyChunkSize];
        NSUInteger keepCount = 0;
        NSInteger lastInstruction = -1;
        NSInteger secondToLastInstruction = -1;
        uint32_t previousAddress = cursor;
        bool reachedBoundary = false; // Wrapped past $ffff or reached `end`
        NSUInteger index = 0;
        for (GBDisassemblyRow *row in chunk) {
            if (!row.isLabel) {
                if (row.address < previousAddress || row.address >= end) {
                    reachedBoundary = true;
                    break;
                }
                previousAddress = row.address;
                secondToLastInstruction = lastInstruction;
                lastInstruction = index;
            }
            index++;
            keepCount = index;
        }
        if (lastInstruction < 0) break; // Nothing parseable; bail out

        if (reachedBoundary || keepCount < chunk.count) {
            /* This chunk reached the end of the range */
            [result addObjectsFromArray:[chunk subarrayWithRange:NSMakeRange(0, keepCount)]];
            return;
        }
        if (secondToLastInstruction < 0) break; // Cannot establish the next anchor
        /* Keep everything up to (and including) the second-to-last
           instruction; the last one becomes the next chunk's anchor. */
        [result addObjectsFromArray:[chunk subarrayWithRange:NSMakeRange(0, secondToLastInstruction + 1)]];
        cursor = chunk[lastInstruction].address;
    }
}

/* Rebuilds the full $0000-$ffff disassembly. With an anchor (the PC), the
   sweep restarts at the anchor so it is always a row boundary; the bytes the
   last pre-anchor instruction would overlap are shown as raw .BYTE rows. */
- (void)rebuildDisassemblyWithAnchor:(int32_t)anchor
{
    Document *document = _document;
    if (!document) return;
    GB_gameboy_t *gb = document.gb;
    [self updateCurrentBankContext];

    NSMutableArray<GBDisassemblyRow *> *rows = [NSMutableArray arrayWithCapacity:0x8000];
    if (anchor > 0) {
        [self appendSweepTo:rows from:0 upTo:(uint32_t)anchor];

        NSInteger lastInstruction = -1;
        for (NSInteger i = (NSInteger)rows.count - 1; i >= 0; i--) {
            if (!rows[(NSUInteger)i].isLabel) {
                lastInstruction = i;
                break;
            }
        }
        uint32_t gapStart = (uint32_t)anchor;
        if (lastInstruction >= 0) {
            /* Find where the last instruction before the anchor ends */
            GBDisassemblyRow *last = rows[(NSUInteger)lastInstruction];
            NSMutableArray<GBDisassemblyRow *> *probe = [self disassemblyRowsFrom:last.address count:2];
            uint32_t lastEnd = (uint32_t)anchor;
            unsigned seen = 0;
            for (GBDisassemblyRow *row in probe) {
                if (row.isLabel) continue;
                seen++;
                if (seen == 2) {
                    lastEnd = row.address;
                    break;
                }
            }
            if (lastEnd > (uint32_t)anchor || lastEnd < last.address) {
                /* It would span across the anchor — replace it with raw bytes */
                [rows removeObjectsInRange:NSMakeRange(lastInstruction, rows.count - lastInstruction)];
                gapStart = last.address;
            }
            else {
                gapStart = lastEnd;
            }
        }
        else if (!rows.count) {
            gapStart = 0;
        }
        for (uint32_t address = gapStart; address < (uint32_t)anchor; address++) {
            GBDisassemblyRow *row = [[GBDisassemblyRow alloc] init];
            row.address = address;
            row.isPadding = true;
            uint8_t byte = GB_safe_read_memory(gb, address);
            char buffer[16];
            snprintf(buffer, sizeof(buffer), ".BYTE $%02x", byte);
            row.text = @(buffer);
            snprintf(buffer, sizeof(buffer), "%02x", byte);
            row.bytes = @(buffer);
            row.instructionLength = 1;
            [rows addObject:row];
        }
        [self appendSweepTo:rows from:(uint32_t)anchor upTo:0x10000];
    }
    else {
        [self appendSweepTo:rows from:0 upTo:0x10000];
    }

    [self fillBytesForRows:rows];
    _disassemblyRows = rows;
    [self rebuildRowIndex];
    _sweepBankContext = _currentBankContext;
    _sweepValid = true;
}

- (void)fillBytesForRows:(NSMutableArray<GBDisassemblyRow *> *)rows
{
    Document *document = _document;
    if (!document) return;
    GB_gameboy_t *gb = document.gb;

    GBDisassemblyRow *previous = nil;
    for (GBDisassemblyRow *row in rows) {
        if (row.isLabel) continue;
        if (previous && !previous.bytes) {
            uint32_t length = (uint32_t)row.address - previous.address;
            if (length >= 1 && length <= 3) {
                uint8_t bytes[3];
                for (unsigned i = 0; i < length; i++) {
                    bytes[i] = GB_safe_read_memory(gb, previous.address + i);
                }
                previous.bytes = hexStringForBytes(bytes, length);
                previous.instructionLength = length;
            }
        }
        previous = row;
    }
}

- (void)rebuildRowIndex
{
    if (!_rowIndexByAddress) {
        _rowIndexByAddress = calloc(0x10000, sizeof(*_rowIndexByAddress));
    }
    else {
        memset(_rowIndexByAddress, 0, 0x10000 * sizeof(*_rowIndexByAddress));
    }
    NSUInteger index = 0;
    for (GBDisassemblyRow *row in _disassemblyRows) {
        if (!row.isLabel && !_rowIndexByAddress[row.address]) {
            _rowIndexByAddress[row.address] = (uint32_t)index + 1;
        }
        index++;
    }
}

- (NSInteger)rowIndexForAddress:(uint16_t)address
{
    if (!_rowIndexByAddress) return -1;
    uint32_t stored = _rowIndexByAddress[address];
    return stored? (NSInteger)stored - 1 : -1;
}

- (NSInteger)rowIndexAtOrAfterAddress:(uint16_t)address
{
    if (!_rowIndexByAddress) return -1;
    for (uint32_t candidate = address; candidate <= 0xFFFF; candidate++) {
        uint32_t stored = _rowIndexByAddress[candidate];
        if (stored) return (NSInteger)stored - 1;
    }
    return -1;
}

- (void)reloadDisassembly
{
    Document *document = _document;
    if (!document) return;
    [self updateCurrentBankContext];
    NSInteger pcRow = [self rowIndexForAddress:_pc];
    if (_sweepValid && GBDebuggerBankContextEqual(_currentBankContext, _sweepBankContext) && pcRow >= 0 &&
        !_disassemblyRows[pcRow].isPadding) {
        /* The PC still falls on a row boundary of the current sweep — no need
           to re-disassemble; stepping stays snappy. */
        return;
    }
    [self rebuildDisassemblyWithAnchor:_pc];
}

- (void)reloadStack
{
    Document *document = _document;
    if (!document) return;
    GB_gameboy_t *gb = document.gb;
    uint16_t sp = GB_get_registers(gb)->sp;

    [_stackRows removeAllObjects];
    for (unsigned i = 0; i < GBStackRowCount; i++) {
        uint16_t address = sp + i * 2;
        if (address < sp) break; // Wrapped around
        uint16_t value = GB_safe_read_memory(gb, address) | (GB_safe_read_memory(gb, address + 1) << 8);
        const char *description = GB_debugger_describe_address(gb, value, -1, false, false);
        NSString *descriptionString = description? (@(description) ?: @"") : @"";
        if ([descriptionString hasPrefix:@"$"]) {
            descriptionString = @""; // No symbol; the bare address adds nothing over the value column
        }
        [_stackRows addObject:@{
            @"address": [NSString stringWithFormat:@"$%04x", address],
            @"value": [NSString stringWithFormat:@"$%04x", value],
            @"description": descriptionString,
        }];
    }
}

- (void)scrollToRowIndex:(NSInteger)index force:(bool)force
{
    if (index < 0 || (NSUInteger)index >= _disassemblyRows.count) return;
    if (!force) {
        NSRange visible = [_disassemblyTable rowsInRect:_disassemblyTable.visibleRect];
        if (index >= (NSInteger)visible.location + 2 &&
            index + 2 < (NSInteger)(visible.location + visible.length)) {
            return; // Already comfortably visible; keep the view stable
        }
    }
    NSUInteger last = MIN((NSUInteger)index + GBDisassemblyContextRows, _disassemblyRows.count - 1);
    [_disassemblyTable scrollRowToVisible:last];
    [_disassemblyTable scrollRowToVisible:(NSUInteger)index > GBDisassemblyContextRows? index - GBDisassemblyContextRows : 0];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    if (tableView == _disassemblyTable) return _disassemblyRows.count;
    if (tableView == _stackTable) return _stackRows.count;
    if (tableView == _registersTable) return _registerRows.count;
    return 0;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (tableView == _disassemblyTable) {
        if ((NSUInteger)row >= _disassemblyRows.count) return @"";
        GBDisassemblyRow *rowData = _disassemblyRows[row];
        if ([tableColumn.identifier isEqualToString:@"gutter"]) {
            if (rowData.isLabel) return @"";
            NSString *marker = @"";
            if ([_breakpointAddresses containsIndex:rowData.address]) {
                marker = @"●";
            }
            if (_pcValid && rowData.address == _pc) {
                marker = [marker stringByAppendingString:@"→"];
            }
            return marker;
        }
        if ([tableColumn.identifier isEqualToString:@"address"]) {
            return rowData.isLabel? @"" : [NSString stringWithFormat:@"%04x", rowData.address];
        }
        if ([tableColumn.identifier isEqualToString:@"bytes"]) {
            return rowData.bytes ?: @"";
        }
        return rowData.text ?: @"";
    }
    if (tableView == _stackTable) {
        if ((NSUInteger)row >= _stackRows.count) return @"";
        return _stackRows[row][tableColumn.identifier] ?: @"";
    }
    if (tableView == _registersTable) {
        if ((NSUInteger)row >= _registerRows.count) return @"";
        return _registerRows[row][tableColumn.identifier] ?: @"";
    }
    return @"";
}

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (![cell isKindOfClass:[NSTextFieldCell class]]) return;
    NSTextFieldCell *textCell = cell;
    textCell.font = _font;
    textCell.drawsBackground = false;
    textCell.textColor = [NSColor controlTextColor];

    if (tableView == _disassemblyTable && (NSUInteger)row < _disassemblyRows.count) {
        GBDisassemblyRow *rowData = _disassemblyRows[row];
        bool isPCRow = _pcValid && !rowData.isLabel && rowData.address == _pc;
        if (rowData.isLabel) {
            textCell.font = _boldFont;
        }
        else if (isPCRow) {
            textCell.drawsBackground = true;
            textCell.backgroundColor = GBPCRowColor();
        }
        if ([tableColumn.identifier isEqualToString:@"gutter"] && !rowData.isLabel &&
            [_breakpointAddresses containsIndex:rowData.address]) {
            textCell.textColor = GBBreakpointColor();
        }
        if ([tableColumn.identifier isEqualToString:@"bytes"] ||
            [tableColumn.identifier isEqualToString:@"address"]) {
            if (@available(macOS 10.10, *)) {
                if (!isPCRow) {
                    textCell.textColor = [NSColor secondaryLabelColor];
                }
            }
        }
    }
    else if (tableView == _registersTable && (NSUInteger)row < _registerRows.count) {
        if ([tableColumn.identifier isEqualToString:@"name"]) {
            textCell.font = _boldFont;
        }
    }
    else if (tableView == _stackTable && (NSUInteger)row < _stackRows.count) {
        if (![tableColumn.identifier isEqualToString:@"value"]) {
            if (@available(macOS 10.10, *)) {
                textCell.textColor = [NSColor secondaryLabelColor];
            }
        }
    }
}

- (BOOL)tableView:(NSTableView *)tableView shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (tableView == _disassemblyTable) {
        if (![tableColumn.identifier isEqualToString:@"bytes"] &&
            ![tableColumn.identifier isEqualToString:@"text"]) return false;
        return [self canEditDisassemblyRow:row];
    }
    if (tableView != _registersTable) return false;
    if (![tableColumn.identifier isEqualToString:@"value"]) return false;
    if ((NSUInteger)row >= GB_REGISTERS_16_BIT) return false; // Only the main registers are editable
    return _document.isPaused;
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (tableView == _disassemblyTable) {
        if (![self canEditDisassemblyRow:row]) return;
        GBDisassemblyRow *rowData = _disassemblyRows[row];
        NSString *input = [[object description] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!input.length) return;

        if ([tableColumn.identifier isEqualToString:@"bytes"]) {
            NSString *error = nil;
            NSData *bytes = GBSM83ParseHexByteString(input, &error);
            [self commitEditedBytes:bytes atAddress:rowData.address error:error
                           fallback:@"Enter hex bytes, e.g. “3e 05”"];
            return;
        }

        if ([tableColumn.identifier isEqualToString:@"text"]) {
            NSString *error = nil;
            NSData *bytes = GBSM83Assemble(input, rowData.address, ^bool(NSString *expression, uint16_t *value) {
                return [self evaluateExpression:expression result:value errorMessage:NULL];
            }, &error);
            [self commitEditedBytes:bytes atAddress:rowData.address error:error
                           fallback:@"Could not assemble"];
            return;
        }
        return;
    }
    if (tableView != _registersTable) return;
    if ((NSUInteger)row >= GB_REGISTERS_16_BIT) return;
    Document *document = _document;
    if (!document || !document.isPaused) return;

    NSString *expression = [object description];
    if (!expression.length) return;

    GB_gameboy_t *gb = document.gb;
    uint16_t value = 0;
    NSString *errorMessage = nil;
    if (![self evaluateExpression:expression result:&value errorMessage:&errorMessage]) {
        NSBeep();
        if (errorMessage) {
            [GBWarningPopover popoverWithContents:errorMessage onWindow:_window];
        }
        return;
    }

    if ((NSUInteger)row >= _registerRows.count) return;
    /* Match by the row's label rather than its index, so reordering the rows
       in reloadRegistersLive: cannot silently write the wrong register. */
    NSString *name = _registerRows[row][@"name"];
    for (unsigned i = 0; i < GB_REGISTERS_16_BIT; i++) {
        if ([name isEqualToString:@(GBMainRegisterNames[i])]) {
            /* Through performAtomicBlock, like writeBytes: — a pause can be
               requested before the emulation thread has parked, and a direct
               write would race it. */
            [document performAtomicBlock:^{
                GB_get_registers(gb)->registers[i] = value;
            }];
            [self debuggerDidRefresh];
            return;
        }
    }
}

@end
