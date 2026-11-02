#include "SameBoyCore.h"
#include <stdbool.h>

uint64_t gbemu_run_frame_lockstep(GB_gameboy_t *const *gbs, uint64_t *cycles, unsigned count)
{
    bool finished[2] = {false, false};
    unsigned pending = count;
    uint64_t max_skew = 0;
    while (pending) {
        unsigned behind = 0;
        for (unsigned i = 1; i < count; i++) {
            if (cycles[i] < cycles[behind]) behind = i;
        }
        GB_gameboy_t *gb = gbs[behind];
        cycles[behind] += GB_run(gb);
        /* GB_run() clears this on entry and sets it when a vblank happened. */
        if (!finished[behind] && gb->vblank_just_occured) {
            finished[behind] = true;
            pending--;
        }
        if (count == 2) {
            uint64_t skew = cycles[0] > cycles[1] ? cycles[0] - cycles[1] : cycles[1] - cycles[0];
            if (skew > max_skew) max_skew = skew;
        }
    }
    return max_skew;
}
