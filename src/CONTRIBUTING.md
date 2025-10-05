# Contributing

Pull requests are always welcome. You probably want to file an issue first, to avoid duplicating work etc, and also in case I have anything pending that might break yours. 

## Guidelines

Some minimal guidelines for contributing. These may be loosely followed or totally ignored - any code is better than no code.

These are just personal preferences, not hard rules; reading them might help you to reason about my code. I won't turn down a PR just for not following them.

- Follow [Tiger Style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md) as closely as possible.
- All functions should include a doc comment.
- Code comments are fine, I'm not a comment hater. But if the comment could be replaced with an assertion, do so. Which leads me to my next guideline...
- There is no such thing as too many assertions. Feel free to spam them.
    - If a value will always fall within a smaller subrange of its type's possible values, assert it. (or use an enum if practical)
        - i.e. if an integer `i` will always be greater than 5, then `assert(i > 5)` as early as possible, or before operating on it.
- All allocations should be explicitly freed, even if using arenas. Call `free`/`destroy` even if it is a no-op.
    - Ideally, you should be able to substitute any random allocator and still run.
    - If not practical, and an arena is the only way to go, the function signature/doc-comment should reflect that. For example, see `std.json.parseFromSliceLeaky` and other similar `Leaky` methods in std. Also consider if a temp arena might be a good option.
