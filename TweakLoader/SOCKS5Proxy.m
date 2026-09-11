//
//  SOCKS5Proxy.m
//  Routes guest app TCP connections through a configured SOCKS5 proxy.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <pthread.h>
#import "../LiveContainer/utils.h"

#if __has_include("../litehook/src/litehook.h")
#include "../litehook/src/litehook.h"
#define HAS_LITEHOOK 1
#else
#define HAS_LITEHOOK 0
#endif

static BOOL gProxyEnabled = NO;
static char gProxyHost[256] = {0};
static int gProxyPort = 0;
static char gProxyUser[128] = {0};
static char gProxyPass[128] = {0};
static pthread_mutex_t gProxyLock = PTHREAD_MUTEX_INITIALIZER;

static int (*orig_connect)(int, const struct sockaddr *, socklen_t) = NULL;

static BOOL socks5_handshake(int fd, const struct sockaddr *dest, socklen_t destLen) {
    // Only IPv4/IPv6 TCP destinations
    if (dest->sa_family != AF_INET && dest->sa_family != AF_INET6) {
        return NO;
    }

    uint8_t buf[512];
    BOOL needAuth = (gProxyUser[0] != '\0');

    // greeting
    buf[0] = 0x05;
    if (needAuth) {
        buf[1] = 0x02;
        buf[2] = 0x00;
        buf[3] = 0x02;
        if (write(fd, buf, 4) != 4) return NO;
    } else {
        buf[1] = 0x01;
        buf[2] = 0x00;
        if (write(fd, buf, 3) != 3) return NO;
    }

    if (read(fd, buf, 2) != 2) return NO;
    if (buf[0] != 0x05) return NO;

    if (buf[1] == 0x02 && needAuth) {
        size_t ulen = strnlen(gProxyUser, 125);
        size_t plen = strnlen(gProxyPass, 125);
        size_t idx = 0;
        buf[idx++] = 0x01;
        buf[idx++] = (uint8_t)ulen;
        memcpy(buf + idx, gProxyUser, ulen); idx += ulen;
        buf[idx++] = (uint8_t)plen;
        memcpy(buf + idx, gProxyPass, plen); idx += plen;
        if (write(fd, buf, idx) != (ssize_t)idx) return NO;
        if (read(fd, buf, 2) != 2) return NO;
        if (buf[1] != 0x00) return NO;
    } else if (buf[1] != 0x00) {
        return NO;
    }

    // CONNECT request
    size_t idx = 0;
    buf[idx++] = 0x05;
    buf[idx++] = 0x01; // CONNECT
    buf[idx++] = 0x00;

    if (dest->sa_family == AF_INET) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)dest;
        buf[idx++] = 0x01; // IPv4
        memcpy(buf + idx, &sin->sin_addr, 4); idx += 4;
        memcpy(buf + idx, &sin->sin_port, 2); idx += 2;
    } else {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)dest;
        buf[idx++] = 0x04; // IPv6
        memcpy(buf + idx, &sin6->sin6_addr, 16); idx += 16;
        memcpy(buf + idx, &sin6->sin6_port, 2); idx += 2;
    }

    if (write(fd, buf, idx) != (ssize_t)idx) return NO;

    // response: ver, rep, rsv, atyp, bindaddr...
    if (read(fd, buf, 4) != 4) return NO;
    if (buf[0] != 0x05 || buf[1] != 0x00) return NO;

    uint8_t atyp = buf[3];
    size_t remain = 0;
    if (atyp == 0x01) remain = 4 + 2;
    else if (atyp == 0x04) remain = 16 + 2;
    else if (atyp == 0x03) {
        if (read(fd, buf, 1) != 1) return NO;
        remain = buf[0] + 2;
    } else {
        return NO;
    }
    while (remain > 0) {
        ssize_t n = read(fd, buf, remain > sizeof(buf) ? sizeof(buf) : remain);
        if (n <= 0) return NO;
        remain -= (size_t)n;
    }
    return YES;
}

static int proxy_connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    if (!gProxyEnabled || !orig_connect) {
        return orig_connect ? orig_connect(sockfd, addr, addrlen) : connect(sockfd, addr, addrlen);
    }

    // Don't proxy connections to the proxy itself
    if (addr->sa_family == AF_INET) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
        struct in_addr proxyAddr;
        if (inet_aton(gProxyHost, &proxyAddr) && proxyAddr.s_addr == sin->sin_addr.s_addr &&
            ntohs(sin->sin_port) == gProxyPort) {
            return orig_connect(sockfd, addr, addrlen);
        }
    }

    // Only TCP stream sockets
    int type = 0;
    socklen_t tlen = sizeof(type);
    if (getsockopt(sockfd, SOL_SOCKET, SO_TYPE, &type, &tlen) != 0 || type != SOCK_STREAM) {
        return orig_connect(sockfd, addr, addrlen);
    }

    // Resolve proxy host
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;
    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%d", gProxyPort);
    if (getaddrinfo(gProxyHost, portStr, &hints, &res) != 0 || !res) {
        errno = ECONNREFUSED;
        return -1;
    }

    int rc = orig_connect(sockfd, res->ai_addr, (socklen_t)res->ai_addrlen);
    freeaddrinfo(res);
    if (rc != 0) {
        return rc;
    }

    if (!socks5_handshake(sockfd, addr, addrlen)) {
        // leave socket connected-but-failed; close semantics left to caller
        errno = ECONNREFUSED;
        return -1;
    }
    return 0;
}

static void load_proxy_config(void) {
    @autoreleasepool {
        NSDictionary *containerInfo = NSUserDefaults.guestContainerInfo;
        NSString *proxyId = containerInfo[@"proxyId"];
        if (proxyId.length == 0) {
            // Also try reading from container home plist if available
            return;
        }

        NSUserDefaults *defaults = NSUserDefaults.lcSharedDefaults ?: NSUserDefaults.standardUserDefaults;
        NSData *data = [defaults dataForKey:@"LCProxies"];
        if (!data) {
            NSLog(@"[LiveProxy] No LCProxies data in shared defaults");
            return;
        }

        NSError *err = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (![json isKindOfClass:[NSArray class]]) {
            NSLog(@"[LiveProxy] Failed to parse LCProxies: %@", err);
            return;
        }

        for (NSDictionary *p in (NSArray *)json) {
            NSString *pid = [p[@"id"] description];
            // UUID may be encoded as string
            if (p[@"id"] && ![pid isEqualToString:proxyId]) {
                // try uppercase/lowercase match
                if ([pid caseInsensitiveCompare:proxyId] != NSOrderedSame) {
                    continue;
                }
            } else if (!p[@"id"]) {
                continue;
            }

            NSString *host = p[@"host"];
            NSNumber *port = p[@"port"];
            if (host.length == 0 || port == nil) continue;

            pthread_mutex_lock(&gProxyLock);
            strncpy(gProxyHost, host.UTF8String, sizeof(gProxyHost) - 1);
            gProxyPort = port.intValue;
            NSString *user = p[@"username"];
            NSString *pass = p[@"password"];
            if (user.length) strncpy(gProxyUser, user.UTF8String, sizeof(gProxyUser) - 1);
            if (pass.length) strncpy(gProxyPass, pass.UTF8String, sizeof(gProxyPass) - 1);
            gProxyEnabled = (gProxyHost[0] != '\0' && gProxyPort > 0);
            pthread_mutex_unlock(&gProxyLock);

            NSLog(@"[LiveProxy] SOCKS5 enabled -> %s:%d (auth=%d)", gProxyHost, gProxyPort, gProxyUser[0] != 0);
            return;
        }
        NSLog(@"[LiveProxy] proxyId %@ not found in LCProxies list", proxyId);
    }
}

static void install_connect_hook(void) {
#if HAS_LITEHOOK
    void *sym = dlsym(RTLD_DEFAULT, "connect");
    if (!sym) {
        NSLog(@"[LiveProxy] connect symbol not found");
        return;
    }
    orig_connect = (int (*)(int, const struct sockaddr *, socklen_t))sym;
    // Global rebind of connect in all images
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, sym, (void *)proxy_connect, NULL);
    NSLog(@"[LiveProxy] connect() hooked via litehook");
#else
    // Fallback: try fishhook-style not available — log only
    NSLog(@"[LiveProxy] litehook not available; SOCKS5 hook not installed");
#endif
}

__attribute__((constructor))
static void socks5_proxy_init(void) {
    // Delay slightly so NSUserDefaults category globals are ready
    // Guest container info is set before TweakLoader constructors for guest apps
    load_proxy_config();
    if (gProxyEnabled) {
        install_connect_hook();
    }
}
