/* Shared scaffolding for the headless Cocoa unit tests */
#import <Foundation/Foundation.h>

static unsigned failures = 0;

static inline void expectTrue(bool condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        failures++;
    }
}

/* Prints the verdict and returns the process exit code */
static inline int testConclusion(const char *what)
{
    if (failures) {
        fprintf(stderr, "%u failure(s)\n", failures);
        return 1;
    }
    printf("All %s checks passed\n", what);
    return 0;
}
