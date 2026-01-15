# Known Issues and Workarounds

## CPPHTTPLIB_HEADER_MAX_LENGTH too small

**Issue**: DuckDB's httplib has a default header max length that can cause issues with some sites (e.g., lidl.fi). See https://github.com/duckdb/duckdb/pull/20460

**Workaround**: For debug builds, define `CPPHTTPLIB_HEADER_MAX_LENGTH=16384` to increase the header buffer size.

**Status**: Awaiting upstream fix in DuckDB.

## "Unaligned fetch in validity and main column data for update" crash

**Issue**: Internal DuckDB error during UPDATE operations affecting column validity (NULL/non-NULL transitions).

**Cause**: DuckDB bug #16836 - during CHECKPOINT, validity changes weren't being properly synchronized with column data.

**Fix**: Fixed in DuckDB v1.2.2 (PR #16851). Current DuckDB v1.4.3 includes this fix.

**If you still see this error**:
1. Ensure you're using DuckDB v1.2.2 or later
2. The crash may be caused by the httplib header length issue above (connection failures during crawl)
3. Try reducing `max_parallel_per_domain` to 1
