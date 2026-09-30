// Small Bluetooth radio helper for the Sidecar shortcut.
//
// macOS does not ship a supported shell command for changing the Bluetooth
// radio. These IOBluetoothPreference* symbols are the same private API used
// by blueutil. The caller always reads the state back after a change; a
// missing/changed symbol is reported as failure rather than treated as on.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern int IOBluetoothPreferencesAvailable(void);
extern int IOBluetoothPreferenceGetControllerPowerState(void);
extern void IOBluetoothPreferenceSetControllerPowerState(int state);

static int state(void) {
    return IOBluetoothPreferenceGetControllerPowerState() ? 1 : 0;
}

static int wait_for(int wanted) {
    for (int i = 0; i <= 100; i++) {
        if (state() == wanted) return 0;
        if (i < 100) usleep(100000);
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "status") != 0 &&
                      strcmp(argv[1], "prepare") != 0)) {
        fprintf(stderr, "usage: %s status|prepare\n", argv[0]);
        return 64;
    }
    fprintf(stderr, "bluetooth helper: checking IOBluetooth preferences API\n");
    fflush(stderr);
    if (!IOBluetoothPreferencesAvailable()) {
        fprintf(stderr, "Bluetooth preferences API unavailable\n");
        return 2;
    }
    fprintf(stderr, "bluetooth helper: preferences API available; reading controller state\n");
    fflush(stderr);
    if (strcmp(argv[1], "status") == 0) {
        int current = state();
        fprintf(stderr, "bluetooth helper: initial controller state read complete\n");
        fflush(stderr);
        printf("%s\n", current ? "on" : "off");
        return 0;
    }
    int current = state();
    fprintf(stderr, "bluetooth helper: initial controller state read complete\n");
    fflush(stderr);
    if (!current) {
        fprintf(stderr, "bluetooth helper: requesting controller power on\n");
        fflush(stderr);
        IOBluetoothPreferenceSetControllerPowerState(1);
    }
    fprintf(stderr, "bluetooth helper: waiting for controller state verification\n");
    fflush(stderr);
    if (wait_for(1) != 0) {
        fprintf(stderr, "Bluetooth radio did not become ready\n");
        return 1;
    }
    printf("on\n");
    return 0;
}
