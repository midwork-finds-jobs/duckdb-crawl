# Debugging & Profiling

This guide describes how to build the extension with debug information, enable profiling, and troubleshoot issues like hangs.

## 1. Build Types

Use the `Makefile` to build with different configurations.

### Debug Build (`make debug`)
Builds with `-O0 -g` and `CMAKE_BUILD_TYPE=Debug`. This provides full debug symbols and disables optimizations, making it ideal for stepping through code with a debugger.

```bash
make debug
```

The output extension will be in `build/debug/extension/crawler/crawler.duckdb_extension`.

### RelWithDebInfo Build (`make reldebug`)
Builds with `-O2 -g` (typically) and `CMAKE_BUILD_TYPE=RelWithDebInfo`. This is faster than a debug build but still has symbols. Use this if the debug build is too slow to reproduce the issue.

```bash
make reldebug
```

## 2. Enabling Profiling

DuckDB has a built-in profiler that can help identify slow queries or hangs.

### Enable Profiling in SQL
You can enable profiling for a session. The output will show the query execution plan and timing for each operator.

```sql
PRAGMA enable_profiling = 'query_tree'; -- 'query_tree' or 'json'
PRAGMA profiling_output = '/path/to/profile.json'; -- Optional: write to file
```

Example usage:

```sql
LOAD 'build/debug/extension/crawler/crawler.duckdb_extension';
PRAGMA enable_profiling;
SELECT * FROM duckdb_crawl('https://example.com');
```

## 3. Debugging Hangs on macOS

If the extension hangs, you can attach a debugger to inspect the current state.

### Using `lldb`

1.  **Start your DuckDB process** (e.g., the CLI or your application).
2.  **Find the process ID (PID)**:
    ```bash
    pgrep -l duckdb
    ```
3.  **Attach `lldb`**:
    ```bash
    lldb -p <PID>
    ```
4.  **Inspect**:
    Once attached, the process will pause.
    *   `bt`: Print backtrace of the current thread.
    *   `thread list`: List all threads.
    *   `thread backtrace all`: Print backtraces for all threads.
    *   `c`: Continue execution.

### Building with Sanitizers

Sanitizers can help detect memory errors and race conditions. You can pass extra flags to CMake via the `EXT_DEBUG_FLAGS` variable in the Makefile.

#### AddressSanitizer (ASan)
Detects memory corruption, buffer overflows, etc.

```bash
EXT_DEBUG_FLAGS="-fsanitize=address" make debug
```

#### ThreadSanitizer (TSan)
Detects data races. This is very useful for debugging hangs in multi-threaded code.

```bash
EXT_DEBUG_FLAGS="-fsanitize=thread" make debug
```

> [!NOTE]
> You cannot use ASan and TSan at the same time.

## 4. Common Issues

### Deadlocks
If you see threads waiting on locks in the backtrace (e.g., `std::mutex`, `std::condition_variable`), you might have a deadlock. TSan can often help identify the conflicting accesses.

### Infinite Loops
If the backtrace shows the code stuck in a specific loop or function repeatedly, check the termination conditions.
