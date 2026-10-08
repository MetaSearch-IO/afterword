#include "arg.h"
#include "common.h"
#include "json-schema-to-grammar.h"
#include "sampling.h"
#include "llama.h"
#include "json.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <map>
#include <set>
#include <stdexcept>
#include <sys/resource.h>
#include <unistd.h>
#include <fcntl.h>

using json = nlohmann::ordered_json;
namespace fs = std::filesystem;
using clock_type = std::chrono::steady_clock;
static_assert(std::atomic<int>::is_always_lock_free, "Cancellation must be signal-safe and lock-free");
static std::atomic<int> interrupted{0};
static void on_signal(int signal) { interrupted.store(signal, std::memory_order_relaxed); }
static bool should_abort(void *) { return interrupted.load(std::memory_order_relaxed) != 0; }
static double seconds(clock_type::time_point start) {
    return std::chrono::duration<double>(clock_type::now() - start).count();
}
static void require(bool value, const char * message) {
    if (!value) throw std::runtime_error(message);
}
static std::string read_file(const fs::path & path, size_t limit) {
    require(path.is_absolute() && fs::is_regular_file(path), "Input must be an absolute local file");
    require(fs::file_size(path) <= limit, "Input file exceeds limit");
    std::ifstream stream(path, std::ios::binary);
    require(stream.good(), "Cannot open input");
    return {std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
}
static void output_file(const fs::path & path, const std::string & data) {
    int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600);
    require(fd >= 0, "Output exists or cannot be created");
    size_t offset = 0;
    while (offset < data.size()) {
        ssize_t count = ::write(fd, data.data() + offset, data.size() - offset);
        if (count <= 0) { ::close(fd); throw std::runtime_error("Cannot write output"); }
        offset += count;
    }
    int sync_result = ::fsync(fd);
    int close_result = ::close(fd);
    require(sync_result == 0 && close_result == 0, "Cannot persist output");
}
struct job {
    std::string id, prompt, grammar;
    fs::path output;
    int predict;
    std::vector<llama_token> tokens, generated;
    std::string response;
    clock_type::time_point started;
};
struct slot {
    int job_index = -1;
    int position = 0;
    int prompt_consumed = 0;
    int logits_index = -1;
    llama_token pending = LLAMA_TOKEN_NULL;
    std::unique_ptr<common_sampler, decltype(&common_sampler_free)> sampler{nullptr, common_sampler_free};
};
struct backend_lifetime {
    backend_lifetime() { llama_backend_init(); }
    ~backend_lifetime() { llama_backend_free(); }
};
struct batch_lifetime {
    llama_batch value;
    explicit batch_lifetime(int capacity) : value(llama_batch_init(capacity, 0, 1)) {}
    ~batch_lifetime() { llama_batch_free(value); }
};

int main(int argc, char ** argv) {
    if (argc == 2 && std::string(argv[1]) == "--help") {
        std::cout << "afterword-summary-batch --model ABS --manifest ABS\n";
        return 0;
    }
    fs::path receipt_path;
    json receipt = {{"schema_version", 1}, {"helper_version", 1}, {"mode", "serial"}, {"jobs", json::array()}};
    auto started = clock_type::now();
    try {
        require(argc == 5, "Expected --model and --manifest");
        std::string model_path, manifest_path;
        constexpr int parallel = 1;
        std::set<std::string> flags;
        for (int i = 1; i < argc; i += 2) {
            std::string key = argv[i];
            require(flags.insert(key).second, "Duplicate option");
            if (key == "--model") model_path = argv[i + 1];
            else if (key == "--manifest") manifest_path = argv[i + 1];
            else throw std::runtime_error("Unknown option");
        }
        require(fs::path(model_path).is_absolute() && fs::is_regular_file(model_path), "Invalid local model");
        auto manifest = json::parse(read_file(manifest_path, 1024 * 1024));
        require(manifest.at("schema_version").is_number_integer() && manifest.at("schema_version") == 1 && manifest.at("jobs").is_array(), "Invalid manifest");
        require(!manifest["jobs"].empty() && manifest["jobs"].size() <= 16, "Expected1–16 jobs");
        receipt_path = manifest.at("receipt_path").get<std::string>();
        std::set<fs::path> output_paths;
        auto reserve_path = [&](const fs::path & path) {
            require(path.is_absolute() && fs::is_directory(path.parent_path()) && !fs::exists(path), "Invalid or existing output path");
            require(output_paths.insert(fs::weakly_canonical(path)).second, "Duplicate output path");
        };
        reserve_path(receipt_path);
        std::set<std::string> ids;
        std::vector<job> jobs;
        for (const auto & item : manifest["jobs"]) {
            job value;
            value.id = item.at("id").get<std::string>();
            require(!value.id.empty() && value.id.size() <= 100 && ids.insert(value.id).second, "Invalid or duplicate job ID");
            value.prompt = read_file(item.at("prompt_path").get<std::string>(), 4 * 1024 * 1024);
            value.grammar = json_schema_to_grammar(common_json::parse(read_file(item.at("schema_path").get<std::string>(), 8 * 1024 * 1024)));
            value.output = item.at("output_path").get<std::string>();
            require(item.at("n_predict").is_number_integer(), "Prediction budget must be an integer");
            value.predict = item.at("n_predict").get<int>();
            require(value.predict > 0 && value.predict <= 8192, "Invalid prediction budget");
            reserve_path(value.output);
            reserve_path(value.output.string() + ".tokens.json");
            jobs.push_back(std::move(value));
        }
        std::signal(SIGTERM, on_signal);
        std::signal(SIGINT, on_signal);
        common_init();
        common_params params;
        std::vector<std::string> arguments = {"afterword-summary-batch", "--model", model_path, "--ctx-size", std::to_string(8192 * parallel),
            "--temp", "0", "--seed", "0", "--no-escape", "--no-conversation", "--no-display-prompt", "--no-context-shift", "--offline"};
        std::vector<char *> pointers;
        for (auto & argument : arguments) pointers.push_back(argument.data());
        require(common_params_parse(pointers.size(), pointers.data(), params, LLAMA_EXAMPLE_COMPLETION), "Cannot initialize completion parameters");
        params.n_parallel = parallel;
        params.kv_unified = false;
        require(!params.sampling.backend_sampling, "Backend sampling is outside this experiment");
        backend_lifetime backend;
        llama_numa_init(params.numa);
        auto initialization = common_init_from_params(params);
        auto * ctx = initialization->context();
        auto * model = initialization->model();
        require(ctx && model, "Model/context initialization failed");
        require(!llama_model_has_encoder(model) && llama_n_ctx_seq(ctx) == 8192, "Expected decoder-only8192 context per sequence");
        llama_set_abort_callback(ctx, should_abort, nullptr);
        auto * vocab = llama_model_get_vocab(model);
        auto memory = llama_get_memory(ctx);
        require(memory, "Missing model sequence memory");
        for (auto & value : jobs) {
            value.tokens = common_tokenize(ctx, value.prompt, true, true);
            require(!value.tokens.empty() && value.tokens.size() + value.predict + 16 <= 8192, "Prompt and output budget exceed sequence context");
        }
        receipt["parallel"] = parallel;
        receipt["context_per_sequence"] = llama_n_ctx_seq(ctx);
        receipt["context_total"] = llama_n_ctx(ctx);
        receipt["logical_batch"] = params.n_batch;
        receipt["physical_batch"] = params.n_ubatch;
        receipt["threads"] = params.cpuparams.n_threads;
        receipt["threads_batch"] = params.cpuparams_batch.n_threads;
        receipt["gpu_layers"] = params.n_gpu_layers;
        receipt["temperature"] = params.sampling.temp;
        receipt["seed"] = params.sampling.seed;
        receipt["setup_seconds"] = seconds(started);
        std::vector<slot> slots(parallel);
        batch_lifetime storage(params.n_batch);
        auto & batch = storage.value;
        size_t next_job = 0, completed = 0;
        size_t prefill_calls = 0, generation_calls = 0, mixed_prefill_calls = 0;
        double prefill_seconds = 0, generation_seconds = 0, sampling_seconds = 0;
        std::map<int, size_t> generation_width_counts;
        std::map<int, double> generation_width_seconds;
        bool all_eog = true;
        auto finish = [&](slot & current, int sequence, const char * reason) {
            auto & value = jobs[current.job_index];
            output_file(value.output, value.response);
            output_file(value.output.string() + ".tokens.json", json({{"prompt", value.tokens}, {"generated", value.generated}}).dump());
            json result = {{"id", value.id}, {"stop_reason", reason}, {"prompt_tokens", value.tokens.size()},
                {"generated_tokens", value.generated.size()}, {"output_bytes", value.response.size()}, {"elapsed_seconds", seconds(value.started)}};
            receipt["jobs"].push_back(result);
            result["type"] = "job_completed";
            std::cout << result.dump() << std::endl;
            require(llama_memory_seq_rm(memory, sequence, -1, -1), "Cannot clear completed sequence");
            current = slot{};
            ++completed;
        };
        while (completed < jobs.size()) {
            require(!should_abort(nullptr), "Interrupted");
            common_batch_clear(batch);
            int prompt_tokens_in_batch = 0;
            for (int sequence = 0; sequence < parallel; ++sequence) {
                auto & current = slots[sequence];
                if (current.job_index < 0 && next_job < jobs.size()) {
                    current.job_index = next_job++;
                    auto & value = jobs[current.job_index];
                    value.started = clock_type::now();
                    auto sampling = params.sampling;
                    sampling.grammar = {COMMON_GRAMMAR_TYPE_OUTPUT_FORMAT, value.grammar};
                    current.sampler.reset(common_sampler_init(model, sampling));
                    require(current.sampler != nullptr, "Sampler initialization failed");
                    std::cout << json({{"type", "job_started"}, {"id", value.id}, {"prompt_tokens", value.tokens.size()}}).dump() << std::endl;
                }
                current.logits_index = -1;
                if (current.job_index >= 0 && current.pending != LLAMA_TOKEN_NULL) {
                    current.logits_index = batch.n_tokens;
                    common_batch_add(batch, current.pending, current.position++, {sequence}, true);
                    current.pending = LLAMA_TOKEN_NULL;
                }
            }
            const int generation_tokens_in_batch = batch.n_tokens;
            for (int sequence = 0; sequence < parallel; ++sequence) {
                auto & current = slots[sequence];
                if (current.job_index < 0) continue;
                auto & value = jobs[current.job_index];
                while (current.prompt_consumed < (int) value.tokens.size() && batch.n_tokens < params.n_batch) {
                    auto token = value.tokens[current.prompt_consumed++];
                    ++prompt_tokens_in_batch;
                    bool last = current.prompt_consumed == (int) value.tokens.size();
                    if (last) current.logits_index = batch.n_tokens;
                    common_sampler_accept(current.sampler.get(), token, false);
                    common_batch_add(batch, token, current.position++, {sequence}, last);
                }
            }
            require(batch.n_tokens > 0, "No decoding progress");
            batch.logits[batch.n_tokens - 1] = true;
            const auto decode_started = clock_type::now();
            require(llama_decode(ctx, batch) == 0, "Native batch decode failed");
            llama_synchronize(ctx);
            const double decode_seconds = seconds(decode_started);
            if (prompt_tokens_in_batch > 0) {
                ++prefill_calls;
                prefill_seconds += decode_seconds;
                if (generation_tokens_in_batch > 0) ++mixed_prefill_calls;
            } else {
                ++generation_calls;
                generation_seconds += decode_seconds;
                ++generation_width_counts[batch.n_tokens];
                generation_width_seconds[batch.n_tokens] += decode_seconds;
            }
            for (int sequence = 0; sequence < parallel; ++sequence) {
                auto & current = slots[sequence];
                if (current.job_index < 0 || current.logits_index < 0) continue;
                auto & value = jobs[current.job_index];
                const auto sampling_started = clock_type::now();
                auto token = common_sampler_sample(current.sampler.get(), ctx, current.logits_index);
                common_sampler_accept(current.sampler.get(), token, true);
                sampling_seconds += seconds(sampling_started);
                value.generated.push_back(token);
                if (llama_vocab_is_eog(vocab, token)) {
                    finish(current, sequence, "eog");
                    continue;
                }
                value.response += common_token_to_piece(ctx, token, false);
                require(value.response.size() <= 4 * 1024 * 1024, "Output exceeds4MiB");
                if ((int) value.generated.size() >= value.predict) {
                    all_eog = false;
                    finish(current, sequence, "predict_limit");
                } else {
                    current.pending = token;
                }
            }
        }
        struct rusage usage{};
        getrusage(RUSAGE_SELF, &usage);
        receipt["peak_rss_bytes"] = usage.ru_maxrss;
        receipt["prefill_decode_wall_seconds"] = prefill_seconds;
        receipt["generation_decode_wall_seconds"] = generation_seconds;
        receipt["sampling_wall_seconds"] = sampling_seconds;
        receipt["prefill_decode_calls"] = prefill_calls;
        receipt["mixed_prefill_decode_calls"] = mixed_prefill_calls;
        receipt["generation_decode_calls"] = generation_calls;
        receipt["pure_generation_width_histogram"] = json::object();
        for (const auto & entry : generation_width_counts) {
            receipt["pure_generation_width_histogram"][std::to_string(entry.first)] = {
                {"calls", entry.second}, {"decode_wall_seconds", generation_width_seconds[entry.first]}};
        }
        receipt["total_seconds"] = seconds(started);
        receipt["status"] = all_eog ? "completed" : "incomplete";
        output_file(receipt_path, receipt.dump(2));
        std::cout << json({{"type", "terminal"}, {"status", receipt["status"]}, {"jobs", completed}, {"seconds", seconds(started)}}).dump() << std::endl;
        return 0;
    } catch (const std::exception &) {
        receipt["status"] = should_abort(nullptr) ? "cancelled" : "failed";
        receipt["total_seconds"] = seconds(started);
        if (!receipt_path.empty() && !fs::exists(receipt_path)) {
            try { output_file(receipt_path, receipt.dump(2)); } catch (...) {}
        }
        std::cerr << "Summary batch failed; review native diagnostics and manifest bounds.\n";
        std::cout << json({{"type", "terminal"}, {"status", receipt["status"]}}).dump() << std::endl;
        return should_abort(nullptr) ? 130 : 1;
    }
}
