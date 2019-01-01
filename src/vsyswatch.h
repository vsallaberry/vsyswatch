/*
 ** Copyright (C) 2018-2019 Vincent Sallaberry
 ** vsyswatch <https://github.com/vsallaberry/vsyswatch>
 **
 ** This program is free software; you can redistribute it and/or modify
 ** it under the terms of the GNU General Public License as published by
 ** the Free Software Foundation; either version 3 of the License, or
 ** (at your option) any later version.
 **
 ** This program is distributed in the hope that it will be useful,
 ** but WITHOUT ANY WARRANTY; without even the implied warranty of
 ** MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 ** GNU General Public License for more details.
 **
 ** You should have received a copy of the GNU General Public License along
 ** with this program; if not, write to the Free Software Foundation, Inc.,
 ** 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 **
 ** -------------------------------------------------------------------------
 ** vsyswatch:
 **   little utility for MacOS watching for availability of differents
 **   resources like network, battery, ...
 **/
#ifndef VSYSWATCH_VSYSWATCH_H
#define VSYSWATCH_VSYSWATCH_H

#include <pthread.h>

#include "version.h"

/** global vsyswatch flags */
enum {
    FLG_NONE            = 0,
    FLG_VERBOSE         = 1 << 0,
    FLG_TEST            = 1 << 1,
    FLG_TRIG_ON_START   = 1 << 2,
    FLG_PRINT_EVENT     = 1 << 3,
};

/* generic network host list */
typedef struct netlist_s {
    const char *                    host;
    char                            status;
    void *                          specific;
    struct netlist_s *              next;
} netlist_t;

/* battery info */
typedef enum {
    BS_NONE = 0, BS_AC = 1, BS_BAT_OK = 2, BS_BAT_LOW = 3
} battery_state_t;
# define VSYSWATCH_BATTERY_UNKNOWN_TIME -1
# define VSYSWATCH_BATTERY_INFINITE_TIME -2
typedef struct {
    battery_state_t     state;
    char                percents;
    long                time_remaining; /*minutes*/
} battery_info_t;

/** global vsyswatch context */
typedef struct {
    unsigned int        flags;
    struct netlist_s *  netlist;
    void *              battery;
    void *              network;
    void *              file;
    const char *        network_watch_file;
    const char *        battery_watch_file;
    char                battery_percents_low;
    long                battery_time_remaining_low;
} vsyswatch_ctx_t;

#endif /* ! ifndef VSYSWATCH_VSYSWATCH_H */

