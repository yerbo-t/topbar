// Помощник «Сейчас играет» для topbar.
//
// Системный интерфейс MediaRemote закрыт для сторонних приложений (macOS 15.4+), но открыт процессам с идентификатором
// `com.apple.*`. Системный `/usr/bin/perl` — такой процесс, поэтому приложение запускает perl, тот загружает эту библиотеку и
// вызывает одну из функций ниже (`tb_now_playing_stream` — поток состояний в stdout строками JSON, `tb_now_playing_send` —
// одна команда плееру). Параметры команды — через переменные окружения.
//
// Приём неофициальный: Apple может закрыть его обновлением системы. Тогда помощник сообщает об ошибке (`{"error":...}`),
// а приложение прячет плеер.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>

#define EXPORT __attribute__((visibility("default")))

typedef void (^TBInfoHandler)(CFDictionaryRef info);
typedef void (^TBBoolHandler)(Boolean value);
typedef void (^TBIntHandler)(int value);

static void (*MRRegister)(dispatch_queue_t);
static void (*MRGetInfo)(dispatch_queue_t, TBInfoHandler);
static void (*MRGetIsPlaying)(dispatch_queue_t, TBBoolHandler);
static void (*MRGetPID)(dispatch_queue_t, TBIntHandler);
static Boolean (*MRSendCommand)(int, id);
static void (*MRSetElapsed)(double);

static dispatch_queue_t queue;
static dispatch_source_t timer;
static NSDictionary *lastState;
static NSUInteger lastArtworkHash;
static BOOL emitScheduled;
static BOOL queryInFlight;

static BOOL loadMediaRemote(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!handle) return NO;
    MRRegister = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    MRGetInfo = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
    MRGetIsPlaying = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRGetPID = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
    MRSendCommand = dlsym(handle, "MRMediaRemoteSendCommand");
    MRSetElapsed = dlsym(handle, "MRMediaRemoteSetElapsedTime");
    return MRRegister && MRGetInfo && MRGetIsPlaying;
}

static void printLine(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static NSNumber *number(id value) {
    if (![value isKindOfClass:[NSNumber class]]) return nil;
    double d = [value doubleValue];
    return (isnan(d) || isinf(d)) ? nil : value;
}

static void put(NSMutableDictionary *dict, NSString *key, id value) {
    if (value) dict[key] = value;
}

/// Собрать и выдать состояние, если оно изменилось. Обложка уходит только вместе с новой обложкой (она тяжёлая).
static void emitState(NSDictionary *info, BOOL playing, int pid) {
    NSString *title = [info[@"kMRMediaRemoteNowPlayingInfoTitle"] isKindOfClass:[NSString class]] ? info[@"kMRMediaRemoteNowPlayingInfoTitle"] : nil;
    NSMutableDictionary *state = [NSMutableDictionary new];
    if (title.length == 0) {
        state[@"none"] = @YES;
    } else {
        state[@"playing"] = @(playing);
        state[@"pid"] = @(pid);
        state[@"title"] = title;
        put(state, @"artist", [info[@"kMRMediaRemoteNowPlayingInfoArtist"] isKindOfClass:[NSString class]] ? info[@"kMRMediaRemoteNowPlayingInfoArtist"] : nil);
        put(state, @"album", [info[@"kMRMediaRemoteNowPlayingInfoAlbum"] isKindOfClass:[NSString class]] ? info[@"kMRMediaRemoteNowPlayingInfoAlbum"] : nil);
        put(state, @"duration", number(info[@"kMRMediaRemoteNowPlayingInfoDuration"]));
        put(state, @"elapsed", number(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]));
        put(state, @"rate", number(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]));
        NSDate *stamp = [info[@"kMRMediaRemoteNowPlayingInfoTimestamp"] isKindOfClass:[NSDate class]] ? info[@"kMRMediaRemoteNowPlayingInfoTimestamp"] : nil;
        if (stamp) state[@"timestamp"] = @(stamp.timeIntervalSince1970);
    }
    if ([state isEqualToDictionary:lastState]) return;
    NSMutableDictionary *line = [state mutableCopy];
    NSData *art = [info[@"kMRMediaRemoteNowPlayingInfoArtworkData"] isKindOfClass:[NSData class]] ? info[@"kMRMediaRemoteNowPlayingInfoArtworkData"] : nil;
    NSUInteger hash = art ? art.hash : 0;
    if (hash != lastArtworkHash) {
        line[@"artwork"] = art ? [art base64EncodedStringWithOptions:0] : (id)[NSNull null];
        lastArtworkHash = hash;
    }
    lastState = state;
    printLine(line);
}

static void query(void) {
    if (queryInFlight) return;
    queryInFlight = YES;
    MRGetInfo(queue, ^(CFDictionaryRef info) {
        NSDictionary *infoCopy = (__bridge NSDictionary *)info;
        MRGetIsPlaying(queue, ^(Boolean playing) {
            void (^finish)(int) = ^(int pid) {
                emitState(infoCopy, playing, pid);
                queryInFlight = NO;
            };
            if (MRGetPID) MRGetPID(queue, finish); else finish(0);
        });
    });
}

static void scheduleQuery(void) {
    dispatch_async(queue, ^{
        if (emitScheduled) return;
        emitScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), queue, ^{
            emitScheduled = NO;
            query();
        });
    });
}

EXPORT void tb_now_playing_stream(void) {
    @autoreleasepool {
        if (!loadMediaRemote()) {
            printLine(@{@"error": @"MediaRemote не загрузился"});
            exit(2);
        }
        queue = dispatch_queue_create("dev.topbar.nowplaying", DISPATCH_QUEUE_SERIAL);
        MRRegister(queue);
        NSArray *names = @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"];
        for (NSString *name in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) { scheduleQuery(); }];
        }
        // Страховка: раз в 3 секунды сверяемся сами и выходим, если приложение, запустившее помощника, закрылось.
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            if (getppid() == 1) exit(0);
            query();
        });
        dispatch_resume(timer);
        scheduleQuery();
        [[NSRunLoop currentRunLoop] run];
    }
}

/// Одна команда плееру: `TB_COMMAND` — номер команды MediaRemote (0 играть, 1 пауза, 2 переключить, 4 дальше, 5 назад);
/// `TB_SEEK` — перемотать на столько секунд от начала.
EXPORT void tb_now_playing_send(void) {
    @autoreleasepool {
        if (!loadMediaRemote() || !MRSendCommand) {
            printLine(@{@"error": @"MediaRemote не загрузился"});
            exit(2);
        }
        const char *seek = getenv("TB_SEEK");
        if (seek && MRSetElapsed) {
            MRSetElapsed(atof(seek));
        } else {
            const char *command = getenv("TB_COMMAND");
            MRSendCommand(command ? atoi(command) : 2, nil);
        }
        // Команда уходит асинхронно — даём ей дойти.
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    }
}
