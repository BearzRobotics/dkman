# 0002: Optional experimental C interface

Status: accepted by the maintainer in conversation.

## Decision

`src/capi.zig` and `include/gtroff.h` adapt the native module to C and are built
only by the `c-api` step and the C smoke test. The surface is two functions
that take a man(7) page in memory and return terminal text or HTML (strings are
not NUL terminated; the caller frees them with `gtroff_free_string`). The
interface is marked experimental: no source or binary compatibility is promised.
The `md.Node` tree is not exposed; C users who want it should use md-zig's C
interface once it exposes the tree.

## Consequences

- Native Zig consumers do not depend on or pay for the C layer.
- Allocation uses `std.heap.smp_allocator`; the C side needs no allocator.
