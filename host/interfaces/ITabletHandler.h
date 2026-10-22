#pragma once

#include <QTabletEvent>
#include <cstdint>

// Translates pen input for a session. Brush dynamics belong to the upstream tool, not the window or device adapter.
class ITabletHandler {
public:
    virtual ~ITabletHandler() = default;

    virtual int32_t dispatch(const QTabletEvent &event, uint64_t sessionHandle, int32_t modifiers) = 0;
};
