#include "http_client.hpp"
#include "duckdb/main/connection.hpp"
#include "duckdb/common/string_util.hpp"
#include <thread>
#include <chrono>
#include <cmath>
#include <cstdlib>

namespace duckdb {

bool HttpClient::IsRetryable(int status_code) {
	// Network errors (connection failures)
	if (status_code <= 0) {
		return true;
	}
	// 429 is NOT auto-retryable here - crawler handles domain-level blocking
	// Server errors
	if (status_code >= 500 && status_code <= 504) {
		return true;
	}
	return false;
}

int HttpClient::ParseRetryAfter(const std::string &retry_after) {
	if (retry_after.empty()) {
		return 0;
	}

	// Try to parse as integer (seconds)
	try {
		int seconds = std::stoi(retry_after);
		return seconds * 1000; // Convert to milliseconds
	} catch (...) {
		// Could be HTTP-date format, but for simplicity we'll just return 0
		// and fall back to exponential backoff
		return 0;
	}
}

HttpResponse HttpClient::ExecuteHttpGet(DatabaseInstance &db, const std::string &url,
                                         const std::string &user_agent, bool compress,
                                         const std::string &if_none_match, const std::string &if_modified_since) {
	HttpResponse response;

	Connection conn(db);

	// Load http_request in this connection
	auto load_result = conn.Query("LOAD http_request");
	if (load_result->HasError()) {
		response.error = "Failed to load http_request: " + load_result->GetError();
		return response;
	}

	// Escape URL for SQL
	std::string escaped_url = StringUtil::Replace(url, "'", "''");

	// Build headers map
	std::string headers_map = "{";
	bool first_header = true;

	if (!user_agent.empty()) {
		std::string escaped_ua = StringUtil::Replace(user_agent, "'", "''");
		headers_map += "'User-Agent': '" + escaped_ua + "'";
		first_header = false;
	}

	if (compress) {
		if (!first_header) headers_map += ", ";
		headers_map += "'Accept-Encoding': 'gzip, deflate'";
		first_header = false;
	}

	// Add conditional request headers
	if (!if_none_match.empty()) {
		if (!first_header) headers_map += ", ";
		std::string escaped_etag = StringUtil::Replace(if_none_match, "'", "''");
		headers_map += "'If-None-Match': '" + escaped_etag + "'";
		first_header = false;
	}

	if (!if_modified_since.empty()) {
		if (!first_header) headers_map += ", ";
		std::string escaped_lm = StringUtil::Replace(if_modified_since, "'", "''");
		headers_map += "'If-Modified-Since': '" + escaped_lm + "'";
		first_header = false;
	}

	headers_map += "}";

	// Build query - request headers to get Retry-After, Date, Content-Length, ETag, Last-Modified
	std::string query;
	if (headers_map != "{}") {
		query = StringUtil::Format(
		    "SELECT status, decode(body) AS body, "
		    "content_type, "
		    "headers['retry-after'] AS retry_after, "
		    "headers['Date'] AS server_date, "
		    "headers['content-length'] AS content_length, "
		    "headers['ETag'] AS etag, "
		    "headers['Last-Modified'] AS last_modified "
		    "FROM http_get('%s', headers := %s)",
		    escaped_url, headers_map);
	} else {
		query = StringUtil::Format(
		    "SELECT status, decode(body) AS body, "
		    "content_type, "
		    "headers['retry-after'] AS retry_after, "
		    "headers['Date'] AS server_date, "
		    "headers['content-length'] AS content_length, "
		    "headers['ETag'] AS etag, "
		    "headers['Last-Modified'] AS last_modified "
		    "FROM http_get('%s')",
		    escaped_url);
	}

	auto result = conn.Query(query);

	if (result->HasError()) {
		response.error = result->GetError();
		response.status_code = 0;
		return response;
	}

	auto chunk = result->Fetch();
	if (!chunk || chunk->size() == 0) {
		response.error = "No response from HTTP request";
		response.status_code = 0;
		return response;
	}

	// Get status code
	auto status_val = chunk->GetValue(0, 0);
	response.status_code = status_val.IsNull() ? 0 : status_val.GetValue<int>();

	// Get body
	auto body_val = chunk->GetValue(1, 0);
	response.body = body_val.IsNull() ? "" : body_val.GetValue<std::string>();

	// Get content-type
	auto ct_val = chunk->GetValue(2, 0);
	response.content_type = ct_val.IsNull() ? "" : ct_val.GetValue<std::string>();

	// Get retry-after
	auto ra_val = chunk->GetValue(3, 0);
	response.retry_after = ra_val.IsNull() ? "" : ra_val.GetValue<std::string>();

	// Get server date
	auto date_val = chunk->GetValue(4, 0);
	response.server_date = date_val.IsNull() ? "" : date_val.GetValue<std::string>();

	// Get content-length
	auto cl_val = chunk->GetValue(5, 0);
	if (!cl_val.IsNull()) {
		try {
			response.content_length = std::stoll(cl_val.GetValue<std::string>());
		} catch (...) {
			response.content_length = -1;
		}
	}

	// Get ETag
	auto etag_val = chunk->GetValue(6, 0);
	response.etag = etag_val.IsNull() ? "" : etag_val.GetValue<std::string>();

	// Get Last-Modified
	auto lm_val = chunk->GetValue(7, 0);
	response.last_modified = lm_val.IsNull() ? "" : lm_val.GetValue<std::string>();

	// 304 Not Modified is also considered success for conditional requests
	response.success = (response.status_code >= 200 && response.status_code < 300) || response.status_code == 304;
	return response;
}

HttpResponse HttpClient::Fetch(ClientContext &context, const std::string &url, const RetryConfig &config,
                               const std::string &user_agent, bool compress,
                               const std::string &if_none_match, const std::string &if_modified_since) {
	auto &db = DatabaseInstance::GetDatabase(context);

	// Single attempt - crawler handles all retries with Fibonacci backoff
	return ExecuteHttpGet(db, url, user_agent, compress, if_none_match, if_modified_since);
}

} // namespace duckdb
