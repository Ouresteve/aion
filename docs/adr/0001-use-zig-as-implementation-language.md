# ADR-0001: Use Zig as the Implementation Language

**Date:** 2026-10-30  
**Status:** Accepted  
**Deciders:** Project maintainers

## Context

Aion requires a systems programming language that provides:

- Fine-grained control over memory and performance
- Predictable execution suitable for a high-throughput settlement engine
- Strong support for explicit error handling
- Ability to avoid garbage-collection pauses
- Good support for low-level networking and cryptography
- A modern language that is still relatively simple to reason about

The project also values long-term maintainability and the ability to produce reproducible benchmarks.

## Decision

Aion will be implemented primarily in **Zig**.

Zig is chosen because it offers:

- Manual memory management without a garbage collector
- Explicit error handling via error unions
- Excellent cross-compilation
- Direct access to the machine while still providing useful safety features
- A standard library that includes solid cryptographic primitives (Ed25519, etc.)
- A build system that is integrated and relatively straightforward

## Consequences

### Positive
- Full control over allocations and hot-path performance
- No garbage-collection pauses in the settlement path
- Ability to write zero-cost abstractions where needed
- Strong alignment with the project’s performance and predictability goals

### Negative
- Smaller ecosystem compared to Rust or Go
- Fewer high-level libraries available
- Team must be comfortable with lower-level systems programming
- Learning curve for contributors who are not familiar with Zig

### Neutral
- The language is still evolving (currently targeting Zig 0.17+)
- Some APIs in the standard library may change between minor versions

## Alternatives Considered

- **Rust** — Excellent safety and performance, but heavier compile times, more complex language model, and a stronger emphasis on abstractions that can sometimes obscure the hot path.
- **C / C++** — Maximum control, but significantly higher risk of memory safety issues and weaker modern tooling for error handling.
- **Go** — Simple and productive, but garbage collection makes it less suitable for the strict latency and allocation goals of the settlement engine.
- **Nim / Odin / other systems languages** — Smaller communities and less mature ecosystems for cryptographic and networking work at this time.

## References

- Zig language documentation
- Project vision document (Core Engineering Principles)