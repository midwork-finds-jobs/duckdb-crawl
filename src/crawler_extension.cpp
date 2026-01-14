#define DUCKDB_EXTENSION_MAIN

#include "crawler_extension.hpp"
#include "crawler_function.hpp"
#include "duckdb.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/main/connection.hpp"
#include "duckdb/main/config.hpp"

namespace duckdb {

static void LoadInternal(ExtensionLoader &loader) {
	auto &db = loader.GetDatabaseInstance();
	auto &config = DBConfig::GetConfig(db);

	// Register crawler_user_agent setting
	config.AddExtensionOption("crawler_user_agent",
	                          "User agent string for crawler HTTP requests",
	                          LogicalType::VARCHAR,
	                          Value("DuckDB-Crawler/1.0"));

	// Register crawler_default_delay setting
	config.AddExtensionOption("crawler_default_delay",
	                          "Default crawl delay in seconds if not in robots.txt",
	                          LogicalType::DOUBLE,
	                          Value(1.0));

	Connection conn(db);

	// Install and load http_request from community
	auto install_result = conn.Query("INSTALL http_request FROM community");
	if (install_result->HasError()) {
		throw IOException("Crawler extension requires http_request extension. Failed to install: " +
		                  install_result->GetError());
	}

	auto load_result = conn.Query("LOAD http_request");
	if (load_result->HasError()) {
		throw IOException("Crawler extension requires http_request extension. Failed to load: " +
		                  load_result->GetError());
	}

	// Register crawl_urls() table function
	RegisterCrawlerFunction(loader);
}

void CrawlerExtension::Load(ExtensionLoader &loader) {
	LoadInternal(loader);
}

std::string CrawlerExtension::Name() {
	return "crawler";
}

std::string CrawlerExtension::Version() const {
#ifdef EXT_VERSION_CRAWLER
	return EXT_VERSION_CRAWLER;
#else
	return "";
#endif
}

} // namespace duckdb

extern "C" {

DUCKDB_CPP_EXTENSION_ENTRY(crawler, loader) {
	duckdb::LoadInternal(loader);
}
}
