#pragma once

#include <stdint.h>

/// Runs `count` (1 or 2) cores in lock step until every one of them has
/// completed at least one more frame. Each step runs a single GB_run() slice
/// on the core whose accumulated time in `cycles` (8 MHz ticks, in/out) is
/// lowest, the same scheme as SameBoy's own link-cable front ends. With one
/// core this is the same loop as GB_run_frame().
///
/// Returns the largest gap between the cores' clocks seen during the call.
/// Kept in C so the per-instruction loop stays cheap in unoptimized builds.
uint64_t gbemu_run_frame_lockstep(GB_gameboy_t *const *gbs, uint64_t *cycles, unsigned count);
