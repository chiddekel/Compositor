#pragma once

#include "interfaces/ITabletHandler.h"

// The Qt pen adapter forwards raw pressure to the same CanvasView that handles mouse input.
class UpstreamTabletHandler final : public ITabletHandler {
public:
    int32_t dispatch(const QTabletEvent &event, uint64_t sessionHandle, int32_t modifiers) override;
};
