//
//  ideviceinfo.h
//  StikDebug
//
//  Created by Stephen on 8/2/25.
//

#ifndef IDEVICEINFO_H
#define IDEVICEINFO_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize the device connection:
 * - Reads the pairing file
 * - Creates a TCP provider
 * - Starts a persistent heartbeat
 * - Connects & starts a lockdown session
 *
 * @param pairing_file_path path to pairingFile.plist
 * @return 0 on success, non-zero on error
 */
int  ideviceinfo_c_init(const char *pairing_file_path);

/**
 * Fetches all device info via the already-open lockdown session,
 * returning a malloc'd XML plist string (caller must free it).
 *
 * @return malloc'd XML on success, or NULL on error
 */
char *ideviceinfo_c_get_xml(void);

/**
 * Clean up everything:
 * - Stops heartbeat
 * - Frees lockdown client
 * - Frees provider & pairing file
 */
void ideviceinfo_c_cleanup(void);

#ifdef __cplusplus
}
#endif

#endif // IDEVICEINFO_H
