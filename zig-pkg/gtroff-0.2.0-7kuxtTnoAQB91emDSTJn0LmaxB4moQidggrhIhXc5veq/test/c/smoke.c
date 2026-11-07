/* Smoke test of the experimental C interface. */
#include <stdio.h>
#include <string.h>
#include "gtroff.h"

static int fails = 0;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static int contains(const uint8_t *s, size_t n, const char *needle) {
    size_t m = strlen(needle);
    for (size_t i = 0; i + m <= n; i++) if (memcmp(s + i, needle, m) == 0) return 1;
    return 0;
}

int main(void) {
    const char *page = ".TH LS 1\n.SH NAME\nls \\- list \\fBdirectory\\fR contents\n.TP\n.B \\-a\nall\n";
    uint8_t *out = NULL; size_t n = 0;

    CHECK(gtroff_man_to_text((const uint8_t *)page, strlen(page), 60, 0, &out, &n) == GTROFF_OK);
    CHECK(contains(out, n, "ls - list **directory** contents"));
    CHECK(contains(out, n, "**-a**\n    all"));
    gtroff_free_string(out, n);

    CHECK(gtroff_man_to_html((const uint8_t *)page, strlen(page), &out, &n) == GTROFF_OK);
    CHECK(contains(out, n, "<dl>"));
    CHECK(contains(out, n, "<strong>directory</strong>"));
    gtroff_free_string(out, n);

    const char *mdoc = ".Dd today\n.Dt LS 1\n.Os\n.Sh NAME\n.Nm ls\n.Nd list files\n";
    CHECK(gtroff_mdoc_to_text((const uint8_t *)mdoc, strlen(mdoc), 60, 0, &out, &n) == GTROFF_OK);
    CHECK(contains(out, n, "**ls** \xe2\x80\x94 list files"));
    gtroff_free_string(out, n);
    CHECK(gtroff_mdoc_to_html((const uint8_t *)mdoc, strlen(mdoc), &out, &n) == GTROFF_OK);
    CHECK(contains(out, n, "<strong>ls</strong>"));
    gtroff_free_string(out, n);

    CHECK(gtroff_man_to_text(NULL, 0, 0, 0, &out, &n) == GTROFF_OK);
    gtroff_free_string(out, n);
    CHECK(gtroff_man_to_text(NULL, 3, 0, 0, &out, &n) == GTROFF_ERR_INVALID_ARGUMENT);
    CHECK(out == NULL && n == 0);
    CHECK(gtroff_man_to_text((const uint8_t *)"x", 1, 0, 0, NULL, &n) == GTROFF_ERR_INVALID_ARGUMENT);
    gtroff_free_string(NULL, 0);
    CHECK(strcmp(gtroff_version(), "0.2.0") == 0);
    if (fails == 0) printf("c api ok\n");
    return fails ? 1 : 0;
}
