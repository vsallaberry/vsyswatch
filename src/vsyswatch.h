/*
 ** Copyright (C) 2018 Vincent Sallaberry
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

/** global vsyswatch flags */
enum {
    FLG_NONE            = 0,
    FLG_DEBUG           = 1 << 0,
    FLG_TEST            = 1 << 1,
    FLG_TRIG_ON_START   = 1 << 2,
};

/** opaque struct netlist_s declared in scnetwork */
struct netlist_s;

/** global vsyswatch context */
typedef struct {
    unsigned int        flags;
    struct netlist_s *  netlist;
    void *              battery;
    const char *        network_watch_file;
    const char *        battery_watch_file;
} vsyswatch_ctx_t;

#endif /* ! ifndef VSYSWATCH_VSYSWATCH_H */

