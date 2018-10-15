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
#import <SystemConfiguration/SCNetwork.h>
#import <SystemConfiguration/SCNetworkReachability.h>

#include <stdlib.h>
#include <stdio.h>
#include <arpa/inet.h>
#include <signal.h>

#include "version.h"

enum {
    FLG_NONE            = 0,
    FLG_DEBUG           = 1 << 0,
    FLG_TEST            = 1 << 1,
    FLG_TRIG_ON_START   = 1 << 2,
};

typedef struct netlist_s {
    const char *                    host;
    SCNetworkReachabilityRef        net_ref;
    char                            status;
    SCNetworkReachabilityContext    reachability_context;
    struct netlist_s *              next;
} netlist_t;

typedef struct {
    unsigned int    flags;
    netlist_t *     netlist;
} scnetwork_ctx_t;

typedef struct {
    scnetwork_ctx_t *   ctx;
    netlist_t *         netlist_elt;
} reach_data_t;

int is_reachable(SCNetworkReachabilityFlags net_flags) {
    return ((net_flags & kSCNetworkFlagsReachable) != 0);
}

void reachability_callback(SCNetworkReachabilityRef net_ref, SCNetworkReachabilityFlags net_flags, void * data) {
    reach_data_t *  reachdata = (reach_data_t *) data;
    netlist_t *     netlist_elt = reachdata->netlist_elt;
    (void) net_ref;

    if (netlist_elt) {
        char status = is_reachable(net_flags);
        if (status != netlist_elt->status) {
            if ((reachdata->ctx->flags & FLG_TEST) == 0) // in test mode, timer_callback will update cur->status
                netlist_elt->status = status;
            if ((reachdata->ctx->flags & FLG_DEBUG) != 0) {
                fprintf(stdout, "\n%s(): host '%s' reachable=%d net_flags=%d\n",
                        __func__, netlist_elt->host, status, net_flags);
                fflush(stdout);
            }
            system("touch /etc/resolv.conf");
        }
    }
}

void netlist_delete(netlist_t * netlist) {
    for (netlist_t * cur = netlist; cur; ) {
        netlist_t * to_delete = cur;
        cur = cur->next;
        if (to_delete->net_ref)
            CFRelease(to_delete->net_ref);
        if (to_delete->reachability_context.info) {
            free(to_delete->reachability_context.info);
        }
        free(to_delete);
    }
}

int netlist_addhost(const char * host, scnetwork_ctx_t * ctx) {
    netlist_t * new;
    if ((new = calloc(1, sizeof(netlist_t))) == NULL) {
        fprintf(stderr, "warning: cannot malloc for host '%s'\n", host);
        return 1;
    }
    new->status = -1;
    new->next = ctx->netlist;
    new->host = host;
    reach_data_t * reachdata = malloc(sizeof(reach_data_t));
    if (reachdata) {
        reachdata->ctx = ctx;
        reachdata->netlist_elt = new;
    }
    new->reachability_context.info = reachdata;
    ctx->netlist = new;
    return 0;
}

static CFRunLoopTimerRef    init_timer(CFRunLoopTimerContext * timer_context);
static void                 timer_callback(CFRunLoopTimerRef timer, void * data);
static int                  test();

static void sig_handler(int sig) {
    (void)sig;
    CFRunLoopStop(CFRunLoopGetCurrent());
    //[ CFRunLoopGetCurrent() stop];
}

int main(int argc, const char *const* argv) { @autoreleasepool {
    scnetwork_ctx_t             ctx = { .flags = FLG_NONE, .netlist = NULL };
    CFRunLoopTimerRef           timer = NULL;

    fprintf(stdout, "%s v%s git#%s (GPL v3 - Copyright (c) 2018 Vincent Sallaberry)\n",
            BUILD_APPNAME, APP_VERSION, BUILD_GITREV);
    fflush(stdout);

    for (int i_argv = 1; i_argv < argc; i_argv++) {
        if (argv[i_argv][0] == '-') {
            for (const char * opt = argv[i_argv] + 1; *opt; opt++) {
                switch (*opt) {
                    case 'h': fprintf(stdout, "Usage: %s [-h] [-s] [-d] [-x] [-T] host1[ host2[...]]\n", *argv);
                              netlist_delete(ctx.netlist);
                              exit(0); break;
                    case 's': for (const char *const* s = vsyswatch_get_source(); s && *s; s++) {
                                  fprintf(stdout, "%s\n", *s);
                              }
                              netlist_delete(ctx.netlist);
                              exit(0); break ;
                    case 'x': ctx.flags |= FLG_TRIG_ON_START; break ;
                    case 'd': ctx.flags |= FLG_DEBUG; break ;
                    case 'T': ctx.flags |= FLG_TEST | FLG_DEBUG; break ;
                    default: fprintf(stderr, "error: wrong option %c\n", *opt);
                             netlist_delete(ctx.netlist);
                             exit(1); break ;
                }
            }
        } else {
            netlist_addhost(argv[i_argv], &ctx);
        }
    }

    if (ctx.netlist == NULL && (ctx.flags & FLG_TEST) == 0) {
        fprintf(stderr, "error: no host given\n");
        exit(2);
    }

    if ((ctx.flags & FLG_TEST) != 0) {
        test();
    }

    for (netlist_t * cur = ctx.netlist; cur; cur = cur->next) {
        if (!(cur->net_ref = SCNetworkReachabilityCreateWithName(NULL, cur->host))) {
            fprintf(stderr, "warning: cannot create net_ref for '%s'\n", cur->host);
        } else {
            SCNetworkReachabilityFlags net_flags;
            if (SCNetworkReachabilityGetFlags(cur->net_ref, &net_flags)) {
                if ((ctx.flags & FLG_TRIG_ON_START) != 0) {
                    reachability_callback(cur->net_ref, net_flags, cur->reachability_context.info);
                } else {
                    cur->status = is_reachable(net_flags);
                    if ((ctx.flags & FLG_DEBUG) != 0) {
                        fprintf(stdout, "+ watching '%s' (reachable=%d, net_flags=%d)\n", cur->host, cur->status, net_flags);
                    }
                }
            } else if ((ctx.flags & FLG_DEBUG) != 0) {
                fprintf(stdout, "+ watching '%s' (SCNetworkReachabilityGetFlags FAILED)\n", cur->host);
            }
            if (!SCNetworkReachabilitySetCallback(cur->net_ref, &reachability_callback, &cur->reachability_context)) {
                fprintf(stderr, "error SCNetworkReachabilitySetCallback(%s)\n", cur->host);
            }
            if (!SCNetworkReachabilityScheduleWithRunLoop(cur->net_ref, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode)) {
                fprintf(stderr, "error SCNetworkReachabilityScheduleWithRunLoop(%s)\n", cur->host);
            }
        }
    }

    CFRunLoopTimerContext timer_context = { 0, &ctx, NULL, NULL, NULL };
    if ((ctx.flags & FLG_TEST) != 0) {
        timer = init_timer(&timer_context);
        if (!timer)
            fprintf(stderr, "error: Create CFRunLoopTimer FAILED\n");
    }

    struct sigaction sa = { .sa_handler = sig_handler, .sa_flags = SA_RESTART };
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGINT, &sa, NULL) < 0) perror("sigaction(SIGINT)");
    if (sigaction(SIGTERM, &sa, NULL) < 0) perror("sigaction(SIGTERM)");
    fflush(stdout); fflush(stderr);

    if (ctx.netlist)
        CFRunLoopRun();

    fprintf(stdout, "\nCFRunLoop FINISHED.\n");
    if (timer)
        CFRelease(timer);
    netlist_delete(ctx.netlist);
    return 0;
} /*!autoreleasepool*/ }

static void timer_callback(CFRunLoopTimerRef timer, void * data) {
    (void)timer;
    SCNetworkConnectionFlags    net_flags;
    scnetwork_ctx_t *           ctx = (scnetwork_ctx_t *) data;
    netlist_t *                 netlist = ctx->netlist;
    int                         newline = 0;
    char                        status;
    for (netlist_t * cur = netlist; cur; cur = cur->next) {
        if (cur->net_ref && SCNetworkReachabilityGetFlags(cur->net_ref, &net_flags)
        && (status = is_reachable(net_flags)) != cur->status) {
            if (!newline) { putc('\n', stdout); newline = 1; }
            cur->status = status;
            printf("Timer: host '%s' reachability changed to %d\n", cur->host, cur->status);
        }
    }

    putc('.', stdout);
    fflush(stdout);
}

static CFRunLoopTimerRef init_timer(CFRunLoopTimerContext * context) {
    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(kCFAllocatorDefault, 0.1 /*firedate_s*/, 1 /*interval_s*/,
                                                   0, 0, &timer_callback, context);
    CFRunLoopAddTimer(runLoop, timer, kCFRunLoopCommonModes);
    return timer;
}

static int test() {
    SCNetworkReachabilityRef    net_ref;
    SCNetworkReachabilityFlags  net_flags;
    Boolean                     ok;
    const char *                host;

    //***
    host = "localhost";
    net_flags = 0;
    if ((net_ref = SCNetworkReachabilityCreateWithName(NULL, host))) {
        ok = SCNetworkReachabilityGetFlags(net_ref, &net_flags);
        printf("CreateWithName(%s) ok=%d, net_flags=%d, reach=%d\n",
               host, ok, net_flags, (net_flags & kSCNetworkFlagsReachable) != 0);
        CFRelease(net_ref);
    } else {
        printf("CreateWithName(%s) FAILED\n", host);
    }

    //***
    host = "github.com";
    net_flags = 0;
    if ((net_ref = SCNetworkReachabilityCreateWithName(NULL, host))) {
        ok = SCNetworkReachabilityGetFlags(net_ref, &net_flags);
        printf("CreateWithName(%s) ok=%d, net_flags=%d, reach=%d\n",
               host, ok, net_flags, (net_flags & kSCNetworkFlagsReachable) != 0);
        CFRelease(net_ref);
    } else {
        printf("CreateWithName(%s) FAILED\n", host);
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
        printf("CreateWithAddress(%s) ok=%d, net_flags=%d, reach=%d\n",
               host, ok, net_flags, (net_flags & kSCNetworkFlagsReachable) != 0);
        CFRelease(net_ref);
    } else {
        printf("CreateWithAddress(%s) FAILED\n", host);
    }

    //***
    host = "192.168.0.1";
    net_flags = 0;
    if ((net_ref = SCNetworkReachabilityCreateWithName(NULL, host))) {
        ok = SCNetworkReachabilityGetFlags(net_ref, &net_flags);
        printf("CreateWithName(%s) ok=%d, net_flags=%d, reach=%d\n",
               host, ok, net_flags, (net_flags & kSCNetworkFlagsReachable) != 0);
        CFRelease(net_ref);
    }  else {
        printf("CreateWithName(%s) FAILED\n", host);
    }
    return 0;
}

