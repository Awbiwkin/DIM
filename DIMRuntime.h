// Общий код для настроек (Settings) и твика.
//
// Почему нужен отдельный файл: твик загружается в ЧУЖИЕ приложения (Telegram и т.д.),
// которые работают в песочнице и не могут надёжно читать NSUserDefaults другого домена.
// Поэтому менеджер после каждого изменения записывает маленький "runtime" plist
// с обычным путём, а твик читает только его (быстро и без огромного каталога устройств).

#import <Foundation/Foundation.h>
#import <notify.h>
#import <stdint.h>

#define DIM_RUNTIME_PATH @"/var/mobile/Library/Preferences/com.dim.manager.runtime.plist"

// FNV-1a 64 бит: используется для проверки "что реально видит приложение".
static inline uint64_t DIMFNV1a(const char *string) {
    uint64_t hash = 1469598103934665603ULL;

    while (string && *string) {
        hash ^= (uint8_t)*string++;
        hash *= 1099511628211ULL;
    }

    return hash;
}

// Менеджер -> runtime plist. Вызывается после любого изменения настроек.
static inline void DIMWriteRuntime(NSUserDefaults *prefs) {
    if (!prefs) return;

    NSMutableDictionary *config = [NSMutableDictionary dictionary];

    config[@"Enabled"] =
        @([prefs objectForKey:@"Enabled"] ? [prefs boolForKey:@"Enabled"] : YES);
    config[@"DeviceEnabled"] = @([prefs boolForKey:@"DeviceEnabled"]);
    config[@"Global"] = @([prefs boolForKey:@"GlobalProfileEnabled"]);
    config[@"OnlyIn"] = @([prefs boolForKey:@"OnlyInEnabled"]);

    NSArray *apps = [prefs arrayForKey:@"SelectedApps"];
    config[@"Apps"] = [apps isKindOfClass:[NSArray class]] ? apps : @[];

    NSDictionary *profile = [prefs dictionaryForKey:@"ActiveProfile"];
    config[@"Profile"] = [profile isKindOfClass:[NSDictionary class]] ? profile : @{};

    [config writeToFile:DIM_RUNTIME_PATH atomically:YES];
}
