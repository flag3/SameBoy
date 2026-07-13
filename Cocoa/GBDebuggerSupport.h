#import <Foundation/Foundation.h>

extern const uint16_t GBDebuggerAnyBank;

typedef struct {
    uint16_t rom0Bank;
    uint16_t romBank;
    uint16_t wramBank;
} GBDebuggerBankContext;

bool GBDebuggerBankContextEqual(GBDebuggerBankContext a, GBDebuggerBankContext b);
uint16_t GBDebuggerBankForAddress(uint16_t address, GBDebuggerBankContext context);
bool GBDebuggerBreakpointMatchesAddress(uint16_t breakpointAddress,
                                        uint16_t breakpointBank,
                                        uint16_t address,
                                        GBDebuggerBankContext context);
uint16_t GBDebuggerBankForNewBreakpointAtAddress(uint16_t address,
                                                 GBDebuggerBankContext context);
NSString *GBDebuggerBreakpointCommandForAddress(uint16_t address,
                                                GBDebuggerBankContext context);

/* A row of the disassembly model: an instruction, a label, or a raw .BYTE
   padding row. */
@interface GBDisassemblyRow : NSObject
@property uint16_t address;
@property bool isLabel;
@property bool isPadding; // A raw .BYTE row filling the gap before a sweep anchor
@property unsigned instructionLength; // In bytes; 0 when unknown (trailing row of a sweep)
@property NSString *bytes;
@property NSString *text;
@end

/* Parses the text output of GB_cpu_disassemble into rows. Instruction lines
   look like "  ->0150 <+000>: LD A, $01" or "    0150: NOP"; symbol lines are
   "Name:". Leading whitespace may already be trimmed off the first line. */
NSMutableArray<GBDisassemblyRow *> *GBDebuggerParseDisassembly(NSString *output);
