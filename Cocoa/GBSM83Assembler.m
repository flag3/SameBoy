#import "GBSM83Assembler.h"
#import <ctype.h>

/* Failure tail shared by every parse error: sets the out-parameter (when
   given) and bails. Expects an NSString ** named `error` in scope. */
#define fail(message) do { \
    if (error) { \
        *error = message; \
    } \
    return nil; \
} while (0)

/* Operand kinds for templates with a numeric operand */
typedef enum {
    GBOperandImm8,      // 8-bit immediate
    GBOperandImm8High,  // 8-bit immediate; also accepts $ffxx (LDH)
    GBOperandImm16,     // 16-bit immediate, little endian
    GBOperandRel8,      // Relative jump encoded from a target address
    GBOperandSign8,     // Signed 8-bit immediate (ADD SP / LD hl, sp)
    GBOperandSign8Negated, // Like Sign8, but negated (the "sp-$xx" alias)
} GBOperandKind;

@interface GBSM83Template : NSObject
@property NSString *prefix;
@property NSString *suffix;
@property GBOperandKind kind;
@property uint8_t opcode;
@property bool emitsOpcode; // false for .BYTE
@end

@implementation GBSM83Template
@end

static NSMutableDictionary<NSString *, NSData *> *literals;
static NSMutableArray<GBSM83Template *> *templates;

static void addLiteral(NSString *pattern, NSData *bytes)
{
    if (!literals[pattern]) {
        literals[pattern] = bytes;
    }
}

static void addLiteralOpcode(NSString *pattern, uint8_t opcode)
{
    addLiteral(pattern, [NSData dataWithBytes:&opcode length:1]);
}

static void addLiteralCB(NSString *pattern, uint8_t opcode)
{
    uint8_t bytes[] = {0xCB, opcode};
    addLiteral(pattern, [NSData dataWithBytes:bytes length:2]);
}

static void addTemplate(NSString *pattern, GBOperandKind kind, uint8_t opcode)
{
    /* `pattern` contains a single \x01 placeholder for the operand */
    NSArray<NSString *> *parts = [pattern componentsSeparatedByString:@"\x01"];
    GBSM83Template *entry = [[GBSM83Template alloc] init];
    entry.prefix = parts[0];
    entry.suffix = parts.count > 1? parts[1] : @"";
    entry.kind = kind;
    entry.opcode = opcode;
    entry.emitsOpcode = true;
    [templates addObject:entry];
}

static void buildTables(void)
{
    literals = [NSMutableDictionary dictionary];
    templates = [NSMutableArray array];

    static const char *registers8[] = {"b", "c", "d", "e", "h", "l", "[hl]", "a"};
    static const char *registers16[] = {"bc", "de", "hl", "sp"};
    static const char *stackRegisters[] = {"bc", "de", "hl", "af"};
    static const char *conditions[] = {"nz", "z", "nc", "c"};
    static const char *aluOps[] = {"add", "adc", "sub", "sbc", "and", "xor", "or", "cp"};
    static const char *shiftOps[] = {"rlc", "rrc", "rl", "rr", "sla", "sra", "swap", "srl"};
    static const char *bitOps[] = {"bit", "res", "set"};

    /* Single-byte instructions with no operands */
    static const struct {const char *pattern; uint8_t opcode;} singles[] = {
        {"nop", 0x00}, {"rlca", 0x07}, {"rrca", 0x0F}, {"rla", 0x17}, {"rra", 0x1F},
        {"daa", 0x27}, {"cpl", 0x2F}, {"scf", 0x37}, {"ccf", 0x3F}, {"halt", 0x76},
        {"ret", 0xC9}, {"reti", 0xD9}, {"di", 0xF3}, {"ei", 0xFB},
        {"jphl", 0xE9}, {"jp[hl]", 0xE9}, {"ldsp,hl", 0xF9},
        {"ld[bc],a", 0x02}, {"ld[de],a", 0x12}, {"lda,[bc]", 0x0A}, {"lda,[de]", 0x1A},
        {"ld[hli],a", 0x22}, {"ld[hld],a", 0x32}, {"lda,[hli]", 0x2A}, {"lda,[hld]", 0x3A},
        {"ld[hl+],a", 0x22}, {"ld[hl-],a", 0x32}, {"lda,[hl+]", 0x2A}, {"lda,[hl-]", 0x3A},
        {"ldi[hl],a", 0x22}, {"ldd[hl],a", 0x32}, {"ldia,[hl]", 0x2A}, {"ldda,[hl]", 0x3A},
        {"ldh[c],a", 0xE2}, {"ldha,[c]", 0xF2}, {"ld[c],a", 0xE2}, {"lda,[c]", 0xF2},
    };
    for (unsigned i = 0; i < sizeof(singles) / sizeof(singles[0]); i++) {
        addLiteralOpcode(@(singles[i].pattern), singles[i].opcode);
    }

    /* STOP is conventionally followed by a padding byte */
    static const uint8_t stopBytes[] = {0x10, 0x00};
    addLiteral(@"stop", [NSData dataWithBytes:stopBytes length:2]);

    for (unsigned i = 0; i < 4; i++) {
        NSString *rr = @(registers16[i]);
        addTemplate([NSString stringWithFormat:@"ld%@,\x01", rr], GBOperandImm16, 0x01 + i * 0x10);
        addLiteralOpcode([NSString stringWithFormat:@"inc%@", rr], 0x03 + i * 0x10);
        addLiteralOpcode([NSString stringWithFormat:@"dec%@", rr], 0x0B + i * 0x10);
        addLiteralOpcode([NSString stringWithFormat:@"addhl,%@", rr], 0x09 + i * 0x10);

        NSString *stackRR = @(stackRegisters[i]);
        addLiteralOpcode([NSString stringWithFormat:@"pop%@", stackRR], 0xC1 + i * 0x10);
        addLiteralOpcode([NSString stringWithFormat:@"push%@", stackRR], 0xC5 + i * 0x10);

        NSString *cc = @(conditions[i]);
        addLiteralOpcode([NSString stringWithFormat:@"ret%@", cc], 0xC0 + i * 8);
        addTemplate([NSString stringWithFormat:@"jr%@,\x01", cc], GBOperandRel8, 0x20 + i * 8);
        addTemplate([NSString stringWithFormat:@"jp%@,\x01", cc], GBOperandImm16, 0xC2 + i * 8);
        addTemplate([NSString stringWithFormat:@"call%@,\x01", cc], GBOperandImm16, 0xC4 + i * 8);
    }

    for (unsigned i = 0; i < 8; i++) {
        NSString *reg = @(registers8[i]);
        addLiteralOpcode([NSString stringWithFormat:@"inc%@", reg], 0x04 + i * 8);
        addLiteralOpcode([NSString stringWithFormat:@"dec%@", reg], 0x05 + i * 8);
        addTemplate([NSString stringWithFormat:@"ld%@,\x01", reg], GBOperandImm8, 0x06 + i * 8);

        /* LD r, r' */
        for (unsigned j = 0; j < 8; j++) {
            uint8_t opcode = 0x40 + i * 8 + j;
            if (opcode == 0x76) continue; // HALT
            addLiteralOpcode([NSString stringWithFormat:@"ld%@,%@", reg, @(registers8[j])], opcode);
        }

        /* ALU on registers — the disassembler omits the "a," destination;
           accept it as an alias too */
        for (unsigned op = 0; op < 8; op++) {
            uint8_t opcode = 0x80 + op * 8 + i;
            addLiteralOpcode([NSString stringWithFormat:@"%s%@", aluOps[op], reg], opcode);
            addLiteralOpcode([NSString stringWithFormat:@"%sa,%@", aluOps[op], reg], opcode);
        }

        /* CB-prefixed */
        for (unsigned op = 0; op < 8; op++) {
            addLiteralCB([NSString stringWithFormat:@"%s%@", shiftOps[op], reg], op * 8 + i);
        }
        for (unsigned op = 0; op < 3; op++) {
            for (unsigned bit = 0; bit < 8; bit++) {
                uint8_t opcode = 0x40 + op * 0x40 + bit * 8 + i;
                /* The disassembler prints the register first; accept the
                   conventional order as well */
                addLiteralCB([NSString stringWithFormat:@"%s%@,%u", bitOps[op], reg, bit], opcode);
                addLiteralCB([NSString stringWithFormat:@"%s%u,%@", bitOps[op], bit, reg], opcode);
            }
        }
    }

    /* ALU on immediates */
    for (unsigned op = 0; op < 8; op++) {
        addTemplate([NSString stringWithFormat:@"%s\x01", aluOps[op]], GBOperandImm8, 0xC6 + op * 8);
        addTemplate([NSString stringWithFormat:@"%sa,\x01", aluOps[op]], GBOperandImm8, 0xC6 + op * 8);
    }

    /* RST vectors */
    for (unsigned i = 0; i < 8; i++) {
        addLiteralOpcode([NSString stringWithFormat:@"rst$%02x", i * 8], 0xC7 + i * 8);
        addLiteralOpcode([NSString stringWithFormat:@"rst%02x", i * 8], 0xC7 + i * 8);
        addLiteralOpcode([NSString stringWithFormat:@"rst%x", i * 8], 0xC7 + i * 8);
    }

    addTemplate(@"ld[\x01],sp", GBOperandImm16, 0x08);
    addTemplate(@"jr\x01", GBOperandRel8, 0x18);
    addTemplate(@"jp\x01", GBOperandImm16, 0xC3);
    addTemplate(@"call\x01", GBOperandImm16, 0xCD);
    addTemplate(@"ldh[\x01],a", GBOperandImm8High, 0xE0);
    addTemplate(@"ldha,[\x01]", GBOperandImm8High, 0xF0);
    addTemplate(@"addsp,\x01", GBOperandSign8, 0xE8);
    addTemplate(@"ldhl,sp,\x01", GBOperandSign8, 0xF8);
    addTemplate(@"ldhl,sp+\x01", GBOperandSign8, 0xF8);
    addTemplate(@"ldhl,sp-\x01", GBOperandSign8Negated, 0xF8);
    addTemplate(@"ld[\x01],a", GBOperandImm16, 0xEA);
    addTemplate(@"lda,[\x01]", GBOperandImm16, 0xFA);

    /* Raw data */
    GBSM83Template *byteEntry = [[GBSM83Template alloc] init];
    byteEntry.prefix = @".byte";
    byteEntry.suffix = @"";
    byteEntry.kind = GBOperandImm8;
    byteEntry.emitsOpcode = false;
    [templates addObject:byteEntry];

    /* More specific patterns first */
    [templates sortUsingComparator:^NSComparisonResult(GBSM83Template *a, GBSM83Template *b) {
        NSUInteger lengthA = a.prefix.length + a.suffix.length;
        NSUInteger lengthB = b.prefix.length + b.suffix.length;
        if (lengthA == lengthB) return NSOrderedSame;
        return lengthA > lengthB? NSOrderedAscending : NSOrderedDescending;
    }];
}

/* Strips comments and whitespace, and maps parentheses to brackets, without
   changing character content otherwise (case is preserved so symbol operands
   survive). */
static NSString *canonicalize(NSString *input)
{
    NSString *output = [input componentsSeparatedByString:@";"][0];
    output = [[output componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] componentsJoinedByString:@""];
    output = [output stringByReplacingOccurrencesOfString:@"(" withString:@"["];
    return [output stringByReplacingOccurrencesOfString:@")" withString:@"]"];
}

/* Bare register names never make sense as numeric operands: without this
   guard, "ld [hl], sp" would silently assemble to LD [imm16],SP with hl's
   current value (via the evaluator), and "jp c" to JP $000c (via the hex
   parser). */
static bool isRegisterName(NSString *operand)
{
    static NSSet<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:@[@"a", @"f", @"b", @"c", @"d", @"e", @"h", @"l",
                                      @"af", @"bc", @"de", @"hl", @"sp", @"pc"]];
    });
    return [names containsObject:operand.lowercaseString];
}

bool GBSM83ParseHexLiteral(NSString *expression, uint16_t *value)
{
    NSString *hexPart = [expression hasPrefix:@"$"]? [expression substringFromIndex:1] : expression;
    if (hexPart.length < 1 || hexPart.length > 4) return false;
    for (NSUInteger i = 0; i < hexPart.length; i++) {
        if (!isxdigit((unsigned char)[hexPart characterAtIndex:i])) {
            return false;
        }
    }
    *value = (uint16_t)strtoul(hexPart.UTF8String, NULL, 16);
    return true;
}

static signed hexDigitValue(unichar digit)
{
    return digit <= 0x7F && isxdigit(digit)? digittoint(digit) : -1;
}

NSData *GBSM83ParseHexByteString(NSString *input, NSString **error)
{
    if (error) {
        *error = nil;
    }

    NSString *stripped = [[input componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] componentsJoinedByString:@""];
    if (!stripped.length || (stripped.length & 1)) {
        fail(@"Enter complete hex byte pairs, e.g. \"3e 05\"");
    }
    if (stripped.length > 32) {
        fail(@"Enter at most 16 bytes");
    }

    NSMutableData *bytes = [NSMutableData dataWithCapacity:stripped.length / 2];
    for (NSUInteger i = 0; i < stripped.length; i += 2) {
        signed high = hexDigitValue([stripped characterAtIndex:i]);
        signed low = hexDigitValue([stripped characterAtIndex:i + 1]);
        if (high < 0 || low < 0) {
            fail(@"Enter hex bytes using digits 0-9 and a-f");
        }
        uint8_t value = (uint8_t)((high << 4) | low);
        [bytes appendBytes:&value length:1];
    }
    return bytes;
}

/* Parses hexadecimal with an optional $ or 0x prefix; falls back to the
   evaluator for anything else. Hex wins: a symbol that reads as hex up to 4
   digits ("face") is taken as an address — write "face+0" to force symbol
   lookup. */
static bool parseOperand(NSString *expression, GBSM83OperandEvaluator evaluator, uint16_t *value)
{
    if (!expression.length) return false;
    if (isRegisterName(expression)) return false;
    NSString *stripped = expression;
    if ([stripped.lowercaseString hasPrefix:@"0x"]) {
        stripped = [stripped substringFromIndex:2];
    }
    if (GBSM83ParseHexLiteral(stripped, value)) return true;
    return evaluator && evaluator(expression, value);
}

NSData *GBSM83Assemble(NSString *instruction, uint16_t address, GBSM83OperandEvaluator evaluator, NSString **error)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        buildTables();
    });
    if (error) {
        *error = nil;
    }

    NSString *canonical = canonicalize(instruction);
    NSString *lowered = canonical.lowercaseString;
    if (!lowered.length) {
        fail(@"Empty instruction");
    }

    NSData *literal = literals[lowered];
    if (literal) return literal;

    for (GBSM83Template *entry in templates) {
        if (lowered.length <= entry.prefix.length + entry.suffix.length) continue;
        if (![lowered hasPrefix:entry.prefix]) continue;
        if (entry.suffix.length && ![lowered hasSuffix:entry.suffix]) continue;

        NSRange operandRange = NSMakeRange(entry.prefix.length,
                                           lowered.length - entry.prefix.length - entry.suffix.length);
        NSString *operand = [canonical substringWithRange:operandRange]; // Case preserved for symbols

        bool negated = false;
        if ((entry.kind == GBOperandSign8 || entry.kind == GBOperandSign8Negated) && [operand hasPrefix:@"-"]) {
            negated = true;
            operand = [operand substringFromIndex:1];
        }
        if (entry.kind == GBOperandSign8Negated) {
            negated = !negated;
        }

        uint16_t value = 0;
        if (!parseOperand(operand, evaluator, &value)) continue;

        uint8_t operandBytes[2];
        unsigned operandLength = 1;
        switch (entry.kind) {
            case GBOperandImm8:
                if (value > 0xFF) {
                    fail(@"Operand does not fit in 8 bits");
                }
                operandBytes[0] = value;
                break;
            case GBOperandImm8High:
                if (value > 0xFF && value < 0xFF00) {
                    fail(@"LDH operands must be in the $ff00-$ffff range");
                }
                operandBytes[0] = value & 0xFF;
                break;
            case GBOperandImm16:
                operandBytes[0] = value & 0xFF;
                operandBytes[1] = value >> 8;
                operandLength = 2;
                break;
            case GBOperandRel8: {
                int32_t offset = (int32_t)value - ((int32_t)address + 2);
                if (offset < -128 || offset > 127) {
                    fail(@"Jump target is out of range for JR");
                }
                operandBytes[0] = (uint8_t)offset;
                break;
            }
            case GBOperandSign8:
            case GBOperandSign8Negated: {
                if (negated) {
                    if (value < 1 || value > 128) {
                        fail(@"Operand does not fit in 8 bits");
                    }
                    operandBytes[0] = (uint8_t)(0x100 - value);
                }
                else {
                    if (value > 0xFF) {
                        fail(@"Operand does not fit in 8 bits");
                    }
                    operandBytes[0] = value & 0xFF;
                }
                break;
            }
        }

        NSMutableData *bytes = [NSMutableData data];
        if (entry.emitsOpcode) {
            /* All CB-prefixed instructions are literals; templates only ever
               emit single-byte opcodes. */
            uint8_t opcode = entry.opcode;
            [bytes appendBytes:&opcode length:1];
        }
        [bytes appendBytes:operandBytes length:operandLength];
        return bytes;
    }

    fail(@"Unrecognized instruction");
}
