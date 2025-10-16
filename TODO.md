# TODO

- Feature: Options for potential additional output formats? For use with other bars if they support custom modules.

- Feature: Parse mount flags, include certain ones in tooltip if present
    - Options that you might want to check for i.e. `noexec`, `users`/`user_id=`/`group_id=`, `_netdev`, et al
    - Don't show in `.compact` mode

- Feature: Configurable update signal number
    - Allow to format as either `RTMIN + n` or explicit `n`
    - Assert between 32-64

- Issue: `statvfs()` may hang on network filesystems. Skip filesystem if `_netdev` mount flag found?

- Refactor: Use one of the existing arg parsing libs, so I can add more planned options.
