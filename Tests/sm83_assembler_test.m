/* Self-check for GBSM83Assemble. Run with `make sm83-assembler-test`. */
#import "test_common.h"
#import "../Cocoa/GBSM83Assembler.h"

static void expectBytes(NSString *text, uint16_t address, GBSM83OperandEvaluator evaluator,
                        const uint8_t *expected, unsigned length)
{
    NSString *error = nil;
    NSData *bytes = GBSM83Assemble(text, address, evaluator, &error);
    NSData *expectedData = [NSData dataWithBytes:expected length:length];
    if (![bytes isEqualToData:expectedData]) {
        fprintf(stderr, "FAIL: \"%s\" @ $%04x: got %s (%s), expected %s\n",
                text.UTF8String, address,
                bytes.description.UTF8String ?: "nil", error.UTF8String ?: "-",
                expectedData.description.UTF8String);
        failures++;
    }
}

static void expectError(NSString *text, uint16_t address, GBSM83OperandEvaluator evaluator)
{
    NSData *bytes = GBSM83Assemble(text, address, evaluator, NULL);
    if (bytes) {
        fprintf(stderr, "FAIL: \"%s\" @ $%04x: expected an error, got %s\n",
                text.UTF8String, address, bytes.description.UTF8String);
        failures++;
    }
}

static void expectHexBytes(NSString *text, const uint8_t *expected, unsigned length)
{
    NSString *error = nil;
    NSData *bytes = GBSM83ParseHexByteString(text, &error);
    NSData *expectedData = [NSData dataWithBytes:expected length:length];
    if (![bytes isEqualToData:expectedData]) {
        fprintf(stderr, "FAIL: hex bytes \"%s\": got %s (%s), expected %s\n",
                text.UTF8String,
                bytes.description.UTF8String ?: "nil", error.UTF8String ?: "-",
                expectedData.description.UTF8String);
        failures++;
    }
}

static void expectHexByteError(NSString *text)
{
    NSData *bytes = GBSM83ParseHexByteString(text, NULL);
    if (bytes) {
        fprintf(stderr, "FAIL: hex bytes \"%s\": expected an error, got %s\n",
                text.UTF8String, bytes.description.UTF8String);
        failures++;
    }
}

#define EXPECT(text, address, ...) do { \
    const uint8_t expected[] = {__VA_ARGS__}; \
    expectBytes(@text, address, NULL, expected, sizeof(expected)); \
} while (0)

#define EXPECT_HEX_BYTES(text, ...) do { \
    const uint8_t expected[] = {__VA_ARGS__}; \
    expectHexBytes(@text, expected, sizeof(expected)); \
} while (0)

int main(void)
{
    @autoreleasepool {
        /* Literals */
        EXPECT("nop", 0, 0x00);
        EXPECT("LD A, B", 0, 0x78);
        EXPECT("ld [hl+], a", 0, 0x22);
        EXPECT("ldi [hl], a", 0, 0x22);
        EXPECT("push af", 0, 0xF5);
        EXPECT("pop bc", 0, 0xC1);
        EXPECT("jp hl", 0, 0xE9);
        EXPECT("add a, b", 0, 0x80);
        EXPECT("add b", 0, 0x80);
        EXPECT("rst $08", 0, 0xCF);
        EXPECT("rst 8", 0, 0xCF);
        EXPECT("stop", 0, 0x10, 0x00);

        /* CB-prefixed, both operand orders for bit ops */
        EXPECT("swap a", 0, 0xCB, 0x37);
        EXPECT("bit 7, h", 0, 0xCB, 0x7C);
        EXPECT("bit h, 7", 0, 0xCB, 0x7C);
        EXPECT("res 0, [hl]", 0, 0xCB, 0x86);

        /* Immediate operands */
        EXPECT("ld a, $05", 0, 0x3E, 0x05);
        EXPECT("cp $90", 0, 0xFE, 0x90);
        EXPECT("cp a, $90", 0, 0xFE, 0x90);
        EXPECT("ld hl, $8000", 0, 0x21, 0x00, 0x80);
        EXPECT("jp $0100", 0, 0xC3, 0x00, 0x01);
        EXPECT("call z, $1234", 0, 0xCC, 0x34, 0x12);
        EXPECT("ld [$c000], sp", 0, 0x08, 0x00, 0xC0);
        EXPECT("ld [$1234], a", 0, 0xEA, 0x34, 0x12);
        EXPECT(".byte $ff", 0, 0xFF);

        /* LDH, and LD to the high page taking the long form */
        EXPECT("ldh [$ff40], a", 0, 0xE0, 0x40);
        EXPECT("ldh [$40], a", 0, 0xE0, 0x40);
        EXPECT("ldh a, [$ff00]", 0, 0xF0, 0x00);
        EXPECT("ld [$ff40], a", 0, 0xEA, 0x40, 0xFF);

        /* Relative jumps take the target address */
        EXPECT("jr $0152", 0x0150, 0x18, 0x00);
        EXPECT("jr nz, $0150", 0x0150, 0x20, 0xFE);

        /* Signed 8-bit operands and the sp-$xx alias */
        EXPECT("add sp, -$02", 0, 0xE8, 0xFE);
        EXPECT("ld hl, sp+$03", 0, 0xF8, 0x03);
        EXPECT("ld hl, sp-$01", 0, 0xF8, 0xFF);

        /* Symbols resolve through the evaluator */
        GBSM83OperandEvaluator evaluator = ^bool(NSString *expression, uint16_t *value) {
            if ([expression isEqualToString:@"MySym"]) {
                *value = 0x1234;
                return true;
            }
            return false;
        };
        const uint8_t jpSym[] = {0xC3, 0x34, 0x12};
        expectBytes(@"jp MySym", 0, evaluator, jpSym, sizeof(jpSym));

        /* Errors */
        expectError(@"frob", 0, NULL);
        expectError(@"", 0, NULL);
        expectError(@"ld a, $100", 0, NULL);
        expectError(@"ldh [$8000], a", 0, NULL);
        expectError(@"jr $8000", 0x0150, NULL);

        /* Register names must not be accepted as numeric operands, even when
           the evaluator could resolve them */
        GBSM83OperandEvaluator registerEvaluator = ^bool(NSString *expression, uint16_t *value) {
            *value = 0xC000;
            return true;
        };
        expectError(@"ld [hl], sp", 0, registerEvaluator);
        expectError(@"jp c", 0, registerEvaluator);
        expectError(@"ld a, b, c", 0, registerEvaluator);

        /* Direct byte editing accepts only complete ASCII hex byte pairs. */
        EXPECT_HEX_BYTES("3e 05", 0x3E, 0x05);
        EXPECT_HEX_BYTES("3e05", 0x3E, 0x05);
        expectHexByteError(@"0g");
        expectHexByteError(@"-1");
        expectHexByteError(@"f");

        return testConclusion("SM83 assembler");
    }
}
