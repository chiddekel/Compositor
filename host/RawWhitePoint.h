// DNG camera-neutral -> CIE 1960 uv -> correlated temperature and tint.
// Robertson's isotemperature data: Wyszecki & Stiles, Color Science, 2nd ed., p. 228.
#pragma once

#include <algorithm>
#include <cmath>
#include <optional>

namespace rawwhite {

struct Neutral { double temperature, tint; };

inline std::optional<Neutral> fromCamera(const double (&matrix)[3][3], const double (&neutral)[3]) {
    double system[3][4];
    double magnitude = 0;
    for (int row = 0; row < 3; ++row) {
        if (!std::isfinite(neutral[row]) || neutral[row] <= 0) return {};
        for (int col = 0; col < 3; ++col) {
            if (!std::isfinite(matrix[row][col])) return {};
            system[row][col] = matrix[row][col];
            magnitude = std::max(magnitude, std::abs(matrix[row][col]));
        }
        system[row][3] = neutral[row];
    }
    if (magnitude == 0) return {};
    // Solve camera = matrix * XYZ with pivoting; a singular profile retains the decoder's fallback.
    for (int col = 0; col < 3; ++col) {
        int pivot = col;
        for (int row = col + 1; row < 3; ++row)
            if (std::abs(system[row][col]) > std::abs(system[pivot][col])) pivot = row;
        if (std::abs(system[pivot][col]) <= magnitude * 1e-12) return {};
        for (int i = col; i < 4; ++i) std::swap(system[pivot][i], system[col][i]);
        const double divisor = system[col][col];
        for (int i = col; i < 4; ++i) system[col][i] /= divisor;
        for (int row = 0; row < 3; ++row) if (row != col) {
            const double factor = system[row][col];
            for (int i = col; i < 4; ++i) system[row][i] -= factor * system[col][i];
        }
    }
    const double x = system[0][3], y = system[1][3], z = system[2][3];
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z) || x <= 0 || y <= 0 || z <= 0) return {};
    const double denominator = x + 15 * y + 3 * z;
    if (!std::isfinite(denominator)) return {};
    const double u = 4 * x / denominator, v = 6 * y / denominator;
    struct Line { double reciprocal, u, v, slope; };
    static constexpr Line lines[] = {
        {0,.18006,.26352,-.24341}, {10,.18066,.26589,-.25479}, {20,.18133,.26846,-.26876},
        {30,.18208,.27119,-.28539}, {40,.18293,.27407,-.30470}, {50,.18388,.27709,-.32675},
        {60,.18494,.28021,-.35156}, {70,.18611,.28342,-.37915}, {80,.18740,.28668,-.40955},
        {90,.18880,.28997,-.44278}, {100,.19032,.29326,-.47888}, {125,.19462,.30141,-.58204},
        {150,.19962,.30921,-.70471}, {175,.20525,.31647,-.84901}, {200,.21142,.32312,-1.0182},
        {225,.21807,.32909,-1.2168}, {250,.22511,.33439,-1.4512}, {275,.23247,.33904,-1.7298},
        {300,.24010,.34308,-2.0637}, {325,.24792,.34655,-2.4681}, {350,.25591,.34951,-2.9641},
        {375,.26400,.35200,-3.5814}, {400,.27218,.35407,-4.3633}, {425,.28039,.35577,-5.3762},
        {450,.28863,.35714,-6.7262}, {475,.29685,.35823,-8.5955}, {500,.30505,.35907,-11.324},
        {525,.31320,.35968,-15.628}, {550,.32129,.36011,-23.325}, {575,.32931,.36038,-40.770},
        {600,.33724,.36051,-116.45},
    };
    double previousDistance = 0, previousU = 0, previousV = 0;
    for (int i = 1; i < 31; ++i) {
        const auto &line = lines[i];
        const double length = std::hypot(1, line.slope), du = 1 / length, dv = line.slope / length;
        const double distance = -(u - line.u) * dv + (v - line.v) * du;
        if (distance <= 0 || i == 30) {
            const double below = std::max(0.0, -distance);
            const double weight = i == 1 ? 0 : below / (previousDistance + below);
            const auto &low = lines[i - 1];
            const double reciprocal = low.reciprocal * weight + line.reciprocal * (1 - weight);
            const double alongU = previousU * weight + du * (1 - weight);
            const double alongV = previousV * weight + dv * (1 - weight);
            const double norm = std::hypot(alongU, alongV);
            const double temperature = 1e6 / reciprocal;
            const double tint = -3000 * ((u - low.u * weight - line.u * (1 - weight)) * alongU
                                      + (v - low.v * weight - line.v * (1 - weight)) * alongV) / norm;
            if (!std::isfinite(temperature) || !std::isfinite(tint)) return {};
            return Neutral{temperature, tint};
        }
        previousDistance = distance; previousU = du; previousV = dv;
    }
    return {};
}

}  // namespace rawwhite
