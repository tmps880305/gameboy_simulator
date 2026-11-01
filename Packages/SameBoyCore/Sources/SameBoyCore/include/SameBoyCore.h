#pragma once

// Must match `featureDefines` in Package.swift.
#ifndef GB_DISABLE_DEBUGGER
#define GB_DISABLE_DEBUGGER
#endif
#ifndef GB_DISABLE_CHEATS
#define GB_DISABLE_CHEATS
#endif
#ifndef GB_DISABLE_REWIND
#define GB_DISABLE_REWIND
#endif

#include "../Core/gb.h"
#include "GBEmuAtomics.h"
