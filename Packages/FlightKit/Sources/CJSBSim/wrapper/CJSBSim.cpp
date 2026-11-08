#include "CJSBSim.h"

#include <cmath>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <string>

#include "FGFDMExec.h"
#include "input_output/FGPropertyManager.h"
#include "simgear/misc/sg_path.hxx"

struct JSBInstance {
    std::unique_ptr<JSBSim::FGFDMExec> fdm;
};

// JSBSim keeps process-wide static state, so two instances stepping on different threads can
// crash even though they share no objects (seen when tests ran in parallel). Every entry point
// takes this lock; with one physics loop running there is no contention.
static std::recursive_mutex &engineLock() {
    static std::recursive_mutex lock;
    return lock;
}
#define JSB_LOCK std::lock_guard<std::recursive_mutex> guard(engineLock())

static void writeError(char *buffer, int length, const std::string &message) {
    if (!buffer || length <= 0) return;
    std::strncpy(buffer, message.c_str(), static_cast<size_t>(length - 1));
    buffer[length - 1] = '\0';
}

extern "C" const char *jsb_version(void) {
    return "1.3.3";
}

extern "C" JSBInstance *jsb_create(const char *rootDir, char *error, int errorLength) {
    JSB_LOCK;
    try {
        auto instance = new JSBInstance();
        instance->fdm = std::make_unique<JSBSim::FGFDMExec>();
        instance->fdm->SetDebugLevel(0);
        instance->fdm->SetRootDir(SGPath(rootDir));
        instance->fdm->SetAircraftPath(SGPath("aircraft"));
        instance->fdm->SetEnginePath(SGPath("engine"));
        instance->fdm->SetSystemsPath(SGPath("systems"));
        return instance;
    } catch (const std::exception &e) {
        writeError(error, errorLength, e.what());
    } catch (...) {
        writeError(error, errorLength, "unknown JSBSim error during create");
    }
    return nullptr;
}

extern "C" void jsb_destroy(JSBInstance *instance) {
    JSB_LOCK;
    try { delete instance; } catch (...) {}
}

extern "C" int jsb_load_model(JSBInstance *instance, const char *model, char *error, int errorLength) {
    JSB_LOCK;
    if (!instance) return 0;
    try {
        if (instance->fdm->LoadModel(model)) return 1;
        writeError(error, errorLength, std::string("LoadModel failed for ") + model);
    } catch (const std::exception &e) {
        writeError(error, errorLength, e.what());
    } catch (...) {
        writeError(error, errorLength, "unknown JSBSim error during LoadModel");
    }
    return 0;
}

extern "C" void jsb_set_dt(JSBInstance *instance, double dt) {
    JSB_LOCK;
    if (instance) instance->fdm->Setdt(dt);
}

extern "C" int jsb_has(JSBInstance *instance, const char *property) {
    JSB_LOCK;
    if (!instance) return 0;
    try {
        return instance->fdm->GetPropertyManager()->GetNode(property) != nullptr ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

extern "C" double jsb_get(JSBInstance *instance, const char *property) {
    JSB_LOCK;
    if (!instance) return NAN;
    try {
        auto node = instance->fdm->GetPropertyManager()->GetNode(property);
        return node ? node->getDoubleValue() : NAN;
    } catch (...) {
        return NAN;
    }
}

extern "C" int jsb_set(JSBInstance *instance, const char *property, double value) {
    JSB_LOCK;
    if (!instance) return 0;
    try {
        auto node = instance->fdm->GetPropertyManager()->GetNode(property, true);
        if (!node) return 0;
        return node->setDoubleValue(value) ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

extern "C" int jsb_run_ic(JSBInstance *instance, char *error, int errorLength) {
    JSB_LOCK;
    if (!instance) return 0;
    try {
        return instance->fdm->RunIC() ? 1 : 0;
    } catch (const std::exception &e) {
        writeError(error, errorLength, e.what());
    } catch (...) {
        writeError(error, errorLength, "unknown JSBSim error during RunIC");
    }
    return 0;
}

extern "C" int jsb_trim(JSBInstance *instance, int mode, char *error, int errorLength) {
    JSB_LOCK;
    if (!instance) return 0;
    try {
        instance->fdm->DoTrim(mode);
        return 1;
    } catch (const std::exception &e) {
        writeError(error, errorLength, e.what());
    } catch (...) {
        writeError(error, errorLength, "trim did not converge");
    }
    return 0;
}

extern "C" int jsb_step(JSBInstance *instance) {
    JSB_LOCK;
    if (!instance) return 0;
    try {
        return instance->fdm->Run() ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

extern "C" double jsb_sim_time(JSBInstance *instance) {
    JSB_LOCK;
    return instance ? instance->fdm->GetSimTime() : NAN;
}
