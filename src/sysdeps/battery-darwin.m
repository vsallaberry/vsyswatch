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
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/time.h>
#include <unistd.h>
#include <notify.h>
#include <signal.h>
#include <pthread.h>

#include "vsyswatch.h"

#define SIG_SPECIAL_VALUE   0
#define SIG_KILL_THREAD     SIGUSR1

typedef struct {
    pthread_t       tid;
    void            (*callback)(battery_info_t *, void *);
    void *          callback_data;
    battery_info_t  info;
} battery_data_t;

static void *           battery_notify(void * data);
static pthread_mutex_t  mutex = PTHREAD_MUTEX_INITIALIZER;

void vsyswatch_battery_stop(vsyswatch_ctx_t * ctx) {
    if (ctx && ctx->battery) {
        battery_data_t * battery = (battery_data_t *) ctx->battery;
        pthread_mutex_lock(&mutex);
        pthread_kill(battery->tid, SIG_KILL_THREAD);
        pthread_join(battery->tid, NULL);
        pthread_mutex_unlock(&mutex);
        ctx->battery = NULL;
        free(battery);
    }
}

int vsyswatch_battery(vsyswatch_ctx_t * ctx, void (*callback)(battery_info_t*,void*), void * callback_data) {
    if (ctx == NULL) {
        fprintf(stderr, "%s(): error ctx NULL\n", __func__);
        return -1;
    }
    if (ctx->battery) {
        fprintf(stderr, "%s(): error battery watcher is already started\n", __func__);
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

static int register_events(vsyswatch_ctx_t * ctx, int * nf, battery_state_t * old_state,
                           int * ev_power_source, int * ev_low_battery, int * ev_time_remaining) {

    const struct { const char * ev; int * tok; int flags; } *cur_ev, evs[] = {
        { kIOPSNotifyPowerSource,   ev_power_source,   (1 << BS_AC) },
        { kIOPSNotifyTimeRemaining, ev_time_remaining, (1 << BS_BAT_LOW) | (1 << BS_BAT_OK) },
        { kIOPSNotifyLowBattery,    ev_low_battery,    (1 << BS_NONE) },
        { NULL, NULL, 0 }
    };
    battery_data_t * battery = ctx ? (battery_data_t *) ctx->battery : NULL;
    int status;

    if (!battery) {
        return -1;
    }

    int notify_flags = (*nf == -1) ? 0 : NOTIFY_REUSE;

    if (old_state && *old_state != battery->info.state) {
        for (cur_ev = evs; cur_ev && cur_ev->ev; cur_ev++) {
            if ((cur_ev->flags & (1 << battery->info.state)) != 0 && (cur_ev->flags & (1 << *old_state)) == 0) {
                status = notify_register_file_descriptor(cur_ev->ev, nf, notify_flags, cur_ev->tok);
                if (status != NOTIFY_STATUS_OK) {
                    fprintf(stderr, "%s(): notify registration failed (%u) for %s\n", __func__, status, cur_ev->ev);
                } else {
                    verbose(ctx, stderr, "%s(): %s: REGISTERED (tok=%d).\n", __func__, cur_ev->ev, *cur_ev->tok);
                }
            }
        }
        for (cur_ev = evs; cur_ev && cur_ev->ev; cur_ev++) {
            if ((cur_ev->flags & (1 << battery->info.state)) == 0 && *cur_ev->tok != -1) {
                notify_cancel(*cur_ev->tok);
                *cur_ev->tok = -1;
                verbose(ctx, stderr, "%s(): %s: unregistered.\n", __func__, cur_ev->ev);
            }
        }
        *old_state = battery->info.state;
    }
    return (*nf >= 0) ? 0 : -1;
}


static void sig_handler(int sig, siginfo_t * sig_info,  void * data) {
    /* list of registered threads */
    static struct threadlist_s {
        pthread_t tid; volatile sig_atomic_t * running; struct threadlist_s * next;
    } *         threadlist = NULL;
    pthread_t   tself = pthread_self();

    if (sig != SIG_SPECIAL_VALUE) {
        if (sig_info && sig_info->si_pid == getpid()) {
            /* looking for tid in threadlist and update running if found, then delete entry */
            for (struct threadlist_s * prev = NULL, * cur = threadlist; cur; prev = cur, cur = cur->next) {
                if (tself == cur->tid && cur->running) {
                    *cur->running = 0;
                    if (prev == NULL)
                        threadlist = cur->next;
                    else
                        prev->next = cur->next;
                    free(cur);
                    break ;
                }
            }
        }
        return ;
    }
    /* following is not a signal */
    sigset_t block, save;
    sigemptyset(&block);
    sigaddset(&block, SIG_KILL_THREAD);
    pthread_sigmask(SIG_BLOCK, &block, &save);
    pthread_mutex_lock(&mutex);
    /* special mode to delete threadlist, but if thread exited normally this should not be necessary */
    if (sig == SIG_SPECIAL_VALUE && sig_info == NULL && data == NULL) {
        fprintf(stderr, "%s(): flag_sig_handler deleting all\n", __func__);
        for (struct threadlist_s * cur = threadlist; cur; ) {
            struct threadlist_s * to_delete = cur;
            cur = cur->next;
            free(to_delete);
        }
        threadlist = NULL;
    } else {
        /* if this is reached we register the data as running ptr for pthread_self() */
        fprintf(stderr, "%s(): flag_sig_handler registering thread %lu\n", __func__, (unsigned long)tself);
        struct threadlist_s * new = malloc(sizeof(struct threadlist_s));
        if (new) {
            new->tid = tself;
            new->running = data;
            new->next = threadlist;
            threadlist = new;
        } else {
            fprintf(stderr, "%s(): flag_sig_handler: malloc threadlist error: %s\n", __func__, strerror(errno));
        }
    }
    pthread_mutex_unlock(&mutex);
    pthread_sigmask(SIG_SETMASK, &save, NULL);
}

static void print_battery_dict(const void * key, const void * value, void * context) {
    vsyswatch_ctx_t * ctx = (vsyswatch_ctx_t *) context;
    char buffer1[128];
    char buffer2[128];
    (void) ctx;

    CFStringRef value_desc = CFCopyDescription(value);
    CFStringGetCString(key, buffer1, sizeof(buffer1), kCFStringEncodingASCII);
    CFStringGetCString(value_desc, buffer2, sizeof(buffer2), kCFStringEncodingASCII);
    fprintf(stderr, "KEY <%s> = <%s>\n", buffer1, buffer2);

    if (value_desc)
        CFRelease(value_desc);
}

static int get_battery_info(vsyswatch_ctx_t * ctx) {
    battery_data_t * battery = ctx ? (battery_data_t *) ctx->battery : NULL;
    CFTypeRef binfo;
    CFArrayRef barray = NULL;
    CFDictionaryRef bdict = NULL;
    CFTypeRef bsource = NULL;
    int max_capacity = 0;
    int current_capacity = 0;
    long time_remaining = 0;
    int debug = (ctx->flags & FLG_TEST) != 0;

    binfo = IOPSCopyPowerSourcesInfo();
    barray = IOPSCopyPowerSourcesList(binfo);

    if (battery && binfo && barray) {
        for (int i = 0; i < CFArrayGetCount(barray); i++) {
            const void * value;
            int n;
            long l;

            if (debug)
                fprintf(stderr, "\n ***** PowerSource #%i ******************************\n", i);

            bsource = CFArrayGetValueAtIndex(barray, i);
            if (CFGetTypeID(bsource) != CFDictionaryGetTypeID())
                continue ;

            bdict = IOPSGetPowerSourceDescription(binfo, bsource);

            if (CFDictionaryGetValueIfPresent(bdict, (__bridge CFStringRef) @kIOPSPowerSourceStateKey, &value)
            && CFStringGetTypeID() == CFGetTypeID(value)) {
                if (!CFStringCompare(value, (__bridge CFStringRef) @kIOPSACPowerValue, 0))
                    time_remaining = VSYSWATCH_BATTERY_INFINITE_TIME;
            }

            if (!CFDictionaryGetValueIfPresent(bdict, (__bridge CFStringRef) @kIOPSIsPresentKey, &value)
            || CFBooleanGetTypeID() != CFGetTypeID(value) || value != kCFBooleanTrue) {
                continue ;
            }

            if (CFDictionaryGetValueIfPresent(bdict, (__bridge CFStringRef) @kIOPSMaxCapacityKey, &value)
            && CFNumberGetTypeID() == CFGetTypeID(value)) {
                if (CFNumberGetValue(value, kCFNumberIntType, &n))
                    max_capacity += n;
            }
            if (CFDictionaryGetValueIfPresent(bdict, (__bridge CFStringRef) @kIOPSCurrentCapacityKey, &value)
            && CFNumberGetTypeID() == CFGetTypeID(value)) {
                if (CFNumberGetValue(value, kCFNumberIntType, &n))
                    current_capacity += n;
            }
            if (CFDictionaryGetValueIfPresent(bdict, (__bridge CFStringRef) @kIOPSTimeToEmptyKey, &value)
            && CFNumberGetTypeID() == CFGetTypeID(value)) {
                if (CFNumberGetValue(value, kCFNumberLongType, &l)) {
                    if (l < 0)
                        time_remaining = VSYSWATCH_BATTERY_UNKNOWN_TIME;
                    else if (time_remaining >= 0)
                        time_remaining += l;
                }
            }

            if (debug)
                CFDictionaryApplyFunction(bdict, print_battery_dict, NULL);
        }

        battery->info.percents = max_capacity ? ((current_capacity * 100) / max_capacity) : 0;
        battery->info.time_remaining = time_remaining;
        if (battery->info.time_remaining == VSYSWATCH_BATTERY_INFINITE_TIME) {
            battery->info.state = BS_AC;
        } else if (battery->info.time_remaining > ctx->battery_time_remaining_low
        && battery->info.percents > ctx->battery_percents_low) {
            battery->info.state = BS_BAT_OK;
        } else {
            battery->info.state = BS_BAT_LOW;
        }

        if (debug)
            fprintf(stderr, "CHARGE: %d%% remaining: %ld state %d\n",
                    battery->info.percents, time_remaining, battery->info.state);
    }

    if (binfo)
        CFRelease(binfo);
    if (barray)
        CFRelease(barray);

    return 0;
}

static void * battery_notify(void * data) {
    vsyswatch_ctx_t *   ctx = (vsyswatch_ctx_t *) data;
    battery_data_t *    battery = (battery_data_t *) ctx->battery;
    int                 nf = -1;
    int                 ev_low_battery = -1, ev_time_remaining = -1, ev_power_source = -1;
    fd_set              readfds, errfds;
    int                 t, ret;
    battery_info_t      battery_info_copy = { .state = BS_NONE, .time_remaining = LONG_MAX, .percents = CHAR_MAX };
    battery_state_t     old_state = BS_NONE;
    struct sigaction    sa = { .sa_sigaction = sig_handler, .sa_flags = SA_SIGINFO | SA_RESTART };
    volatile sig_atomic_t thread_running = 1;
    sigset_t            sigset;

    sigemptyset(&sigset);
    sigaddset(&sigset, SIG_KILL_THREAD);
    pthread_sigmask(SIG_BLOCK, &sigset, NULL);
    sigemptyset(&sigset);
    sigaddset(&sigset, SIGINT);

    /* call sig_handler to register this thread with thread_running ptr */
    if (sigaction(SIG_SPECIAL_VALUE, &sa, NULL) == 0) {
        fprintf(stderr, "%s(): error sigaction(%d) is accepted, "
                        "choose another value for SIG_SPECIAL_VALUE\n", __func__, SIG_SPECIAL_VALUE);
        return (void*) -1;
    }
    sig_handler(SIG_SPECIAL_VALUE, NULL, (void *) &thread_running);
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIG_KILL_THREAD, &sa, NULL) < 0) {
        fprintf(stderr, "%s(): error sigaction(%d): %s\n", __func__, SIG_KILL_THREAD, strerror(errno));
        return (void*) -1;
    }

    get_battery_info(ctx);

    /*CFRunLoopSourceRef IOPSNotificationCreateRunLoopSource(IOPowerSourceCallbackType callback, void *context);
     *                   IOPSCreateLimitedPowerNotification */

    if (register_events(ctx, &nf, &old_state, &ev_power_source, &ev_low_battery, &ev_time_remaining) != 0) {
        return (void *) -1;
    }

    if ((ctx->flags & FLG_TRIG_ON_START) != 0 && battery->callback) {
        memcpy(&battery_info_copy, &battery->info, sizeof(battery_info_t));
        battery->callback(&battery_info_copy, battery->callback_data);
    }

    while (thread_running) {
        FD_ZERO(&readfds);
        FD_ZERO(&errfds);
        FD_SET(nf, &readfds);
        FD_SET(nf, &errfds);
        ret = pselect(nf+1, &readfds, NULL, &errfds, NULL, &sigset);
        if (ret == 0) {
            verbose(ctx, stderr, "%s(): notify select timeout\n", __func__);
            continue ;
        }
        if (ret < 0 && errno == EINTR) {
            continue;
        }
        if (ret < 0) {
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

        get_battery_info(ctx);

        if (t == ev_low_battery) {
            const char * str = "";
            if ((ctx->flags & FLG_TEST) != 0) {
                IOPSLowBatteryWarningLevel battery_warning_level = IOPSGetBatteryWarningLevel();
                switch (battery_warning_level) {
                    case kIOPSLowBatteryWarningNone:
                        /*The system is not in a low battery situation, or is on drawing from an external power source.*/
                        str = " kIOPSLowBatteryWarningNone";
                        break ;
                    case kIOPSLowBatteryWarningEarly:
                        /* The system is in an early low battery situation.
                         * Per Apple's definition, the battery has dropped below 22% remaining power. */
                        str = " IOPSLowBatteryWarningEarly";
                        break ;
                    case kIOPSLowBatteryWarningFinal:
                        /* The battery can provide no more than 10 minutes of runtime. */
                        str = " kIOPSLowBatteryWarningFinal";
                        break ;
                    default:
                        str = " IOPSLowBatteryWarningLevel %d";
                        break ;
                }
            }
            verbose(ctx, stderr, "battery: EVENT lowbattery%s %ld remaining, percents %d%%, state %d\n",
                    str, battery->info.time_remaining, battery->info.percents, battery->info.state);
        } else if (t == ev_time_remaining) {
            if (battery->info.time_remaining == VSYSWATCH_BATTERY_UNKNOWN_TIME) {
                verbose(ctx, stderr, "battery: EVENT timeremaining kIOPSTimeRemainingUnknown "
                                     "%ld remaining, percents %d%%, state %d\n",
                        battery->info.time_remaining, battery->info.percents, battery->info.state);
            } else if (battery->info.time_remaining == VSYSWATCH_BATTERY_INFINITE_TIME) {
                verbose(ctx, stderr, "battery: EVENT timeremaining kIOPSTimeRemainingUnlimited "
                                     "%ld remaining, percents %d%%, state %d\n",
                        battery->info.time_remaining, battery->info.percents, battery->info.state);
            } else {
                verbose(ctx, stderr, "battery: EVENT timeremaining %ld, percents %d%%, state %d\n",
                        battery->info.time_remaining, battery->info.percents, battery->info.state);
            }
        } else if (t == ev_power_source) {
            /* @define      kIOPSNotifyPowerSource
             * C-string key for a notification of changes to the active power source.
             * Use this notification to discover when the active power source changes from AC power (unlimited/wall power),
             * to Battery Power or UPS Power (limited power). IOKit will not deliver this notification when a battery's
             * time remaining changes, only when the active power source changes. This makes it a more effiicent
             * choice for clients only interested in differentiating AC vs Battery.
             */
            if (battery->info.time_remaining == VSYSWATCH_BATTERY_UNKNOWN_TIME) {
                verbose(ctx, stderr, "battery: EVENT powersource kIOPSTimeRemainingUnknown "
                                     "%ld remaining, percents %d%%, state %d\n",
                        battery->info.time_remaining, battery->info.percents, battery->info.state);
            } else if (battery->info.time_remaining == VSYSWATCH_BATTERY_INFINITE_TIME) {
                verbose(ctx, stderr, "battery: EVENT powersource kIOPSTimeRemainingUnlimited "
                                     "%ld remaining, percents %d%%, state %d\n",
                        battery->info.time_remaining, battery->info.percents, battery->info.state);
            } else {
                verbose(ctx, stderr, "battery: EVENT powersource %ld remaining, percents %d%%, state %d\n",
                        battery->info.time_remaining, battery->info.percents, battery->info.state);
            }
        } else {
            fprintf(stderr, "battery: unknown EVENT (%d) %ld remaining, percents %d%%, state %d\n",
                    t, battery->info.time_remaining, battery->info.percents, battery->info.state);
        }

        if (battery->callback) {
            /* callback only if state change, or if data changes while the state is bs_bat_low */
            if ((battery->info.state != battery_info_copy.state || battery->info.state == BS_BAT_LOW)
            && memcmp(&battery->info, &battery_info_copy, sizeof(battery_info_t))) {
                memcpy(&battery_info_copy, &battery->info, sizeof(battery_info_t));
                battery->callback(&battery_info_copy, battery->callback_data);
            }
        }

        if (old_state != battery->info.state
        && register_events(ctx, &nf, &old_state, &ev_power_source, &ev_low_battery, &ev_time_remaining) != 0) {
            break ;
        }
        old_state = battery->info.state;

    }
    verbose(ctx, stderr, "battery: shutting down\n");
    notify_cancel(ev_low_battery);
    notify_cancel(ev_time_remaining);
    notify_cancel(ev_power_source);
    close(nf);
    return (void*) 0;
}

int vsyswatch_battery_test(vsyswatch_ctx_t * ctx) {
    (void) ctx;
    return 0;
}
