/* segGuard and Defects (task 13.4, R3-1): a Defect inside an export becomes
 * SEG_ERR_INTERNAL with its message, and later calls on the same thread (and
 * on others) still work. Built against tests/c/guard_lib.nim by
 * tests/tcapi.nim. Exits non-zero on the first failure. */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern void NimMain(void);
extern int32_t guard_defect(int64_t i);
extern int32_t guard_ok(int64_t *out);
extern int32_t guard_argument(void);
extern const char *guard_last_error(void);

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { \
    fprintf(stderr, "FAIL %s:%d: %s (last error: %s)\n", __FILE__, __LINE__, #cond, \
            guard_last_error()); failures++; } } while (0)

static void after_defect(void) {
    int64_t v = 0;
    CHECK(guard_defect(0) == 0);
    CHECK(guard_defect(5) == -6); /* SEG_ERR_INTERNAL */
    CHECK(strstr(guard_last_error(), "IndexDefect") != NULL);
    CHECK(guard_ok(&v) == 0 && v == 42);
    CHECK(guard_last_error()[0] == 0);
    CHECK(guard_argument() == -1 && strstr(guard_last_error(), "bad argument") != NULL);
    CHECK(guard_defect(-1) == -6);
    v = 0;
    CHECK(guard_ok(&v) == 0 && v == 42);
}

static void *thread_main(void *arg) {
    (void)arg;
    after_defect();
    return NULL;
}

int main(void) {
    NimMain();
    after_defect();
    pthread_t t;
    pthread_create(&t, NULL, thread_main, NULL);
    pthread_join(t, NULL);
    int64_t v = 0;
    CHECK(guard_ok(&v) == 0 && v == 42);
    if (failures) fprintf(stderr, "%d failure(s)\n", failures);
    else printf("guard_test: ok\n");
    return failures != 0;
}
