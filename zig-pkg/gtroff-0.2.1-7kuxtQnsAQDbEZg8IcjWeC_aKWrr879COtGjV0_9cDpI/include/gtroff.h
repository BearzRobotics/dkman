/*
 * gtroff-zig C interface.
 *
 * EXPERIMENTAL AND UNSTABLE: names, signatures and behaviour may change between
 * releases; there is no source or binary compatibility guarantee. The native Zig
 * module is the primary interface (see README.md).
 *
 * The functions read a man(7) or mdoc(7) page from memory and return the rendered result.
 * Returned strings are NOT NUL terminated; use the returned length and release
 * them with gtroff_free_string(ptr, len). No function keeps a pointer to caller
 * memory after it returns. All functions are thread-safe on independent inputs.
 */
#ifndef GTROFF_ZIG_H
#define GTROFF_ZIG_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GTROFF_OK 0
#define GTROFF_ERR_INVALID_ARGUMENT 1
#define GTROFF_ERR_OUT_OF_MEMORY 2

/* Library version, a static NUL terminated string. */
const char *gtroff_version(void);

/* Renders a man(7) page as text for a terminal. width 0 means do not wrap;
 * color nonzero adds ANSI styles. On error *out is NULL and *out_len is 0. */
int gtroff_man_to_text(const uint8_t *src, size_t len, size_t width, int color, uint8_t **out, size_t *out_len);

/* Renders a man(7) page as HTML. */
int gtroff_man_to_html(const uint8_t *src, size_t len, uint8_t **out, size_t *out_len);

/* The same for mdoc(7) pages. */
int gtroff_mdoc_to_text(const uint8_t *src, size_t len, size_t width, int color, uint8_t **out, size_t *out_len);
int gtroff_mdoc_to_html(const uint8_t *src, size_t len, uint8_t **out, size_t *out_len);

/* Releases a string returned by the functions above. NULL is allowed. */
void gtroff_free_string(uint8_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif
