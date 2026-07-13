/* Self-checks for graphical debugger support helpers. Run with `make debugger-support-test`. */
#import "test_common.h"
#import "../Cocoa/GBDebuggerSupport.h"

static void expectFalse(bool condition, const char *message)
{
    expectTrue(!condition, message);
}

static void expectEqualUnsigned(unsigned actual, unsigned expected, const char *message)
{
    if (actual != expected) {
        fprintf(stderr, "FAIL: %s: got $%x, expected $%x\n", message, actual, expected);
        failures++;
    }
}

static void expectEqualString(NSString *actual, NSString *expected, const char *message)
{
    if (![actual isEqualToString:expected]) {
        fprintf(stderr, "FAIL: %s: got %s, expected %s\n",
                message, actual.UTF8String, expected.UTF8String);
        failures++;
    }
}

int main(void)
{
    @autoreleasepool {
        GBDebuggerBankContext context = {.rom0Bank = 0x01, .romBank = 0x02, .wramBank = 0x03};

        expectEqualUnsigned(GBDebuggerBankForAddress(0x0150, context), 0x01,
                            "ROM0 addresses use the current ROM0 bank");
        expectEqualUnsigned(GBDebuggerBankForAddress(0x4000, context), 0x02,
                            "switchable ROM addresses use the current ROM bank");
        expectEqualUnsigned(GBDebuggerBankForAddress(0xd123, context), 0x03,
                            "switchable WRAM addresses use the current WRAM bank");
        expectEqualUnsigned(GBDebuggerBankForAddress(0xc000, context), 0x00,
                            "fixed RAM addresses use bank zero");
        expectEqualUnsigned(GBDebuggerBankForAddress(0xe123, context), 0x00,
                            "echo RAM of fixed WRAM uses bank zero");
        expectEqualUnsigned(GBDebuggerBankForAddress(0xf123, context), 0x03,
                            "echo RAM of banked WRAM uses the current WRAM bank");
        expectEqualUnsigned(GBDebuggerBankForAddress(0xff40, context), 0x00,
                            "I/O addresses use bank zero");

        expectTrue(GBDebuggerBreakpointMatchesAddress(0x4000, GBDebuggerAnyBank, 0x4000, context),
                   "bankless breakpoints match the current address");
        expectTrue(GBDebuggerBreakpointMatchesAddress(0x4000, 0x02, 0x4000, context),
                   "banked breakpoints match their current bank");
        expectFalse(GBDebuggerBreakpointMatchesAddress(0x4000, 0x03, 0x4000, context),
                    "banked breakpoints do not match the same address in another bank");
        expectFalse(GBDebuggerBreakpointMatchesAddress(0x4001, GBDebuggerAnyBank, 0x4000, context),
                    "breakpoints do not match a different address");

        expectEqualUnsigned(GBDebuggerBankForNewBreakpointAtAddress(0x4000, context), 0x02,
                            "new ROM breakpoints are scoped to the visible bank");
        expectEqualUnsigned(GBDebuggerBankForNewBreakpointAtAddress(0xc000, context), GBDebuggerAnyBank,
                            "new non-ROM breakpoints stay bankless");
        expectEqualString(GBDebuggerBreakpointCommandForAddress(0x4000, context),
                          @"breakpoint $02:$4000",
                          "ROM breakpoint commands include the visible bank");
        expectEqualString(GBDebuggerBreakpointCommandForAddress(0xc000, context),
                          @"breakpoint $c000",
                          "non-ROM breakpoint commands remain bankless");

        NSArray<GBDisassemblyRow *> *rows = GBDebuggerParseDisassembly(
            @"->0150 <+000>: LD A, $01\n"
            @"    0152: NOP\n"
            @"Main:\n"
            @"    0153: RET\n"
            @"not a disassembly line\n");
        expectEqualUnsigned((unsigned)rows.count, 4,
                            "unparseable lines produce no rows");
        expectEqualUnsigned(rows[0].address, 0x0150,
                            "the marked current instruction parses its address");
        expectEqualString(rows[0].text, @"LD A, $01",
                          "the marked current instruction parses its text");
        expectFalse(rows[0].isLabel, "instruction rows are not labels");
        expectEqualUnsigned(rows[1].address, 0x0152,
                            "plain instruction lines parse their address");
        expectEqualString(rows[1].text, @"NOP",
                          "plain instruction lines parse their text");
        expectTrue(rows[2].isLabel, "symbol lines become label rows");
        expectEqualString(rows[2].text, @"Main:", "label rows keep the full line");
        expectEqualUnsigned(rows[3].address, 0x0153,
                            "parsing continues after a label");
        expectEqualUnsigned((unsigned)GBDebuggerParseDisassembly(nil).count, 0,
                            "nil output parses to no rows");

        return testConclusion("debugger support");
    }
}
