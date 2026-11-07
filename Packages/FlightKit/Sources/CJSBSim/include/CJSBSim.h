#ifndef CJSBSIM_H
#define CJSBSIM_H

// C API over the JSBSim C++ flight dynamics engine.
// Placeholder (M0 stub): only jsb_version exists and returns "stub".
// M2 compiles the JSBSim v1.3.3 sources into this target and adds
// jsb_create / jsb_load_aircraft / jsb_set_property / jsb_get_property / jsb_step.

#ifdef __cplusplus
extern "C" {
#endif

/// Version of the linked flight dynamics engine. Returns "stub" until M2.
const char *jsb_version(void);

#ifdef __cplusplus
}
#endif

#endif
