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
        close(battery->notify_fd);
        pthread_join(battery->tid, NULL);
        free(battery);
        ctx->battery = NULL;
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
    battery_data_t * battery = malloc(sizeof(battery_data_t));
    ctx->battery = battery;
    battery->callback = callback;
    battery->callback_data = callback_data;
    if (battery == NULL) {
        perror("malloc");
        return -1;
    }
    return pthread_create(&battery->tid, NULL, battery_notify, ctx);
}

static void * battery_notify(void * data) {
    vsyswatch_ctx_t *   ctx = (vsyswatch_ctx_t *) data;
    battery_data_t *    battery = (battery_data_t *) ctx->battery;
    int                 status;
    int                 nf, low_battery, time_remaining = -1, power_source = -1, t, ret;
    int                 battery_warning_level = IOPSGetBatteryWarningLevel();
    fd_set              readfds, errfds;

    status = notify_register_file_descriptor(kIOPSNotifyLowBattery,
            &nf, 0, &low_battery);
    if (status != NOTIFY_STATUS_OK)
    {
        fprintf(stderr, "%s(): notify registration failed (%u) for %s\n", __func__, status, kIOPSNotifyLowBattery);
        return (void *) -1;
    }
    battery->notify_fd = nf;

    /* status = notify_register_file_descriptor(kIOPSNotifyTimeRemaining,
            &nf, NOTIFY_REUSE, &time_remaining);
    if (status != NOTIFY_STATUS_OK)
    {
        fprintf(stderr, "notify registration failed (%u) for %s\n", status, kIOPSNotifyTimeRemaining);
        exit(status);
    }

    status = notify_register_file_descriptor(kIOPSNotifyPowerSource,
            &nf, NOTIFY_REUSE, &power_source);
    if (status != NOTIFY_STATUS_OK)
    {
        fprintf(stderr, "notify registration failed (%u) for %s\n", status, kIOPSNotifyPowerSource);
        exit(status);
    } */

    while (1) {
        FD_ZERO(&readfds);
        FD_ZERO(&errfds);
        FD_SET(nf, &readfds);
        FD_SET(nf, &errfds);

        ret = select(nf+1, &readfds, NULL, &errfds, NULL);
        if (ret == 0) {
            fprintf(stdout, "%s(): notify closed\n", __func__);
            break ;
        }
        if (ret < 0 && errno == EINTR)
            continue;
        if (ret < 0) {
            fprintf(stdout, "%s(): notify select error\n", __func__);
            break ;
        }
        if (FD_ISSET(nf, &errfds) || !FD_ISSET(nf, &readfds)) {
            fprintf(stdout, "%s(): notify other error\n", __func__);
            break ;
        }

        status = read(nf, &t, sizeof(int));
        if (status < 0) {
            perror("notify read");
            break;
        }

        t = ntohl(t);

        if (t == low_battery) {
            battery_warning_level = IOPSGetBatteryWarningLevel();
            switch (battery_warning_level) {
                case kIOPSLowBatteryWarningNone:
                /*The system is not in a low battery situation, or is on drawing from an external power source.*/
                    printf("battery: level kIOPSLowBatteryWarningNone\n");
                    if (battery->callback)
                        battery->callback((void*)0, battery->callback_data);
                    break ;
                case kIOPSLowBatteryWarningEarly:
                    /* The system is in an early low battery situation.
                     * Per Apple's definition, the battery has dropped below 22% remaining power. */
                    printf("battery: level IOPSLowBatteryWarningEarly\n");
                    if (battery->callback)
                        battery->callback((void*)1, battery->callback_data);
                    break ;
                case kIOPSLowBatteryWarningFinal:
                    /* The battery can provide no more than 10 minutes of runtime. */
                    printf("battery: level kIOPSLowBatteryWarningFinal\n");
                    if (battery->callback)
                        battery->callback((void*)2, battery->callback_data);
                    break ;
                default:
                    printf("battery: level IOPSLowBatteryWarningLevel %d\n", t);
                    break ;
            }
        } else if (t == time_remaining) {
            CFTimeInterval time = IOPSGetTimeRemainingEstimate();
            if (time == kIOPSTimeRemainingUnknown) {
                printf("battery: time kIOPSTimeRemainingUnknown\n");
            } else if (time == kIOPSTimeRemainingUnlimited) {
                printf("battery: time kIOPSTimeRemainingUnlimited\n");
            } else {
                printf("battery: time %lf remaining\n", time);
            }
        } else if (t == power_source) {
            /* @define      kIOPSNotifyPowerSource
             * C-string key for a notification of changes to the active power source.
             * Use this notification to discover when the active power source changes from AC power (unlimited/wall power),
             * to Battery Power or UPS Power (limited power). IOKit will not deliver this notification when a battery's
             * time remaining changes, only when the active power source changes. This makes it a more effiicent
             * choice for clients only interested in differentiating AC vs Battery.
             */
            CFTimeInterval time = IOPSGetTimeRemainingEstimate();
            if (time == kIOPSTimeRemainingUnknown) {
                printf("battery: power_source kIOPSTimeRemainingUnknown\n");
            } else if (time == kIOPSTimeRemainingUnlimited) {
                printf("battery: power_source kIOPSTimeRemainingUnlimited\n");
            } else {
                printf("battery: power_source %lf remaining\n", time);
            }
        } else {
            printf("battery: unknown power notification (%d)\n", t);
        }
        fflush(stdout); fflush(stderr);
    }

    fprintf(stdout, "battery: shutting down\n");
    notify_cancel(low_battery);
    notify_cancel(time_remaining);
    notify_cancel(power_source);
    close(nf);
    return (void*) 0;
}

