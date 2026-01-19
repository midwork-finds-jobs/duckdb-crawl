#pragma once

#include "duckdb.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

namespace duckdb {

void RegisterCrawlingMergeFunction(ExtensionLoader &loader);

} // namespace duckdb
