//
//  CellTunnelSignalSupport.h
//  CellTunnelSignalSupport
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-23.
//  Copyright © 2026, all rights reserved.
//

#ifndef CELL_TUNNEL_SIGNAL_SUPPORT_H
#define CELL_TUNNEL_SIGNAL_SUPPORT_H

#include <stddef.h>
#include <stdint.h>

#define CELL_TUNNEL_PROBE_EXITED 0
#define CELL_TUNNEL_PROBE_TIMED_OUT 1
#define CELL_TUNNEL_PROBE_INTERRUPTED 2
#define CELL_TUNNEL_PROBE_SYSTEM_ERROR 3

typedef struct {
    int32_t outcome;
    int32_t status;
    int32_t signal_number;
    int32_t error_number;
} CellTunnelProbeResult;

void cell_tunnel_probe_run(
    const uint8_t *command,
    size_t command_length,
    uint64_t timeout_milliseconds,
    CellTunnelProbeResult *result
);

#endif
