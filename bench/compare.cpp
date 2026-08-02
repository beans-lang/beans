#include "../compiler/bootstrap/json.h"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

using beans::Json;

struct Target {
    double median = 0.0;
    double cv = 0.0;
    double rss = 0.0;
};

struct Row {
    std::string name;
    std::string group;
    std::string size;
    std::string seed;
    std::string input_hash;
    std::string output_hash;
    bool scored = false;
    std::map<std::string, Target> targets;
};

struct Result {
    std::string path;
    std::string mode;
    std::map<std::string, std::string> metadata;
    std::map<std::string, double> policy;
    std::map<std::string, Row> rows;
};

static std::string read_file(const std::string& path) {
    std::ifstream input(path);
    if (!input) throw std::runtime_error("cannot read " + path);
    std::ostringstream out;
    out << input.rdbuf();
    return out.str();
}

static const Json& need(const Json& object, const std::string& key,
                        Json::T type) {
    const Json* value = object.find(key);
    if (!value || value->t != type)
        throw std::runtime_error("missing or invalid JSON field: " + key);
    return *value;
}

static bool get_bool(const Json& object, const std::string& key) {
    return need(object, key, Json::T::boolean).b;
}

static Target read_target(const Json& value) {
    const Json& stats = need(value, "stats", Json::T::object);
    Target target;
    target.median = need(stats, "median", Json::T::number).num;
    target.cv = need(stats, "cv_percent", Json::T::number).num;
    target.rss = need(stats, "peak_rss", Json::T::number).num;
    if (target.median <= 0.0)
        throw std::runtime_error("benchmark median must be positive");
    return target;
}

static Result read_result(const std::string& path) {
    bool ok = false;
    Json root = beans::json_parse(read_file(path), &ok);
    if (!ok || !root.is_object())
        throw std::runtime_error("invalid JSON: " + path);
    if (need(root, "schema", Json::T::number).num < 4.0)
        throw std::runtime_error(path + " uses an old benchmark schema");

    Result result;
    result.path = path;
    result.mode = need(root, "mode", Json::T::string).str;
    for (const auto& [key, value] : need(root, "metadata", Json::T::object).obj) {
        if (value.is_string()) result.metadata[key] = value.str;
    }
    for (const auto& [key, value] : need(root, "policy", Json::T::object).obj) {
        if (value.is_number()) result.policy[key] = value.num;
    }
    for (const Json& value : need(root, "benchmarks", Json::T::array).arr) {
        Row row;
        row.name = need(value, "name", Json::T::string).str;
        row.group = need(value, "group", Json::T::string).str;
        row.size = need(value, "size", Json::T::string).str;
        row.seed = need(value, "seed", Json::T::string).str;
        row.input_hash = need(value, "input_hash", Json::T::string).str;
        row.output_hash = need(value, "output_hash", Json::T::string).str;
        row.scored = get_bool(value, "scored");
        for (const Json& target : need(value, "targets", Json::T::array).arr) {
            const auto id = need(target, "id", Json::T::string).str;
            row.targets[id] = read_target(target);
        }
        if (!result.rows.emplace(row.name, std::move(row)).second)
            throw std::runtime_error("duplicate workload in " + path);
    }
    return result;
}

static const std::string& metadata(const Result& result,
                                   const std::string& key) {
    auto found = result.metadata.find(key);
    if (found == result.metadata.end())
        throw std::runtime_error(result.path + " has no metadata field " + key);
    return found->second;
}

static double policy(const Result& result, const std::string& key) {
    auto found = result.policy.find(key);
    if (found == result.policy.end())
        throw std::runtime_error(result.path + " has no policy field " + key);
    return found->second;
}

static const Target& target(const Row& row, const std::string& id) {
    auto found = row.targets.find(id);
    if (found == row.targets.end())
        throw std::runtime_error(row.name + " has no " + id + " target");
    return found->second;
}

static double geometric_mean(const std::vector<double>& values) {
    if (values.empty()) throw std::runtime_error("empty geometric mean");
    double sum = 0.0;
    for (double value : values) {
        if (value <= 0.0) throw std::runtime_error("non-positive ratio");
        sum += std::log(value);
    }
    return std::exp(sum / static_cast<double>(values.size()));
}

static double tuned_score(const Row& row) {
    return target(row, "cpp_tuned").median / target(row, "beans").median;
}

static double memory_ratio(const Row& row) {
    const double tuned = target(row, "cpp_tuned").rss;
    return tuned > 0.0 ? target(row, "beans").rss / tuned : 0.0;
}

static std::map<std::string, double>
group_scores(const std::map<std::string, Row>& rows) {
    std::map<std::string, std::vector<double>> groups;
    for (const auto& [name, row] : rows) {
        (void)name;
        if (row.scored) groups[row.group].push_back(tuned_score(row));
    }
    std::map<std::string, double> scores;
    for (const auto& [group, values] : groups)
        scores[group] = geometric_mean(values);
    return scores;
}

static double overall_score(const std::map<std::string, Row>& rows) {
    std::vector<double> scores;
    for (const auto& [group, score] : group_scores(rows)) {
        (void)group;
        scores.push_back(score);
    }
    return geometric_mean(scores);
}

static double overall_memory(const std::map<std::string, Row>& rows) {
    std::vector<double> ratios;
    for (const auto& [name, row] : rows) {
        (void)name;
        if (!row.scored) continue;
        const double ratio = memory_ratio(row);
        if (ratio > 0.0) ratios.push_back(ratio);
    }
    return geometric_mean(ratios);
}

static double change(double before, double after) {
    return after / before - 1.0;
}

static void require_same_run_contract(const Result& before,
                                      const Result& after) {
    if (before.mode != "full" || after.mode != "full")
        throw std::runtime_error("before/after comparison requires two full runs");
    for (const std::string& key :
         {"os", "cpu", "architecture", "logical_cpus", "memory_bytes", "cxx",
          "cxx_flags", "beans_flags", "suite_fnv1a64", "policy_fnv1a64"}) {
        if (metadata(before, key) != metadata(after, key))
            throw std::runtime_error("run contract changed: " + key);
    }
    if (before.rows.size() != after.rows.size())
        throw std::runtime_error("workload count changed between runs");

    const std::set<std::string> required = {
        "fib", "loops", "mandel", "matrix", "direct_calls", "shapes",
        "generic_calls", "closures", "churn", "trees", "option_chain",
        "deep_teardown", "cycles", "box_churn", "arena_churn", "sequences",
        "sequence_churn", "slices", "sort_objects", "maps", "map_churn",
        "ordered_maps", "strings", "utf8", "bytes", "decimal_kernel",
        "sized_numeric", "thread_spawn", "atomic_contention",
        "mutex_contention", "channels", "parallel", "parallel_1",
        "parallel_2", "kv_store", "log_aggregate", "graph", "mixed_app"};
    for (const std::string& name : required) {
        if (!before.rows.contains(name) || !after.rows.contains(name))
            throw std::runtime_error("full contract is missing " + name);
    }

    const double max_cv = policy(after, "max_cv_percent");
    for (const auto& [name, old_row] : before.rows) {
        auto found = after.rows.find(name);
        if (found == after.rows.end())
            throw std::runtime_error("after run is missing " + name);
        const Row& new_row = found->second;
        if (old_row.group != new_row.group || old_row.size != new_row.size ||
            old_row.seed != new_row.seed ||
            old_row.input_hash != new_row.input_hash ||
            old_row.output_hash != new_row.output_hash ||
            old_row.scored != new_row.scored)
            throw std::runtime_error(name + " changed its benchmark contract");
        for (const std::string& id : {"beans", "cpp_tuned", "cpp_matched"}) {
            if (target(old_row, id).cv > max_cv ||
                target(new_row, id).cv > max_cv)
                throw std::runtime_error(name + " " + id +
                                         " exceeds the CV limit");
        }
    }
}

int main(int argc, char** argv) try {
    if (argc < 3) {
        std::cerr << "usage: bench-compare <before.json> <after.json> "
                     "<expected-workload>...\n";
        return 2;
    }
    const Result before = read_result(argv[1]);
    const Result after = read_result(argv[2]);
    require_same_run_contract(before, after);

    const double row_limit = policy(after, "compare_workload_regression");
    const double group_limit = policy(after, "compare_group_regression");
    const double overall_limit = policy(after, "compare_overall_regression");
    const double memory_limit = policy(after, "compare_memory_regression");
    const double expected_gain = policy(after, "expected_improvement");
    bool failed = false;
    std::vector<std::string> failures;
    std::vector<std::string> warnings;

    std::cout << "full benchmark comparison\n";
    std::cout << "before: " << before.path << '\n';
    std::cout << "after:  " << after.path << "\n\n";
    std::cout << std::left << std::setw(22) << "workload" << std::setw(14)
              << "group" << std::right << std::setw(11) << "before"
              << std::setw(11) << "after" << std::setw(11) << "score Δ"
              << std::setw(11) << "Beans Δ" << '\n';

    for (const auto& [name, old_row] : before.rows) {
        const Row& new_row = after.rows.at(name);
        if (!old_row.scored) continue;
        const double old_score = tuned_score(old_row);
        const double new_score = tuned_score(new_row);
        const double score_change = change(old_score, new_score);
        const double beans_change =
            change(target(new_row, "beans").median,
                   target(old_row, "beans").median);
        // A changed C++ reference must not turn a faster Beans binary into a
        // row regression. Gate the compiler under test directly here; group
        // and overall scores below still catch broad reference-normalized
        // regressions.
        if (beans_change < -row_limit) {
            failed = true;
            std::ostringstream reason;
            reason << name << " Beans throughput changed "
                   << std::showpos << std::fixed
                   << std::setprecision(1)
                   << beans_change * 100.0 << "% (limit -"
                   << std::noshowpos << row_limit * 100.0 << "%)";
            failures.push_back(reason.str());
        } else if (score_change < -row_limit) {
            std::ostringstream warning;
            warning << name << " reference score changed "
                    << std::showpos << std::fixed
                    << std::setprecision(1)
                    << score_change * 100.0
                    << "% while Beans changed "
                    << beans_change * 100.0 << '%';
            warnings.push_back(warning.str());
        }
        std::cout << std::left << std::setw(22) << name << std::setw(14)
                  << old_row.group << std::right << std::fixed
                  << std::setprecision(1) << std::setw(10) << old_score * 100.0
                  << '%' << std::setw(10) << new_score * 100.0 << '%'
                  << std::showpos << std::setw(10) << score_change * 100.0 << '%'
                  << std::setw(10) << beans_change * 100.0 << '%'
                  << std::noshowpos << '\n';
    }

    std::cout << "\ngroups\n";
    const auto old_groups = group_scores(before.rows);
    const auto new_groups = group_scores(after.rows);
    for (const auto& [group, old_score] : old_groups) {
        const double new_score = new_groups.at(group);
        const double delta = change(old_score, new_score);
        if (delta < -group_limit) {
            failed = true;
            std::ostringstream reason;
            reason << group << " group score changed "
                   << std::showpos << std::fixed
                   << std::setprecision(1) << delta * 100.0
                   << "% (limit -" << std::noshowpos
                   << group_limit * 100.0 << "%)";
            failures.push_back(reason.str());
        }
        std::cout << std::left << std::setw(18) << group << std::right
                  << std::fixed << std::setprecision(1) << std::setw(8)
                  << old_score * 100.0 << "% -> " << std::setw(8)
                  << new_score * 100.0 << "%  " << std::showpos
                  << delta * 100.0 << '%' << std::noshowpos << '\n';
    }

    const double old_overall = overall_score(before.rows);
    const double new_overall = overall_score(after.rows);
    const double overall_delta = change(old_overall, new_overall);
    if (overall_delta < -overall_limit) {
        failed = true;
        std::ostringstream reason;
        reason << "overall score changed " << std::showpos
               << std::fixed << std::setprecision(1)
               << overall_delta * 100.0 << "% (limit -"
               << std::noshowpos << overall_limit * 100.0 << "%)";
        failures.push_back(reason.str());
    }
    const double old_memory = overall_memory(before.rows);
    const double new_memory = overall_memory(after.rows);
    if (new_memory > old_memory * (1.0 + memory_limit)) {
        failed = true;
        std::ostringstream reason;
        reason << "memory ratio changed " << std::showpos
               << std::fixed << std::setprecision(1)
               << change(old_memory, new_memory) * 100.0
               << "% (limit +" << std::noshowpos
               << memory_limit * 100.0 << "%)";
        failures.push_back(reason.str());
    }
    std::cout << "\noverall: " << std::fixed << std::setprecision(1)
              << old_overall * 100.0 << "% -> " << new_overall * 100.0
              << "%  " << std::showpos << overall_delta * 100.0 << "%"
              << std::noshowpos << '\n';
    std::cout << "memory:  " << std::setprecision(2) << old_memory
              << "x -> " << new_memory << "x tuned C++\n";

    if (argc == 3) {
        std::cout << "\nno expected workload was supplied; regression checks only\n";
    }
    for (int i = 3; i < argc; ++i) {
        const std::string name = argv[i];
        if (!before.rows.contains(name) || !after.rows.contains(name))
            throw std::runtime_error("unknown expected workload: " + name);
        const Row& old_row = before.rows.at(name);
        const Row& new_row = after.rows.at(name);
        const double score_gain =
            change(tuned_score(old_row), tuned_score(new_row));
        const double beans_gain =
            change(target(new_row, "beans").median,
                   target(old_row, "beans").median);
        const bool improved = beans_gain >= expected_gain;
        std::cout << "expected " << name << ": Beans " << std::showpos
                  << std::setprecision(1) << beans_gain * 100.0
                  << "%, score " << score_gain * 100.0 << "% — "
                  << (improved ? "PASS" : "FAIL") << std::noshowpos << '\n';
        if (!improved) {
            failed = true;
            std::ostringstream reason;
            reason << name << " did not meet the expected "
                   << std::fixed << std::setprecision(1)
                   << expected_gain * 100.0
                   << "% Beans improvement";
            failures.push_back(reason.str());
        }
    }

    if (!warnings.empty()) {
        std::cout << "\nreference warnings\n";
        for (const std::string& warning : warnings)
            std::cout << "- " << warning << '\n';
    }
    if (failed) {
        std::cerr << "\nfailed gates\n";
        for (const std::string& failure : failures)
            std::cerr << "- " << failure << '\n';
        std::cerr << "benchmark comparison failed\n";
        return 1;
    }
    std::cout << "benchmark comparison passed\n";
    return 0;
} catch (const std::exception& error) {
    std::cerr << "bench compare: " << error.what() << '\n';
    return 1;
}
