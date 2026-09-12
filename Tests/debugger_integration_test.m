/* Headless checks of the actual Document/controller paths: make cocoa-tests. */
#import "test_common.h"
#import "../Cocoa/Document.h"
#import "../Cocoa/GBDebuggerWindowController.h"
#import "../Cocoa/GBDebuggerSupport.h"
#import <signal.h>
#import <unistd.h>

@interface Document (TestAccess)
- (char *)getDebuggerInput;
- (void)updateSideView;
- (void)log:(const char *)text;
@end

@interface GBDebuggerWindowController (TestAccess)
- (void)runToCursor:(id)sender;
- (void)cleanUpRunToBreakpoint;
- (void)reloadDisassembly;
- (void)reloadBreakpoints;
- (void)toggleBreakpointAtAddress:(uint16_t)address;
- (void)updateCurrentBankContext;
- (void)reloadRegistersLive:(bool)live;
- (GBDisassemblyRow *)selectedInstructionRow;
@end

/* Suppress audio, windows and threads; retain real core/queue/synchronization. */
@interface TestDocument : Document
@property GBDebuggerWindowController *testDebugger;
@end

static void captureLog(GB_gameboy_t *gb, const char *text, GB_log_attributes_t attributes)
{
    Document *document = (__bridge Document *)GB_get_user_data(gb);
    [[document valueForKey:@"capturedOutput"] appendString:@(text)];
}

@implementation TestDocument
- (instancetype)init
{
    if ((self = [super init])) {
        GB_init(self.gb, GB_MODEL_DMG_B);
        uint8_t rom[0x8000] = {0};
        GB_load_rom_from_buffer(self.gb, rom, sizeof(rom));
        GB_set_user_data(self.gb, (__bridge void *)self);
        GB_set_log_callback(self.gb, captureLog);
    }
    return self;
}
- (void)start { [self setValue:@YES forKey:@"running"]; }
- (void)stop { [self setValue:@NO forKey:@"running"]; }
- (void)log:(const char *)text {}
- (void)updateSideView { [self.testDebugger cleanUpRunToBreakpoint]; }
@end

/* Pause the input callback at a controlled point before consuming continue. */
@interface ThreadedDocument : TestDocument
@property dispatch_semaphore_t ready;
@property dispatch_semaphore_t resumeInput;
@property dispatch_semaphore_t finished;
- (void)readCommand;
@end
@implementation ThreadedDocument
- (void)updateSideView
{
    dispatch_semaphore_signal(self.ready);
    dispatch_semaphore_wait(self.resumeInput, DISPATCH_TIME_FOREVER);
}
- (void)readCommand
{
    @autoreleasepool {
        char *command = [self getDebuggerInput];
        GB_debugger_execute_command(self.gb, command);
        free(command);
        dispatch_semaphore_signal(self.finished);
    }
}
@end

@interface TestDebugger : GBDebuggerWindowController
@end
@implementation TestDebugger
- (GBDisassemblyRow *)selectedInstructionRow
{
    GBDisassemblyRow *row = [GBDisassemblyRow new];
    row.address = 0xc010;
    return row;
}
@end

/* Exercise the real refresh without constructing AppKit windows. */
@interface VisibleTestWindow : NSObject
- (BOOL)isVisible;
@end
@implementation VisibleTestWindow
- (BOOL)isVisible { return YES; }
@end

@interface RefreshTestDebugger : TestDebugger
@property ThreadedDocument *threadedDocument;
@property bool resumedEarly;
@end
@implementation RefreshTestDebugger
- (void)updateFonts {}
- (void)reloadDataPanes {}
- (void)updateRunningState {}
- (void)reloadRegistersLive:(bool)live
{
    dispatch_semaphore_signal(self.threadedDocument.resumeInput);
    self.resumedEarly = dispatch_semaphore_wait(self.threadedDocument.finished,
                           dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10)) == 0;
    expectTrue(!self.resumedEarly && GB_debugger_is_stopped(self.threadedDocument.gb),
               "stopped refresh excludes continue throughout core data acquisition");
    if (!self.resumedEarly) [super reloadRegistersLive:live];
}
@end

static void timeoutHandler(int signalNumber)
{
    const char message[] = "FAIL: debugger synchronization timed out\n";
    write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(1);
}

static void consumeCommand(TestDocument *document, NSString *expected)
{
    char *command = [document getDebuggerInput];
    expectTrue(command && strcmp(command, expected.UTF8String) == 0,
               "debugger commands execute in submission order");
    GB_debugger_execute_command(document.gb, command);
    free(command);
}

static void checkRunToCursor(bool parked, bool conditional)
{
    TestDocument *document = [TestDocument new];
    TestDebugger *debugger = [TestDebugger new];
    [debugger setValue:document forKey:@"document"];
    document.testDebugger = debugger;
    if (parked) {
        [document start];
        GB_debugger_break(document.gb);
        [document setValue:@YES forKey:@"inSyncInput"];
    }
    if (conditional) {
        char command[] = "breakpoint $c010 if 0";
        GB_debugger_execute_command(document.gb, command);
        [debugger reloadBreakpoints];
    }
    [debugger runToCursor:nil];
    [document setValue:@YES forKey:@"inSyncInput"]; // The initial prompt is now parked
    NSString *armed = [document captureOutputForBlock:^{
        char command[] = "list";
        GB_debugger_execute_command(document.gb, command);
    }];
    expectTrue([armed rangeOfString:conditional? @"2 breakpoint(s)" : @"1 breakpoint(s)"].location != NSNotFound,
               "Run to Cursor installs a separate breakpoint before continuing");
    consumeCommand(document, @"continue");
    expectTrue([debugger valueForKey:@"runToState"] != nil,
               "temporary breakpoint survives the prompts before continue");
    GB_debugger_break(document.gb);
    [document setValue:@YES forKey:@"inSyncInput"];
    [debugger cleanUpRunToBreakpoint];
    expectTrue([debugger valueForKey:@"runToState"] == nil,
               "temporary breakpoint is cleaned up on the next stop");
    NSString *listing = [document captureOutputForBlock:^{
        char command[] = "list";
        GB_debugger_execute_command(document.gb, command);
    }];
    expectTrue((listing && [listing rangeOfString:conditional? @"1 breakpoint(s)" : @"No breakpoints set"].location != NSNotFound),
               "cleanup removes only the temporary breakpoint from the core");
    if (conditional) {
        expectTrue([listing rangeOfString:@"Condition: 0"].location != NSNotFound,
                   "the user's breakpoint condition survives Run to Cursor");
    }
}

static void checkConcurrentContinue(bool linked)
{
    ThreadedDocument *document = [ThreadedDocument new];
    TestDocument *runner = linked? [TestDocument new] : document;
    if (linked) {
        [runner setValue:document forKey:@"slave"];
        [document setValue:runner forKey:@"master"];
    }
    document.ready = dispatch_semaphore_create(0);
    document.resumeInput = dispatch_semaphore_create(0);
    document.finished = dispatch_semaphore_create(0);
    GB_debugger_break(document.gb);
    [runner start];
    NSThread *thread = [[NSThread alloc] initWithTarget:document selector:@selector(readCommand) object:nil];
    [runner setValue:thread forKey:@"emulationThread"];
    [thread start];
    dispatch_semaphore_wait(document.ready, DISPATCH_TIME_FOREVER);
    [document queueDebuggerCommand:@"continue"];
    __block bool resumedEarly = false;
    [document performAtomicBlock:^{
        dispatch_semaphore_signal(document.resumeInput);
        resumedEarly = dispatch_semaphore_wait(document.finished,
                           dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10)) == 0;
        expectTrue(!resumedEarly && GB_debugger_is_stopped(document.gb),
                   "continue cannot resume the core during an atomic block");
    }];
    if (!resumedEarly) {
        expectTrue(dispatch_semaphore_wait(document.finished,
                       dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
                   "continue resumes after atomic access finishes");
    }
    expectTrue(!GB_debugger_is_stopped(document.gb), "the queued continue executes");
    if (linked) {
        [runner setValue:nil forKey:@"slave"];
        [document setValue:nil forKey:@"master"];
    }
}

static void checkConcurrentRefresh(void)
{
    ThreadedDocument *document = [ThreadedDocument new];
    document.ready = dispatch_semaphore_create(0);
    document.resumeInput = dispatch_semaphore_create(0);
    document.finished = dispatch_semaphore_create(0);
    [document start];
    GB_debugger_break(document.gb);
    NSThread *thread = [[NSThread alloc] initWithTarget:document selector:@selector(readCommand) object:nil];
    [document setValue:thread forKey:@"emulationThread"];
    [thread start];
    dispatch_semaphore_wait(document.ready, DISPATCH_TIME_FOREVER);
    [document queueDebuggerCommand:@"continue"];
    RefreshTestDebugger *debugger = [RefreshTestDebugger new];
    debugger.threadedDocument = document;
    [debugger setValue:document forKey:@"document"];
    [debugger setValue:[VisibleTestWindow new] forKey:@"window"];
    [debugger debuggerDidRefresh];
    if (!debugger.resumedEarly) {
        expectTrue(dispatch_semaphore_wait(document.finished,
                       dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
                   "continue completes once the stopped refresh releases core access");
    }
}

int main(void)
{
    signal(SIGALRM, timeoutHandler);
    alarm(30);
    @autoreleasepool {
        TestDocument *master = [TestDocument new];
        TestDocument *slave = [TestDocument new];
        [master setValue:slave forKey:@"slave"];
        [slave setValue:master forKey:@"master"];
        [master start];
        expectTrue(!master.isPaused && !slave.isPaused, "linked documents share running state");
        GB_debugger_break(slave.gb);
        [slave setValue:@YES forKey:@"inSyncInput"];
        expectTrue(master.isDebuggerParked && slave.isDebuggerParked,
                   "both documents see a parked linked debugger");
        __block unsigned calls = 0;
        [slave performAtomicBlock:^{
            calls++;
            [slave performAtomicBlock:^{ calls++; }];
        }];
        expectTrue(calls == 2, "slave stop drains forwarded blocks, including nested access");
        [master setValue:nil forKey:@"slave"];
        [slave setValue:nil forKey:@"master"];

        checkConcurrentRefresh();
        checkConcurrentContinue(false);
        checkConcurrentContinue(true);

        checkRunToCursor(false, false);
        checkRunToCursor(true, false);
        checkRunToCursor(false, true);
        checkRunToCursor(true, true);

        TestDocument *document = [TestDocument new];
        TestDebugger *debugger = [TestDebugger new];
        [debugger setValue:document forKey:@"document"];
        [debugger setValue:@0xc000 forKey:@"pc"];
        GB_write_memory(document.gb, 0xc000, 0x00);
        [debugger reloadDisassembly];
        GB_write_memory(document.gb, 0xc000, 0x76);
        [debugger reloadDisassembly];
        bool foundHalt = false;
        for (GBDisassemblyRow *row in [debugger valueForKey:@"disassemblyRows"]) {
            if (!row.isLabel && row.address == 0xc000) foundHalt = [row.text isEqualToString:@"HALT"];
        }
        expectTrue(foundHalt, "memory changes refresh disassembly even with unchanged PC and banks");

        uint8_t rom[0x10000] = {0};
        rom[0x147] = 1; // MBC1, four physical banks
        rom[0x148] = 1;
        GB_load_rom_from_buffer(document.gb, rom, sizeof(rom));
        GB_write_memory(document.gb, 0x2000, 5);
        uint16_t mappedBank;
        GB_get_direct_access(document.gb, GB_DIRECT_ACCESS_ROM, NULL, &mappedBank);
        expectTrue(mappedBank == 1, "bank 5 aliases physical bank 1");
        [debugger updateCurrentBankContext];
        GBDebuggerBankContext context;
        [[debugger valueForKey:@"currentBankContext"] getValue:&context];
        expectTrue(context.romBank == 5, "GUI uses the core debugger bank before size masking");
        expectTrue([GBDebuggerBreakpointCommandForAddress(0x4000, context)
                    isEqualToString:@"breakpoint $05:$4000"], "aliased ROM breakpoint uses bank 5");
        /* A bank switch while running must affect both adding and deleting. */
        [debugger reloadBreakpoints]; // Cache bank 5
        GB_write_memory(document.gb, 0x2000, 2);
        [document start];
        [debugger toggleBreakpointAtAddress:0x4000];
        [document stop];
        NSString *listing = [document captureOutputForBlock:^{
            char command[] = "list";
            GB_debugger_execute_command(document.gb, command);
        }];
        expectTrue([listing rangeOfString:@"$02:$4000"].location != NSNotFound,
                   "running breakpoint creation uses the current bank");
        GB_write_memory(document.gb, 0x2000, 1);
        [debugger reloadBreakpoints]; // Stale context no longer matches bank 2
        GB_write_memory(document.gb, 0x2000, 2);
        [document start];
        [debugger toggleBreakpointAtAddress:0x4000];
        [document stop];
        listing = [document captureOutputForBlock:^{
            char command[] = "list";
            GB_debugger_execute_command(document.gb, command);
        }];
        expectTrue([listing rangeOfString:@"No breakpoints set"].location != NSNotFound,
                   "running breakpoint deletion uses the current bank");
        GB_gameboy_t *cgb = GB_init(GB_alloc(), GB_MODEL_CGB_E);
        GB_write_memory(cgb, 0xff70, 3);
        context.wramBank = GB_debugger_bank_for_address(cgb, 0xd000);
        expectTrue(context.wramBank == 3, "CGB WRAM bank 3 is selected");
        expectTrue(GBDebuggerBreakpointMatchesAddress(0xf123,
                       GB_debugger_bank_for_address(cgb, 0xf123), 0xf123, context),
                   "GUI recognizes the core's bank-zero echo RAM breakpoint");
        GB_dealloc(cgb);
        alarm(0);
        return testConclusion("debugger integration");
    }
}
