# Refactoring Plan: Decoupling `crawler_function.cpp`

The primary challenge in extracting `CrawlWorker` and `sitemap_discovery` is that `crawler_function.cpp` (2,700+ lines) contains **everything**: data structures, thread queues, database helpers, and business logic.

To decouple this without getting tangled in circular dependencies, we need a **bottom-up extraction strategy**. We must peel off the layers that the Worker and Discovery logic depend on.

## Phase 1: Extract Shared Types & Utilities (The Foundation)

We cannot move `CrawlWorker` until the things it uses (like `DomainState` or `UrlQueueEntry`) are accessible from a header.

### 1. `src/include/crawler_types.hpp`
Move all simple data structures (PODs) and Enums here. This file should rely only on standard libraries.
- **Enums:** `CrawlErrorType`, `SiteInputType`
- **Structs:**
    - `DomainState` (and its helper `RobotsRules` if not already separated)
    - `UrlQueueEntry`
    - `BatchCrawlEntry`
    - `ParsedSiteInput`
    - `SitemapDiscoveryResult`

### 2. `src/include/crawler_utils.hpp` (and `src/crawler_utils.cpp`)
Move stateless helper functions here.
- `DecompressGzip`, `IsGzippedData`
- `GenerateSurtKey`, `GenerateDomainSurt`
- `GenerateContentHash`
- `ParseSiteInput`, `IsValidUrlOrHostname`
- `ParseAndValidateServerDate`
- `ClassifyError`, `ErrorTypeToString`

## Phase 2: Extract Core Infrastructure

Once types are available, we extract the "mechanisms" used for crawling.

### 3. `src/include/crawler_state.hpp`
Move the thread-safe containers here.
- **Classes:**
    - `ThreadSafeUrlQueue`
    - `ThreadSafeDomainMap` (this will now include `crawler_types.hpp`)

### 4. `src/include/crawler_db.hpp` (and `src/crawler_db.cpp`)
Move all DuckDB-specific helper functions here. This isolates the database dependency.
- `EnsureTargetTable`, `EnsureSitemapCacheTable`, `EnsureDiscoveryStatusTable`
- `FlushBatch`
- `GetCachedSitemapUrls`, `CacheSitemapUrls`
- `GetDiscoveryStatus`, `UpdateDiscoveryStatus`
- `IsUrlStale`

## Phase 3: The "Context Object" Pattern

One reason `CrawlWorker` is hard to extract is that it takes **13 arguments**. We should introduce a Context struct to bundle these dependencies.

### 5. Define `WorkerContext` in `crawler_types.hpp`
```cpp
struct WorkerContext {
    // References to shared state
    ThreadSafeUrlQueue& url_queue;
    ThreadSafeDomainMap& domain_states;
    
    // Configuration
    const CrawlIntoBindData& config;
    
    // Database connection (thread-local or shared)
    std::mutex& db_mutex;
    Connection& conn;
    
    // Global coordination
    std::atomic<int64_t>& rows_changed;
    std::atomic<int64_t>& processed_urls;
    std::atomic<bool>& should_stop;
    std::atomic<int>& in_flight;
};
```
This dramatically simplifies the `CrawlWorker` signature to `void CrawlWorker(int worker_id, WorkerContext& ctx)`.

## Phase 4: Extracting the Logic

Now that the dependencies are in headers (`types`, `utils`, `state`, `db`), we can move the complex logic into their own translation units.

### 6. `src/sitemap_discovery.cpp` (and `.hpp`)
- **Move:** `DiscoverSitemapUrlsThreadSafe`, `DiscoverSitemapUrls`
- **Dependencies:** Includes `crawler_types.hpp`, `crawler_utils.hpp`, `crawler_db.hpp`.

### 7. `src/crawler_worker.cpp` (and `.hpp`)
- **Move:** `CrawlWorker`, `ProcessSingleURL` (refactored helper)
- **Dependencies:** Includes `crawler_types.hpp`, `crawler_utils.hpp`, `crawler_state.hpp`, `crawler_db.hpp`.

## Phase 5: Cleanup `crawler_function.cpp`

The original file `src/crawler_function.cpp` will now only contain:
1.  The DuckDB binding hooks (`CrawlerBind`, `CrawlerInitGlobal`, etc.).
2.  The main entry points (`CrawlerFunction`, `CrawlIntoFunction`).
3.  The setup code that initializes the `WorkerContext` and launches threads.

## Summary of New File Structure

```text
src/
├── include/
│   ├── crawler_types.hpp       # Enums, Structs (DomainState, BatchEntry)
│   ├── crawler_utils.hpp       # Gzip, SurtKey, Parsers
│   ├── crawler_state.hpp       # ThreadSafeQueue, DomainMap
│   ├── crawler_db.hpp          # FlushBatch, CacheHelpers
│   ├── crawler_worker.hpp      # CrawlWorker declarations
│   └── sitemap_discovery.hpp   # Discovery declarations
├── crawler_utils.cpp           # Implementation of utils
├── crawler_db.cpp              # Implementation of DB helpers
├── crawler_worker.cpp          # Implementation of Worker
├── sitemap_discovery.cpp       # Implementation of Discovery
└── crawler_function.cpp        # Main entry point (now much smaller)
```
