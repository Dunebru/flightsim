#ifndef CJSBSIM_H
#define CJSBSIM_H

// C API over the JSBSim C++ flight dynamics engine (v1.3.3, LGPL-2.1, vendored in jsbsim/).
// Every call catches C++ exceptions at the boundary; failures come back as return codes and an
// error message, never as exceptions crossing into Swift.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct JSBInstance JSBInstance;

/// Version of the linked engine ("1.3.3").
const char *jsb_version(void);

/// Creates an engine rooted at `rootDir`, which must contain aircraft/, engine/ and systems/.
/// Returns NULL on failure, with a message in `error`.
JSBInstance *jsb_create(const char *rootDir, char *error, int errorLength);
void jsb_destroy(JSBInstance *instance);

/// Loads aircraft/<model>/<model>.xml. Returns 1 on success.
int jsb_load_model(JSBInstance *instance, const char *model, char *error, int errorLength);

/// Integration step in seconds (for example 1/120).
void jsb_set_dt(JSBInstance *instance, double dt);

/// Property access. `jsb_get` returns NaN when the property does not exist; `jsb_set` returns 0.
int jsb_has(JSBInstance *instance, const char *property);
double jsb_get(JSBInstance *instance, const char *property);
int jsb_set(JSBInstance *instance, const char *property, double value);

/// Applies the ic/ properties. Returns 1 on success.
int jsb_run_ic(JSBInstance *instance, char *error, int errorLength);

/// Trims the aircraft: 0 longitudinal, 1 full, 2 ground. Returns 1 when the trim converged.
int jsb_trim(JSBInstance *instance, int mode, char *error, int errorLength);

/// Advances one step. Returns 1 while the simulation continues.
int jsb_step(JSBInstance *instance);

/// Simulation time in seconds.
double jsb_sim_time(JSBInstance *instance);

#ifdef __cplusplus
}
#endif

#endif
