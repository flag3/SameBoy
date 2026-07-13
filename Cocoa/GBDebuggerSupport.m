#import "GBDebuggerSupport.h"
#import <ctype.h>

const uint16_t GBDebuggerAnyBank = UINT16_MAX;

bool GBDebuggerBankContextEqual(GBDebuggerBankContext a, GBDebuggerBankContext b)
{
    return a.rom0Bank == b.rom0Bank &&
           a.romBank == b.romBank &&
           a.wramBank == b.wramBank;
}

uint16_t GBDebuggerBankForAddress(uint16_t address, GBDebuggerBankContext context)
{
    if (address < 0x4000) {
        return context.rom0Bank;
    }
    if (address < 0x8000) {
        return context.romBank;
    }
    if (address < 0xd000) {
        return 0;
    }
    if (address < 0xe000) {
        return context.wramBank;
    }
    if (address < 0xf000) {
        return 0; /* Echo RAM mirroring fixed WRAM */
    }
    if (address < 0xfe00) {
        return context.wramBank; /* Echo RAM mirroring banked WRAM */
    }
    return 0;
}

bool GBDebuggerBreakpointMatchesAddress(uint16_t breakpointAddress,
                                        uint16_t breakpointBank,
                                        uint16_t address,
                                        GBDebuggerBankContext context)
{
    if (breakpointAddress != address) {
        return false;
    }
    if (breakpointBank == GBDebuggerAnyBank) {
        return true;
    }
    return breakpointBank == GBDebuggerBankForAddress(address, context);
}

uint16_t GBDebuggerBankForNewBreakpointAtAddress(uint16_t address,
                                                 GBDebuggerBankContext context)
{
    if (address < 0x8000) {
        return GBDebuggerBankForAddress(address, context);
    }
    return GBDebuggerAnyBank;
}

NSString *GBDebuggerBreakpointCommandForAddress(uint16_t address,
                                                GBDebuggerBankContext context)
{
    uint16_t bank = GBDebuggerBankForNewBreakpointAtAddress(address, context);
    if (bank == GBDebuggerAnyBank) {
        return [NSString stringWithFormat:@"breakpoint $%04x", address];
    }
    return [NSString stringWithFormat:@"breakpoint $%02x:$%04x", bank, address];
}

@implementation GBDisassemblyRow
@end

NSMutableArray<GBDisassemblyRow *> *GBDebuggerParseDisassembly(NSString *output)
{
    NSMutableArray<GBDisassemblyRow *> *rows = [NSMutableArray array];
    if (!output) return rows;

    const char *cursor = output.UTF8String;
    while (*cursor) {
        const char *newline = strchr(cursor, '\n');
        const char *lineEnd = newline ?: cursor + strlen(cursor);
        size_t lineLength = lineEnd - cursor;
        if (lineLength) {
            const char *p = cursor;
            while (p < lineEnd && *p == ' ') {
                p++;
            }
            if (p + 1 < lineEnd && p[0] == '-' && p[1] == '>') {
                p += 2;
            }
            while (p < lineEnd && *p == ' ') {
                p++;
            }

            unsigned parsedAddress = 0;
            unsigned digits = 0;
            while (p + digits < lineEnd && digits < 4 && isxdigit((unsigned char)p[digits])) {
                char c = p[digits];
                parsedAddress = parsedAddress * 16 + (unsigned)(c <= '9'? c - '0' : tolower(c) - 'a' + 10);
                digits++;
            }
            const char *q = p + digits;
            bool parsed = false;
            if (digits == 4) {
                if (q + 1 < lineEnd && q[0] == ' ' && q[1] == '<') {
                    const char *close = memchr(q, '>', lineEnd - q);
                    if (close) {
                        q = close + 1;
                    }
                }
                if (q < lineEnd && *q == ':') {
                    q++;
                    if (q < lineEnd && *q == ' ') {
                        q++;
                    }
                    GBDisassemblyRow *row = [[GBDisassemblyRow alloc] init];
                    row.address = parsedAddress;
                    row.text = [[NSString alloc] initWithBytes:q length:lineEnd - q encoding:NSUTF8StringEncoding] ?: @"";
                    [rows addObject:row];
                    parsed = true;
                }
            }
            if (!parsed && lineEnd[-1] == ':') {
                GBDisassemblyRow *row = [[GBDisassemblyRow alloc] init];
                row.isLabel = true;
                row.text = [[NSString alloc] initWithBytes:cursor length:lineLength encoding:NSUTF8StringEncoding] ?: @"";
                [rows addObject:row];
            }
        }
        cursor = newline? newline + 1 : lineEnd;
    }
    return rows;
}
