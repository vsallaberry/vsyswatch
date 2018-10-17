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
#import <IOKit/IOKitLib.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/ps/IOPowerSources.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/time.h>
#include <unistd.h>
#include <notify.h>
#include <pthread.h>

#include "vsyswatch.h"

typedef struct {
    pthread_t       tid;
    int             notify_fd;
    void            (*callback)(void *, void *);
    void *          callback_data;
} battery_data_t;

static void * battery_notify(void * data);

void vsyswatch_battery_stop(vsyswatch_ctx_t * ctx) {
    if (ctx && ctx->battery) {
        battery_data_t * battery = (battery_data_t *) ctx->battery;
        int fd = battery->notify_fd;
        battery->notify_fd = -1;
        close(fd);
        pthread_join(battery->tid, NULL);
        ctx->battery = NULL;
        free(battery);
    }
}

int vsyswatch_battery(vsyswatch_ctx_t * ctx, void (*callback)(void*,void*), void * callback_data) {
    if (ctx == NULL) {
        fprintf(stderr, "%s(): error ctx NULL\n", __func__);
        return -1;
    }
    if (ctx->battery) {
        fprintf(stderr, "%s(): error battery is already watched\n", __func__);
        return -1;
    }
    battery_data_t * battery = calloc(1, sizeof(battery_data_t));
    ctx->battery = battery;
    if (battery == NULL) {
        fprintf(stderr, "%s(): malloc error: %s\n", __func__, strerror(errno));
        return -1;
    }
    battery->callback = callback;
    battery->callback_data = callback_data;
    battery->notify_fd = -1;

    return pthread_create(&battery->tid, NULL, battery_notify, ctx);
}

static int verbose(vsyswatch_ctx_t * ctx, FILE * file, const char * fmt, ...) {
    if (ctx && file && fmt && (ctx->flags & FLG_VERBOSE) != 0) {
        va_list valist;
        int ret;

        va_start(valist, fmt);
        ret = vfprintf(file, fmt, valist);
        va_end(valist);

        return ret;
    }
    return 0;
}

enum { EV_NONE = 0, EV_AC = 1 << 0, EV_BAT_OK = 1 << 1, EV_BAT_LOW = 1 << 2 };

int register_events(vsyswatch_ctx_t * ctx,
                    int * nf, int * ev_power_source, int * ev_low_battery, int * ev_time_remaining,
                    int battery_warning_level, CFTimeInterval time_remaining, int * state) {

    const struct { const char * ev; int * tok; int flags; } *cur_ev, evs[] = {
        { kIOPSNotifyPowerSource,   ev_power_source,   EV_AC },
        { kIOPSNotifyTimeRemaining, ev_time_remaining, EV_BAT_LOW },
        { kIOPSNotifyLowBattery,    ev_low_battery,    EV_BAT_OK },
        { NULL, NULL, 0 }
    };
    int new_state;
    int status;

    if (time_remaining == kIOPSTimeRemainingUnlimited) {
        new_state = EV_AC;
    } else if (battery_warning_level == kIOPSLowBatteryWarningNone) {
        new_state = EV_BAT_OK;
    } else {
        new_state = EV_BAT_LOW;
    }

    if (new_state != *state) {
        int notify_flags = (*nf == -1) ? 0 : NOTIFY_REUSE;

        for (cur_ev = evs; cur_ev && cur_ev->ev; cur_ev++) {
            if ((cur_ev->flags & new_state) != 0) {
                status = notify_register_file_descriptor(cur_ev->ev, nf, notify_flags, cur_ev->tok);
                if (status != NOTIFY_STATUS_OK) {
                    fprintf(stderr, "%s(): notify registration failed (%u) for %s\n", __func__, status, cur_ev->ev);
                } else {
                    verbose(ctx, stderr, "%s(): %s: REGISTERED (tok=%d).\n", __func__, cur_ev->ev, *cur_ev->tok);
                }
            }
        }
        for (cur_ev = evs; cur_ev && cur_ev->ev; cur_ev++) {
            if ((cur_ev->flags & new_state) == 0 && *cur_ev->tok != -1) {
                notify_cancel(*cur_ev->tok);
                *cur_ev->tok = -1;
                verbose(ctx, stderr, "%s(): %s: unregistered.\n", __func__, cur_ev->ev);
            }
        }

        *state = new_state;
    }
    return (*nf >= 0) ? 0 : -1;
}

static void * battery_notify(void * data) {
    vsyswatch_ctx_t *   ctx = (vsyswatch_ctx_t *) data;
    battery_data_t *    battery = (battery_data_t *) ctx->battery;
    int                 nf = -1, state = EV_NONE;
    int                 ev_low_battery = -1, ev_time_remaining = -1, ev_power_source = -1;
    fd_set              readfds, errfds;
    int                 t, ret;
    CFTimeInterval      time_remaining;
    int                 battery_warning_level;

    time_remaining = IOPSGetTimeRemainingEstimate();
    battery_warning_level = IOPSGetBatteryWarningLevel();
    if (register_events(ctx, &nf, &ev_power_source, &ev_low_battery, &ev_time_remaining,
                        battery_warning_level, time_remaining, &state) != 0) {
        return (void *) -1;
    }
    battery->notify_fd = nf;

    if ((ctx->flags & FLG_TRIG_ON_START) != 0 && battery->callback) {
        long l;
        if (time_remaining == kIOPSTimeRemainingUnknown) l = -4;
        else if (time_remaining == kIOPSTimeRemainingUnlimited) l = -5;
        else l = (long)(time_remaining);
        battery->callback((void*) l, battery->callback_data);
    }

    while (1) {
        FD_ZERO(&readfds);
        FD_ZERO(&errfds);
        FD_SET(nf, &readfds);
        FD_SET(nf, &errfds);
        ret = select(nf+1, &readfds, NULL, &errfds, NULL);
        if (ret == 0) {
            verbose(ctx, stderr, "%s(): notify select timeout\n", __func__);
            continue ;
        }
        if (ret < 0 && errno == EINTR)
            continue;
        if (ret < 0) {
            if (battery->notify_fd >= 0)
                fprintf(stderr, "%s(): notify select error: %s\n", __func__, strerror(errno));
            break ;
        }
        if (FD_ISSET(nf, &errfds) || !FD_ISSET(nf, &readfds)) {
            fprintf(stderr, "%s(): notify other error\n", __func__);
            break ;
        }
        if (read(nf, &t, sizeof(int)) < 0) {
            fprintf(stderr, "%s(): notify read error: %s\n", __func__, strerror(errno));
            break;
        }
        t = ntohl(t);

        battery_warning_level = IOPSGetBatteryWarningLevel();
        time_remaining = IOPSGetTimeRemainingEstimate();

        if (t == ev_low_battery) {
            switch (battery_warning_level) {
                case kIOPSLowBatteryWarningNone:
                    /*The system is not in a low battery situation, or is on drawing from an external power source.*/
                    verbose(ctx, stderr, "battery: EVENT lowbattery kIOPSLowBatteryWarningNone\n");
                    if (battery->callback)
                        battery->callback((void*)-1, battery->callback_data);
                    break ;
                case kIOPSLowBatteryWarningEarly:
                    /* The system is in an early low battery situation.
                     * Per Apple's definition, the battery has dropped below 22% remaining power. */
                    verbose(ctx, stderr, "battery: EVENT lowbattery IOPSLowBatteryWarningEarly\n");
                    if (battery->callback)
                        battery->callback((void*)-2, battery->callback_data);
                    break ;
                case kIOPSLowBatteryWarningFinal:
                    /* The battery can provide no more than 10 minutes of runtime. */
                    verbose(ctx, stderr, "battery: EVENT lowbattery kIOPSLowBatteryWarningFinal\n");
                    if (battery->callback)
                        battery->callback((void*)-3, battery->callback_data);
                    break ;
                default:
                    verbose(ctx, stderr, "battery: EVENT lowbattery IOPSLowBatteryWarningLevel %d\n", t);
                    if (battery->callback)
                        battery->callback((void*)((long)time_remaining), battery->callback_data);
                    break ;
            }
        } else if (t == ev_time_remaining) {
            if (time_remaining == kIOPSTimeRemainingUnknown) {
                verbose(ctx, stderr, "battery: EVENT timeremaining kIOPSTimeRemainingUnknown\n");
                if (battery->callback)
                    battery->callback((void*)-4, battery->callback_data);
            } else if (time_remaining == kIOPSTimeRemainingUnlimited) {
                verbose(ctx, stderr, "battery: EVENT timeremaining kIOPSTimeRemainingUnlimited\n");
                if (battery->callback)
                    battery->callback((void*)-5, battery->callback_data);
            } else {
                verbose(ctx, stderr, "battery: EVENT timeremaining %lf remaining\n", time_remaining);
                if (battery->callback)
                    battery->callback((void*)((long)time_remaining), battery->callback_data);
            }
        } else if (t == ev_power_source) {
            /* @define      kIOPSNotifyPowerSource
             * C-string key for a notification of changes to the active power source.
             * Use this notification to discover when the active power source changes from AC power (unlimited/wall power),
             * to Battery Power or UPS Power (limited power). IOKit will not deliver this notification when a battery's
             * time remaining changes, only when the active power source changes. This makes it a more effiicent
             * choice for clients only interested in differentiating AC vs Battery.
             */
            if (time_remaining == kIOPSTimeRemainingUnknown) {
                verbose(ctx, stderr, "battery: EVENT powersource kIOPSTimeRemainingUnknown\n");
                if (battery->callback)
                    battery->callback((void*)-4, battery->callback_data);
            } else if (time_remaining == kIOPSTimeRemainingUnlimited) {
                verbose(ctx, stderr, "battery: EVENT powersource kIOPSTimeRemainingUnlimited\n");
                if (battery->callback)
                    battery->callback((void*)-5, battery->callback_data);
            } else {
                verbose(ctx, stderr, "battery: EVENT powersource %lf remaining\n", time_remaining);
                if (battery->callback)
                    battery->callback((void*)((long)time_remaining), battery->callback_data);
            }
        } else {
            fprintf(stderr, "battery: unknown EVENT (%d)\n", t);
        }

        if (register_events(ctx, &nf, &ev_power_source, &ev_low_battery, &ev_time_remaining,
                            battery_warning_level, time_remaining, &state) != 0) {
            break ;
        }
    }
    verbose(ctx, stderr, "battery: shutting down\n");
    notify_cancel(ev_low_battery);
    notify_cancel(ev_time_remaining);
    notify_cancel(ev_power_source);
    battery->notify_fd = -1;
    close(nf);
    return (void*) 0;
}

