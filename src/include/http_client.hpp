#pragma once

#include "duckdb.hpp"
#include <string>
#include <map>

namespace duckdb {

struct HttpResponse {
	int status_code = 0;
	std::string body;
	std::string content_type;
	std::string retry_after;
	std::string server_date;  // Date header from server
	std::string etag;         // ETag header for conditional requests
	std::string last_modified; // Last-Modified header for conditional requests
	std::string error;
	int64_t content_length = -1;  // -1 if unknown
	bool success = false;
};

struct RetryConfig {
	int max_retries = 5;
	int initial_backoff_ms = 100;
	double backoff_multiplier = 2.0;
	int max_backoff_ms = 30000;
};

class HttpClient {
public:
	static HttpResponse Fetch(ClientContext &context, const std::string &url, const RetryConfig &config,
	                          const std::string &user_agent = "", bool compress = true,
	                          const std::string &if_none_match = "", const std::string &if_modified_since = "");
	static int ParseRetryAfter(const std::string &retry_after);

private:
	static HttpResponse ExecuteHttpGet(DatabaseInstance &db, const std::string &url,
	                                    const std::string &user_agent, bool compress,
	                                    const std::string &if_none_match, const std::string &if_modified_since);
	static bool IsRetryable(int status_code);
};

} // namespace duckdb
