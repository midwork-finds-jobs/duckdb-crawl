#include "crawler_function.hpp"
#include "robots_parser.hpp"
#include "http_client.hpp"
#include "duckdb/main/extension_util.hpp"
#include "duckdb/parser/parsed_data/create_table_function_info.hpp"
#include "duckdb/common/string_util.hpp"
#include "duckdb/main/connection.hpp"
#include "duckdb/main/client_context.hpp"

#include <atomic>
#include <csignal>
#include <chrono>
#include <thread>
#include <mutex>
#include <unordered_map>
#include <queue>

namespace duckdb {

// Global signal flag for graceful shutdown
static std::atomic<bool> g_shutdown_requested(false);
static std::atomic<int> g_sigint_count(0);
static std::chrono::steady_clock::time_point g_last_sigint_time;

// Signal handler
static void SignalHandler(int signum) {
	if (signum == SIGINT) {
		auto now = std::chrono::steady_clock::now();
		auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(now - g_last_sigint_time).count();

		g_sigint_count++;
		g_last_sigint_time = now;

		if (g_sigint_count >= 2 && elapsed < 3) {
			// Double Ctrl+C within 3 seconds - force exit
			std::exit(1);
		}

		g_shutdown_requested = true;
	}
}

// Domain state for rate limiting
struct DomainState {
	std::chrono::steady_clock::time_point last_crawl_time;
	double crawl_delay_seconds = 1.0;
	RobotsRules rules;
	bool robots_fetched = false;
	int urls_crawled = 0;
	int urls_failed = 0;
	int urls_skipped = 0;
};

// Crawl result for a single URL
struct CrawlResult {
	std::string url;
	std::string domain;
	int http_status;
	std::string body;
	std::string content_type;
	std::string error;
	int64_t elapsed_ms;
	std::chrono::system_clock::time_point crawled_at;
};

// Extract domain from URL
static std::string ExtractDomain(const std::string &url) {
	// Simple domain extraction: find :// then extract until next /
	size_t proto_end = url.find("://");
	if (proto_end == std::string::npos) {
		return "";
	}
	size_t domain_start = proto_end + 3;
	size_t domain_end = url.find('/', domain_start);
	if (domain_end == std::string::npos) {
		domain_end = url.length();
	}
	std::string domain = url.substr(domain_start, domain_end - domain_start);

	// Remove port if present
	size_t port_pos = domain.find(':');
	if (port_pos != std::string::npos) {
		domain = domain.substr(0, port_pos);
	}

	return domain;
}

// Extract path from URL
static std::string ExtractPath(const std::string &url) {
	size_t proto_end = url.find("://");
	if (proto_end == std::string::npos) {
		return "/";
	}
	size_t path_start = url.find('/', proto_end + 3);
	if (path_start == std::string::npos) {
		return "/";
	}
	return url.substr(path_start);
}

// Bind data for the crawler function
struct CrawlerBindData : public TableFunctionData {
	std::vector<std::string> urls;
	std::string user_agent;
	double default_crawl_delay;
	double min_crawl_delay;
	double max_crawl_delay;
	int timeout_seconds;
	bool respect_robots_txt;
	bool log_skipped;
};

// Global state for the crawler function
struct CrawlerGlobalState : public GlobalTableFunctionState {
	std::mutex mutex;
	size_t current_url_index = 0;
	std::unordered_map<std::string, DomainState> domain_states;

	// Statistics
	int total_crawled = 0;
	int total_failed = 0;
	int total_skipped = 0;
	int total_cancelled = 0;
	std::chrono::steady_clock::time_point start_time;

	idx_t MaxThreads() const override {
		return 1; // Single-threaded for now to respect rate limits properly
	}
};

// Local state for the crawler function
struct CrawlerLocalState : public LocalTableFunctionState {
	bool finished = false;
};

static unique_ptr<FunctionData> CrawlerBind(ClientContext &context, TableFunctionBindInput &input,
                                            vector<LogicalType> &return_types, vector<string> &names) {
	auto bind_data = make_uniq<CrawlerBindData>();

	// Get user_agent parameter (required)
	bool has_user_agent = false;
	for (auto &kv : input.named_parameters) {
		if (kv.first == "user_agent") {
			bind_data->user_agent = StringValue::Get(kv.second);
			has_user_agent = true;
		} else if (kv.first == "default_crawl_delay") {
			bind_data->default_crawl_delay = kv.second.GetValue<double>();
		} else if (kv.first == "min_crawl_delay") {
			bind_data->min_crawl_delay = kv.second.GetValue<double>();
		} else if (kv.first == "max_crawl_delay") {
			bind_data->max_crawl_delay = kv.second.GetValue<double>();
		} else if (kv.first == "timeout_seconds") {
			bind_data->timeout_seconds = kv.second.GetValue<int>();
		} else if (kv.first == "respect_robots_txt") {
			bind_data->respect_robots_txt = kv.second.GetValue<bool>();
		} else if (kv.first == "log_skipped") {
			bind_data->log_skipped = kv.second.GetValue<bool>();
		}
	}

	if (!has_user_agent) {
		throw BinderException("crawl_urls requires 'user_agent' parameter");
	}

	// Set defaults
	if (bind_data->default_crawl_delay == 0) {
		bind_data->default_crawl_delay = 1.0;
	}
	if (bind_data->max_crawl_delay == 0) {
		bind_data->max_crawl_delay = 60.0;
	}
	if (bind_data->timeout_seconds == 0) {
		bind_data->timeout_seconds = 30;
	}
	bind_data->respect_robots_txt = true; // Default
	bind_data->log_skipped = true; // Default

	// Get URLs from the first argument (should be a list of strings)
	if (input.inputs.size() < 1) {
		throw BinderException("crawl_urls requires a list of URLs as first argument");
	}

	auto &urls_value = input.inputs[0];
	if (urls_value.type().id() == LogicalTypeId::LIST) {
		auto &list_children = ListValue::GetChildren(urls_value);
		for (auto &child : list_children) {
			bind_data->urls.push_back(StringValue::Get(child));
		}
	} else {
		throw BinderException("crawl_urls first argument must be a list of URLs");
	}

	// Define output schema
	names.emplace_back("url");
	return_types.emplace_back(LogicalType::VARCHAR);

	names.emplace_back("domain");
	return_types.emplace_back(LogicalType::VARCHAR);

	names.emplace_back("http_status");
	return_types.emplace_back(LogicalType::INTEGER);

	names.emplace_back("body");
	return_types.emplace_back(LogicalType::VARCHAR);

	names.emplace_back("content_type");
	return_types.emplace_back(LogicalType::VARCHAR);

	names.emplace_back("elapsed_ms");
	return_types.emplace_back(LogicalType::BIGINT);

	names.emplace_back("crawled_at");
	return_types.emplace_back(LogicalType::TIMESTAMP);

	names.emplace_back("error");
	return_types.emplace_back(LogicalType::VARCHAR);

	return std::move(bind_data);
}

static unique_ptr<GlobalTableFunctionState> CrawlerInitGlobal(ClientContext &context,
                                                               TableFunctionInitInput &input) {
	auto state = make_uniq<CrawlerGlobalState>();
	state->start_time = std::chrono::steady_clock::now();

	// Reset signal state
	g_shutdown_requested = false;
	g_sigint_count = 0;

	// Install signal handler
	std::signal(SIGINT, SignalHandler);

	return std::move(state);
}

static unique_ptr<LocalTableFunctionState> CrawlerInitLocal(ExecutionContext &context,
                                                             TableFunctionInitInput &input,
                                                             GlobalTableFunctionState *global_state) {
	return make_uniq<CrawlerLocalState>();
}

static void CrawlerFunction(ClientContext &context, TableFunctionInput &data, DataChunk &output) {
	auto &bind_data = data.bind_data->CastNoConst<CrawlerBindData>();
	auto &global_state = data.global_state->Cast<CrawlerGlobalState>();
	auto &local_state = data.local_state->Cast<CrawlerLocalState>();

	if (local_state.finished || g_shutdown_requested) {
		output.SetCardinality(0);
		return;
	}

	std::lock_guard<std::mutex> lock(global_state.mutex);

	// Check if we have more URLs
	if (global_state.current_url_index >= bind_data.urls.size()) {
		local_state.finished = true;
		output.SetCardinality(0);
		return;
	}

	// Process one URL at a time
	auto &url = bind_data.urls[global_state.current_url_index];
	global_state.current_url_index++;

	std::string domain = ExtractDomain(url);
	std::string path = ExtractPath(url);

	// Get or create domain state
	auto &domain_state = global_state.domain_states[domain];

	// Fetch robots.txt if not already done
	if (bind_data.respect_robots_txt && !domain_state.robots_fetched) {
		std::string robots_url = "https://" + domain + "/robots.txt";
		RetryConfig retry_config;
		retry_config.max_retries = 2;

		auto response = HttpClient::Fetch(context, robots_url, retry_config, bind_data.user_agent);

		if (response.success) {
			auto robots_data = RobotsParser::Parse(response.body);
			domain_state.rules = RobotsParser::GetRulesForUserAgent(robots_data, bind_data.user_agent);

			// Set crawl delay
			if (domain_state.rules.crawl_delay.has_value()) {
				domain_state.crawl_delay_seconds = domain_state.rules.crawl_delay.value();
			} else {
				domain_state.crawl_delay_seconds = bind_data.default_crawl_delay;
			}

			// Clamp to min/max
			domain_state.crawl_delay_seconds = std::max(domain_state.crawl_delay_seconds, bind_data.min_crawl_delay);
			domain_state.crawl_delay_seconds = std::min(domain_state.crawl_delay_seconds, bind_data.max_crawl_delay);
		} else {
			// robots.txt not found or error - use default delay, allow all
			domain_state.crawl_delay_seconds = bind_data.default_crawl_delay;
		}

		domain_state.robots_fetched = true;
	}

	// Check if URL is allowed by robots.txt
	if (bind_data.respect_robots_txt && !RobotsParser::IsAllowed(domain_state.rules, path)) {
		global_state.total_skipped++;
		domain_state.urls_skipped++;

		if (bind_data.log_skipped) {
			// Return skipped result
			output.SetCardinality(1);
			output.SetValue(0, 0, Value(url));
			output.SetValue(1, 0, Value(domain));
			output.SetValue(2, 0, Value(-1)); // Special status for robots.txt disallow
			output.SetValue(3, 0, Value());
			output.SetValue(4, 0, Value());
			output.SetValue(5, 0, Value(0));
			output.SetValue(6, 0, Value::TIMESTAMP(Timestamp::GetCurrentTimestamp()));
			output.SetValue(7, 0, Value("robots.txt disallow"));
			return;
		} else {
			// Skip silently, try next URL
			output.SetCardinality(0);
			return;
		}
	}

	// Wait for crawl delay
	auto now = std::chrono::steady_clock::now();
	auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - domain_state.last_crawl_time).count();
	auto required_delay_ms = static_cast<int64_t>(domain_state.crawl_delay_seconds * 1000);

	if (elapsed < required_delay_ms) {
		auto wait_time = required_delay_ms - elapsed;
		std::this_thread::sleep_for(std::chrono::milliseconds(wait_time));
	}

	// Check for shutdown after waiting
	if (g_shutdown_requested) {
		global_state.total_cancelled++;
		output.SetCardinality(0);
		return;
	}

	// Fetch URL
	auto fetch_start = std::chrono::steady_clock::now();

	RetryConfig retry_config;
	retry_config.max_retries = 3;

	auto response = HttpClient::Fetch(context, url, retry_config, bind_data.user_agent);

	auto fetch_end = std::chrono::steady_clock::now();
	auto fetch_elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(fetch_end - fetch_start).count();

	// Update domain state
	domain_state.last_crawl_time = fetch_end;

	if (response.success) {
		global_state.total_crawled++;
		domain_state.urls_crawled++;
	} else {
		global_state.total_failed++;
		domain_state.urls_failed++;
	}

	// Return result
	output.SetCardinality(1);
	output.SetValue(0, 0, Value(url));
	output.SetValue(1, 0, Value(domain));
	output.SetValue(2, 0, Value(response.status_code));
	output.SetValue(3, 0, response.body.empty() ? Value() : Value(response.body));
	output.SetValue(4, 0, response.content_type.empty() ? Value() : Value(response.content_type));
	output.SetValue(5, 0, Value(fetch_elapsed_ms));
	output.SetValue(6, 0, Value::TIMESTAMP(Timestamp::GetCurrentTimestamp()));
	output.SetValue(7, 0, response.error.empty() ? Value() : Value(response.error));
}

void RegisterCrawlerFunction(ExtensionLoader &loader) {
	TableFunction crawl_func("crawl_urls", {LogicalType::LIST(LogicalType::VARCHAR)}, CrawlerFunction, CrawlerBind,
	                         CrawlerInitGlobal, CrawlerInitLocal);

	// Named parameters
	crawl_func.named_parameters["user_agent"] = LogicalType::VARCHAR;
	crawl_func.named_parameters["default_crawl_delay"] = LogicalType::DOUBLE;
	crawl_func.named_parameters["min_crawl_delay"] = LogicalType::DOUBLE;
	crawl_func.named_parameters["max_crawl_delay"] = LogicalType::DOUBLE;
	crawl_func.named_parameters["timeout_seconds"] = LogicalType::INTEGER;
	crawl_func.named_parameters["respect_robots_txt"] = LogicalType::BOOLEAN;
	crawl_func.named_parameters["log_skipped"] = LogicalType::BOOLEAN;

	ExtensionUtil::RegisterFunction(loader, crawl_func);
}

} // namespace duckdb
