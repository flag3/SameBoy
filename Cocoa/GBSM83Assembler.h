#import <Foundation/Foundation.h>

/* Resolves an operand expression (a symbol, register or debugger expression)
   to a value. Returns false if the expression cannot be evaluated. */
typedef bool (^GBSM83OperandEvaluator)(NSString *expression, uint16_t *value);

/* Assembles a single SM83 instruction written in the same syntax the
   disassembler prints (e.g. "LD a, $05", "JR nz, $0150", "BIT b, 0"), plus a
   few common aliases ("ADD a, b", "BIT 0, b", "LD hl, sp+$05"). `address` is
   where the instruction will live, used for relative jumps — JR takes the
   TARGET address, like the disassembly shows. Numbers are hexadecimal with an
   optional $ or 0x prefix; anything else is resolved through `evaluator`.
   Returns the encoded bytes, or nil with a message in `error`. */
NSData *GBSM83Assemble(NSString *instruction, uint16_t address, GBSM83OperandEvaluator evaluator, NSString **error);

/* Parses a bare 1-4 digit hex literal with an optional $ prefix ("4008",
   "$ff"). Returns false for anything else. */
bool GBSM83ParseHexLiteral(NSString *expression, uint16_t *value);

/* Parses compact or whitespace-separated hex bytes for direct byte editing
   ("3e05", "3e 05"). Returns nil with `error` set for malformed input. */
NSData *GBSM83ParseHexByteString(NSString *input, NSString **error);
