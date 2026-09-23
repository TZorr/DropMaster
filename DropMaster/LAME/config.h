/*
 * config.h  --  hand-written for Audio Converter
 *
 * LAME 3.100 normally gets this file from `./configure`. We don't run
 * autoconf here: the app builds the ~20 libmp3lame/*.c files straight
 * into the target, so this file states by hand the handful of facts
 * configure would have probed on an Apple-Silicon macOS / clang toolchain.
 *
 * Scope on purpose is minimal. We only ever *encode*, so:
 *   - HAVE_MPGLIB / HAVE_MPG123 are left undefined  -> mpglib_interface.c
 *     compiles to almost nothing and no mpglib/ sources are needed.
 *   - DECODE_ON_THE_FLY is left undefined           -> lame.c never calls
 *     hip_decode_init(), so the missing decoder is never referenced.
 *   - HAVE_XMMINTRIN_H is left undefined            -> the SSE paths in
 *     fft.c / quantize.c are skipped, so vector/xmm_quantize_sub.c and the
 *     i386 NASM files are not part of the build. Plain C on arm64.
 *
 * NOANALYSIS is defined: the GTK analyzer hooks are dead weight in a
 * library-only build and pull in lame-analysis plotting state.
 */

#ifndef LAME_CONFIG_H
#define LAME_CONFIG_H

/* ---- ANSI / POSIX headers that clang on macOS always has -------------- */
#define STDC_HEADERS 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_MEMORY_H 1
#define HAVE_LIMITS_H 1
#define HAVE_UNISTD_H 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIME_H 1

/* ---- libc functions ------------------------------------------------- */
#define HAVE_STRCHR 1
#define HAVE_MEMCPY 1
#define HAVE_STRTOL 1
#define HAVE_GETTIMEOFDAY 1

/* ---- fixed-width integer types come from <stdint.h> ----------------- */
/* Tell config.h.in-style fallbacks in this file to stay out of the way.  */
#define HAVE_INT8_T 1
#define HAVE_INT16_T 1
#define HAVE_INT32_T 1
#define HAVE_INT64_T 1
#define HAVE_UINT8_T 1
#define HAVE_UINT16_T 1
#define HAVE_UINT32_T 1
#define HAVE_UINT64_T 1

/* ---- floating-point types LAME wants named ------------------------- */
/* Not standard names, so provide them (matches config.h.in's fallback). */
#ifndef HAVE_IEEE754_FLOAT32_T
typedef float ieee754_float32_t;
#endif
#ifndef HAVE_IEEE754_FLOAT64_T
typedef double ieee754_float64_t;
#endif
#ifndef HAVE_IEEE854_FLOAT80_T
typedef long double ieee854_float80_t;
#endif

/* IEEE-754 storage layout is what takehiro.c's fast quantiser assumes;
 * arm64 doubles are little-endian IEEE-754, so the hack is valid here. */
#define TAKEHIRO_IEEE754_HACK 1

/* faster log2 approximation, precise to ~1e-6 -- fine for a psy model. */
#define USE_FAST_LOG 1

/* library build, no analyzer plotting hooks. */
#define LAME_LIBRARY_BUILD 1
#define NOANALYSIS 1

/* ---- package identification -------------------------------------- */
#define PACKAGE "lame"
#define VERSION "3.100"
#define PACKAGE_NAME "lame"
#define PACKAGE_STRING "lame 3.100"
#define PACKAGE_VERSION "3.100"
#define PACKAGE_BUGREPORT "lame-dev@lists.sourceforge.net"

/* ---- sizeof(), as measured on arm64 macOS ------------------------ */
#define SIZEOF_SHORT 2
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_LONG_LONG 8
#define SIZEOF_FLOAT 4
#define SIZEOF_DOUBLE 8
#define SIZEOF_LONG_DOUBLE 16
#define SIZEOF_UNSIGNED_SHORT 2
#define SIZEOF_UNSIGNED_INT 4
#define SIZEOF_UNSIGNED_LONG 8
#define SIZEOF_UNSIGNED_LONG_LONG 8

#endif /* LAME_CONFIG_H */
