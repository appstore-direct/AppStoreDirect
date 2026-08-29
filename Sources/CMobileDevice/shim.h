#ifndef APPSTOREDIRECT_CMOBILEDEVICE_SHIM_H
#define APPSTOREDIRECT_CMOBILEDEVICE_SHIM_H

// Single entry point for every C symbol the Swift side is allowed to touch.
// Nothing outside DeviceKit imports this module.

#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/afc.h>
#include <libimobiledevice/installation_proxy.h>
#include <plist/plist.h>

#endif
