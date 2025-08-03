//
//  ls.c
//  StikDebug
//
//  Created by Stephen on 8/3/25.
//

#include "ls.h"
#include "idevice.h"
#include <arpa/inet.h>
#include <netinet/in.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

static IdevicePairingFile       *g_pairing       = NULL;
static IdeviceProviderHandle    *g_provider      = NULL;
static CoreDeviceProxyHandle    *g_core_device   = NULL;
static AdapterHandle            *g_adapter       = NULL;
static RsdHandshakeHandle       *g_handshake     = NULL;
static RemoteServerHandle       *g_remote_server = NULL;
static LocationSimulationHandle *g_location_sim  = NULL;

static void cleanup_on_error(void) {
    if (g_location_sim)  { location_simulation_free(g_location_sim);    g_location_sim  = NULL; }
    if (g_remote_server) { remote_server_free(g_remote_server);         g_remote_server = NULL; }
    if (g_handshake)     { rsd_handshake_free(g_handshake);             g_handshake     = NULL; }
    if (g_adapter)       { adapter_free(g_adapter);                    g_adapter       = NULL; }
    if (g_core_device)   { core_device_proxy_free(g_core_device);       g_core_device   = NULL; }
    if (g_provider)      { idevice_provider_free(g_provider);           g_provider      = NULL; }
    if (g_pairing)       { idevice_pairing_file_free(g_pairing);        g_pairing       = NULL; }
}

int simulate_location(const char *device_ip,
                      double latitude,
                      double longitude,
                      const char *pairing_file)
{
    idevice_init_logger(Debug, Disabled, NULL);
    IdeviceFfiError *err = NULL;

    struct sockaddr_in addr = { .sin_family = AF_INET,
                                .sin_port   = htons(LOCKDOWN_PORT) };
    if (inet_pton(AF_INET, device_ip, &addr.sin_addr) != 1) {
        return IPA_ERR_INVALID_IP;
    }

    if ((err = idevice_pairing_file_read(pairing_file, &g_pairing))) {
        idevice_error_free(err);
        return IPA_ERR_PAIRING_READ;
    }

    if ((err = idevice_tcp_provider_new((struct sockaddr *)&addr,
                                        g_pairing,
                                        "LocationSimCLI",
                                        &g_provider)))
    {
        idevice_error_free(err);
        cleanup_on_error();
        return IPA_ERR_PROVIDER_CREATE;
    }

    if ((err = core_device_proxy_connect(g_provider, &g_core_device))) {
        idevice_error_free(err);
        cleanup_on_error();
        return IPA_ERR_CORE_DEVICE;
    }
    idevice_provider_free(g_provider);
    g_provider = NULL;

    uint16_t rsd_port;
    if ((err = core_device_proxy_get_server_rsd_port(g_core_device,
                                                     &rsd_port)))
    {
        idevice_error_free(err);
        cleanup_on_error();
        return IPA_ERR_RSD_PORT;
    }

    if ((err = core_device_proxy_create_tcp_adapter(g_core_device,
                                                    &g_adapter)))
    {
        idevice_error_free(err);
        cleanup_on_error();
        return IPA_ERR_ADAPTER_CREATE;
    }

    AdapterStreamHandle *stream = NULL;
    if ((err = adapter_connect(g_adapter, rsd_port, &stream))) {
        idevice_error_free(err);
        cleanup_on_error();
        return IPA_ERR_STREAM;
    }

    if ((err = rsd_handshake_new(stream, &g_handshake))) {
        idevice_error_free(err);
        adapter_close(stream);
        cleanup_on_error();
        return IPA_ERR_HANDSHAKE;
    }

    if ((err = remote_server_connect_rsd(g_adapter,
                                         g_handshake,
                                         &g_remote_server)))
    {
        idevice_error_free(err);
        cleanup_on_error();
        return IPA_ERR_REMOTE_SERVER;
    }

    if ((err = location_simulation_new(g_remote_server,
                                       &g_location_sim))) {
        idevice_error_free(err);
        cleanup_on_error();
        return IPA_ERR_LOCATION_SIM;
    }

    if ((err = location_simulation_set(g_location_sim,
                                       latitude,
                                       longitude))) {
        idevice_error_free(err);
        cleanup_on_error();
        return IPA_ERR_LOCATION_SET;
    }

    return IPA_OK;
}

int clear_simulated_location(void)
{
    IdeviceFfiError *err = NULL;
    if (!g_location_sim) return IPA_ERR_LOCATION_CLEAR;

    err = location_simulation_clear(g_location_sim);
    location_simulation_free(g_location_sim);
    g_location_sim = NULL;

    if (g_remote_server) { remote_server_free(g_remote_server);    g_remote_server = NULL; }
    if (g_handshake)     { rsd_handshake_free(g_handshake);        g_handshake     = NULL; }
    if (g_adapter)       { adapter_free(g_adapter);               g_adapter       = NULL; }
  
    return err ? IPA_ERR_LOCATION_CLEAR : IPA_OK;
}
