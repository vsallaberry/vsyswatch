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
#include <stdio.h>

#include "vsyswatch.h"

void vsyswatch_network_stop(vsyswatch_ctx_t * ctx) {
    (void) ctx;
}

int vsyswatch_network(vsyswatch_ctx_t * ctx, void (*callback)(void*,void*), void * callback_data) {
    (void) ctx;
    (void) callback;
    (void) callback_data;

    fprintf(stderr, "warning, %s is not supported on this system\n", __func__);
    return -1;
}

