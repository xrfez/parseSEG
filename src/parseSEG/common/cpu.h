/* parseSEG: what the C compiler targets, as constants Nim can read
   (common/endians.nim). Set by -march (e.g. -march=x86-64-v3 or native). */
#if defined(__AVX2__)
#  define PARSESEG_AVX2 1
#else
#  define PARSESEG_AVX2 0
#endif
