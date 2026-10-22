#pragma once

// PerfTrace — call counts and wall time per named section, printed at exit when COMPOSITOR_PROFILE is set.
// Zero cost otherwise beyond one cached environment check. Header-only (no moc).
//
//   void SessionWindow::refreshImage() { PERF_SCOPE("refreshImage"); ... }

#include <QElapsedTimer>
#include <QString>
#include <QtGlobal>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>
#include <vector>

namespace perftrace {

struct Stat { long long calls = 0; long long nanos = 0; long long worst = 0; };

inline bool enabled() {
    static const bool on = qEnvironmentVariableIsSet("COMPOSITOR_PROFILE");
    return on;
}

inline std::map<std::string, Stat> &stats() {
    static std::map<std::string, Stat> table;
    static const bool registered = [] {
        std::atexit([] {
            std::vector<std::pair<std::string, Stat>> rows(stats().begin(), stats().end());
            std::sort(rows.begin(), rows.end(), [](const auto &a, const auto &b) { return a.second.nanos > b.second.nanos; });
            std::fprintf(stderr, "PERF %-34s %8s %10s %9s %9s\n", "section", "calls", "total ms", "avg ms", "worst ms");
            for (const auto &[name, s] : rows)
                std::fprintf(stderr, "PERF %-34s %8lld %10.1f %9.2f %9.2f\n", name.c_str(), s.calls, s.nanos / 1e6,
                             s.calls ? s.nanos / 1e6 / s.calls : 0.0, s.worst / 1e6);
        });
        return true;
    }();
    (void)registered;
    return table;
}

class Scope {
public:
    explicit Scope(const char *name) : m_name(enabled() ? name : nullptr) { if (m_name) m_timer.start(); }
    Scope(const QString &name) : m_owned(enabled() ? name.toStdString() : std::string()), m_name(enabled() ? m_owned.c_str() : nullptr) {
        if (m_name) m_timer.start();
    }
    ~Scope() {
        if (!m_name) return;
        const long long ns = m_timer.nsecsElapsed();
        Stat &s = stats()[m_name];
        ++s.calls; s.nanos += ns; s.worst = std::max(s.worst, ns);
    }
private:
    std::string m_owned;
    const char *m_name;
    QElapsedTimer m_timer;
};

}  // namespace perftrace

#define PERF_CONCAT2(a, b) a##b
#define PERF_CONCAT(a, b) PERF_CONCAT2(a, b)
#define PERF_SCOPE(name) perftrace::Scope PERF_CONCAT(perfScope_, __LINE__)(name)
