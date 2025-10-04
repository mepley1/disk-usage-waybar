# Contributing

Pull requests are always welcome. You probably want to file an issue first, to avoid duplicating work etc.

## Guidelines

Some minimal guidelines for contributing. These may be loosely followed - any code is better than no code.

- Follow [Tiger Style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md) as closely as possible.
- All functions should include a doc comment.
- Code comments are fine, I'm not a comment hater. But if the comment could be replaced with an assertion, do so. Which leads me to my next guideline...
- There is no such thing as too many assertions.
    - If a value will always fall within a smaller subrange of its type's possible values, assert it. (or use an enum if practical)
        - i.e. if an integer `i` will always be greater than 5, then `assert(i > 5)` as early as possible, or before operating on it.
- All allocations should be explicitly freed, even if using arenas. Call `free`/`destroy` even if it is a no-op.
    - Should be able to substitute any random allocator and still run.
    - If not practical, and arena is the only way to go, the function signature/doc-comment should reflect that. For example, see `std.json.parseFromSliceLeaky` and other similar `Leaky` methods in std.
- Ensure you own any necessary rights to the code. 
    - **Vibe coding/raw LLM output is strictly disallowed**; it is physically impossible for an LLM to output anything that is *not* a *derivative work* of every piece of data in its "training" set. Currently, there exist no known publicly-available LLMs that are "trained" exclusively on public-domain/permissively-licensed data; as such, it cannot be inferred that you own the proper license to anything an LLM outputs. Please keep this in mind.
