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
#include <fcntl.h>
#include <unistd.h>
#include <sys/time.h>
#include <stdlib.h>
#include <stdio.h>
#include <signal.h>
#include <errno.h>
#include <string.h>

#include "vlib/options.h"
#include "vlib/util.h"

#include "version.h"
#include "vsyswatch.h"

int touch(const char * file) {
    int fd = open(file, O_CREAT | O_WRONLY | O_APPEND, S_IWUSR | S_IRUSR | S_IRGRP | S_IROTH);
    if (fd < 0) {
        fprintf(stderr, "error, '%s', %s\n", file, strerror(errno));
        return fd;
    }
    int ret = futimes(fd, NULL);
    if (ret < 0) {
        fprintf(stderr, "error, '%s', %s\n", file, strerror(errno));
    }
    close(fd);
    return ret;
}

void network_callback(netlist_t * netlist_elt, void * data) {
   vsyswatch_ctx_t * ctx = (vsyswatch_ctx_t *) data;

    if ((ctx->flags & FLG_PRINT_EVENT) != 0) {
        fprintf(stdout, "%-10s | name: %s | reachable: %d\n",
                "HOST", netlist_elt->host, netlist_elt->status);
        fflush(stdout);
    }
    if (ctx->network_watch_file)
        touch(ctx->network_watch_file);
}

void battery_callback(battery_info_t * info, void * data) {
    const char * state_strs[] = { "none", "ac", "bat_ok", "bat_low", "unknown" };
    vsyswatch_ctx_t * ctx = (vsyswatch_ctx_t *) data;
    if ((ctx->flags & FLG_PRINT_EVENT) != 0) {
        FILE * out = stdout;
        const char * str = NULL;
        const char * state_str = info->state >= 0 && info->state < sizeof(state_strs)/sizeof(*state_strs) - 1 ?
                        state_strs[info->state] : state_strs[sizeof(state_strs)/sizeof(*state_strs)-1];
        if (info->time_remaining == VSYSWATCH_BATTERY_UNKNOWN_TIME)
            str = "unknown";
        else if (info->time_remaining == VSYSWATCH_BATTERY_INFINITE_TIME)
            str = "unlimited";
        else if (info->time_remaining < 0)
            str = "bad_state";
        flockfile(out);
        fprintf(out, "%-10s | state: %s | time_remaining: ", "BATTERY", state_str);
        if (str)
            fprintf(out, "%s", str);
        else
            fprintf(out, "%ld", info->time_remaining);
        fprintf(out, " | percents: %d%%\n", info->percents);
        fflush(out);
        funlockfile(out);
    }
    if (ctx->battery_watch_file)
        touch(ctx->battery_watch_file);
}

void netlist_delete(netlist_t * netlist) {
    for (netlist_t * cur = netlist; cur; ) {
        netlist_t * to_delete = cur;
        cur = cur->next;
        free(to_delete);
    }
}

int netlist_addhost(const char * host, vsyswatch_ctx_t * ctx) {
    netlist_t * new;
    if ((new = calloc(1, sizeof(netlist_t))) == NULL) {
        fprintf(stderr, "warning: cannot malloc for host '%s'\n", host);
        return 1;
    }
    new->status = -1;
    new->next = ctx->netlist;
    new->host = host;
    ctx->netlist = new;
    return 0;
}

void vsyswatch_quit(int exit_status, vsyswatch_ctx_t * ctx) {
    netlist_delete(ctx->netlist);
    exit(exit_status);
}

static void sig_handler(int sig) {
    (void)sig;
}

int         vsyswatch_battery(vsyswatch_ctx_t * ctx, void(*)(battery_info_t*,void*), void *);
void        vsyswatch_battery_stop(vsyswatch_ctx_t * ctx);
int         vsyswatch_battery_test(vsyswatch_ctx_t * ctx);

/* temporary function renaming to avoid conflicts with sysdeps/network-default.c */
#define vsyswatch_network       vsyswatch_network_main
#define vsyswatch_network_stop  vsyswatch_network_stop_main
int         vsyswatch_network(vsyswatch_ctx_t * ctx, void (*callback)(netlist_t*,void*), void * callback_data);
void        vsyswatch_network_stop(vsyswatch_ctx_t * ctx);
int         vsyswatch_network_test(vsyswatch_ctx_t * ctx);

static int  test();

int main(int argc, const char *const* argv) { @autoreleasepool {
    vsyswatch_ctx_t             ctx = { .flags = FLG_NONE | FLG_PRINT_EVENT,
                                        .netlist = NULL, .battery = NULL, .file = NULL,
                                        .network_watch_file = NULL,
                                        .battery_watch_file = NULL,
                                        .battery_percents_low = 12,
                                        .battery_time_remaining_low = 15 };

    fprintf(stderr, "%s v%s git#%s (GPL v3 - Copyright (c) 2018-2019 Vincent Sallaberry)\n",
            BUILD_APPNAME, APP_VERSION, BUILD_GITREV);
    fflush(stderr);

    for (int i_argv = 1; i_argv < argc; i_argv++) {
        if (argv[i_argv][0] == '-') {
            for (const char * opt = argv[i_argv] + 1; *opt; opt++) {
                switch (*opt) {
                    case 'h': fprintf(stderr, "Usage: %s [-h] [-s] [-v] [-x] [-N netfile] [-B batfile]"
                                              " [-T] [host1[ host2[...]]]\n", *argv);
                              vsyswatch_quit(0, &ctx);
                              break;
                    case 's': vsyswatch_get_source(stdout, NULL, 0, NULL);
                              vlib_get_source(stdout, NULL, 0, NULL);
                              vsyswatch_quit(0, &ctx);
                              break ;
                    case 'x': ctx.flags |= FLG_TRIG_ON_START; break ;
                    case 'v': ctx.flags |= FLG_VERBOSE; break ;
                    case 'N': if (i_argv + 1 >= argc) {
                                fprintf(stderr, "error: missing argument for -N\n");
                                vsyswatch_quit(2, &ctx);
                              }
                              ctx.network_watch_file = argv[++i_argv];
                              break ;
                    case 'B': if (i_argv + 1 >= argc) {
                                fprintf(stderr, "error: missing argument for -B\n");
                                vsyswatch_quit(3, &ctx);
                              }
                              ctx.battery_watch_file = argv[++i_argv];
                              break ;
                    case 'T': ctx.flags |= FLG_TEST | FLG_VERBOSE; break ;
                    default: fprintf(stderr, "error: wrong option %c\n", *opt);
                             vsyswatch_quit(1, &ctx);
                             break ;
                }
            }
        } else {
            netlist_addhost(argv[i_argv], &ctx);
        }
    }

    if ((ctx.flags & FLG_TEST) != 0) {
        test();
    }

    /* launch battery watcher */
    vsyswatch_battery(&ctx, &battery_callback, &ctx);

    /* launch network watcher */
    vsyswatch_network(&ctx, &network_callback, &ctx);

    struct sigaction sa = { .sa_handler = sig_handler, .sa_flags = SA_RESTART };
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGINT, &sa, NULL) < 0) perror("sigaction(SIGINT)");
    if (sigaction(SIGTERM, &sa, NULL) < 0) perror("sigaction(SIGTERM)");
    fflush(stdout); fflush(stderr);

    /* wait for a signal */
    pause();

    /* stop watchers and clean resources */
    vsyswatch_network_stop(&ctx);
    vsyswatch_battery_stop(&ctx);
    netlist_delete(ctx.netlist);

    return 0;
} /*!autoreleasepool*/ }

int test(vsyswatch_ctx_t * ctx) {
    int nerr = 0;

    nerr += vsyswatch_network_test(ctx);
    nerr += vsyswatch_battery_test(ctx);

    return nerr;
}

/**************************************************
 * DARWIN SPECIFIC CODE
 **************************************************/

#import <CoreFoundation/CFRunLoop.h>
#import <SystemConfiguration/SCNetwork.h>
#import <SystemConfiguration/SCNetworkReachability.h>

#include <stdlib.h>
#include <stdio.h>
#include <arpa/inet.h>
#include <errno.h>
#include <string.h>

#include "vsyswatch.h"

/* darwin specific network element data */
typedef struct {
    SCNetworkReachabilityRef        net_ref;
    SCNetworkReachabilityContext    reachability_context;
} netlist_data_t;

/* data to be passed to darwin reachability callback */
typedef struct {
    vsyswatch_ctx_t *   ctx;
    netlist_t *         netlist_elt;
} reach_data_t;

/* darwin specic network data */
typedef struct {
    pthread_cond_t      wait_cond;
    pthread_mutex_t     wait_mutex;
    CFRunLoopRef        runloop;
    pthread_t           tid;
    void                (*callback)(netlist_t*,void*);
    void *              callback_data;
} network_t;

static CFRunLoopTimerRef    init_timer(CFRunLoopTimerContext * timer_context);
static void                 timer_callback(CFRunLoopTimerRef timer, void * data);

/* darwin conversion of reachability flags to generic network host status */
int is_reachable(SCNetworkReachabilityFlags net_flags) {
    return ((net_flags & kSCNetworkFlagsReachable) != 0);
}

void reachability_callback(SCNetworkReachabilityRef net_ref, SCNetworkReachabilityFlags net_flags, void * data) {
    reach_data_t *  reachdata = (reach_data_t *) data;
    netlist_t *     netlist_elt = reachdata ? reachdata->netlist_elt : NULL;
    network_t *     network = reachdata && reachdata->ctx ? reachdata->ctx->network : NULL;
    (void) net_ref;

    if (netlist_elt) {
        char status = is_reachable(net_flags);
        if ((reachdata->ctx->flags & FLG_VERBOSE) != 0) {
            fprintf(stderr, "%s(): host %s reachable:%d netflags:%d\n",
                            __func__, netlist_elt->host, status, net_flags);
        }
        if (status != netlist_elt->status) {
            if ((reachdata->ctx->flags & FLG_TEST) == 0) // in test mode, timer_callback will update cur->status
                netlist_elt->status = status;
            if (network && network->callback) {
                network->callback(netlist_elt, network->callback_data);
            }
        }
    }
}

void observer_callback(CFRunLoopObserverRef obs_ref, CFRunLoopActivity activity, void * info) {
    vsyswatch_ctx_t * ctx = (vsyswatch_ctx_t *) info;
    network_t * network = ctx ? (network_t *) ctx->network : NULL;
    (void) obs_ref;

    if (network) {
        if ((ctx->flags & FLG_VERBOSE) != 0) {
            const char * label = "CFRunLoop Unknown Activity";
            if (activity == kCFRunLoopEntry)        label = "CFRunLoop Entry";
            else if (activity == kCFRunLoopExit)    label = "CFRunLoop Exit";
            fprintf(stderr, "%s(): %s (%lu)\n", __func__, label, activity);
        }

        pthread_mutex_lock(&network->wait_mutex);
        if (activity == kCFRunLoopEntry) {
            /* runLoop started: we can update the runLoop reference, and inform thread creator that we are ready */
            network->runloop = CFRunLoopGetCurrent();
            pthread_cond_signal(&network->wait_cond);
        } else if (activity == kCFRunLoopExit) {
            /* runLoop is exiting: remove runloop ref to avoid sending CFRunLoopStop which may crash if not started */
            network->runloop = NULL;
        }
        pthread_mutex_unlock(&network->wait_mutex);
    }
}

void * network_thread(void * data) {
    vsyswatch_ctx_t *           ctx = (vsyswatch_ctx_t *) data;
    network_t *                 network = ctx ? (network_t *) ctx->network : NULL;
    long                        ret = 0;
    CFRunLoopObserverRef        obs_ref = NULL;
    CFRunLoopObserverContext    obs_context = { 0, ctx, NULL, NULL, NULL };
    CFRunLoopTimerRef           timer = NULL;
    CFRunLoopRef                runloop = CFRunLoopGetCurrent();

    if (ctx == NULL || network == NULL) {
        fprintf(stderr, "%s(): error: bad network context\n", __func__);
        return (void *) -1;
    }

    do {
        /* Add observer which will help knowing the state of CFRunLoop: Started ? Exited ? */
        if ((obs_ref = CFRunLoopObserverCreate(NULL, kCFRunLoopExit|kCFRunLoopEntry,
                                               TRUE, 0, observer_callback, &obs_context)) == NULL) {
            fprintf(stderr, "error CFRunLoopObserverCreate()\n");
            ret = -1;
            break ;
        }
        CFRunLoopAddObserver(runloop, obs_ref, kCFRunLoopDefaultMode);

        /* Create Reachability ref for each host */
        for (netlist_t * cur = ctx->netlist; cur; cur = cur->next) {
            netlist_data_t *    data;
            reach_data_t *      reachdata;

            if ((data = calloc(1, sizeof(netlist_data_t))) == NULL) {
                fprintf(stderr, "error: cannot malloc netlist specific data: %s\n", strerror(errno));
                ret = -1;
                break ;
            }
            cur->specific = data;

            if ((reachdata = calloc(1, sizeof(reach_data_t))) == NULL) {
                fprintf(stderr, "error: cannot malloc netlist callback data: %s\n", strerror(errno));
                ret = -1;
                break ;
            }
            reachdata->ctx = ctx;
            reachdata->netlist_elt = cur;
            data->reachability_context.info = reachdata;

            if (!(data->net_ref = SCNetworkReachabilityCreateWithName(NULL, cur->host))) {
                fprintf(stderr, "warning: cannot create net_ref for '%s'\n", cur->host);
            } else {
                SCNetworkReachabilityFlags net_flags;
                if (SCNetworkReachabilityGetFlags(data->net_ref, &net_flags)) {
                    if ((ctx->flags & FLG_TRIG_ON_START) != 0) {
                        reachability_callback(data->net_ref, net_flags, data->reachability_context.info);
                    } else {
                        cur->status = is_reachable(net_flags);
                        if ((ctx->flags & FLG_VERBOSE) != 0) {
                            fprintf(stderr, "+ watching '%s' (reachable=%d, net_flags=%d)\n",
                                    cur->host, cur->status, net_flags);
                        }
                    }
                } else if ((ctx->flags & FLG_VERBOSE) != 0) {
                    fprintf(stderr, "+ watching '%s' (SCNetworkReachabilityGetFlags FAILED)\n", cur->host);
                }
                if (!SCNetworkReachabilitySetCallback(data->net_ref, reachability_callback, &data->reachability_context)) {
                    fprintf(stderr, "error SCNetworkReachabilitySetCallback(%s)\n", cur->host);
                }
                if (!SCNetworkReachabilityScheduleWithRunLoop(data->net_ref, runloop, kCFRunLoopDefaultMode)) {
                    fprintf(stderr, "error SCNetworkReachabilityScheduleWithRunLoop(%s)\n", cur->host);
                }
            }
        }
        if (ret != 0)
            break ;

        CFRunLoopTimerContext timer_context = { 0, ctx, NULL, NULL, NULL /*nul?*/};
        if ((ctx->flags & FLG_TEST) != 0) {
            timer = init_timer(&timer_context);
            if (!timer)
                fprintf(stderr, "error: Create CFRunLoopTimer FAILED\n");
        }
    } while (0);

    /* run the CFRunLoop if no errors before */
    if (ret == 0) {
        CFRunLoopRun();
    }

    /* Inform thread creator that it is ready, in case Observer has not done it */
    if ((ctx->flags & FLG_VERBOSE) != 0)
        fprintf(stderr, "network: shutting down\n");
    pthread_mutex_lock(&network->wait_mutex);
    pthread_cond_signal(&network->wait_cond);
    pthread_mutex_unlock(&network->wait_mutex);

    if (obs_ref)
        CFRelease(obs_ref);
    if (timer)
        CFRelease(timer);

    return (void *) ret;
}

int vsyswatch_network(vsyswatch_ctx_t * ctx, void (*callback)(netlist_t*,void*), void * callback_data) {
    network_t * network;
    int ret = -1;

    if (ctx == NULL) {
        fprintf(stderr, "%s(): error: bad context\n", __func__);
        return ret;
    }
    if (ctx->network != NULL) {
        fprintf(stderr, "error: network watcher is already started\n");
        return ret;
    }
    if ((network = calloc(1, sizeof(network_t))) == NULL) {
        fprintf(stderr, "error: cannot malloc network data: %s\n", strerror(errno));
        return ret;
    }

    ctx->network = network;
    network->callback = callback;
    network->callback_data = callback_data;
    pthread_mutex_init(&network->wait_mutex, NULL);
    pthread_cond_init(&network->wait_cond, NULL);

    pthread_mutex_lock(&network->wait_mutex);
    network->runloop = NULL;
    if (pthread_create(&network->tid, NULL, &network_thread, ctx) == 0) {
        /* wait RunLoop is ready so that it updates network->runloop reference */
        pthread_cond_wait(&network->wait_cond, &network->wait_mutex);
        ret = network->runloop != NULL ? 0 : -1;
    }
    pthread_mutex_unlock(&network->wait_mutex);
    return ret;
}

void vsyswatch_network_stop(vsyswatch_ctx_t * ctx) {
    if (ctx && ctx->network) {
        network_t * network = (network_t *) ctx->network;

        /* Stop CFRunLoop (if started) */
        pthread_mutex_lock(&network->wait_mutex);
        if (network->runloop)
            CFRunLoopStop(network->runloop);
        pthread_mutex_unlock(&network->wait_mutex);

        /* wait for end of thread execution */
        pthread_join(network->tid, NULL);

        /* clean resources (clean netlist specific, other is reponsibility of function main()) */
        pthread_cond_destroy(&network->wait_cond);
        pthread_mutex_destroy(&network->wait_mutex);
        for (netlist_t * cur = ctx->netlist; cur; cur = cur->next) {
            netlist_data_t * data = (netlist_data_t *) cur->specific;
            if (data) {
                if (data->reachability_context.info)
                    free(data->reachability_context.info);
                CFRelease(data->net_ref);
                free(data);
            }
        }
        free(network);
    }
}

static void timer_callback(CFRunLoopTimerRef timer, void * data) {
    (void)timer;
    SCNetworkConnectionFlags    net_flags;
    vsyswatch_ctx_t *           ctx = (vsyswatch_ctx_t *) data;
    network_t *                 network = ctx ? ctx->network : NULL;
    netlist_t *                 netlist = ctx->netlist;
    int                         newline = 0;
    char                        status;
    for (netlist_t * cur = netlist; cur; cur = cur->next) {
        netlist_data_t * data = cur->specific;
        if (data && data->net_ref && SCNetworkReachabilityGetFlags(data->net_ref, &net_flags)
        && (status = is_reachable(net_flags)) != cur->status) {
            if (!newline) { putc('\n', stderr); newline = 1; }
            cur->status = status;
            fprintf(stderr, "Timer: host '%s' reachability changed to %d\n", cur->host, cur->status);
            if (network && network->callback) {
                network->callback(cur, network->callback_data);
            }
        }
    }

    putc('.', stderr);
    fflush(stderr);
}

static CFRunLoopTimerRef init_timer(CFRunLoopTimerContext * context) {
    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(kCFAllocatorDefault, 0.1 /*firedate_s*/, 1 /*interval_s*/,
                                                   0, 0, &timer_callback, context);
    CFRunLoopAddTimer(runLoop, timer, kCFRunLoopCommonModes);
    return timer;
}

int vsyswatch_network_test(vsyswatch_ctx_t * ctx) {
    (void) ctx;
    SCNetworkReachabilityRef    net_ref;
    SCNetworkReachabilityFlags  net_flags;
    Boolean                     ok;
    const char *                host;

    //***
    host = "localhost";
    net_flags = 0;
    if ((net_ref = SCNetworkReachabilityCreateWithName(NULL, host))) {
        ok = SCNetworkReachabilityGetFlags(net_ref, &net_flags);
        fprintf(stderr, "CreateWithName(%s) ok=%d, net_flags=%d, reach=%d\n",
               host, ok, net_flags, (net_flags & kSCNetworkFlagsReachable) != 0);
        CFRelease(net_ref);
    } else {
        fprintf(stderr, "CreateWithName(%s) FAILED\n", host);
    }

    //***
    host = "github.com";
    net_flags = 0;
    if ((net_ref = SCNetworkReachabilityCreateWithName(NULL, host))) {
        ok = SCNetworkReachabilityGetFlags(net_ref, &net_flags);
        fprintf(stderr, "CreateWithName(%s) ok=%d, net_flags=%d, reach=%d\n",
               host, ok, net_flags, (net_flags & kSCNetworkFlagsReachable) != 0);
        CFRelease(net_ref);
    } else {
        fprintf(stderr, "CreateWithName(%s) FAILED\n", host);
    }

    //***
    host = "127.0.0.1";
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    inet_pton(addr.sin_family, host, &addr.sin_addr);

    net_flags = 0;
    if ((net_ref = SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *) &addr))) {
        ok = SCNetworkReachabilityGetFlags(net_ref, &net_flags);
        fprintf(stderr, "CreateWithAddress(%s) ok=%d, net_flags=%d, reach=%d\n",
               host, ok, net_flags, (net_flags & kSCNetworkFlagsReachable) != 0);
        CFRelease(net_ref);
    } else {
        fprintf(stderr, "CreateWithAddress(%s) FAILED\n", host);
    }

    //***
    host = "192.168.0.1";
    net_flags = 0;
    if ((net_ref = SCNetworkReachabilityCreateWithName(NULL, host))) {
        ok = SCNetworkReachabilityGetFlags(net_ref, &net_flags);
        fprintf(stderr, "CreateWithName(%s) ok=%d, net_flags=%d, reach=%d\n",
               host, ok, net_flags, (net_flags & kSCNetworkFlagsReachable) != 0);
        CFRelease(net_ref);
    }  else {
        fprintf(stderr, "CreateWithName(%s) FAILED\n", host);
    }
    return 0;
}

#ifndef APP_INCLUDE_SOURCE
# define APP_NO_SOURCE_STRING "\n/* #@@# FILE #@@# " BUILD_APPNAME "/* */\n" \
                              BUILD_APPNAME " source not included in this build.\n"
int vsyswatch_get_source(FILE * out, char * buffer, unsigned int buffer_size, void ** ctx) {
    return vdecode_buffer(out, buffer, buffer_size, ctx,
            APP_NO_SOURCE_STRING, sizeof(APP_NO_SOURCE_STRING) - 1);
}
#endif

